//! Wayland virtual input devices (US-006a): zwlr_virtual_pointer_v1 plus
//! virtual-keyboard-unstable-v1, on a dedicated connection and thread.
//!
//! The virtual keyboard needs an xkb keymap uploaded once (text V1 format
//! over a memfd); we build the evdev/pc105/us default with libxkbcommon.

use std::fs::File;
use std::io::Write as _;
use std::os::fd::{AsFd, FromRawFd};
use std::sync::mpsc;
use std::thread;
use std::time::Instant;

use anyhow::Context;
use wayland_client::protocol::{wl_pointer, wl_registry, wl_seat};
use wayland_client::{delegate_noop, Connection, Dispatch, QueueHandle};
use wayland_protocols_wlr::virtual_pointer::v1::client::zwlr_virtual_pointer_manager_v1::ZwlrVirtualPointerManagerV1;
use wayland_protocols_wlr::virtual_pointer::v1::client::zwlr_virtual_pointer_v1::ZwlrVirtualPointerV1;

/// Generated client bindings for virtual-keyboard-unstable-v1, from the
/// vendored XML at protocols/virtual-keyboard-unstable-v1.xml. The
/// wayland-protocols crate no longer ships this protocol (upstream removed
/// it); the vendored copy comes from hyprwm/Hyprland's protocols directory,
/// the compositor we target.
mod vk {
    pub mod client {
        //! Client-side API of this protocol
        #![allow(dead_code, non_camel_case_types, unused_unsafe, unused_variables)]
        #![allow(non_upper_case_globals, non_snake_case, unused_imports)]
        #![allow(missing_docs, clippy::all)]

        use wayland_client;
        use wayland_client::protocol::*;

        pub mod __interfaces {
            use wayland_client::protocol::__interfaces::*;
            wayland_scanner::generate_interfaces!("protocols/virtual-keyboard-unstable-v1.xml");
        }
        use self::__interfaces::*;

        wayland_scanner::generate_client_code!("protocols/virtual-keyboard-unstable-v1.xml");
    }
}
use vk::client::zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1;
use vk::client::zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1;

use super::InputEvent;

#[derive(Default)]
struct State {
    seat: Option<wl_seat::WlSeat>,
    pointer_manager: Option<ZwlrVirtualPointerManagerV1>,
    keyboard_manager: Option<ZwpVirtualKeyboardManagerV1>,
}

impl Dispatch<wl_registry::WlRegistry, ()> for State {
    fn event(
        state: &mut Self,
        registry: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        let wl_registry::Event::Global {
            name,
            interface,
            version,
        } = event
        else {
            return;
        };
        match interface.as_str() {
            "wl_seat" if state.seat.is_none() => {
                state.seat = Some(registry.bind(name, version.min(5), qh, ()));
            }
            "zwlr_virtual_pointer_manager_v1" => {
                state.pointer_manager = Some(registry.bind(name, version.min(2), qh, ()));
            }
            "zwp_virtual_keyboard_manager_v1" => {
                state.keyboard_manager = Some(registry.bind(name, 1, qh, ()));
            }
            _ => {}
        }
    }
}

