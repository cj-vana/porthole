//! ffmpeg subprocess encoder (US-002).
//!
//! One ffmpeg child process per session: raw bgra frames go to stdin and Annex
//! B H.264/HEVC access units come back through a local Unix seqpacket socket.
//! `-flush_packets 1` and a bounded protocol packet size turn each encoded
//! packet into one or more atomic socket fragments. A reader thread reassembles
//! those fragments and pushes complete access units over a channel without
//! waiting for the following frame's AUD.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{bail, Context};
use socket2::{Domain, SockAddr, Socket, Type};

use super::annexb::{access_unit_is_keyframe, access_unit_starts_with_aud};
use super::{Codec, EncodedFrame, Encoder, EncoderBackend};
use crate::capture::{CaptureFormat, RawFrame};
use crate::config::Config;

/// A DRM render node and the kernel driver bound to its device.
type RenderNode = (PathBuf, String);

/// Kernel drivers with a VAAPI backend, in preference order. The AMD iGPU
/// comes first because that is the whole point of the VAAPI path: leave the
/// dGPU free for games.
const VAAPI_PREFERRED_DRIVERS: [&str; 3] = ["amdgpu", "i915", "xe"];

/// A corrupted or runaway encoder should never make the reader allocate
/// without bound. At 1440p/80 Mbit/s the one-frame VBV is about 70 KiB; this
/// ceiling still leaves orders of magnitude for an unusually large IDR.
const MAX_ENCODED_FRAME_BYTES: usize = 16 * 1024 * 1024;
/// Stay below Linux's default Unix-socket send-buffer ceiling while keeping a
/// normal gaming frame in one message. FFmpeg splits a larger AVPacket into
/// full fragments followed by a short final fragment.
const ENCODER_FRAGMENT_BYTES: usize = 128 * 1024;
static ENCODER_SOCKET_ID: AtomicU64 = AtomicU64::new(0);

/// Bound local socket ffmpeg connects to for packet-preserving encoder output.
/// The pathname is unlinked as soon as the connection is accepted.
struct EncoderSocketListener {
    socket: Socket,
    path: PathBuf,
}

impl EncoderSocketListener {
    fn bind() -> anyhow::Result<Self> {
        let directory = std::env::var_os("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        for _ in 0..32 {
            let id = ENCODER_SOCKET_ID.fetch_add(1, Ordering::Relaxed);
            let path = directory.join(format!("porthole-encoder-{}-{id}.sock", std::process::id()));
            let address = SockAddr::unix(&path).context("encoder socket path is invalid")?;
            let socket = Socket::new(Domain::UNIX, Type::from(libc::SOCK_SEQPACKET), None)
                .context("cannot create encoder seqpacket socket")?;
            match socket.bind(&address) {
                Ok(()) => {
                    socket
                        .set_nonblocking(true)
                        .context("cannot make encoder listener nonblocking")?;
                    socket
                        .listen(1)
                        .context("cannot listen on encoder socket")?;
                    return Ok(Self { socket, path });
                }
                Err(err) if err.kind() == std::io::ErrorKind::AddrInUse => continue,
                Err(err) => return Err(err).context("cannot bind encoder socket"),
            }
        }
        bail!("could not allocate a unique encoder socket path")
    }

    fn accept(&self, stop: &AtomicBool) -> anyhow::Result<Option<Socket>> {
        loop {
            match self.socket.accept() {
                Ok((socket, _)) => {
                    socket
                        .set_nonblocking(false)
                        .context("cannot make encoder output socket blocking")?;
                    socket
                        .set_recv_buffer_size(ENCODER_FRAGMENT_BYTES * 2)
                        .context("cannot size encoder socket receive buffer")?;
                    return Ok(Some(socket));
                }
                Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(err) => return Err(err).context("encoder socket accept failed"),
            }
            if stop.load(Ordering::Acquire) {
                return Ok(None);
            }
            thread::sleep(Duration::from_millis(2));
        }
    }
}

