//! porthole-agent: Linux agent for Porthole.
//!
//! Captures the desktop (US-001, wlr-screencopy on Wayland), hardware-encodes
//! it (US-002), streams it to a Mac client over LAN (US-003), injects the
//! client's pointer and keyboard input (US-006), and announces itself via
//! mDNS with a thumbnail endpoint for the picker (US-007a). The pipeline
//! reports its own encode latency once per second, on the log line and as
//! an `agent_stats` control message, so the client can split its
//! glass-to-glass number into encode and transport. It also streams desktop
//! audio (US-009, Opus over UDP) and syncs the clipboard both ways (US-008)
//! while a client is connected.

mod audio;
mod capture;
mod clipboard;
mod config;
mod desktop_bar;
mod discovery;
mod encode;
mod gamepad;
mod input;
mod subprocess;
mod transfer;
mod transport;
mod virtual_display;

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::Context;
use clap::Parser;
use tracing_subscriber::EnvFilter;

use encode::Codec;

/// Heartbeat interval while the agent idles (pre-capture scaffold behavior).
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(5);
/// Gaming clients request an immediate IDR on join or loss. Keeping routine
/// IDRs sparse avoids a multi-hundred-datagram burst every two seconds while
/// retaining a periodic safety net if a control request is ever missed.
const GAMING_KEYFRAME_INTERVAL_SECS: u32 = 300;
/// Avoid hammering Hyprland or the capture portal when a live display
/// reconfiguration fails transiently. A newer client request bypasses the
/// delay so the latest viewport is still applied immediately.
const DISPLAY_RECONFIG_RETRY_INTERVAL: Duration = Duration::from_millis(500);

/// Porthole Linux agent: screen capture, NVENC encode, LAN streaming.
#[derive(Debug, Parser)]
#[command(name = "porthole-agent", version, about)]
struct Cli {
    /// Path to a TOML config file. Optional; CLI flags override file values.
    #[arg(long, value_name = "PATH")]
    config: Option<PathBuf>,

    /// UDP port for the video stream [default: 52800]
    #[arg(long, value_name = "PORT")]
    port_video: Option<u16>,

    /// TCP port for the control channel [default: 52801]
    #[arg(long, value_name = "PORT")]
    port_control: Option<u16>,

    /// UDP port for the audio stream [default: 52802]
    #[arg(long, value_name = "PORT")]
    port_audio: Option<u16>,

    /// TCP port for the thumbnail endpoint [default: 52803]
    #[arg(long, value_name = "PORT")]
    port_thumbnail: Option<u16>,

    /// Machine name announced via mDNS and shown in the picker
    /// [default: system hostname]
    #[arg(long, value_name = "NAME")]
    name: Option<String>,

    /// NVENC target bitrate in Mbps [default: 40]
    #[arg(long, value_name = "MBPS")]
    bitrate_mbps: Option<u32>,

    /// Video codec [default: h264]
    #[arg(long, value_enum)]
    codec: Option<Codec>,

    /// Hardware encoder backend: nvenc, vaapi, or GPU-resident portal capture
    /// via gpu-screen-recorder (`gsr`) [default: nvenc]
    #[arg(long, value_enum)]
    encoder: Option<encode::EncoderBackend>,

    /// Stream framerate (60, 120, 144, 180, or 288) [default: 60]
    #[arg(long, value_name = "FPS")]
    fps: Option<config::Fps>,

    /// Keyframe (IDR) interval in seconds [default: 2]
    #[arg(long, value_name = "SECS")]
    keyframe_interval_secs: Option<u32>,

    /// Virtual display geometry for headless operation, e.g. 2560x1440@144.
    /// When set and no physical monitor is attached, a Hyprland headless
    /// output at this geometry is created and captured (US-015).
    #[arg(long, value_name = "WxH@HZ")]
    virtual_display: Option<config::VirtualDisplay>,

    /// Path MTU the video datagrams are sized for (576 to 9000). The default
    /// fits the IPv6 minimum and WireGuard/Tailscale tunnels; use 1500 on
    /// plain Ethernet [default: 1280]
    #[arg(long, value_name = "BYTES")]
    mtu: Option<config::Mtu>,

    /// DRM render node for the VAAPI encoder, e.g. /dev/dri/renderD129
    /// [default: auto-detect, preferring amdgpu, i915, xe; never nvidia]
    #[arg(long, value_name = "PATH")]
    vaapi_device: Option<PathBuf>,

    /// Portal restore-token file for the `gsr` backend
    #[arg(long, value_name = "PATH")]
    gsr_restore_token: Option<PathBuf>,

    /// TCP port for the file-transfer endpoint [default: 52804]
    #[arg(long, value_name = "PORT")]
    port_files: Option<u16>,

    /// Folder dragged files are written to [default: ~/Downloads]
    #[arg(long, value_name = "PATH")]
    transfer_dir: Option<PathBuf>,
}

