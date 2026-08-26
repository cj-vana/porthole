//! porthole-agent: Linux agent for Porthole.
//!
//! Captures the desktop (US-001, wlr-screencopy on Wayland), hardware-encodes
//! it (US-002), streams it to a Mac client over LAN (US-003), injects the
//! client's pointer and keyboard input (US-006), and announces itself via
//! mDNS with a thumbnail endpoint for the picker (US-007a). The pipeline
//! reports its own encode latency once per second, on the log line and as
//! an `agent_stats` control message, so the client can split its
//! glass-to-glass number into encode and transport. Audio (US-009) is still
//! a trait stub.

mod audio;
mod capture;
mod config;
mod discovery;
mod encode;
mod input;
mod transport;
mod virtual_display;

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Context;
use clap::Parser;
use tracing_subscriber::EnvFilter;

use encode::Codec;

/// Heartbeat interval while the agent idles (pre-capture scaffold behavior).
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(5);

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

    /// Hardware encoder backend: nvenc on the NVIDIA dGPU, or vaapi on the
    /// Ryzen iGPU (keeps the dGPU free for gaming) [default: nvenc]
    #[arg(long, value_enum)]
    encoder: Option<encode::EncoderBackend>,

    /// Stream framerate (60, 120, or 144) [default: 60]
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
/// connect/disconnect and keyframe requests (answered by restarting the
/// encoder session, which yields a fresh IDR, FR-4). Logs a once-per-second
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

