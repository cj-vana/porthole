//! ffmpeg subprocess encoder (US-002).
//!
//! One ffmpeg child process per session: raw bgra frames go to stdin, Annex
//! B H.264/HEVC access units come back on stdout. A reader thread cuts the
//! stream into AUs (see `super::annexb`) and pushes them over a channel for
//! the pipeline to drain. Both backends convert bgra to the encoder's input
//! format on GPU; no CPU swscale runs.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{bail, Context};

use super::annexb::AuSplitter;
use super::{Codec, EncodedFrame, Encoder, EncoderBackend};
use crate::capture::{CaptureFormat, RawFrame};
use crate::config::Config;

/// A DRM render node and the kernel driver bound to its device.
type RenderNode = (PathBuf, String);

/// Kernel drivers with a VAAPI backend, in preference order. The AMD iGPU
/// comes first because that is the whole point of the VAAPI path: leave the
/// dGPU free for games.
const VAAPI_PREFERRED_DRIVERS: [&str; 3] = ["amdgpu", "i915", "xe"];

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

pub struct FfmpegEncoder {
    backend: EncoderBackend,
    codec: Codec,
    child: Child,
    stdin: Option<ChildStdin>,
    rx: mpsc::Receiver<EncodedFrame>,
}

impl FfmpegEncoder {
    pub fn new(cfg: &Config, format: &CaptureFormat) -> anyhow::Result<Self> {
        if format.width == 0 || format.height == 0 {
            bail!("capture format not negotiated, cannot start encoder");
        }
        let gop = u64::from(cfg.fps.get()) * u64::from(cfg.keyframe_interval_secs);
        let bitrate = format!("{}M", cfg.bitrate_mbps);

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
                // honors VUI; US-005 follow-up). NVENC's internal RGB to YUV
                // conversion ignores setparams for the matrix and tags
                // bt470bg with bgra input, so we convert to nv12 in the
                // filter chain (CPU swscale, measured cheap at 1440p60).
                cmd.args([
                    "-vf",
                    "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,format=nv12",
                    "-preset",
                    "p3",
                    // ll: low-latency tune, single pass, no lookahead.
                    "-tune",
                    "ll",
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
            &format!("{}M", cfg.bitrate_mbps * 2),
            "-g",
            &gop.to_string(),
            "-aud",
            "1", // access unit delimiters let us cut AUs out of the stream
            "-f",
            ffmpeg_muxer_name(cfg.codec),
            "-", // Annex B stream on stdout
        ]);
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            // ffmpeg errors land in the agent's own log stream.
            .stderr(Stdio::inherit());

        tracing::debug!(command = ?cmd, "spawning ffmpeg encoder");
        let mut child = cmd
            .spawn()
            .context("failed to spawn ffmpeg (is it installed?)")?;
        let stdin = child.stdin.take().context("ffmpeg stdin not piped")?;
        let mut stdout = child.stdout.take().context("ffmpeg stdout not piped")?;

        let (tx, rx) = mpsc::channel::<EncodedFrame>();
        let codec = cfg.codec;
        thread::Builder::new()
            .name("encoder-reader".into())
            .spawn(move || read_access_units(&mut stdout, codec, tx))
            .context("failed to spawn encoder reader thread")?;

        Ok(Self {
            backend: cfg.encoder,
            codec: cfg.codec,
            child,
            stdin: Some(stdin),
            rx,
        })
    }
}

/// Read the Annex B stream, cut it into access units, and forward them with
/// sequence numbers until EOF (ffmpeg exits).
fn read_access_units(stdout: &mut impl Read, codec: Codec, tx: mpsc::Sender<EncodedFrame>) {
    let mut splitter = AuSplitter::new(codec);
    let mut sequence = 0u64;
    let mut chunk = [0u8; 256 * 1024];
    let mut push = |au: Vec<u8>, is_keyframe: bool| {
        let frame = EncodedFrame {
            sequence,
            data: au,
            is_keyframe,
            ready_at: Instant::now(),
        };
        sequence += 1;
        if tx.send(frame).is_err() {
            return Err(());
        }
        Ok(())
    };
    loop {
        match stdout.read(&mut chunk) {
            Ok(0) => break, // EOF
            Ok(n) => {
                for (au, keyframe) in splitter.feed(&chunk[..n]) {
                    if push(au, keyframe).is_err() {
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
    if let Some((au, keyframe)) = splitter.finish() {
        let _ = push(au, keyframe);
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
        // Closing stdin makes ffmpeg flush and exit; give it a moment before
        // resorting to kill.
        drop(self.stdin.take());
        for _ in 0..20 {
            match self.child.try_wait() {
                Ok(Some(_)) => return,
                Ok(None) => thread::sleep(Duration::from_millis(50)),
                Err(_) => break,
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
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
}
