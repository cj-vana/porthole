//! Clipboard sync (US-008, FR-9).
//!
//! Two-way text clipboard between the Linux machine and the Mac. On Linux the
//! backend is the `wl-clipboard` tools (`wl-paste` / `wl-copy`), the same
//! subprocess philosophy as video and audio: they are already present on a
//! wlroots desktop and need no new library. The agent watches the Wayland
//! clipboard for changes and forwards the text to the client, and applies
//! text the client sends. Loop prevention lives here: the text last written
//! from the peer is remembered and never sent straight back.
//!
//! Clipboard is Linux only; on other platforms [`spawn`] returns None.

use std::sync::mpsc;

#[cfg(target_os = "linux")]
mod linux;

/// Start clipboard sync. `send_to_client` is called with clipboard text the
/// Linux side copied; `from_client` delivers text the client copied, to be
/// applied to the Linux clipboard. Returns None on non-Linux builds or when
/// the wl-clipboard tools are missing (the rest of the session is
/// unaffected).
pub fn spawn(
    from_client: mpsc::Receiver<String>,
    send_to_client: impl Fn(String) + Send + 'static,
) -> Option<ClipboardHandle> {
    #[cfg(target_os = "linux")]
    {
        linux::spawn(from_client, send_to_client)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (from_client, send_to_client);
        tracing::debug!("non-linux target: clipboard sync is unavailable");
        None
    }
}

/// Keeps the clipboard threads alive; dropping it signals them to stop.
pub struct ClipboardHandle {
    #[cfg(target_os = "linux")]
    shutdown: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

impl Drop for ClipboardHandle {
    fn drop(&mut self) {
        #[cfg(target_os = "linux")]
        self.shutdown
            .store(true, std::sync::atomic::Ordering::Relaxed);
    }
}