impl Drop for EncoderSocketListener {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// Every /dev/dri/renderD* node with its driver name, read from the
/// /sys/class/drm/<node>/device/driver symlink. Sorted by path so the
/// "first usable" fallback is stable across runs.
fn list_render_nodes() -> anyhow::Result<Vec<RenderNode>> {
    let mut nodes = Vec::new();
    for entry in std::fs::read_dir("/dev/dri").context("cannot list /dev/dri")? {
        let entry = entry.context("cannot read /dev/dri entry")?;
        let name = entry.file_name();
        let Some(name) = name.to_str().filter(|n| n.starts_with("renderD")) else {
            continue;
        };
        let driver_link = Path::new("/sys/class/drm").join(name).join("device/driver");
        let driver = match std::fs::read_link(&driver_link) {
            Ok(target) => target
                .file_name()
                .map(|d| d.to_string_lossy().into_owned())
                .unwrap_or_default(),
            Err(err) => {
                tracing::debug!(node = name, %err, "no driver symlink for render node, skipping");
                continue;
            }
        };
        nodes.push((entry.path(), driver));
    }
    nodes.sort();
    Ok(nodes)
}

/// Pick the render node for VAAPI: never nvidia (its driver has no VAAPI
/// backend), one of [`VAAPI_PREFERRED_DRIVERS`] when present, otherwise the
/// first remaining node.
fn pick_vaapi_node(nodes: &[RenderNode]) -> Option<&RenderNode> {
    let usable = || nodes.iter().filter(|(_, driver)| driver != "nvidia");
    VAAPI_PREFERRED_DRIVERS
        .iter()
        .find_map(|preferred| usable().find(|(_, driver)| driver == preferred))
        .or_else(|| usable().next())
}

/// The configured VAAPI device, or the auto-detected one.
fn resolve_vaapi_device(cfg: &Config) -> anyhow::Result<PathBuf> {
    if let Some(path) = &cfg.vaapi_device {
        tracing::info!(device = %path.display(), "vaapi device from configuration");
        return Ok(path.clone());
    }
    let nodes = list_render_nodes()?;
    let (path, driver) = pick_vaapi_node(&nodes).with_context(|| {
        let seen: Vec<String> = nodes
            .iter()
            .map(|(p, d)| format!("{} ({d})", p.display()))
            .collect();
        format!(
            "no usable VAAPI render node in /dev/dri (found: {}); set --vaapi-device",
            if seen.is_empty() {
                "none".to_string()
            } else {
                seen.join(", ")
            }
        )
    })?;
    tracing::info!(device = %path.display(), driver, "vaapi device auto-detected");
    Ok(path.clone())
}

fn ffmpeg_encoder_name(codec: Codec, backend: EncoderBackend) -> &'static str {
    match (backend, codec) {
        (EncoderBackend::Nvenc, Codec::H264) => "h264_nvenc",
        (EncoderBackend::Nvenc, Codec::Hevc) => "hevc_nvenc",
        (EncoderBackend::Vaapi, Codec::H264) => "h264_vaapi",
        (EncoderBackend::Vaapi, Codec::Hevc) => "hevc_vaapi",
    }
}

fn ffmpeg_muxer_name(codec: Codec) -> &'static str {
    match codec {
        Codec::H264 => "h264",
        Codec::Hevc => "hevc",
    }
}

/// NVIDIA recommends a single-frame VBV for ultra-low-latency streaming.
/// Keeping the same bound in quality mode avoids a multi-second rate-control
/// reservoir. FFmpeg's `K` suffix is kilobits here, so 80 Mbit/s at 144 fps is
/// 556K.
fn vbv_buffer_size(cfg: &Config) -> String {
    let kilobits_per_second = u64::from(cfg.bitrate_mbps) * 1_000;
    let fps = u64::from(cfg.fps.get());
    format!("{}K", kilobits_per_second.div_ceil(fps))
}