// wl_seat sends a capabilities event after binding, so it needs a real
// (ignoring) Dispatch impl; delegate_noop would panic on it.
impl Dispatch<wl_seat::WlSeat, ()> for State {
    fn event(
        _: &mut Self,
        _: &wl_seat::WlSeat,
        _: wl_seat::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

delegate_noop!(State: ZwlrVirtualPointerManagerV1);
delegate_noop!(State: ZwlrVirtualPointerV1);
delegate_noop!(State: ZwpVirtualKeyboardManagerV1);
delegate_noop!(State: ZwpVirtualKeyboardV1);

/// Build the default evdev/pc105/us xkb keymap into a memfd for the virtual
/// keyboard's keymap upload.
fn keymap_memfd() -> anyhow::Result<(File, u32)> {
    let context = xkbcommon::xkb::Context::new(xkbcommon::xkb::CONTEXT_NO_FLAGS);
    let keymap = xkbcommon::xkb::Keymap::new_from_names(
        &context,
        "evdev",
        "pc105",
        "us",
        "",
        None,
        xkbcommon::xkb::KEYMAP_COMPILE_NO_FLAGS,
    )
    .context("failed to build xkb keymap (evdev/pc105/us)")?;
    let text = keymap.get_as_string(xkbcommon::xkb::KEYMAP_FORMAT_TEXT_V1);
    let mut bytes = text.into_bytes();
    bytes.push(0); // compositors expect the trailing NUL in the size

    let name = c"porthole-keymap";
    // Safety: memfd_create has no memory-safety requirements; the fd is
    // immediately wrapped in an owning File.
    let fd = unsafe { libc::memfd_create(name.as_ptr(), libc::MFD_CLOEXEC) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error()).context("memfd_create failed");
    }
    let mut file = unsafe { File::from_raw_fd(fd) };
    file.write_all(&bytes)?;
    let size = bytes.len() as u32;
    Ok((file, size))
}

/// Virtual pointer + keyboard on the session's seat.
pub struct WaylandInput {
    conn: Connection,
    pointer: ZwlrVirtualPointerV1,
    keyboard: ZwpVirtualKeyboardV1,
    start: Instant,
    output_width: u32,
    output_height: u32,
    // Hold the keymap fd open for the lifetime of the keyboard upload.
    _keymap_file: File,
    // Bound globals kept alive.
    _seat: wl_seat::WlSeat,
    _registry: wl_registry::WlRegistry,
}

impl WaylandInput {
    pub fn new(output_width: u32, output_height: u32) -> anyhow::Result<Self> {
        let conn = Connection::connect_to_env()
            .context("failed to connect to Wayland for input injection")?;
        let display = conn.display();
        let mut event_queue = conn.new_event_queue();
        let qh = event_queue.handle();
        let registry = display.get_registry(&qh, ());
        let mut state = State::default();
        event_queue
            .roundtrip(&mut state)
            .context("wayland registry roundtrip failed")?;

        let pointer_manager = state
            .pointer_manager
            .as_ref()
            .context("compositor does not support zwlr_virtual_pointer_v1")?;
        let keyboard_manager = state
            .keyboard_manager
            .as_ref()
            .context("compositor does not support virtual-keyboard-v1")?;
        let seat = state.seat.as_ref().context("no wl_seat advertised")?;

        let pointer = pointer_manager.create_virtual_pointer(Some(seat), &qh, ());
        let keyboard = keyboard_manager.create_virtual_keyboard(seat, &qh, ());

        let (keymap_file, keymap_size) = keymap_memfd()?;
        // The vendored protocol XML types format/state as plain uints:
        // 1 = XKB_KEYMAP_FORMAT_TEXT_V1.
        keyboard.keymap(1, keymap_file.as_fd(), keymap_size);
        conn.flush().context("wayland flush failed")?;

        Ok(Self {
            conn,
            pointer,
            keyboard,
            start: Instant::now(),
            output_width,
            output_height,
            _keymap_file: keymap_file,
            _seat: state.seat.take().expect("checked above"),
            _registry: registry,
        })
    }

    /// Run the apply loop on a dedicated thread; events arrive by channel.
    pub fn spawn_thread(self) -> mpsc::Sender<InputEvent> {
        let (tx, rx) = mpsc::channel::<InputEvent>();
        let spawned = thread::Builder::new().name("input".into()).spawn(move || self.run(rx));
        if let Err(err) = spawned {
            tracing::error!(%err, "failed to spawn input thread");
        }
        tx
    }

    fn time_ms(&self) -> u32 {
        self.start.elapsed().as_millis() as u32
    }

    fn apply(&self, event: InputEvent) {
        let time = self.time_ms();
        match event {
            InputEvent::PointerMotionAbs { x, y } => {
                self.pointer.motion_absolute(
                    time,
                    x.max(0) as u32,
                    y.max(0) as u32,
                    self.output_width,
                    self.output_height,
                );
            }
            InputEvent::PointerMotionRel { dx256, dy256 } => {
                self.pointer
                    .motion(time, dx256 as f64 / 256.0, dy256 as f64 / 256.0);
            }
            InputEvent::PointerButton { button, pressed } => {
                let state = if pressed {
                    wl_pointer::ButtonState::Pressed
                } else {
                    wl_pointer::ButtonState::Released
                };
                self.pointer.button(time, u32::from(button), state);
            }
            InputEvent::PointerAxis {
                axis,
                source,
                value256,
            } => {
                let axis = match axis {
                    0 => wl_pointer::Axis::VerticalScroll,
                    _ => wl_pointer::Axis::HorizontalScroll,
                };
                let source = match source {
                    0 => wl_pointer::AxisSource::Wheel,
                    1 => wl_pointer::AxisSource::Finger,
                    3 => wl_pointer::AxisSource::WheelTilt,
                    _ => wl_pointer::AxisSource::Continuous,
                };
                self.pointer.axis_source(source);
                self.pointer.axis(time, axis, value256 as f64 / 256.0);
                self.pointer.frame();
            }
            InputEvent::Key { code, pressed } => {
                // 1 = pressed, 0 = released.
                self.keyboard.key(time, u32::from(code), u32::from(pressed));
            }
        }
    }

    fn run(self, rx: mpsc::Receiver<InputEvent>) {
        while let Ok(event) = rx.recv() {
            tracing::debug!(?event, "input event");
            self.apply(event);
            if let Err(err) = self.conn.flush() {
                tracing::error!(%err, "wayland flush failed, ending input session");
                break;
            }
        }
        tracing::info!("input session ended");
    }
}
