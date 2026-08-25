//! Input injection (US-006 keyboard/mouse, US-014 gamepad).
//!
//! Received input events from the Mac client are injected into Linux via
//! `uinput` virtual devices (PRD FR-5/FR-6): a keyboard, a mouse supporting
//! both absolute and relative (pointer-lock) modes, and a virtual gamepad.
//!
//! `uinput` is Linux-only (`/dev/uinput`, evdev), so the concrete
//! implementation will be `#[cfg(target_os = "linux")]` and pull in an
//! evdev/uinput crate (see Cargo.toml TODO). This stub keeps the trait
//! boundary and event types platform-neutral.

/// An input event received over the control channel.
#[derive(Debug, Clone)]
pub enum InputEvent {
    Key {
        /// Linux input keycode (EV_KEY), translated client-side or here.
        code: u16,
        pressed: bool,
    },
    MouseMove {
        dx: i32,
        dy: i32,
    },
    MouseButton {
        button: u16,
        pressed: bool,
    },
    /// Pixel-precise scroll deltas for native-feeling trackpad scrolling.
    Scroll {
        dx: i32,
        dy: i32,
    },
    /// Full controller state for the virtual gamepad (US-014).
    Gamepad(GamepadState),
}

/// Snapshot of a forwarded gamepad (macOS GameController -> uinput).
#[derive(Debug, Clone, Default)]
pub struct GamepadState {
    pub buttons: u32,
    pub left_x: i16,
    pub left_y: i16,
    pub right_x: i16,
    pub right_y: i16,
    pub left_trigger: u16,
    pub right_trigger: u16,
}

/// Injects input events into the OS.
pub trait InputInjector: Send {
    fn inject(&mut self, event: InputEvent) -> anyhow::Result<()>;
}

/// Placeholder injector: accepts events and drops them.
pub struct NullInjector;

impl InputInjector for NullInjector {
    fn inject(&mut self, _event: InputEvent) -> anyhow::Result<()> {
        // TODO(US-006/US-014): write to uinput virtual devices on Linux.
        Ok(())
    }
}