pub struct FfmpegEncoder {
    backend: EncoderBackend,
    codec: Codec,
    child: Child,
    stdin: Option<ChildStdin>,
    rx: mpsc::Receiver<EncodedFrame>,
    reader_stop: Arc<AtomicBool>,
    reader_thread: Option<thread::JoinHandle<()>>,
}

impl FfmpegEncoder {
    pub fn new(cfg: &Config, format: &CaptureFormat) -> anyhow::Result<Self> {
        if format.width == 0 || format.height == 0 {
            bail!("capture format not negotiated, cannot start encoder");
        }
        let gop = u64::from(cfg.fps.get()) * u64::from(cfg.keyframe_interval_secs);
        let bitrate = format!("{}M", cfg.bitrate_mbps);
        let vbv_buffer = vbv_buffer_size(cfg);
        let listener = EncoderSocketListener::bind()?;
        let output_url = format!("unix://{}", listener.path.display());

        let mut cmd = Command::new("ffmpeg");
        cmd.args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "bgra",
            "-s",
            &format!("{}x{}", format.width, format.height),
            "-r",
            &cfg.fps.get().to_string(),
            "-i",
            "-", // raw frames on stdin
        ]);
        match cfg.encoder {
            EncoderBackend::Nvenc => {
                // setparams tags BT.709 at the frame level (the Mac client
                // honors VUI; US-005 follow-up). In quality mode we convert to
                // NV12 with swscale so the matrix is explicitly BT.709. In
                // gaming mode, preserve BGRA through the filter graph and let
                // NVENC upload and convert it on the GPU. That avoids a full
                // 14.7 MB CPU color-conversion pass; NVENC marks its internal
                // conversion bt470bg and the client honors that VUI matrix.
                // Gaming mode (low_latency) trades a little quality for the
                // fastest preset and the ultra-low-latency tune; quality mode
                // keeps p3/ll, which the encode-latency A/B found within a
                // millisecond of p1/ull at 60 fps while looking better.
                let (preset, tune) = if cfg.low_latency {
                    ("p1", "ull")
                } else {
                    ("p3", "ll")
                };
                let filter = if cfg.low_latency {
                    "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709"
                } else {
                    "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,format=nv12"
                };
                cmd.args([
                    "-vf",
                    filter,
                    "-preset",
                    preset,
                    "-tune",
                    tune,
                    // delay 0: emit each access unit as soon as it is encoded;
                    // the default INT_MAX holds several frames in ffmpeg.
                    "-delay",
                    "0",
                    // zerolatency: no reordering delay inside NVENC itself.
                    "-zerolatency",
                    "1",
                    // bf 0: no B-frames, so no frame waits on a later one.
                    "-bf",
                    "0",
                    // rc cbr: constant bitrate keeps per-frame size, and so
                    // transmit time, predictable.
                    "-rc",
                    "cbr",
                ]);
            }
            EncoderBackend::Vaapi => {
                // Tag BT.709, upload, then convert to nv12 on the iGPU.
                cmd.arg("-vaapi_device")
                    .arg(resolve_vaapi_device(cfg)?)
                    .args([
                        "-vf",
                        "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,hwupload,scale_vaapi=format=nv12",
                        // bf 0: no B-frames, so no frame waits on a later one.
                        "-bf",
                        "0",
                        // async_depth 1: one frame in flight; the default 2
                        // pipelines a frame of extra delay for throughput.
                        "-async_depth",
                        "1",
                        // rc_mode CBR: constant bitrate keeps per-frame size,
                        // and so transmit time, predictable.
                        "-rc_mode",
                        "CBR",
                    ]);
            }
        }
        cmd.args([
            "-c:v",
            ffmpeg_encoder_name(cfg.codec, cfg.encoder),
            "-b:v",
            &bitrate,
            "-maxrate",
            &bitrate,
            "-bufsize",
            &vbv_buffer,
            "-g",
            &gop.to_string(),
            "-aud",
            "1", // access unit delimiters let us cut AUs out of the stream
            // Flush each AVPacket into bounded, packet-preserving fragments.
            // The short final fragment marks the AU boundary without waiting
            // for the next frame; a leading AUD covers the exact-multiple case.
            "-flush_packets",
            "1",
            "-type",
            "5", // SOCK_SEQPACKET
            "-pkt_size",
            &ENCODER_FRAGMENT_BYTES.to_string(),
            "-f",
            ffmpeg_muxer_name(cfg.codec),
            &output_url,
        ]);
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::null())
            // ffmpeg errors land in the agent's own log stream.
            .stderr(Stdio::inherit());

        tracing::debug!(command = ?cmd, "spawning ffmpeg encoder");
        let mut child = cmd
            .spawn()
            .context("failed to spawn ffmpeg (is it installed?)")?;
        let stdin = child.stdin.take().context("ffmpeg stdin not piped")?;

        let (tx, rx) = mpsc::channel::<EncodedFrame>();
        let codec = cfg.codec;
        let reader_stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&reader_stop);
        // FFmpeg does not open its output until it has consumed the first raw
        // frame. Accepting here would deadlock startup, so the reader owns the
        // listener while the pipeline is free to submit that first frame.
        let reader_thread = match thread::Builder::new()
            .name("encoder-reader".into())
            .spawn(move || read_access_units(listener, codec, tx, thread_stop))
        {
            Ok(handle) => handle,
            Err(err) => {
                drop(stdin);
                let _ = child.kill();
                let _ = child.wait();
                return Err(err).context("failed to spawn encoder reader thread");
            }
        };

        Ok(Self {
            backend: cfg.encoder,
            codec: cfg.codec,
            child,
            stdin: Some(stdin),
            rx,
            reader_stop,
            reader_thread: Some(reader_thread),
        })
    }
}

