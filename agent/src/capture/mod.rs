//! Screen capture (US-001).
//!
//! Backend selection per PRD FR-1: PipeWire (Wayland, via the xdg-desktop
//! portal + GStreamer `pipewiresrc`) is the primary path; X11
//! (XShm/XDamage via `ximagesrc` or `x11rb`) is the fallback. Both are
//! Linux-only and need system libraries, so no capture dependency exists
//! yet (see Cargo.toml TODO).

/// A single captured frame, in a pixel format agreed with the encoder.
pub struct RawFrame {
    /// Frame width in pixels.
    pub width: u32,
    /// Frame height in pixels.
    pub height: u32,
    /// Row stride in bytes.
    pub stride: usize,
    /// Pixel data (format TBD by US-001; likely NV12 or BGRA to feed NVENC directly).
    pub data: Vec<u8>,
}

/// Which capture path the agent is using.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptureBackendKind {
    /// PipeWire / xdg-desktop-portal (Wayland). Primary path.
    PipeWire,
    /// X11 XShm/XDamage. Fallback path.
    X11,
}

impl std::fmt::Display for CaptureBackendKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::PipeWire => write!(f, "pipewire"),
            Self::X11 => write!(f, "x11"),
        }
    }
}

/// A screen capture backend.
///
/// TODO(US-001): implement `PipeWireCapture` (GStreamer `pipewiresrc` with
/// portal negotiation) and `X11Capture` behind `cfg(target_os = "linux")`,
/// then have [`select_backend`] probe the session type (`XDG_SESSION_TYPE`)
/// and pick per PRD FR-1.
pub trait CaptureBackend: Send {
    /// Human-readable backend name, logged on startup (US-001 AC).
    fn name(&self) -> &str;

    /// Grab the next frame from the primary display.
    fn next_frame(&mut self) -> anyhow::Result<RawFrame>;

    /// Negotiated resolution and framerate.
    fn format(&self) -> (u32, u32, u32);
}

/// Placeholder backend so the scaffold can run before US-001 lands.
pub struct NoopCapture;

impl CaptureBackend for NoopCapture {
    fn name(&self) -> &str {
        "none (not implemented)"
    }

    fn next_frame(&mut self) -> anyhow::Result<RawFrame> {
        anyhow::bail!("capture backend not implemented yet (US-001)")
    }

    fn format(&self) -> (u32, u32, u32) {
        (0, 0, 0)
    }
}

/// Pick the best available capture backend for the current session.
///
/// TODO(US-001): on Linux, prefer PipeWire when `XDG_SESSION_TYPE=wayland`
/// (or a portal is reachable), else fall back to X11. Until then this always
/// returns [`NoopCapture`].
pub fn select_backend() -> Box<dyn CaptureBackend> {
    #[cfg(target_os = "linux")]
    {
        // TODO(US-001): real probing goes here.
        tracing::debug!("linux target: PipeWire/X11 probing not implemented yet (US-001)");
    }
    #[cfg(not(target_os = "linux"))]
    {
        tracing::debug!("non-linux target: screen capture is unavailable, using noop backend");
    }
    Box::new(NoopCapture)
}