impl Cli {
    /// Apply CLI overrides on top of defaults + config file values.
    fn apply_overrides(&self, cfg: &mut config::Config) {
        if let Some(v) = self.port_video {
            cfg.port_video = v;
        }
        if let Some(v) = self.port_control {
            cfg.port_control = v;
        }
        if let Some(v) = self.port_audio {
            cfg.port_audio = v;
        }
        if let Some(v) = self.port_thumbnail {
            cfg.port_thumbnail = v;
        }
        if let Some(v) = &self.name {
            cfg.name = v.clone();
        }
        if let Some(v) = self.bitrate_mbps {
            cfg.bitrate_mbps = v;
        }
        if let Some(v) = self.codec {
            cfg.codec = v;
        }
        if let Some(v) = self.encoder {
            cfg.encoder = v;
        }
        if let Some(v) = self.fps {
            cfg.fps = v;
        }
        if let Some(v) = self.keyframe_interval_secs {
            cfg.keyframe_interval_secs = v.max(1);
        }
        if let Some(v) = self.virtual_display {
            cfg.virtual_display = Some(v);
        }
        if let Some(v) = self.mtu {
            cfg.mtu = v;
        }
        if let Some(v) = &self.vaapi_device {
            cfg.vaapi_device = Some(v.clone());
        }
        if let Some(v) = &self.gsr_restore_token {
            cfg.gsr_restore_token = Some(v.clone());
        }
        if let Some(v) = self.port_files {
            cfg.port_files = v;
        }
        if let Some(v) = &self.transfer_dir {
            cfg.transfer_dir = Some(v.clone());
        }
    }
}

fn init_tracing() {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();
}

/// Frame pipeline loop, run on a blocking thread: capture, feed the encoder
/// paced at the configured stream fps (capture itself can run faster, e.g.
/// 144 Hz on the headless output), drain encoded access units, fragment and
/// send them to the connected client. Handles control events: client
/// connect/disconnect and keyframe requests (answered in process when the
/// backend supports it, with a session restart fallback, FR-4). Logs a once-per-second
/// stats line for capture, encode, and transmit together, and sends the
/// same numbers to the client as `agent_stats` while one is connected.
/// Build the hello a client receives on connect and after a settings change
/// (US-013): codec, bitrate, and framerate come from the live config, the
/// geometry from the captured output.
fn hello_for(
    cfg: &config::Config,
    format: &capture::CaptureFormat,
) -> porthole_agent::protocol::Hello {
    porthole_agent::protocol::Hello {
        codec: match cfg.codec {
            Codec::H264 => porthole_agent::protocol::CodecTag::H264,
            Codec::Hevc => porthole_agent::protocol::CodecTag::Hevc,
        },
        width: format.width,
        height: format.height,
        fps: u32::from(cfg.fps.get()),
        bitrate_mbps: cfg.bitrate_mbps,
        keyframe_interval_secs: cfg.keyframe_interval_secs,
        video_port: cfg.port_video,
    }
}

/// One compositor frame and the pipeline timestamp taken immediately after
/// Wayland reports it ready.
struct CapturedFrame {
    frame: capture::RawFrame,
    captured_us: u64,
}

/// Single-slot handoff from blocking Wayland capture to encode/transport.
/// Replacing the slot makes overload explicitly newest-frame-wins instead of
/// allowing old screen contents to build latency in a queue.
struct CaptureMailbox {
    slot: Mutex<Option<CapturedFrame>>,
    ready: Condvar,
    format: Mutex<capture::CaptureFormat>,
    captured: AtomicU64,
    replaced: AtomicU64,
    done: AtomicBool,
}

impl CaptureMailbox {
    fn new(format: capture::CaptureFormat) -> Self {
        Self {
            slot: Mutex::new(None),
            ready: Condvar::new(),
            format: Mutex::new(format),
            captured: AtomicU64::new(0),
            replaced: AtomicU64::new(0),
            done: AtomicBool::new(false),
        }
    }

    fn publish(&self, captured: CapturedFrame) {
        self.captured.fetch_add(1, Ordering::Relaxed);
        let mut slot = self.slot.lock().expect("capture mailbox poisoned");
        if slot.replace(captured).is_some() {
            self.replaced.fetch_add(1, Ordering::Relaxed);
        }
        self.ready.notify_one();
    }

    fn take_timeout(&self, timeout: Duration) -> Option<CapturedFrame> {
        let mut slot = self.slot.lock().expect("capture mailbox poisoned");
        if slot.is_none() && !self.done.load(Ordering::Acquire) {
            slot = self
                .ready
                .wait_timeout(slot, timeout)
                .expect("capture mailbox poisoned while waiting")
                .0;
        }
        slot.take()
    }

    fn discard_pending(&self) {
        self.slot.lock().expect("capture mailbox poisoned").take();
    }

    fn finish(&self) {
        self.done.store(true, Ordering::Release);
        self.ready.notify_all();
    }

    fn is_done_and_empty(&self) -> bool {
        self.done.load(Ordering::Acquire)
            && self
                .slot
                .lock()
                .expect("capture mailbox poisoned")
                .is_none()
    }

    fn update_format(&self, format: capture::CaptureFormat) {
        *self.format.lock().expect("capture format poisoned") = format;
    }

    /// Prepare the same bounded mailbox for a new capture generation after
    /// the previous producer has stopped and joined.
    fn reset(&self, format: capture::CaptureFormat) {
        self.slot.lock().expect("capture mailbox poisoned").take();
        self.update_format(format);
        self.captured.store(0, Ordering::Relaxed);
        self.replaced.store(0, Ordering::Relaxed);
        self.done.store(false, Ordering::Release);
        self.ready.notify_all();
    }

