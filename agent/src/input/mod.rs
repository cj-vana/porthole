//! Input injection (US-006a).
//!
//! /dev/uinput is root-only and the box has no sudo, so injection uses
//! Hyprland's Wayland protocols instead of uinput (updated PRD FR-5):
//! zwlr_virtual_pointer_v1 for the pointer and virtual-keyboard-unstable-v1
//! for the keyboard. Linux implementation lives in the `wayland` submodule;
//! other platforms get a no-op. Gamepad passthrough (US-014) comes later.

#[cfg(target_os = "linux")]
mod wayland;

use std::sync::mpsc;

pub use porthole_agent::protocol::InputEvent;

/// Start the input injection session for a `output_width`x`output_height`
/// output; returns the channel input events are sent through. None when
/// unavailable (non-Linux, or no usable Wayland session): input messages are
/// then logged and dropped.
pub fn spawn(output_width: u32, output_height: u32) -> Option<mpsc::Sender<InputEvent>> {
    #[cfg(target_os = "linux")]
    {
        match wayland::WaylandInput::new(output_width, output_height) {
            Ok(session) => {
                tracing::info!("input injection ready (virtual pointer + keyboard)");
                return Some(session.spawn_thread());
            }
            Err(err) => tracing::warn!("{err:#}: input injection unavailable"),
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (output_width, output_height);
        tracing::debug!("non-linux target: input injection is unavailable");
    }
    None
}
