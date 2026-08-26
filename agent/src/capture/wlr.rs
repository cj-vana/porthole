//! Wayland capture via wlr-screencopy-unstable-v1 (US-001).
//!
//! The protocol is request/response: we ask the compositor for a frame of
//! the output, it tells us the shm format it will write (`buffer` event), we
//! hand it a `wl_buffer` backed by a memfd (`copy` request), and it signals
//! `ready` once the frame is copied. The mapped memfd is leased directly to
//! the encoder and returned to a small pool on drop, avoiding a 14.7 MB memcpy
//! on every 1440p frame. Damage tracking and linux-dmabuf capture remain later
//! stories.

use std::fs::File;
use std::os::fd::{AsFd, AsRawFd, FromRawFd, RawFd};
use std::sync::{mpsc, Arc};

use anyhow::{bail, Context};
use memmap2::MmapMut;
use wayland_client::protocol::{wl_buffer, wl_output, wl_registry, wl_shm, wl_shm_pool};
use wayland_client::{delegate_noop, Connection, Dispatch, EventQueue, QueueHandle, WEnum};
use wayland_protocols_wlr::screencopy::v1::client::zwlr_screencopy_frame_v1 as screencopy_frame;
use wayland_protocols_wlr::screencopy::v1::client::zwlr_screencopy_manager_v1::ZwlrScreencopyManagerV1;

use super::{CaptureBackend, CaptureFormat, FrameData, FrameStorage, RawFrame};

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
    mmap: Option<MmapMut>,
    file: Arc<File>,
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
        Ok(Self {
            mmap: Some(mmap),
            file: Arc::new(file),
            buffer,
            params,
        })
    }
}

struct ReturnedMmap {
    slot: usize,
    mmap: MmapMut,
}

/// Exclusive lease of a capture mapping. The Wayland object and memfd stay in
/// the capture state; the mapping itself crosses threads with the frame and is
/// returned only after the corresponding encoded access unit is ready.
struct MappedFrame {
    slot: usize,
    mmap: Option<MmapMut>,
    file: Arc<File>,
    recycler: mpsc::Sender<ReturnedMmap>,
}

impl FrameStorage for MappedFrame {
    fn bytes(&self) -> &[u8] {
        self.mmap.as_deref().expect("mapped frame already returned")
    }

    fn splice_fd(&self) -> Option<RawFd> {
        Some(self.file.as_raw_fd())
    }
}

impl Drop for MappedFrame {
    fn drop(&mut self) {
        let Some(mmap) = self.mmap.take() else {
            return;
        };
        // A disconnected receiver means the capture backend has already gone
        // away; dropping the mapping is then the correct cleanup.
        let _ = self.recycler.send(ReturnedMmap {
            slot: self.slot,
            mmap,
        });
    }
}

/// One bound wl_output and what it has told us about itself.
struct OutputInfo {
    proxy: wl_output::WlOutput,
    name: Option<String>,
    width: u32,
    height: u32,
    refresh_millihz: u32,
}

/// Wayland globals and per-frame capture state.
#[derive(Default)]
struct WlState {
    shm: Option<wl_shm::WlShm>,
    manager: Option<ZwlrScreencopyManagerV1>,
    outputs: Vec<OutputInfo>,
    // The capture target, chosen in new() after enumeration.
    output: Option<wl_output::WlOutput>,
    output_name: Option<String>,
    output_width: u32,
    output_height: u32,
    output_refresh_millihz: u32,
    pending: Option<PendingFormat>,
    buffers: Vec<ShmBuffer>,
    active_buffer: Option<usize>,
    recycle_tx: Option<mpsc::Sender<ReturnedMmap>>,
    recycle_rx: Option<mpsc::Receiver<ReturnedMmap>>,
    frame: Option<RawFrame>,
    frame_failed: bool,
    pixel_format: Option<String>,
}

impl WlState {
    fn reclaim_buffers(&mut self) {
        loop {
            let returned = self
                .recycle_rx
                .as_ref()
                .and_then(|receiver| receiver.try_recv().ok());
            let Some(returned) = returned else {
                break;
            };
            let buffer = self
                .buffers
                .get_mut(returned.slot)
                .expect("capture buffer returned to unknown slot");
            debug_assert!(buffer.mmap.is_none());
            buffer.mmap = Some(returned.mmap);
        }
    }