    fn format(&self) -> capture::CaptureFormat {
        self.format.lock().expect("capture format poisoned").clone()
    }

    fn take_window_counts(&self) -> (u64, u64) {
        (
            self.captured.swap(0, Ordering::Relaxed),
            self.replaced.swap(0, Ordering::Relaxed),
        )
    }
}

struct CaptureProducer {
    stop: Arc<AtomicBool>,
    handle: thread::JoinHandle<()>,
}

impl CaptureProducer {
    fn stop(self, mailbox: &CaptureMailbox) {
        self.stop.store(true, Ordering::Release);
        mailbox.ready.notify_all();
        let _ = self.handle.join();
    }
}

fn spawn_capture_producer(
    mut backend: Box<dyn capture::CaptureBackend>,
    mailbox: Arc<CaptureMailbox>,
    latest_frame: discovery::LatestFrame,
    pipeline_start: Instant,
    raw_capture_enabled: Arc<AtomicBool>,
    shutdown: Arc<AtomicBool>,
) -> std::io::Result<CaptureProducer> {
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = stop.clone();
    let handle = thread::Builder::new()
        .name("wayland-capture".into())
        .spawn(move || {
            let mut sequence = 0u64;
            let mut has_thumbnail = false;
            while !shutdown.load(Ordering::Relaxed) && !thread_stop.load(Ordering::Acquire) {
                let publish_video = raw_capture_enabled.load(Ordering::Acquire);
                // A capture-owning encoder imports compositor dma-bufs itself.
                // Keep one startup frame for the picker, then avoid every SHM
                // readback until a raw-frame encoder is selected again.
                if !publish_video && has_thumbnail {
                    thread::sleep(Duration::from_millis(10));
                    continue;
                }
                let frame = match backend.next_frame() {
                    Ok(frame) => frame,
                    Err(err) => {
                        tracing::error!("{err:#}: capture frame failed, stopping capture producer");
                        break;
                    }
                };
                let captured_us = pipeline_start.elapsed().as_micros() as u64;
                sequence += 1;

                // The negotiated pixel format becomes known with the first
                // frame. Geometry is stable for this capture session.
                if sequence == 1 {
                    mailbox.update_format(backend.format());
                }
                // Picker thumbnails need freshness, not every video frame.
                if !has_thumbnail || (publish_video && sequence % 30 == 1) {
                    *latest_frame.lock().expect("thumbnail slot poisoned") =
                        Some((frame.data.to_vec(), frame.width, frame.height, frame.stride));
                    has_thumbnail = true;
                }
                if publish_video {
                    mailbox.publish(CapturedFrame { frame, captured_us });
                }
            }
            mailbox.finish();
        })?;
    Ok(CaptureProducer { stop, handle })
}

fn rebuild_encoder(
    encoder: &mut Box<dyn encode::Encoder>,
    cfg: &config::Config,
    format: &capture::CaptureFormat,
    raw_capture_enabled: &AtomicBool,
    mailbox: &CaptureMailbox,
) {
    // Portal restore tokens cannot be opened by two simultaneous GSR
    // sessions. Drop the old child before constructing its replacement.
    // Temporarily resume raw capture so the NVENC fallback is ready without
    // waiting for another compositor tick if GSR startup fails.
    raw_capture_enabled.store(true, Ordering::Release);
    let placeholder: Box<dyn encode::Encoder> =
        Box::new(encode::NullEncoder::new(cfg.codec, cfg.encoder));
    drop(std::mem::replace(encoder, placeholder));
    *encoder = encode::create(cfg, format);

    let needs_raw_frames = encoder.needs_raw_frames();
    raw_capture_enabled.store(needs_raw_frames, Ordering::Release);
    if !needs_raw_frames {
        mailbox.discard_pending();
    }
}

/// Recreate every resource bound to the virtual output after its geometry or
/// refresh changes. The old producer is joined before the mailbox generation
/// is reset, so a late `finish` can never terminate the new pipeline.
#[allow(clippy::too_many_arguments)]
fn rebuild_capture_pipeline(
    encoder: &mut Box<dyn encode::Encoder>,
    cfg: &config::Config,
    preferred_output: &str,
    capture_format: &mut capture::CaptureFormat,
    capture_backend: &mut String,
    producer: &mut Option<CaptureProducer>,
    mailbox: &Arc<CaptureMailbox>,
    latest_frame: &discovery::LatestFrame,
    pipeline_start: Instant,
    raw_capture_enabled: &Arc<AtomicBool>,
    shutdown: &Arc<AtomicBool>,
) -> bool {
    let restart_start = Instant::now();
    raw_capture_enabled.store(true, Ordering::Release);
    let placeholder: Box<dyn encode::Encoder> =
        Box::new(encode::NullEncoder::new(cfg.codec, cfg.encoder));
    drop(std::mem::replace(encoder, placeholder));
    if let Some(old) = producer.take() {
        old.stop(mailbox);
    }

    let backend = capture::select_backend(Some(preferred_output));
    let format = backend.format();
    if format.width == 0 || format.height == 0 {
        tracing::error!(
            output = preferred_output,
            "capture backend unavailable after display reconfigure"
        );
        return false;
    }
    *capture_backend = backend.name().to_string();
    *capture_format = format.clone();
    mailbox.reset(format.clone());
    *latest_frame.lock().expect("thumbnail slot poisoned") = None;

    *encoder = encode::create(cfg, &format);
    let needs_raw_frames = encoder.needs_raw_frames();
    raw_capture_enabled.store(needs_raw_frames, Ordering::Release);
    match spawn_capture_producer(
        backend,
        mailbox.clone(),
        latest_frame.clone(),
        pipeline_start,
        raw_capture_enabled.clone(),
        shutdown.clone(),
    ) {
        Ok(new_producer) => *producer = Some(new_producer),
        Err(err) => {
            tracing::error!(%err, "failed to restart Wayland capture thread");
            return false;
        }
    }
    tracing::info!(
        output = preferred_output,
        resolution = format!("{}x{}", format.width, format.height),
        restart_ms = restart_start.elapsed().as_millis(),
        "capture pipeline rebuilt for display mode"
    );
    true
}

