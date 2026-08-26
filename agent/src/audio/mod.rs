//! Audio capture and streaming (US-009, FR-7).
//!
//! Desktop audio is captured from the PulseAudio/PipeWire default sink
//! monitor and encoded to Opus by an ffmpeg subprocess, the same integration
//! choice as video (`super::encode::ffmpeg`): the box runs a very new ffmpeg
//! with libopus, and a subprocess needs no new system packages. ffmpeg muxes
//! Opus as Ogg on stdout; `ogg::OggReader` pulls the Opus packets back out
//! and each is sent as one UDP datagram (`porthole_agent::protocol::audio_datagram`).
//!
//! Opus packets carry a pipeline-clock timestamp (microseconds since the
//! agent started), the same clock the video datagrams and pong answers use,
//! so the client can line audio up with video. The timestamp counts encoded
//! samples at 48 kHz rather than wall clock, so it is free of scheduling
//! jitter; the client absorbs the fixed capture-to-play offset in its jitter
//! buffer.
//!
//! Capture is Linux only; on other platforms (a macOS dev build) [`spawn`]
//! returns None and the agent streams video without audio.

use std::net::IpAddr;

#[cfg(target_os = "linux")]
mod ffmpeg_source;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
mod ogg;

/// Start desktop audio capture, if available. Returns None (with a warning)
/// on non-Linux builds or when ffmpeg cannot open the audio device, so the
/// rest of the agent runs without audio.
///
/// `port_audio` is the client's audio UDP port; `pipeline_epoch_us` is the
/// value of the pipeline clock (video's) when audio starts, so the first
/// packet's timestamp aligns with video.
pub fn spawn(port_audio: u16, pipeline_epoch_us: u64) -> Option<AudioHandle> {
    #[cfg(target_os = "linux")]
    {
        linux::spawn(port_audio, pipeline_epoch_us).map(|client_tx| AudioHandle { client_tx })
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (port_audio, pipeline_epoch_us);
        tracing::debug!("non-linux target: desktop audio capture is unavailable");
        None
    }
}

/// Runtime handle for the audio thread: it captures, encodes, and sends
/// Opus packets to whichever client the control channel last reported.
pub struct AudioHandle {
    #[cfg(target_os = "linux")]
    client_tx: std::sync::mpsc::Sender<Option<IpAddr>>,
}

impl AudioHandle {
    /// Point audio at a client IP (or nobody), matching the video sender.
    pub fn set_client(&self, ip: Option<IpAddr>) {
        #[cfg(target_os = "linux")]
        let _ = self.client_tx.send(ip);
        #[cfg(not(target_os = "linux"))]
        let _ = ip;
    }
}
