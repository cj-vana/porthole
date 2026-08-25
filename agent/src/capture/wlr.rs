//! Wayland capture via wlr-screencopy-unstable-v1 (US-001).
//!
//! The protocol is request/response: we ask the compositor for a frame of
//! the output, it tells us the shm format it will write (`buffer` event), we
//! hand it a `wl_buffer` backed by a memfd (`copy` request), and it signals
//! `ready` once the frame is copied. One memcpy per frame into a Vec; damage
//! tracking and linux-dmabuf zero-copy are deliberately left for later
//! stories.

use std::fs::File;
use std::os::fd::{AsFd, FromRawFd};

use anyhow::{bail, Context};
use memmap2::MmapMut;
use wayland_client::protocol::{wl_buffer, wl_output, wl_registry, wl_shm, wl_shm_pool};
use wayland_client::{delegate_noop, Connection, Dispatch, EventQueue, QueueHandle, WEnum};
use wayland_protocols_wlr::screencopy::v1::client::zwlr_screencopy_frame_v1 as screencopy_frame;
use wayland_protocols_wlr::screencopy::v1::client::zwlr_screencopy_manager_v1::ZwlrScreencopyManagerV1;

use super::{CaptureBackend, CaptureFormat, RawFrame};

/// Shm format offered by the compositor for the pending frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PendingFormat {
    format: wl_shm::Format,
    width: u32,
    height: u32,
    stride: u32,
}

/// A reusable shm buffer handed to the compositor to copy frames into.
struct ShmBuffer {
    mmap: MmapMut,
    buffer: wl_buffer::WlBuffer,
    params: PendingFormat,
}

impl ShmBuffer {
    fn byte_len(&self) -> usize {
        (self.params.stride * self.params.height) as usize
    }

    /// Create a memfd-backed wl_buffer for the negotiated format.
    fn create(
        shm: &wl_shm::WlShm,
        params: PendingFormat,
        qh: &QueueHandle<WlState>,
    ) -> anyhow::Result<Self> {
        let size = (params.stride * params.height) as u64;
        let name = c"porthole-frame";
        // Safety: memfd_create has no memory-safety requirements; the fd is
        // immediately wrapped in an owning File, and the mmap covers exactly
        // the file length set above.
        let fd = unsafe { libc::memfd_create(name.as_ptr(), libc::MFD_CLOEXEC) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error()).context("memfd_create failed");
        }
        let file = unsafe { File::from_raw_fd(fd) };
        file.set_len(size)?;
        let mmap = unsafe { MmapMut::map_mut(&file)? };
        let pool = shm.create_pool(file.as_fd(), size as i32, qh, ());
        let buffer = pool.create_buffer(
            0,
            params.width as i32,
            params.height as i32,
            params.stride as i32,
            params.format,
            qh,
            (),
        );
        pool.destroy();
        Ok(Self { mmap, buffer, params })
    }
}

/// Wayland globals and per-frame capture state.
#[derive(Default)]
struct WlState {
    shm: Option<wl_shm::WlShm>,
    manager: Option<ZwlrScreencopyManagerV1>,
    output: Option<wl_output::WlOutput>,
    output_name: Option<String>,
    output_width: u32,
    output_height: u32,
    output_refresh_millihz: u32,
    pending: Option<PendingFormat>,
    buffer: Option<ShmBuffer>,
    frame: Option<RawFrame>,
    frame_failed: bool,
    pixel_format: Option<String>,
}

impl WlState {
    /// Ensure the shm buffer matches the negotiated format, then copy the
    /// pending frame into it.
    fn copy_frame(
        &mut self,
        frame: &screencopy_frame::ZwlrScreencopyFrameV1,
        qh: &QueueHandle<WlState>,
    ) -> anyhow::Result<()> {
        let pending = self.pending.context("compositor sent no shm format")?;
        let reusable = self
            .buffer
            .as_ref()
            .is_some_and(|b| b.params == pending);
        if !reusable {
            if let Some(old) = self.buffer.take() {
                old.buffer.destroy();
            }
            let shm = self.shm.as_ref().context("wl_shm not bound")?;
            self.buffer = Some(ShmBuffer::create(shm, pending, qh)?);
        }
        self.pixel_format = Some(format!("{:?}", pending.format));
        frame.copy(&self.buffer.as_ref().expect("buffer just created").buffer);
        Ok(())
    }
}

impl Dispatch<wl_registry::WlRegistry, ()> for WlState {
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
            "wl_shm" => state.shm = Some(registry.bind(name, 1, qh, ())),
            "zwlr_screencopy_manager_v1" => {
                state.manager = Some(registry.bind(name, version.min(3), qh, ()));
            }
            // v1 captures the primary display only; multi-monitor is a
            // non-goal, so the first wl_output wins.
            "wl_output" if state.output.is_none() => {
                state.output = Some(registry.bind(name, version.min(4), qh, ()));
            }
            _ => {}
        }
    }
}

