//! Screen capture (US-001).
//!
//! The Hyprland/Wayland target is captured with the wlr-screencopy-unstable-v1
//! protocol (see the `wlr` module, Linux only). Hyprland implements it
//! natively, so no portal and no permission dialog is involved. Damage-aware
//! capture and zero-copy (linux-dmabuf) are later stories; frames are plain
//! per-frame copies for now. An X11 (XShm/XDamage) fallback for X11 sessions
//! also remains a TODO.

#[cfg(target_os = "linux")]
mod wlr;

/// A single captured frame, in a pixel format agreed with the encoder.
pub struct RawFrame {
    /// Frame width in pixels.
    pub width: u32,
    /// Frame height in pixels.
    pub height: u32,
    /// Row stride in bytes.
    pub stride: usize,
    /// Pixel data (format reported via [`CaptureFormat::pixel_format`];
    /// typically XRGB8888 from wl_shm, to be converted or handed to the
    /// encoder zero-copy in later stories).
    pub data: Vec<u8>,
}

/// Negotiated capture parameters. Resolution and refresh come from the
/// wl_output mode at backend construction; the pixel format is known once
/// the first frame is negotiated.
#[derive(Debug, Clone, Default)]
pub struct CaptureFormat {
    pub width: u32,
    pub height: u32,
    /// Output refresh rate in millihertz (60000 = 60 Hz).
    pub refresh_millihz: u32,
    pub pixel_format: Option<String>,
    pub output_name: Option<String>,
}

/// A screen capture backend.
pub trait CaptureBackend: Send {
    /// Human-readable backend name, logged on startup (US-001 AC).
    fn name(&self) -> &str;

    /// Grab the next frame from the primary display.
    fn next_frame(&mut self) -> anyhow::Result<RawFrame>;

    /// Negotiated resolution, refresh, and pixel format.
    fn format(&self) -> CaptureFormat;
}

/// Placeholder used when no real backend is available (non-Linux dev
/// machines, or a Linux session with no supported compositor).
pub struct NoopCapture;

impl CaptureBackend for NoopCapture {
    fn name(&self) -> &str {
        "none (not implemented)"
    }

    fn next_frame(&mut self) -> anyhow::Result<RawFrame> {
        anyhow::bail!("no capture backend available on this session")
    }

    fn format(&self) -> CaptureFormat {
        CaptureFormat::default()
    }
}

/// Pick the best available capture backend for the current session.
///
/// On Linux this tries wlr-screencopy (Wayland/Hyprland), capturing the
/// output named `preferred_output` when given (the virtual display from
/// US-015), otherwise the first output. If the connection fails (no Wayland
/// session, unsupported compositor) it falls back to [`NoopCapture`] for
/// now; an X11 fallback is a later story.
pub fn select_backend(preferred_output: Option<&str>) -> Box<dyn CaptureBackend> {
    #[cfg(target_os = "linux")]
    {
        match wlr::WlrCapture::new(preferred_output) {
            Ok(backend) => return Box::new(backend),
            Err(err) => tracing::warn!("{err:#}: falling back to noop capture backend"),
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = preferred_output;
        tracing::debug!("non-linux target: screen capture is unavailable, using noop backend");
    }
    Box::new(NoopCapture)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn noop_capture_is_a_placeholder() {
        let mut backend = NoopCapture;
        assert_eq!(backend.name(), "none (not implemented)");
        assert_eq!(backend.format().width, 0);
        assert!(backend.next_frame().is_err());
    }
}
