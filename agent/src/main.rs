//! porthole-agent: Linux agent for Porthole.
//!
//! Captures the desktop, NVENC-encodes it, and streams it to a Mac client
//! over LAN. This is the scaffold: CLI + config + logging + graceful
//! shutdown. Capture (US-001), encode (US-002), and transport (US-003)
//! are stubbed behind traits in their modules.

// Scaffold: the trait stubs in these modules are the boundaries for
// US-001..US-003/US-006/US-009 but are not wired into the runtime yet, so
// allow dead code until the real pipeline lands. Remove this once the stubs
// are replaced.
#![allow(dead_code)]

mod audio;
mod capture;
mod config;
mod encode;
mod input;
mod transport;

use std::path::PathBuf;
use std::time::Duration;

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

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    init_tracing();

    let mut cfg = config::load(cli.config.as_deref()).context("failed to load configuration")?;
    cli.apply_overrides(&mut cfg);

    let backend = capture::select_backend();

    tracing::info!(version = env!("CARGO_PKG_VERSION"), "porthole-agent starting");
    tracing::info!(
        video_addr = %cfg.video_addr(),
        control_addr = %cfg.control_addr(),
        audio_addr = %cfg.audio_addr(),
        bitrate_mbps = cfg.bitrate_mbps,
        codec = %cfg.codec,
        encoder = %cfg.encoder,
        fps = %cfg.fps,
        capture_backend = backend.name(),
        "effective configuration"
    );

    // TODO(US-001..US-003): replace the heartbeat loop with the real pipeline:
    // capture frames -> NVENC encode -> UDP video datagrams, plus the TCP
    // control listener, audio task (US-009), input injection (US-006), and
    // mDNS announcement (US-007). Each should run as a tokio task joined
    // into the same ctrl-c shutdown path below.
    let mut heartbeat = tokio::time::interval(HEARTBEAT_INTERVAL);
    heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            _ = heartbeat.tick() => {
                tracing::debug!("heartbeat: agent idle (capture/encode/transport not implemented)");
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

    // TODO: drain encoder, close transport, release capture/uinput devices.
    tracing::info!("porthole-agent stopped cleanly");
    Ok(())
}