impl Dispatch<wl_output::WlOutput, ()> for WlState {
    fn event(
        state: &mut Self,
        _: &wl_output::WlOutput,
        event: wl_output::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            wl_output::Event::Mode {
                width,
                height,
                refresh,
                ..
            } => {
                state.output_width = width as u32;
                state.output_height = height as u32;
                state.output_refresh_millihz = refresh as u32;
            }
            wl_output::Event::Name { name } => state.output_name = Some(name),
            _ => {}
        }
    }
}

impl Dispatch<screencopy_frame::ZwlrScreencopyFrameV1, ()> for WlState {
    fn event(
        state: &mut Self,
        frame: &screencopy_frame::ZwlrScreencopyFrameV1,
        event: screencopy_frame::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        use screencopy_frame::Event as Ev;
        match event {
            Ev::Buffer {
                format: WEnum::Value(format),
                width,
                height,
                stride,
            } => {
                state.pending = Some(PendingFormat {
                    format,
                    width,
                    height,
                    stride,
                });
            }
            Ev::BufferDone => {
                if let Err(err) = state.copy_frame(frame, qh) {
                    tracing::error!("{err:#}: failed to prepare frame buffer");
                    state.frame_failed = true;
                }
            }
            Ev::Ready { .. } => {
                let buffer = state.buffer.as_ref().expect("ready before buffer_done");
                state.frame = Some(RawFrame {
                    width: buffer.params.width,
                    height: buffer.params.height,
                    stride: buffer.params.stride as usize,
                    data: buffer.mmap[..buffer.byte_len()].to_vec(),
                });
            }
            Ev::Failed => state.frame_failed = true,
            // Damage (later story), Flags, LinuxDmabuf (zero-copy, later story).
            _ => {}
        }
    }
}

// wl_shm advertises its supported formats via events after binding, so it
// needs a real (ignoring) Dispatch impl; delegate_noop would panic on them.
impl Dispatch<wl_shm::WlShm, ()> for WlState {
    fn event(
        _: &mut Self,
        _: &wl_shm::WlShm,
        _: wl_shm::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

delegate_noop!(WlState: wl_shm_pool::WlShmPool);

// wl_buffer receives `release` once the compositor is done with a buffer.
impl Dispatch<wl_buffer::WlBuffer, ()> for WlState {
    fn event(
        _: &mut Self,
        _: &wl_buffer::WlBuffer,
        _: wl_buffer::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

delegate_noop!(WlState: ZwlrScreencopyManagerV1);

/// wlr-screencopy capture backend.
pub struct WlrCapture {
    // Kept alive to hold the Wayland socket open.
    _conn: Connection,
    event_queue: EventQueue<WlState>,
    state: WlState,
    _registry: wl_registry::WlRegistry,
}

impl WlrCapture {
    /// Connect to the Wayland display and bind the globals we need.
    pub fn new() -> anyhow::Result<Self> {
        let conn = Connection::connect_to_env()
            .context("failed to connect to Wayland (XDG_RUNTIME_DIR/WAYLAND_DISPLAY set?)")?;
        let display = conn.display();
        let mut event_queue = conn.new_event_queue();
        let qh = event_queue.handle();
        let registry = display.get_registry(&qh, ());
        let mut state = WlState::default();
        // First roundtrip binds the globals, the second delivers the
        // wl_output mode/name events for the output we just bound.
        event_queue
            .roundtrip(&mut state)
            .context("wayland registry roundtrip failed")?;
        event_queue
            .roundtrip(&mut state)
            .context("wayland output roundtrip failed")?;
        if state.manager.is_none() {
            bail!("compositor does not support wlr-screencopy-unstable-v1");
        }
        if state.shm.is_none() {
            bail!("compositor does not offer wl_shm");
        }
        if state.output.is_none() {
            bail!("no wl_output advertised by the compositor");
        }
        Ok(Self {
            _conn: conn,
            event_queue,
            state,
            _registry: registry,
        })
    }
}

impl CaptureBackend for WlrCapture {
    fn name(&self) -> &str {
        "wlr-screencopy"
    }

    fn next_frame(&mut self) -> anyhow::Result<RawFrame> {
        let qh = self.event_queue.handle();
        let manager = self.state.manager.clone().expect("checked in new()");
        let output = self.state.output.clone().expect("checked in new()");
        // overlay_cursor = 0: do not composite the cursor into the frame.
        let frame = manager.capture_output(0, &output, &qh, ());
        loop {
            self.event_queue
                .blocking_dispatch(&mut self.state)
                .context("wayland event dispatch failed")?;
            if self.state.frame_failed {
                frame.destroy();
                bail!("compositor failed to deliver the frame");
            }
            if let Some(raw) = self.state.frame.take() {
                frame.destroy();
                return Ok(raw);
            }
        }
    }

    fn format(&self) -> CaptureFormat {
        CaptureFormat {
            width: self.state.output_width,
            height: self.state.output_height,
            refresh_millihz: self.state.output_refresh_millihz,
            pixel_format: self.state.pixel_format.clone(),
            output_name: self.state.output_name.clone(),
        }
    }
}