    /// Ensure the shm buffer matches the negotiated format, then copy the
    /// pending frame into it.
    fn copy_frame(
        &mut self,
        frame: &screencopy_frame::ZwlrScreencopyFrameV1,
        qh: &QueueHandle<WlState>,
    ) -> anyhow::Result<()> {
        let pending = self.pending.context("compositor sent no shm format")?;
        self.reclaim_buffers();
        let slot = self
            .buffers
            .iter()
            .position(|buffer| buffer.params == pending && buffer.mmap.is_some());
        let slot = match slot {
            Some(slot) => slot,
            None => {
                let shm = self.shm.as_ref().context("wl_shm not bound")?;
                self.buffers.push(ShmBuffer::create(shm, pending, qh)?);
                let slot = self.buffers.len() - 1;
                tracing::debug!(
                    slot,
                    bytes = self.buffers[slot].byte_len(),
                    "allocated leased capture buffer"
                );
                slot
            }
        };
        self.pixel_format = Some(format!("{:?}", pending.format));
        frame.copy(&self.buffers[slot].buffer);
        self.active_buffer = Some(slot);
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
            // Bind every wl_output so we can pick the configured virtual
            // display when set (US-015); the target is chosen in new().
            "wl_output" => {
                let proxy: wl_output::WlOutput = registry.bind(name, version.min(4), qh, ());
                state.outputs.push(OutputInfo {
                    proxy,
                    name: None,
                    width: 0,
                    height: 0,
                    refresh_millihz: 0,
                });
            }
            _ => {}
        }
    }
}

impl Dispatch<wl_output::WlOutput, ()> for WlState {
    fn event(
        state: &mut Self,
        output: &wl_output::WlOutput,
        event: wl_output::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let Some(info) = state.outputs.iter_mut().find(|o| o.proxy == *output) else {
            return;
        };
        match event {
            wl_output::Event::Mode {
                width,
                height,
                refresh,
                ..
            } => {
                info.width = width as u32;
                info.height = height as u32;
                info.refresh_millihz = refresh as u32;
            }
            wl_output::Event::Name { name } => info.name = Some(name),
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
                let slot = state
                    .active_buffer
                    .take()
                    .expect("ready before buffer_done");
                let buffer = &mut state.buffers[slot];
                let mmap = buffer.mmap.take().expect("active buffer has no mapping");
                let recycler = state
                    .recycle_tx
                    .as_ref()
                    .expect("capture recycler not initialized")
                    .clone();
                state.frame = Some(RawFrame {
                    width: buffer.params.width,
                    height: buffer.params.height,
                    stride: buffer.params.stride as usize,
                    data: FrameData::from_storage(MappedFrame {
                        slot,
                        mmap: Some(mmap),
                        file: Arc::clone(&buffer.file),
                        recycler,
                    }),
                });
            }
            Ev::Failed => {
                state.active_buffer = None;
                state.frame_failed = true;
            }
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
    /// Connect to the Wayland display, bind the globals we need, and pick the
    /// capture target: the output named `preferred_output` when given (the
    /// virtual display from US-015), otherwise the first advertised output.
    pub fn new(preferred_output: Option<&str>) -> anyhow::Result<Self> {
        let conn = Connection::connect_to_env()
            .context("failed to connect to Wayland (XDG_RUNTIME_DIR/WAYLAND_DISPLAY set?)")?;
        let display = conn.display();
        let mut event_queue = conn.new_event_queue();
        let qh = event_queue.handle();
        let registry = display.get_registry(&qh, ());
        let (recycle_tx, recycle_rx) = mpsc::channel();
        let mut state = WlState {
            recycle_tx: Some(recycle_tx),
            recycle_rx: Some(recycle_rx),
            ..WlState::default()
        };
        // First roundtrip binds the globals, the second delivers the
        // wl_output mode/name events for the outputs we just bound.
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

        // A freshly created headless output can take a beat to appear in the
        // Wayland registry; retry roundtrips instead of racing it (US-015).
        if let Some(want) = preferred_output {
            for _ in 0..20 {
                if state
                    .outputs
                    .iter()
                    .any(|o| o.name.as_deref() == Some(want))
                {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(100));
                event_queue
                    .roundtrip(&mut state)
                    .context("wayland roundtrip failed while waiting for preferred output")?;
            }
        }

        let chosen = preferred_output
            .and_then(|want| {
                let found = state
                    .outputs
                    .iter()
                    .find(|o| o.name.as_deref() == Some(want));
                if found.is_none() {
                    tracing::warn!(
                        output = want,
                        "preferred output not in wayland registry, using first output"
                    );
                }
                found
            })
            .or_else(|| state.outputs.first())
            .context("no wl_output advertised by the compositor")?;
        state.output = Some(chosen.proxy.clone());
        state.output_name = chosen.name.clone();
        state.output_width = chosen.width;
        state.output_height = chosen.height;
        state.output_refresh_millihz = chosen.refresh_millihz;

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
