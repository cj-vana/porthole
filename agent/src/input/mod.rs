//! Input injection (US-006a).
//!
//! /dev/uinput is root-only and the box has no sudo, so injection uses
//! Hyprland's Wayland protocols instead of uinput (updated PRD FR-5):
//! zwlr_virtual_pointer_v1 for the pointer and virtual-keyboard-unstable-v1
//! for the keyboard. Linux implementation lives in the `wayland` submodule;
//! other platforms get a no-op. Gamepad passthrough (US-014) comes later.

#[cfg(target_os = "linux")]
mod wayland;

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc};

pub use porthole_agent::protocol::InputEvent;

/// Capture geometry shared with the Wayland input worker. Packing both
/// dimensions into one atomic keeps every absolute-motion request internally
/// consistent while a live virtual-display resize is settling.
#[derive(Clone)]
pub struct InputGeometry(Arc<AtomicU64>);

impl InputGeometry {
    fn new(width: u32, height: u32) -> Self {
        Self(Arc::new(AtomicU64::new(Self::pack(width, height))))
    }

    pub fn update(&self, width: u32, height: u32) {
        self.0.store(Self::pack(width, height), Ordering::Release);
    }

    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    pub fn dimensions(&self) -> (u32, u32) {
        let packed = self.0.load(Ordering::Acquire);
        (packed as u32, (packed >> 32) as u32)
    }

    fn pack(width: u32, height: u32) -> u64 {
        u64::from(width) | (u64::from(height) << 32)
    }
}

/// Start the input injection session for a `output_width`x`output_height`
/// output; returns the channel input events are sent through. None when
/// unavailable (non-Linux, or no usable Wayland session): input messages are
/// then logged and dropped.
pub fn spawn(
    output_width: u32,
    output_height: u32,
) -> (Option<mpsc::Sender<InputEvent>>, InputGeometry) {
    let geometry = InputGeometry::new(output_width, output_height);
    #[cfg(target_os = "linux")]
    {
        match wayland::WaylandInput::new(geometry.clone()) {
            Ok(session) => {
                tracing::info!("input injection ready (virtual pointer + keyboard)");
                return (Some(session.spawn_thread()), geometry);
            }
            Err(err) => tracing::warn!("{err:#}: input injection unavailable"),
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        tracing::debug!("non-linux target: input injection is unavailable");
    }
    (None, geometry)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn geometry_update_is_visible_to_clones() {
        let geometry = InputGeometry::new(2560, 1440);
        let worker = geometry.clone();
        geometry.update(3456, 2234);
        assert_eq!(worker.dimensions(), (3456, 2234));
    }
}
