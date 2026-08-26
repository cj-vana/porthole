//! Linux virtual gamepad via evdev/uinput (US-014).
//!
//! Builds one virtual device that looks like a standard dual-stick gamepad
//! (the button and axis set an Xbox-style pad exposes) and applies each
//! `GamepadState` the client sends. State is applied whole rather than
//! diffed: uinput coalesces a batch into one SYN_REPORT, and only genuine
//! changes reach clients, so emitting every field per update is simple and
//! correct.

use std::sync::mpsc;
use std::thread;

use evdev::{
    uinput::VirtualDevice, AbsInfo, AbsoluteAxisCode, AttributeSet, EventType, InputEvent, KeyCode,
    UinputAbsSetup,
};

use super::GamepadState;

/// Stick axes span the signed 16-bit range the wire uses; triggers use the
/// non-negative half. fuzz and flat are zero so nothing is filtered.
fn stick_abs() -> AbsInfo {
    AbsInfo::new(0, i16::MIN as i32, i16::MAX as i32, 0, 0, 0)
}

fn trigger_abs() -> AbsInfo {
    AbsInfo::new(0, 0, i16::MAX as i32, 0, 0, 0)
}

/// The D-pad hat reports -1, 0, or 1 on each axis.
fn hat_abs() -> AbsInfo {
    AbsInfo::new(0, -1, 1, 0, 0, 0)
}

/// evdev buttons in the wire's bit order (0 A, 1 B, 2 X, 3 Y, 4 back,
/// 5 guide, 6 start, 7 left stick, 8 right stick, 9 left shoulder,
/// 10 right shoulder).
const BUTTONS: [KeyCode; 11] = [
    KeyCode::BTN_SOUTH,
    KeyCode::BTN_EAST,
    KeyCode::BTN_WEST,
    KeyCode::BTN_NORTH,
    KeyCode::BTN_SELECT,
    KeyCode::BTN_MODE,
    KeyCode::BTN_START,
    KeyCode::BTN_THUMBL,
    KeyCode::BTN_THUMBR,
    KeyCode::BTN_TL,
    KeyCode::BTN_TR,
];

pub fn spawn() -> Option<mpsc::Sender<GamepadState>> {
    let device = match build_device() {
        Ok(device) => device,
        Err(err) => {
            tracing::warn!("{err:#}: virtual gamepad unavailable (is /dev/uinput writable?)");
            return None;
        }
    };
    let (tx, rx) = mpsc::channel::<GamepadState>();
    let spawned = thread::Builder::new()
        .name("gamepad".into())
        .spawn(move || run(device, rx));
    match spawned {
        Ok(_) => {
            tracing::info!("virtual gamepad ready");
            Some(tx)
        }
        Err(err) => {
            tracing::error!(%err, "failed to spawn gamepad thread");
            None
        }
    }
}

fn build_device() -> anyhow::Result<VirtualDevice> {
    let mut keys = AttributeSet::<KeyCode>::new();
    for button in BUTTONS {
        keys.insert(button);
    }
    let device = VirtualDevice::builder()?
        .name("Porthole Gamepad")
        .with_keys(&keys)?
        .with_absolute_axis(&UinputAbsSetup::new(AbsoluteAxisCode::ABS_X, stick_abs()))?
        .with_absolute_axis(&UinputAbsSetup::new(AbsoluteAxisCode::ABS_Y, stick_abs()))?
        .with_absolute_axis(&UinputAbsSetup::new(AbsoluteAxisCode::ABS_RX, stick_abs()))?
        .with_absolute_axis(&UinputAbsSetup::new(AbsoluteAxisCode::ABS_RY, stick_abs()))?
        .with_absolute_axis(&UinputAbsSetup::new(AbsoluteAxisCode::ABS_Z, trigger_abs()))?
        .with_absolute_axis(&UinputAbsSetup::new(
            AbsoluteAxisCode::ABS_RZ,
            trigger_abs(),
        ))?
        .with_absolute_axis(&UinputAbsSetup::new(AbsoluteAxisCode::ABS_HAT0X, hat_abs()))?
        .with_absolute_axis(&UinputAbsSetup::new(AbsoluteAxisCode::ABS_HAT0Y, hat_abs()))?
        .build()?;
    Ok(device)
}

fn run(mut device: VirtualDevice, rx: mpsc::Receiver<GamepadState>) {
    while let Ok(state) = rx.recv() {
        let events = events_for(&state);
        if let Err(err) = device.emit(&events) {
            tracing::debug!(%err, "gamepad emit failed");
        }
    }
    tracing::info!("gamepad session ended");
}

/// One InputEvent per button, stick, trigger, and hat axis. emit() appends
/// the SYN_REPORT that makes the batch atomic.
fn events_for(state: &GamepadState) -> Vec<InputEvent> {
    let mut events = Vec::with_capacity(BUTTONS.len() + 8);
    for (bit, button) in BUTTONS.iter().enumerate() {
        let pressed = state.buttons & (1 << bit) != 0;
        events.push(InputEvent::new(
            EventType::KEY.0,
            button.0,
            i32::from(pressed),
        ));
    }
    let axis =
        |code: AbsoluteAxisCode, value: i32| InputEvent::new(EventType::ABSOLUTE.0, code.0, value);
    events.push(axis(AbsoluteAxisCode::ABS_X, i32::from(state.axes[0])));
    events.push(axis(AbsoluteAxisCode::ABS_Y, i32::from(state.axes[1])));
    events.push(axis(AbsoluteAxisCode::ABS_RX, i32::from(state.axes[2])));
    events.push(axis(AbsoluteAxisCode::ABS_RY, i32::from(state.axes[3])));
    events.push(axis(AbsoluteAxisCode::ABS_Z, i32::from(state.axes[4])));
    events.push(axis(AbsoluteAxisCode::ABS_RZ, i32::from(state.axes[5])));
    let (hat_x, hat_y) = hat_axes(state.hat);
    events.push(axis(AbsoluteAxisCode::ABS_HAT0X, hat_x));
    events.push(axis(AbsoluteAxisCode::ABS_HAT0Y, hat_y));
    events
}

/// Turn the hat bitmask (bit 0 up, 1 right, 2 down, 3 left) into the
/// (x, y) the ABS_HAT0 axes expect: -1, 0, or 1 each.
fn hat_axes(hat: u8) -> (i32, i32) {
    let up = hat & 0b0001 != 0;
    let right = hat & 0b0010 != 0;
    let down = hat & 0b0100 != 0;
    let left = hat & 0b1000 != 0;
    let x = i32::from(right) - i32::from(left);
    let y = i32::from(down) - i32::from(up);
    (x, y)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hat_directions() {
        assert_eq!(hat_axes(0), (0, 0));
        assert_eq!(hat_axes(0b0001), (0, -1)); // up
        assert_eq!(hat_axes(0b0100), (0, 1)); // down
        assert_eq!(hat_axes(0b1000), (-1, 0)); // left
        assert_eq!(hat_axes(0b0010), (1, 0)); // right
        assert_eq!(hat_axes(0b0011), (1, -1)); // up-right
    }

    #[test]
    fn buttons_map_to_events() {
        let state = GamepadState {
            buttons: 0b101, // A and X
            ..Default::default()
        };
        let events = events_for(&state);
        // A (bit 0) pressed, B (bit 1) released, X (bit 2) pressed.
        assert_eq!(events[0].value(), 1);
        assert_eq!(events[1].value(), 0);
        assert_eq!(events[2].value(), 1);
    }
}