#[allow(clippy::too_many_arguments)]
fn capture_loop(
    backend: Box<dyn capture::CaptureBackend>,
    mut encoder: Box<dyn encode::Encoder>,
    mut cfg: config::Config,
    mut capture_format: capture::CaptureFormat,
    mut sender: transport::VideoSender,
    events: std::sync::mpsc::Receiver<transport::ControlEvent>,
    control: transport::ControlSender,
    audio: Option<audio::AudioHandle>,
    latest_frame: discovery::LatestFrame,
    input_geometry: input::InputGeometry,
    pipeline_start: Instant,
    shutdown: Arc<AtomicBool>,
) {
    let mut capture_backend = backend.name().to_string();
    let mailbox = Arc::new(CaptureMailbox::new(capture_format.clone()));
    let raw_capture_enabled = Arc::new(AtomicBool::new(encoder.needs_raw_frames()));
    let mut capture_producer = match spawn_capture_producer(
        backend,
        mailbox.clone(),
        latest_frame.clone(),
        pipeline_start,
        raw_capture_enabled.clone(),
        shutdown.clone(),
    ) {
        Ok(producer) => Some(producer),
        Err(err) => {
            tracing::error!(%err, "failed to start Wayland capture thread");
            return;
        }
    };
    // Recomputed whenever a settings message (US-013) changes the framerate.
    let mut frame_interval = Duration::from_secs_f64(1.0 / f64::from(cfg.fps.get()));
    let quality_keyframe_interval_secs = cfg.keyframe_interval_secs;
    // Accumulating deadline: captures arrive quantized to the compositor's
    // frame tick (e.g. 6.9ms at 144 Hz), so checking elapsed >= interval
    // would under-feed (45 fps at 60 target). Track the schedule instead.
    let mut next_submit = Instant::now();
    // Submitted frames, FIFO: our encoders emit AUs in submission order (no
    // B-frame reordering at these settings), so the nth drained AU pairs with
    // the nth capture. Keeping the frame here also holds a leased Wayland
    // mapping until FFmpeg has consumed it; this makes memfd-to-pipe splice
    // safe while still allowing the capture thread to use another pool slot.
    let mut pending_frames: std::collections::VecDeque<(u64, capture::RawFrame)> =
        std::collections::VecDeque::new();
    // Debug aid: PORTHOLE_DUMP_VIDEO=<path> writes the encoded Annex B
    // stream to a file (used to ffprobe-verify encoder output).
    let mut dump: Option<std::io::BufWriter<std::fs::File>> = std::env::var_os(
        "PORTHOLE_DUMP_VIDEO",
    )
    .and_then(|path| match std::fs::File::create(&path) {
        Ok(f) => {
            tracing::info!(path = %std::path::Path::new(&path).display(), "dumping encoded stream");
            Some(std::io::BufWriter::new(f))
        }
        Err(err) => {
            tracing::error!(%err, "cannot open PORTHOLE_DUMP_VIDEO file");
            None
        }
    });
    let mut submitted = 0u64;
    let mut encoded = 0u64;
    let mut encoded_bytes = 0u64;
    let mut keyframes = 0u64;
    let mut submit_ms_total = 0.0f64;
    // Capture-to-access-unit latency, summed over the AUs whose capture
    // time is known (an encoder restart clears the FIFO, so the first few
    // AUs afterwards have none and are left out of the mean). The capture
    // stamp is taken before the frame is written to the encoder, so the
    // pipe write counts as encode time; the client subtracts the same stamp
    // from its arrival and present times, so nothing falls between the two.
    let mut enc_latency_us_total = 0u64;
    let mut enc_latency_samples = 0u64;
    // Once the reader has a complete AU, it should reach packetization
    // immediately rather than waiting behind the next compositor capture.
    let mut ready_wait_us_total = 0u64;
    let mut send_us_total = 0u64;
    let mut send_samples = 0u64;
    // Generation of the client video goes to. A replaced connection's
    // reader reports its disconnect after the new client connected; the
    // generation tells that stale event apart from a real disconnect.
    let mut client_generation: Option<u64> = None;
    // Keep the requested geometry separate from the last geometry whose
    // capture pipeline was rebuilt successfully. That lets a transient
    // Hyprland/portal failure recover without waiting for the client to send
    // the same resize again.
    let mut desired_display = cfg.virtual_display;
    let mut next_display_retry = Instant::now();
    let mut window_start = Instant::now();
    while !shutdown.load(Ordering::Relaxed) {
        // Settings and display-size frames are adjacent on the same TCP
        // stream. Retain only the newest of each while draining this turn so
        // one UI action causes at most one capture/encoder rebuild.
        let mut requested_settings = None;
        let mut requested_resize = None;
        let mut keyframe_requested = false;
        for event in events.try_iter() {
            match event {
                transport::ControlEvent::ClientConnected { generation, ip } => {
                    sender.set_client(Some(ip));
                    if let Some(audio) = &audio {
                        audio.set_client(Some(ip));
                    }
                    client_generation = Some(generation);
                    tracing::info!(client = %sender.client().expect("just set"), generation, "streaming video to client");
                }
                transport::ControlEvent::ClientDisconnected { generation } => {
                    if client_generation.is_some_and(|current| generation < current) {
                        tracing::debug!(
                            generation,
                            "stale disconnect for a replaced client, ignored"
                        );
                        continue;
                    }
                    sender.set_client(None);
                    if let Some(audio) = &audio {
                        audio.set_client(None);
                    }
                    client_generation = None;
                    tracing::info!(generation, "client gone, video paused");
                }
                transport::ControlEvent::KeyframeRequest => {
                    keyframe_requested = true;
                }
                transport::ControlEvent::Settings(settings) => {
                    requested_settings = Some(settings);
                }
                transport::ControlEvent::DisplayResize(resize) => {
                    requested_resize = Some(resize);
                }
            }
        }

        if let Some(settings) = requested_settings {
            if let Ok(fps) = config::Fps::new(settings.fps) {
                cfg.fps = fps;
                frame_interval = Duration::from_secs_f64(1.0 / f64::from(fps.get()));
            } else {
                tracing::warn!(
                    fps = settings.fps,
                    "settings: unsupported fps, keeping current"
                );
            }
            cfg.codec = match settings.codec {
                porthole_agent::protocol::CodecTag::H264 => encode::Codec::H264,
                porthole_agent::protocol::CodecTag::Hevc => encode::Codec::Hevc,
            };
            cfg.bitrate_mbps = u32::from(settings.bitrate_mbps).max(1);
            cfg.low_latency = settings.low_latency;
            cfg.keyframe_interval_secs = if settings.low_latency {
                GAMING_KEYFRAME_INTERVAL_SECS
            } else {
                quality_keyframe_interval_secs
            };
        }

        if requested_settings.is_some() || requested_resize.is_some() {
            next_display_retry = Instant::now();
            if let Some(display) = desired_display.as_mut() {
                // The headless output is the source clock; its refresh follows
                // the capture ceiling while its pixels follow the viewport.
                display.refresh_hz = u32::from(cfg.fps.get());
                if let Some(resize) = requested_resize {
                    display.width = resize.width;
                    display.height = resize.height;
                }
            } else if let Some(resize) = requested_resize {
                tracing::warn!(
                    width = resize.width,
                    height = resize.height,
                    "display resize ignored: agent does not own a virtual display"
                );
            }
        }

        let mut stream_reconfigured = false;
        if desired_display != cfg.virtual_display && Instant::now() >= next_display_retry {
            if let Some(output) = virtual_display::ensure(desired_display) {
                stream_reconfigured = rebuild_capture_pipeline(
                    &mut encoder,
                    &cfg,
                    &output,
                    &mut capture_format,
                    &mut capture_backend,
                    &mut capture_producer,
                    &mailbox,
                    &latest_frame,
                    pipeline_start,
                    &raw_capture_enabled,
                    &shutdown,
                );
                if stream_reconfigured {
                    cfg.virtual_display = desired_display;
                    input_geometry.update(capture_format.width, capture_format.height);
                } else {
                    next_display_retry = Instant::now() + DISPLAY_RECONFIG_RETRY_INTERVAL;
                }
            } else {
                tracing::warn!("virtual display reconfiguration was not applied");
                next_display_retry = Instant::now() + DISPLAY_RECONFIG_RETRY_INTERVAL;
            }
        }

        if requested_settings.is_some() && !stream_reconfigured {
            rebuild_encoder(
                &mut encoder,
                &cfg,
                &capture_format,
                &raw_capture_enabled,
                &mailbox,
            );
            stream_reconfigured = true;
        }

        if stream_reconfigured {
            pending_frames.clear();
            next_submit = Instant::now();
            let hello = hello_for(&cfg, &capture_format);
            control.update_hello(hello);
            control.try_send(porthole_agent::protocol::CONTROL_MSG_HELLO, &hello.encode());
            tracing::info!(
                resolution = format!("{}x{}", capture_format.width, capture_format.height),
                fps_cap = cfg.fps.get(),
                codec = %cfg.codec,
                bitrate_mbps = cfg.bitrate_mbps,
                keyframe_interval_secs = cfg.keyframe_interval_secs,
                low_latency = cfg.low_latency,
                "stream reconfigured"
            );
        } else if keyframe_requested {
            match encoder.request_keyframe() {
                Ok(()) => tracing::info!("encoder will emit an in-process keyframe"),
                Err(err) => {
                    let restart_start = Instant::now();
                    rebuild_encoder(
                        &mut encoder,
                        &cfg,
                        &capture_format,
                        &raw_capture_enabled,
                        &mailbox,
                    );
                    pending_frames.clear();
                    tracing::info!(
                        %err,
                        restart_ms = restart_start.elapsed().as_millis(),
                        "encoder restarted for keyframe request"
                    );
                }
            }
        }

        // Encoded output wins over the next capture. Only wait for a frame
        // when there is no AU ready to transmit, which prevents a blocking
        // 14.7 MB stdin write from getting in front of completed video.
        let mut access_units = encoder.drain();
        if access_units.is_empty() {
            if encoder.needs_raw_frames() {
                // Wait at most 100 us for a new capture. Short polling bounds
                // how long an AU that becomes ready meanwhile can sit before
                // transmit.
                let captured = mailbox.take_timeout(Duration::from_micros(100));
                if let Some(captured) = captured {
                    // Pace encoder submissions to the configured stream rate.
                    let now = Instant::now();
                    if now >= next_submit {
                        next_submit += frame_interval;
                        if next_submit < now {
                            // Way behind (stall); restart the schedule instead
                            // of bursting to catch up.
                            next_submit = now + frame_interval;
                        }
                        let submit_start = Instant::now();
                        if let Err(err) = encoder.encode(&captured.frame) {
                            tracing::error!(
                                "{err:#}: encoder submit failed, stopping capture loop"
                            );
                            break;
                        }
                        submit_ms_total += submit_start.elapsed().as_secs_f64() * 1000.0;
                        submitted += 1;
                        pending_frames.push_back((captured.captured_us, captured.frame));
                    }
                }
            } else {
                // GSR produces independently. Polling below a compositor tick
                // prevents its completed AU from waiting behind another frame.
                thread::sleep(Duration::from_micros(100));
            }
            // A previous frame can finish while the pipe write is in flight.
            access_units.extend(encoder.drain());
        }

        for au in access_units {
            if let Some(f) = dump.as_mut() {
                use std::io::Write;
                let _ = f.write_all(&au.data);
            }
            let ready_us = au
                .ready_at
                .saturating_duration_since(pipeline_start)
                .as_micros() as u64;
            let timestamp_us = if let Some(captured_at) = au.captured_at {
                let captured_us = captured_at
                    .saturating_duration_since(pipeline_start)
                    .as_micros() as u64;
                enc_latency_us_total += au
                    .ready_at
                    .saturating_duration_since(captured_at)
                    .as_micros() as u64;
                enc_latency_samples += 1;
                captured_us
            } else {
                match pending_frames.pop_front() {
                    Some((captured_us, _frame_lease)) => {
                        enc_latency_us_total += ready_us.saturating_sub(captured_us);
                        enc_latency_samples += 1;
                        captured_us
                    }
                    None => ready_us,
                }
            };
            let send_start = Instant::now();
            ready_wait_us_total += send_start
                .saturating_duration_since(au.ready_at)
                .as_micros() as u64;
            if let Err(err) = sender.send(&au, timestamp_us) {
                tracing::error!("{err:#}: video send failed");
            }
            send_us_total += send_start.elapsed().as_micros() as u64;
            send_samples += 1;
            encoded += 1;
            encoded_bytes += au.data.len() as u64;
            if au.is_keyframe {
                keyframes += 1;
                tracing::debug!(sequence = au.sequence, "keyframe encoded");
            }
        }

        let elapsed = window_start.elapsed();
        if elapsed >= Duration::from_secs(1) {
            let secs = elapsed.as_secs_f64();
            let format = mailbox.format();
            let (frames, capture_replaced) = mailbox.take_window_counts();
            let capture_owns_frames = !encoder.needs_raw_frames();
            let capture_frames = if capture_owns_frames { encoded } else { frames };
            let encoder_inputs = if capture_owns_frames {
                encoded
            } else {
                submitted
            };
            let active_capture_backend = if capture_owns_frames {
                "pipewire-dmabuf"
            } else {
                capture_backend.as_str()
            };
            let tx_kbps = sender.bytes_sent as f64 * 8.0 / secs / 1000.0;
            let tx_datagrams = sender.datagrams_sent as f64 / secs;
            let enc_latency_us = enc_latency_us_total / enc_latency_samples.max(1);
            sender.bytes_sent = 0;
            sender.datagrams_sent = 0;
            tracing::info!(
                backend = active_capture_backend,
                resolution = format!("{}x{}", format.width, format.height),
                stride = format.width as usize * 4,
                frame_bytes = format.width as usize * format.height as usize * 4,
                pixel_format = format.pixel_format.as_deref().unwrap_or("unknown"),
                fps = format!("{:.0}", capture_frames as f64 / secs),
                capture_replaced,
                enc_backend = %encoder.backend(),
                enc_codec = %encoder.codec(),
                enc_in = format!("{:.0}", encoder_inputs as f64 / secs),
                enc_out = format!("{:.0}", encoded as f64 / secs),
                enc_kbps = format!("{:.0}", encoded_bytes as f64 * 8.0 / secs / 1000.0),
                enc_keyframes = keyframes,
                enc_submit_ms = format!("{:.2}", submit_ms_total / submitted.max(1) as f64),
                enc_latency_ms = format!("{:.2}", enc_latency_us as f64 / 1000.0),
                enc_ready_wait_ms = format!("{:.3}", ready_wait_us_total as f64 / send_samples.max(1) as f64 / 1000.0),
                tx_frame_ms = format!("{:.3}", send_us_total as f64 / send_samples.max(1) as f64 / 1000.0),
                client = sender.client().map(|a| a.to_string()).unwrap_or_else(|| "none".into()),
                tx_kbps = format!("{tx_kbps:.0}"),
                tx_dgrams = format!("{tx_datagrams:.0}"),
                "capture"
            );
            if sender.client().is_some() {
                let stats = porthole_agent::protocol::AgentStats {
                    capture_fps: (capture_frames as f64 / secs).round() as u16,
                    encode_fps: (encoded as f64 / secs).round() as u16,
                    encode_latency_us: enc_latency_us.min(u64::from(u32::MAX)) as u32,
                    tx_kbps: tx_kbps.round() as u32,
                    keyframes: keyframes.min(u64::from(u16::MAX)) as u16,
                };
                control.try_send(
                    porthole_agent::protocol::CONTROL_MSG_AGENT_STATS,
                    &stats.encode(),
                );
            }
            submitted = 0;
            encoded = 0;
            encoded_bytes = 0;
            keyframes = 0;
            submit_ms_total = 0.0;
            enc_latency_us_total = 0;
            enc_latency_samples = 0;
            ready_wait_us_total = 0;
            send_us_total = 0;
            send_samples = 0;
            window_start = Instant::now();
        }

        if mailbox.is_done_and_empty() && pending_frames.is_empty() {
            break;
        }
    }
    shutdown.store(true, Ordering::Relaxed);
    mailbox.ready.notify_all();
    if let Some(producer) = capture_producer.take() {
        producer.stop(&mailbox);
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    init_tracing();

    let mut cfg = config::load(cli.config.as_deref()).context("failed to load configuration")?;
    cli.apply_overrides(&mut cfg);

    let backend = {
        // Before capture selection: make sure the session env is visible to
        // the Wayland client (SSH shells and minimal systemd units lack it),
        // then ensure the configured virtual display exists (US-015) so
        // capture can prefer it by name.
        virtual_display::ensure_session_env();
        let preferred_output = virtual_display::ensure(cfg.virtual_display);
        capture::select_backend(preferred_output.as_deref())
    };
    let capture_format = backend.format();

    tracing::info!(
        version = env!("CARGO_PKG_VERSION"),
        "porthole-agent starting"
    );
    tracing::info!(
        video_addr = %cfg.video_addr(),
        control_addr = %cfg.control_addr(),
        audio_addr = %cfg.audio_addr(),
        thumbnail_addr = %cfg.thumbnail_addr(),
        name = %cfg.name,
        bitrate_mbps = cfg.bitrate_mbps,
        codec = %cfg.codec,
        encoder = %cfg.encoder,
        fps = cfg.fps.get(),
        keyframe_interval_secs = cfg.keyframe_interval_secs,
        virtual_display = %cfg.virtual_display.map(|v| v.to_string()).unwrap_or_else(|| "off".into()),
        mtu = cfg.mtu.get(),
        vaapi_device = %cfg.vaapi_device.as_ref().map(|p| p.display().to_string()).unwrap_or_else(|| "auto".into()),
        gsr_restore_token = %cfg.gsr_restore_token.as_ref().map(|p| p.display().to_string()).unwrap_or_else(|| "unset".into()),
        capture_backend = backend.name(),
        "effective configuration"
    );
    if capture_format.width > 0 {
        tracing::info!(
            output = capture_format.output_name.as_deref().unwrap_or("unknown"),
            resolution = format!("{}x{}", capture_format.width, capture_format.height),
            refresh_hz = format!("{:.0}", capture_format.refresh_millihz as f64 / 1000.0),
            "capture backend negotiated"
        );
    } else {
        tracing::warn!("no capture backend available; running without capture");
    }

    // Spawn the capture/encode/transport pipeline on a blocking thread
    // (Wayland dispatch, ffmpeg stdin writes, and UDP sends are all
    // synchronous). Only when a real backend was found: the noop backend
    // errors immediately, and there is nothing to capture or stream.
    let capture = if capture_format.width > 0 {
        let hello = hello_for(&cfg, &capture_format);
        // The pipeline clock: video datagram timestamps and pong answers
        // both count microseconds from here.
        let pipeline_start = Instant::now();
        let (input_tx, input_geometry) = input::spawn(capture_format.width, capture_format.height);
        // US-008: clipboard sync. The control reader forwards text the client
        // copied through clip_tx; the clipboard module applies it and watches
        // the Linux clipboard, sending changes back over the control channel.
        let (clip_tx, clip_rx) = std::sync::mpsc::channel::<String>();
        // US-014: virtual gamepad. The control reader forwards gamepad state
        // to the uinput device.
        let gamepad_tx = gamepad::spawn();
        let (events, control) = transport::spawn_control_listener(
            &cfg,
            hello,
            input_tx,
            Some(clip_tx),
            gamepad_tx,
            pipeline_start,
        )
        .context("transport control channel startup failed")?;
        let clipboard = {
            let control = control.clone();
            clipboard::spawn(clip_rx, move |text| {
                control.try_send(
                    porthole_agent::protocol::CONTROL_MSG_CLIPBOARD,
                    &porthole_agent::protocol::Clipboard { text }.encode(),
                );
            })
        };
        let sender = transport::VideoSender::new(&cfg).context("transport video socket failed")?;
        // US-007a: discovery. The thumbnail endpoint shares the latest frame
        // through a slot; mDNS announces name/ports/caps.
        let latest_frame = discovery::LatestFrame::default();
        discovery::spawn_thumbnail_server(&cfg, latest_frame.clone())
            .context("thumbnail endpoint startup failed")?;
        // US-011: file drag and drop lands on its own TCP endpoint.
        transfer::spawn_file_server(&cfg).context("file transfer endpoint startup failed")?;
        let announcement = discovery::announce(&cfg);
        let encoder = encode::create(&cfg, &capture_format);
        // US-009: desktop audio, Opus over UDP. Its packets are stamped on
        // the pipeline clock; the epoch is how far into the pipeline audio
        // starts, so the first audio packet lines up with video.
        let audio = audio::spawn(cfg.port_audio, pipeline_start.elapsed().as_micros() as u64);
        let shutdown = Arc::new(AtomicBool::new(false));
        let handle = tokio::task::spawn_blocking({
            let shutdown = shutdown.clone();
            let cfg = cfg.clone();
            let capture_format = capture_format.clone();
            move || {
                capture_loop(
                    backend,
                    encoder,
                    cfg,
                    capture_format,
                    sender,
                    events,
                    control,
                    audio,
                    latest_frame,
                    input_geometry,
                    pipeline_start,
                    shutdown,
                )
            }
        });
        Some((handle, shutdown, announcement, clipboard))
    } else {
        None
    };

    let mut heartbeat = tokio::time::interval(HEARTBEAT_INTERVAL);
    heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            _ = heartbeat.tick() => {
                tracing::debug!("heartbeat: agent running");
            }
            result = tokio::signal::ctrl_c() => {
                match result {
                    Ok(()) => tracing::info!("received SIGINT, shutting down"),
                    Err(err) => tracing::warn!(%err, "failed to listen for SIGINT, shutting down"),
                }
                break;
            }
        }
    }

    if let Some((handle, shutdown, announcement, _clipboard)) = capture {
        shutdown.store(true, Ordering::Relaxed);
        // The capture thread finishes the in-flight frame, then exits.
        if tokio::time::timeout(Duration::from_secs(3), handle)
            .await
            .is_err()
        {
            tracing::warn!("capture thread did not stop within 3s, exiting anyway");
        }
        // Dropping the announcement unregisters the mDNS service. The
        // clipboard handle (_clipboard) drops with this block, ending its
        // watch and apply threads.
        drop(announcement);
        tracing::debug!("mDNS announcement withdrawn");
    }

    // The encoder drops with the capture thread: closing ffmpeg's stdin
    // flushes and exits the child.
    // TODO: close transport.
    tracing::info!("porthole-agent stopped cleanly");
    Ok(())
}

