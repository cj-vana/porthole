//! Linux clipboard sync via the wl-clipboard tools (US-008).
//!
//! `wl-paste --watch` runs a helper once per clipboard change with the new
//! content on stdin, which is the event-driven way to observe the Wayland
//! selection without polling. `wl-copy` sets it. Both are short-lived
//! subprocesses. The last text applied from the peer is shared between the
//! watch and apply sides so a value the client sent is not immediately sent
//! back as a "change".

use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;

use super::ClipboardHandle;

/// The most recent text either side set, so neither echoes it back and
/// starts a loop.
type LastText = Arc<Mutex<Option<String>>>;

pub fn spawn(
    from_client: mpsc::Receiver<String>,
    send_to_client: impl Fn(String) + Send + 'static,
) -> Option<ClipboardHandle> {
    if !wl_clipboard_available() {
        tracing::warn!("wl-clipboard (wl-paste/wl-copy) not found, clipboard sync disabled");
        return None;
    }
    let last_text: LastText = Arc::new(Mutex::new(None));
    let shutdown = Arc::new(AtomicBool::new(false));

    // Watch the Linux clipboard and forward changes to the client.
    spawn_watch(last_text.clone(), shutdown.clone(), send_to_client);
    // Apply clipboard text the client sends to the Linux clipboard.
    spawn_apply(from_client, last_text);

    tracing::info!("clipboard sync ready (wl-clipboard)");
    Some(ClipboardHandle { shutdown })
}

fn wl_clipboard_available() -> bool {
    which("wl-paste") && which("wl-copy")
}

fn which(binary: &str) -> bool {
    Command::new(binary)
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Run `wl-paste --watch cat`: it prints the clipboard, then prints it again
/// on every change. Successive contents are delimited by the process writing
/// a fresh copy each time; we read the whole stream and split on the point
/// wl-paste flushes, which in practice is one full clipboard per change. To
/// keep that reliable we ask wl-paste to run our own marker echo per change
/// instead.
fn spawn_watch(
    last_text: LastText,
    shutdown: Arc<AtomicBool>,
    send_to_client: impl Fn(String) + Send + 'static,
) {
    thread::Builder::new()
        .name("clipboard-watch".into())
        .spawn(move || {
            // `wl-paste --watch` runs the given command once per change with
            // the content on stdin. We run a tiny shell that frames each
            // change with a NUL terminator so the reader can split a stream
            // of changes unambiguously (clipboard text may contain newlines).
            let mut child = match Command::new("wl-paste")
                .args(["--type", "text/plain", "--watch", "sh", "-c", "cat; printf '\\0'"])
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
            {
                Ok(child) => child,
                Err(err) => {
                    tracing::warn!(%err, "failed to start wl-paste --watch, clipboard receive disabled");
                    return;
                }
            };
            let mut stdout = match child.stdout.take() {
                Some(stdout) => stdout,
                None => return,
            };
            let mut buffer: Vec<u8> = Vec::new();
            let mut chunk = [0u8; 8192];
            while !shutdown.load(Ordering::Relaxed) {
                match stdout.read(&mut chunk) {
                    Ok(0) => break,
                    Ok(n) => {
                        buffer.extend_from_slice(&chunk[..n]);
                        // Emit each NUL-terminated clipboard snapshot.
                        while let Some(pos) = buffer.iter().position(|&b| b == 0) {
                            let text_bytes: Vec<u8> = buffer.drain(..=pos).collect();
                            let text = String::from_utf8_lossy(&text_bytes[..text_bytes.len() - 1])
                                .into_owned();
                            forward_change(&last_text, &send_to_client, text);
                        }
                    }
                    Err(err) => {
                        tracing::debug!(%err, "wl-paste read ended");
                        break;
                    }
                }
            }
            let _ = child.kill();
            let _ = child.wait();
        })
        .ok();
}

/// Forward a clipboard change to the client unless it is exactly what the
/// client just sent us (which would start a loop).
fn forward_change(last_text: &LastText, send_to_client: &impl Fn(String), text: String) {
    {
        let last = last_text.lock().expect("clipboard last-text poisoned");
        if last.as_deref() == Some(text.as_str()) {
            return;
        }
    }
    tracing::debug!(
        bytes = text.len(),
        "clipboard changed on Linux, sending to client"
    );
    send_to_client(text);
}

/// Apply clipboard text the client sent to the Linux clipboard with wl-copy,
/// recording it as the last text so the watch side does not echo it back.
fn spawn_apply(from_client: mpsc::Receiver<String>, last_text: LastText) {
    thread::Builder::new()
        .name("clipboard-apply".into())
        .spawn(move || {
            for text in from_client {
                {
                    let mut last = last_text.lock().expect("clipboard last-text poisoned");
                    *last = Some(text.clone());
                }
                if let Err(err) = wl_copy(&text) {
                    tracing::debug!(%err, "wl-copy failed");
                }
            }
        })
        .ok();
}

fn wl_copy(text: &str) -> std::io::Result<()> {
    use std::io::Write;
    let mut child = Command::new("wl-copy")
        .args(["--type", "text/plain"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(text.as_bytes())?;
    }
    child.wait()?;
    Ok(())
}
