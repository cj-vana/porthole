//! Gamepad passthrough (US-014, FR-6).
//!
//! A controller plugged into the Mac shows up on the Linux machine as a
//! standard gamepad. The client sends the full controller state whenever a
//! control changes (protocol `gamepad_state`, docs/protocol.md); the agent
//! maps it onto a virtual uinput device with the evdev crate. uinput needs a
//! writable `/dev/uinput`, which a udev rule grants to the `input` group
//! (see the README); without it the agent logs a warning and drops gamepad
//! input, leaving the rest of the session working.
//!
//! Linux only; on other platforms [`spawn`] returns None.

use std::sync::mpsc;

pub use porthole_agent::protocol::GamepadState;

#[cfg(target_os = "linux")]
mod linux;

/// Start the virtual gamepad. Returns the channel gamepad state is sent
/// through, or None when uinput is unavailable (non-Linux, missing
/// `/dev/uinput` access, or device creation failed).
pub fn spawn() -> Option<mpsc::Sender<GamepadState>> {
    #[cfg(target_os = "linux")]
    {
        linux::spawn()
    }
    #[cfg(not(target_os = "linux"))]
    {
        tracing::debug!("non-linux target: virtual gamepad is unavailable");
        None
    }
}