#[allow(clippy::too_many_arguments)]
fn capture_loop(
    mut backend: Box<dyn capture::CaptureBackend>,
    mut encoder: Box<dyn encode::Encoder>,
    mut cfg: config::Config,
    capture_format: capture::CaptureFormat,
    mut sender: transport::VideoSender,
    events: std::sync::mpsc::Receiver<transport::ControlEvent>,
    control: transport::ControlSender,
    audio: Option<audio::AudioHandle>,
    latest_frame: discovery::LatestFrame,
    pipeline_start: Instant,
    shutdown: Arc<AtomicBool>,
) {
    // Recomputed whenever a settings message (US-013) changes the framerate.
    let mut frame_interval = Duration::from_secs_f64(1.0 / f64::from(cfg.fps.get()));
    // Accumulating deadline: captures arrive quantized to the compositor's
    // frame tick (e.g. 6.9ms at 144 Hz), so checking elapsed >= interval
    // would under-feed (45 fps at 60 target). Track the schedule instead.
    let mut next_submit = Instant::now();
    // Capture instants of submitted frames, FIFO: our encoders emit AUs in
    // submission order (no B-frame reordering at these settings), so the nth
    // drained AU pairs with the nth submitted frame's capture time.
    let mut submitted_at: std::collections::VecDeque<u64> = std::collections::VecDeque::new();
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
    let mut frames = 0u64;
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
    // Generation of the client video goes to. A replaced connection's
    // reader reports its disconnect after the new client connected; the
    // generation tells that stale event apart from a real disconnect.
    let mut client_generation: Option<u64> = None;
    let mut window_start = Instant::now();
    while !shutdown.load(Ordering::Relaxed) {
        // Control channel events (client connect/disconnect, keyframe
        // requests) are handled between frames.
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
                    // FR-4: a subprocess ffmpeg cannot force an IDR
                    // mid-session, so restart the encoder; the new session
                    // starts with an IDR.
                    let restart_start = Instant::now();
                    encoder = encode::create(&cfg, &capture_format);
                    submitted_at.clear();
                    tracing::info!(
                        restart_ms = restart_start.elapsed().as_millis(),
                        "encoder restarted for keyframe request"
                    );
                }
                transport::ControlEvent::Settings(settings) => {
                    // US-013 gaming mode: apply the requested framerate, codec,
                    // bitrate, and latency bias, restart the encoder so the
                    // next access unit is a fresh IDR in the new codec, and
                    // send an updated hello. The client applies its own
                    // request immediately, so a dropped hello does not strand
                    // it on the old codec.
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
                    encoder = encode::create(&cfg, &capture_format);
                    submitted_at.clear();
                    next_submit = Instant::now();
                    let hello = hello_for(&cfg, &capture_format);
                    // Update both the connected client and the hello future
                    // clients receive, so a reconnect is not told the old codec.
                    control.update_hello(hello);
                    control.try_send(porthole_agent::protocol::CONTROL_MSG_HELLO, &hello.encode());
                    tracing::info!(
                        fps = cfg.fps.get(),
                        codec = %cfg.codec,
                        bitrate_mbps = cfg.bitrate_mbps,
                        low_latency = cfg.low_latency,
                        "stream reconfigured"
                    );
                }
            }
        }

        let frame = match backend.next_frame() {
            Ok(frame) => frame,
            Err(err) => {
                tracing::error!("{err:#}: capture frame failed, stopping capture loop");
                break;
            }
        };
        frames += 1;
        let captured_us = pipeline_start.elapsed().as_micros() as u64;

        // FR-10: share a recent frame with the thumbnail endpoint. Every
        // 30th frame is plenty fresh for a picker thumbnail.
        if frames % 30 == 1 {
            *latest_frame.lock().expect("thumbnail slot poisoned") =
                Some((frame.data.clone(), frame.width, frame.height, frame.stride));
        }

        // Pace encoder submissions to the configured stream rate.
        let now = Instant::now();
        if now >= next_submit {
            next_submit += frame_interval;
            if next_submit < now {
                // Way behind (stall); restart the schedule instead of
                // bursting to catch up.
                next_submit = now + frame_interval;
            }
            let submit_start = Instant::now();
            if let Err(err) = encoder.encode(&frame) {
                tracing::error!("{err:#}: encoder submit failed, stopping capture loop");
                break;
            }
            submit_ms_total += submit_start.elapsed().as_secs_f64() * 1000.0;
            submitted += 1;
            submitted_at.push_back(captured_us);
        }

        for au in encoder.drain() {
            if let Some(f) = dump.as_mut() {
                use std::io::Write;
                let _ = f.write_all(&au.data);
            }
            let ready_us = au
                .ready_at
                .saturating_duration_since(pipeline_start)
                .as_micros() as u64;
            let timestamp_us = match submitted_at.pop_front() {
                Some(captured_us) => {
                    enc_latency_us_total += ready_us.saturating_sub(captured_us);
                    enc_latency_samples += 1;
                    captured_us
                }
                None => ready_us,
            };
            if let Err(err) = sender.send(&au, timestamp_us) {
                tracing::error!("{err:#}: video send failed");
            }
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
            let format = backend.format();
            let tx_kbps = sender.bytes_sent as f64 * 8.0 / secs / 1000.0;
            let tx_datagrams = sender.datagrams_sent as f64 / secs;
            let enc_latency_us = enc_latency_us_total / enc_latency_samples.max(1);
            sender.bytes_sent = 0;
            sender.datagrams_sent = 0;
            tracing::info!(
                backend = backend.name(),
                resolution = format!("{}x{}", frame.width, frame.height),
                stride = frame.stride,
                frame_bytes = frame.data.len(),
                pixel_format = format.pixel_format.as_deref().unwrap_or("unknown"),
                fps = format!("{:.0}", frames as f64 / secs),
                enc_backend = %encoder.backend(),
                enc_codec = %encoder.codec(),
                enc_in = format!("{:.0}", submitted as f64 / secs),
                enc_out = format!("{:.0}", encoded as f64 / secs),
                enc_kbps = format!("{:.0}", encoded_bytes as f64 * 8.0 / secs / 1000.0),
                enc_keyframes = keyframes,
                enc_submit_ms = format!("{:.2}", submit_ms_total / submitted.max(1) as f64),
                enc_latency_ms = format!("{:.2}", enc_latency_us as f64 / 1000.0),
                client = sender.client().map(|a| a.to_string()).unwrap_or_else(|| "none".into()),
                tx_kbps = format!("{tx_kbps:.0}"),
                tx_dgrams = format!("{tx_datagrams:.0}"),
                "capture"
            );
            if sender.client().is_some() {
                let stats = porthole_agent::protocol::AgentStats {
                    capture_fps: (frames as f64 / secs).round() as u16,
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
            frames = 0;
            submitted = 0;
            encoded = 0;
            encoded_bytes = 0;
            keyframes = 0;
            submit_ms_total = 0.0;
            enc_latency_us_total = 0;
            enc_latency_samples = 0;
            window_start = Instant::now();
        }
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
        let input_tx = input::spawn(capture_format.width, capture_format.height);
        let (events, control) =
            transport::spawn_control_listener(&cfg, hello, input_tx, pipeline_start)
                .context("transport control channel startup failed")?;
        let sender = transport::VideoSender::new(&cfg).context("transport video socket failed")?;
        // US-007a: discovery. The thumbnail endpoint shares the latest frame
        // through a slot; mDNS announces name/ports/caps.
        let latest_frame = discovery::LatestFrame::default();
        discovery::spawn_thumbnail_server(&cfg, latest_frame.clone())
            .context("thumbnail endpoint startup failed")?;
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
                    pipeline_start,
                    shutdown,
                )
            }
        });
        Some((handle, shutdown, announcement))
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

    if let Some((handle, shutdown, announcement)) = capture {
        shutdown.store(true, Ordering::Relaxed);
        // The capture thread finishes the in-flight frame, then exits.
        if tokio::time::timeout(Duration::from_secs(3), handle)
            .await
            .is_err()
        {
            tracing::warn!("capture thread did not stop within 3s, exiting anyway");
        }
        // Dropping the announcement unregisters the mDNS service.
        drop(announcement);
        tracing::debug!("mDNS announcement withdrawn");
    }

    // The encoder drops with the capture thread: closing ffmpeg's stdin
    // flushes and exits the child.
    // TODO: close transport.
    tracing::info!("porthole-agent stopped cleanly");
    Ok(())
}
