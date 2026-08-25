//! Audio capture and streaming (US-009).
//!
//! Per PRD FR-7: capture Linux desktop audio (PipeWire/PulseAudio) and
//! stream it as Opus over the audio UDP port. This module defines the
//! boundary only; the PipeWire capture and Opus encode land with US-009
//! (likely via the same GStreamer pipeline dependency as video, plus an
//! Opus encoder element).

/// One chunk of encoded Opus audio, timestamped for A/V sync.
pub struct AudioPacket {
    pub data: Vec<u8>,
    /// Capture timestamp in microseconds, same clock domain as video PTS
    /// so the client can keep audio in sync with video (US-009 AC).
    pub pts_us: u64,
}

/// Desktop audio source producing Opus packets for the transport.
pub trait AudioSource: Send {
    /// Receive the next encoded audio packet.
    fn next_packet(&mut self) -> anyhow::Result<AudioPacket>;
}

/// Placeholder source until US-009 lands.
pub struct NullAudioSource;

impl AudioSource for NullAudioSource {
    fn next_packet(&mut self) -> anyhow::Result<AudioPacket> {
        // TODO(US-009): PipeWire capture -> Opus encode -> packet out.
        anyhow::bail!("audio capture not implemented yet (US-009)")
    }
}
