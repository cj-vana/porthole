//! LAN stream transport (US-003).
//!
//! Per PRD FR-3: encoded video goes out as sequence-numbered UDP datagrams;
//! a TCP control channel carries the handshake (negotiate resolution / codec
//! / fps), settings, and keyframe requests. Audio rides its own UDP port
//! (US-009). The PRD asks that this stay behind a trait so a WebRTC or QUIC
//! transport can replace it later for internet play, and it must not
//! hardcode LAN assumptions that would block running over Tailscale.

use std::net::SocketAddr;

use crate::encode::EncodedFrame;

/// Video frame header prepended to each UDP datagram (US-003).
///
/// TODO(US-003): finalize the wire format (sequence number, frame index,
/// fragment index/count, timestamp) and add FEC/loss handling so the
/// receiver can tolerate loss by requesting a keyframe (FR-4).
#[derive(Debug, Clone, Copy)]
pub struct FrameHeader {
    pub sequence: u64,
    pub timestamp_us: u64,
}

/// The video/audio datagram path.
pub trait MediaTransport: Send {
    /// Send one encoded frame, fragmenting into datagrams as needed.
    fn send_frame(&mut self, frame: &EncodedFrame) -> anyhow::Result<()>;

    /// Local address this transport is bound to (for logging/discovery).
    fn local_addr(&self) -> anyhow::Result<SocketAddr>;
}

/// The TCP control channel: handshake, stream parameters, keyframe
/// requests (FR-3/FR-4), clipboard (FR-9), file transfer (US-011).
///
/// TODO(US-003): implement a length-prefixed message codec over
/// `tokio::net::TcpListener` bound to `config.port_control`.
pub trait ControlChannel: Send {
    /// Handle one incoming control message. Placeholder until the message
    /// schema exists.
    fn handle_message(&mut self, payload: &[u8]) -> anyhow::Result<()>;
}

/// Placeholder transport that binds nothing and sends nothing, so the
/// scaffold runs before US-003 lands.
pub struct NullTransport {
    pub video_addr: SocketAddr,
    pub audio_addr: SocketAddr,
}

impl MediaTransport for NullTransport {
    fn send_frame(&mut self, _frame: &EncodedFrame) -> anyhow::Result<()> {
        // TODO(US-003): fragment + send over UDP socket on `video_addr`.
        Ok(())
    }

    fn local_addr(&self) -> anyhow::Result<SocketAddr> {
        Ok(self.video_addr)
    }
}