struct AccessUnitAssembler {
    codec: Codec,
    current: Vec<u8>,
}

type CompletedAccessUnits = (Option<Vec<u8>>, Option<Vec<u8>>);

impl AccessUnitAssembler {
    fn new(codec: Codec) -> Self {
        Self {
            codec,
            current: Vec::with_capacity(ENCODER_FRAGMENT_BYTES),
        }
    }

    /// Add one atomic socket fragment. Normally a short fragment completes
    /// the AU. If an AU is exactly a multiple of the fragment size, the next
    /// leading AUD completes it before bytes from the new AU are appended.
    fn push(&mut self, fragment: &[u8]) -> anyhow::Result<CompletedAccessUnits> {
        let starts_access_unit = access_unit_starts_with_aud(fragment, self.codec);
        let first = if starts_access_unit && !self.current.is_empty() {
            Some(self.take_current())
        } else {
            None
        };

        if self.current.is_empty() && !starts_access_unit {
            bail!("encoder fragment did not begin with an AUD");
        }
        let next_len = self
            .current
            .len()
            .checked_add(fragment.len())
            .context("encoded access unit size overflow")?;
        if next_len > MAX_ENCODED_FRAME_BYTES {
            bail!(
                "encoded access unit exceeded {} byte safety limit",
                MAX_ENCODED_FRAME_BYTES
            );
        }
        self.current.extend_from_slice(fragment);

        let second = (fragment.len() < ENCODER_FRAGMENT_BYTES).then(|| self.take_current());
        Ok((first, second))
    }

    fn take_current(&mut self) -> Vec<u8> {
        std::mem::replace(
            &mut self.current,
            Vec::with_capacity(ENCODER_FRAGMENT_BYTES),
        )
    }
}