#[cfg(test)]
mod pipeline_tests {
    use super::*;

    fn captured(value: u8) -> CapturedFrame {
        CapturedFrame {
            frame: capture::RawFrame {
                width: 1,
                height: 1,
                stride: 4,
                data: vec![value; 4].into(),
            },
            captured_us: u64::from(value),
        }
    }

    #[test]
    fn capture_mailbox_replaces_old_frame_with_newest() {
        let mailbox = CaptureMailbox::new(capture::CaptureFormat::default());
        mailbox.publish(captured(1));
        mailbox.publish(captured(2));

        let newest = mailbox
            .take_timeout(Duration::ZERO)
            .expect("newest frame remains queued");
        assert_eq!(newest.captured_us, 2);
        assert_eq!(newest.frame.data.as_ref(), &[2; 4]);
        assert_eq!(mailbox.take_window_counts(), (2, 1));

        mailbox.finish();
        assert!(mailbox.is_done_and_empty());
    }

    #[test]
    fn capture_mailbox_reset_starts_a_fresh_generation() {
        let mailbox = CaptureMailbox::new(capture::CaptureFormat::default());
        mailbox.publish(captured(1));
        mailbox.finish();

        let format = capture::CaptureFormat {
            width: 1920,
            height: 1080,
            ..capture::CaptureFormat::default()
        };
        mailbox.reset(format);
        assert!(!mailbox.is_done_and_empty());
        assert!(mailbox.take_timeout(Duration::ZERO).is_none());
        assert_eq!(mailbox.take_window_counts(), (0, 0));
        assert_eq!(
            (mailbox.format().width, mailbox.format().height),
            (1920, 1080)
        );

        mailbox.publish(captured(2));
        assert_eq!(
            mailbox
                .take_timeout(Duration::ZERO)
                .expect("new generation frame")
                .captured_us,
            2
        );
    }
}
