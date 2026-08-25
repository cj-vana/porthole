//! porthole-agent: Linux agent for Porthole.
//!
//! Captures the desktop (US-001, wlr-screencopy on Wayland), hardware-encodes
//! it, and streams it to a Mac client over LAN. Encode (US-002), transport
//! (US-003), input (US-006), and audio (US-009) are still trait stubs.

// These modules hold trait stubs for later stories (US-002, US-003, US-006,
// US-009) that are not wired into the runtime yet. Remove each allow as the
// corresponding story lands.
#[allow(dead_code)]
mod audio;
mod capture;
mod config;
mod encode;
#[allow(dead_code)]
mod input;
#[allow(dead_code)]
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
/// 144 Hz on the headless output), drain encoded access units. Logs a
/// once-per-second stats line for capture and encode together. The drained
/// AUs are dropped for now; the transport (US-003) will consume them.
fn capture_loop(
    mut backend: Box<dyn capture::CaptureBackend>,
    mut encoder: Box<dyn encode::Encoder>,
    stream_fps: u16,
    shutdown: Arc<AtomicBool>,
) {
    let frame_interval = Duration::from_secs_f64(1.0 / f64::from(stream_fps));
    // Accumulating deadline: captures arrive quantized to the compositor's
    // frame tick (e.g. 6.9ms at 144 Hz), so checking elapsed >= interval
    // would under-feed (45 fps at 60 target). Track the schedule instead.
    let mut next_submit = Instant::now();
    // Debug aid: PORTHOLE_DUMP_VIDEO=<path> writes the encoded Annex B
    // stream to a file (used to ffprobe-verify encoder output).
    let mut dump: Option<std::io::BufWriter<std::fs::File>> =
        std::env::var_os("PORTHOLE_DUMP_VIDEO").and_then(|path| {
            match std::fs::File::create(&path) {
                Ok(f) => {
                    tracing::info!(path = %std::path::Path::new(&path).display(), "dumping encoded stream");
                    Some(std::io::BufWriter::new(f))
                }
                Err(err) => {
                    tracing::error!(%err, "cannot open PORTHOLE_DUMP_VIDEO file");
                    None
                }
            }
        });
    let mut frames = 0u64;
    let mut submitted = 0u64;
    let mut encoded = 0u64;
    let mut encoded_bytes = 0u64;
    let mut keyframes = 0u64;
    let mut submit_ms_total = 0.0f64;
    let mut window_start = Instant::now();
    while !shutdown.load(Ordering::Relaxed) {
        let frame = match backend.next_frame() {
            Ok(frame) => frame,
            Err(err) => {
                tracing::error!("{err:#}: capture frame failed, stopping capture loop");
                break;
            }
        };
        frames += 1;

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
        }

        for au in encoder.drain() {
            // TODO(US-003): hand `au` to the transport for packetization.
            if let Some(f) = dump.as_mut() {
                use std::io::Write;
                let _ = f.write_all(&au.data);
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
                "capture"
            );
            frames = 0;
            submitted = 0;
            encoded = 0;
            encoded_bytes = 0;
            keyframes = 0;
            submit_ms_total = 0.0;
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

    tracing::info!(version = env!("CARGO_PKG_VERSION"), "porthole-agent starting");
    tracing::info!(
        video_addr = %cfg.video_addr(),
        control_addr = %cfg.control_addr(),
        audio_addr = %cfg.audio_addr(),
        bitrate_mbps = cfg.bitrate_mbps,
        codec = %cfg.codec,
        encoder = %cfg.encoder,
        fps = cfg.fps.get(),
        keyframe_interval_secs = cfg.keyframe_interval_secs,
        virtual_display = %cfg.virtual_display.map(|v| v.to_string()).unwrap_or_else(|| "off".into()),
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

    // Spawn the capture/encode pipeline on a blocking thread (Wayland
    // dispatch and ffmpeg stdin writes are synchronous). Only when a real
    // backend was found: the noop backend errors immediately, and there is
    // nothing to capture.
    let capture = if capture_format.width > 0 {
        let encoder = encode::create(&cfg, &capture_format);
        let shutdown = Arc::new(AtomicBool::new(false));
        let handle = tokio::task::spawn_blocking({
            let shutdown = shutdown.clone();
            move || capture_loop(backend, encoder, cfg.fps.get(), shutdown)
        });
        Some((handle, shutdown))
    } else {
        None
    };

    // TODO(US-003): stream the encoded frames, plus the TCP control
    // listener, audio task (US-009), input injection (US-006), and mDNS
    // announcement (US-007). Each joins the ctrl-c shutdown path.
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

    if let Some((handle, shutdown)) = capture {
        shutdown.store(true, Ordering::Relaxed);
        // The capture thread finishes the in-flight frame, then exits.
        if tokio::time::timeout(Duration::from_secs(3), handle).await.is_err() {
            tracing::warn!("capture thread did not stop within 3s, exiting anyway");
        }
    }

    // The encoder drops with the capture thread: closing ffmpeg's stdin
    // flushes and exits the child.
    // TODO: close transport, release uinput devices.
    tracing::info!("porthole-agent stopped cleanly");
    Ok(())
}
