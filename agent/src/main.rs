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
#[allow(dead_code)]
mod encode;
#[allow(dead_code)]
mod input;
#[allow(dead_code)]
mod transport;

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
    }
}

fn init_tracing() {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();
}

/// Frame-grab loop, run on a blocking thread. Logs a once-per-second line
/// with resolution, pixel format, backend, and measured fps. Encode and
/// transport plug in here in US-002/US-003.
fn capture_loop(mut backend: Box<dyn capture::CaptureBackend>, shutdown: Arc<AtomicBool>) {
    let mut frames = 0u64;
    let mut window_start = Instant::now();
    while !shutdown.load(Ordering::Relaxed) {
        match backend.next_frame() {
            Ok(frame) => {
                frames += 1;
                let elapsed = window_start.elapsed();
                if elapsed >= Duration::from_secs(1) {
                    let fps = frames as f64 / elapsed.as_secs_f64();
                    let format = backend.format();
                    tracing::info!(
                        backend = backend.name(),
                        resolution = format!("{}x{}", frame.width, frame.height),
                        stride = frame.stride,
                        frame_bytes = frame.data.len(),
                        pixel_format = format.pixel_format.as_deref().unwrap_or("unknown"),
                        fps = format!("{fps:.0}"),
                        "capture"
                    );
                    frames = 0;
                    window_start = Instant::now();
                }
            }
            Err(err) => {
                tracing::error!("{err:#}: capture frame failed, stopping capture loop");
                break;
            }
        }
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    init_tracing();

    let mut cfg = config::load(cli.config.as_deref()).context("failed to load configuration")?;
    cli.apply_overrides(&mut cfg);

    let backend = capture::select_backend();
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

    // Spawn the capture loop on a blocking thread (Wayland dispatch is
    // synchronous). Only when a real backend was found: the noop backend
    // errors immediately, and there is nothing to capture.
    let capture = if capture_format.width > 0 {
        let shutdown = Arc::new(AtomicBool::new(false));
        let handle = tokio::task::spawn_blocking({
            let shutdown = shutdown.clone();
            move || capture_loop(backend, shutdown)
        });
        Some((handle, shutdown))
    } else {
        None
    };

    // TODO(US-002/US-003): encode captured frames and stream them, plus the
    // TCP control listener, audio task (US-009), input injection (US-006),
    // and mDNS announcement (US-007). Each joins the ctrl-c shutdown path.
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

    // TODO: drain encoder, close transport, release uinput devices.
    tracing::info!("porthole-agent stopped cleanly");
    Ok(())
}