/// Read packet-preserving Annex B fragments, reassemble access units, and
/// forward them with sequence numbers until EOF (ffmpeg exits).
fn read_access_units(
    listener: EncoderSocketListener,
    codec: Codec,
    tx: mpsc::Sender<EncodedFrame>,
    stop: Arc<AtomicBool>,
) {
    let mut socket = match listener.accept(&stop) {
        Ok(Some(socket)) => socket,
        Ok(None) => return,
        Err(err) => {
            tracing::error!(%err, "failed accepting encoder output");
            return;
        }
    };
    drop(listener); // unlink the pathname; the accepted socket stays live

    let mut sequence = 0u64;
    let mut assembler = AccessUnitAssembler::new(codec);
    let mut buffer = vec![0u8; ENCODER_FRAGMENT_BYTES];
    loop {
        match socket.read(&mut buffer) {
            Ok(0) => break, // EOF
            Ok(n) => {
                let completed = match assembler.push(&buffer[..n]) {
                    Ok(completed) => completed,
                    Err(err) => {
                        tracing::error!(%err, bytes = n, "invalid encoder output framing");
                        break;
                    }
                };
                for au in [completed.0, completed.1].into_iter().flatten() {
                    let frame = EncodedFrame {
                        sequence,
                        is_keyframe: access_unit_is_keyframe(&au, codec),
                        data: au,
                        ready_at: Instant::now(),
                    };
                    sequence += 1;
                    if tx.send(frame).is_err() {
                        return; // pipeline gone
                    }
                }
            }
            Err(err) => {
                tracing::error!(%err, "failed reading encoder output");
                break;
            }
        }
    }
}

impl Encoder for FfmpegEncoder {
    fn encode(&mut self, frame: &RawFrame) -> anyhow::Result<()> {
        let stdin = self.stdin.as_mut().context("encoder stdin closed")?;
        let tight_stride = frame.width as usize * 4;
        if frame.stride == tight_stride {
            stdin.write_all(&frame.data)?;
        } else {
            // rawvideo input assumes tight packing; repack row by row.
            for row in frame.data.chunks(frame.stride).take(frame.height as usize) {
                stdin.write_all(&row[..tight_stride])?;
            }
        }
        Ok(())
    }

    fn drain(&mut self) -> Vec<EncodedFrame> {
        self.rx.try_iter().collect()
    }

    fn request_keyframe(&mut self) -> anyhow::Result<()> {
        // TODO(US-003/FR-4): a subprocess ffmpeg cannot force an IDR
        // mid-session. Options: restart the encoder, or move to libavcodec
        // bindings when this becomes user-visible. Periodic IDRs come from
        // -g until then.
        tracing::debug!("request_keyframe: not supported by the subprocess encoder yet");
        Ok(())
    }

    fn codec(&self) -> Codec {
        self.codec
    }

    fn backend(&self) -> EncoderBackend {
        self.backend
    }
}

impl Drop for FfmpegEncoder {
    fn drop(&mut self) {
        self.reader_stop.store(true, Ordering::Release);
        // Closing stdin makes ffmpeg flush and exit; give it a moment before
        // resorting to kill.
        drop(self.stdin.take());
        let mut exited = false;
        for _ in 0..20 {
            match self.child.try_wait() {
                Ok(Some(_)) => {
                    exited = true;
                    break;
                }
                Ok(None) => thread::sleep(Duration::from_millis(50)),
                Err(_) => break,
            }
        }
        if !exited {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
        if let Some(handle) = self.reader_thread.take() {
            let _ = handle.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nodes(pairs: &[(&str, &str)]) -> Vec<RenderNode> {
        pairs
            .iter()
            .map(|(p, d)| (PathBuf::from(p), d.to_string()))
            .collect()
    }

    fn pick(pairs: &[(&str, &str)]) -> Option<String> {
        pick_vaapi_node(&nodes(pairs)).map(|(p, _)| p.display().to_string())
    }

    #[test]
    fn vaapi_node_prefers_amdgpu_and_skips_nvidia() {
        // The target box: dGPU on renderD128, iGPU on renderD129.
        assert_eq!(
            pick(&[
                ("/dev/dri/renderD128", "nvidia"),
                ("/dev/dri/renderD129", "amdgpu")
            ])
            .as_deref(),
            Some("/dev/dri/renderD129")
        );
        // Preference order holds regardless of node order.
        assert_eq!(
            pick(&[
                ("/dev/dri/renderD128", "xe"),
                ("/dev/dri/renderD129", "i915"),
                ("/dev/dri/renderD130", "amdgpu")
            ])
            .as_deref(),
            Some("/dev/dri/renderD130")
        );
        assert_eq!(
            pick(&[
                ("/dev/dri/renderD128", "xe"),
                ("/dev/dri/renderD129", "i915")
            ])
            .as_deref(),
            Some("/dev/dri/renderD129")
        );
    }

    #[test]
    fn vaapi_node_falls_back_to_first_non_nvidia() {
        assert_eq!(
            pick(&[
                ("/dev/dri/renderD128", "nvidia"),
                ("/dev/dri/renderD129", "virtio_gpu"),
                ("/dev/dri/renderD130", "nouveau")
            ])
            .as_deref(),
            Some("/dev/dri/renderD129")
        );
    }

    #[test]
    fn vaapi_node_none_when_only_nvidia() {
        assert_eq!(pick(&[("/dev/dri/renderD128", "nvidia")]), None);
        assert_eq!(pick(&[]), None);
    }

    #[test]
    fn vbv_is_one_frame_in_both_stream_modes() {
        let mut cfg = Config {
            low_latency: true,
            bitrate_mbps: 80,
            fps: crate::config::Fps::new(144).unwrap(),
            ..Config::default()
        };
        assert_eq!(vbv_buffer_size(&cfg), "556K");

        cfg.low_latency = false;
        cfg.fps = crate::config::Fps::new(60).unwrap();
        assert_eq!(vbv_buffer_size(&cfg), "1334K");
    }

    fn h264_au(len: usize, marker: u8) -> Vec<u8> {
        assert!(len >= 6);
        let mut au = vec![marker; len];
        au[..6].copy_from_slice(&[0, 0, 0, 1, 0x09, 0x10]);
        au
    }

    #[test]
    fn assembler_completes_on_short_final_fragment() {
        let au = h264_au(ENCODER_FRAGMENT_BYTES + 37, 0x55);
        let mut assembler = AccessUnitAssembler::new(Codec::H264);
        assert_eq!(
            assembler.push(&au[..ENCODER_FRAGMENT_BYTES]).unwrap(),
            (None, None)
        );
        let completed = assembler.push(&au[ENCODER_FRAGMENT_BYTES..]).unwrap();
        assert_eq!(completed, (None, Some(au)));
    }

    #[test]
    fn assembler_uses_next_aud_for_exact_multiple_boundary() {
        let exact = h264_au(ENCODER_FRAGMENT_BYTES, 0x44);
        let next = h264_au(32, 0x77);
        let mut assembler = AccessUnitAssembler::new(Codec::H264);
        assert_eq!(assembler.push(&exact).unwrap(), (None, None));
        assert_eq!(assembler.push(&next).unwrap(), (Some(exact), Some(next)));
    }

    #[test]
    fn assembler_rejects_or_bounds_malformed_fragments() {
        let mut assembler = AccessUnitAssembler::new(Codec::H264);
        assert!(assembler.push(&[1, 2, 3]).is_err());

        let full = h264_au(ENCODER_FRAGMENT_BYTES, 0x33);
        assert_eq!(assembler.push(&full).unwrap(), (None, None));
        let continuation = vec![0x33; ENCODER_FRAGMENT_BYTES];
        for _ in 1..(MAX_ENCODED_FRAME_BYTES / ENCODER_FRAGMENT_BYTES) {
            assert_eq!(assembler.push(&continuation).unwrap(), (None, None));
        }
        assert!(assembler.push(&continuation).is_err());
    }
}
