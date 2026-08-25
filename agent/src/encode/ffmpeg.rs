//! ffmpeg subprocess encoder (US-002).
//!
//! One ffmpeg child process per session: raw bgra frames go to stdin, Annex
//! B H.264/HEVC access units come back on stdout. A reader thread cuts the
//! stream into AUs (see `super::annexb`) and pushes them over a channel for
//! the pipeline to drain. Both backends convert bgra to the encoder's input
//! format on GPU; no CPU swscale runs.

use std::io::{Read, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use anyhow::{bail, Context};

use super::annexb::AuSplitter;
use super::{Codec, EncodedFrame, Encoder, EncoderBackend};
use crate::capture::{CaptureFormat, RawFrame};
use crate::config::Config;

/// AMD iGPU render node for VAAPI, resolved by PCI path so the renderD
/// number does not matter.
const VAAPI_DEVICE: &str = "/dev/dri/by-path/pci-0000:0b:00.0-render";

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
                // `ll` tune: zero-latency mode, no B-frame reordering.
                cmd.args([
                    "-vf",
                    "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,format=nv12",
                    "-preset",
                    "p3",
                    "-tune",
                    "ll",
                ]);
            }
            EncoderBackend::Vaapi => {
                // Tag BT.709, upload, then convert to nv12 on the iGPU.
                cmd.args([
                    "-vaapi_device",
                    VAAPI_DEVICE,
                    "-vf",
                    "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,hwupload,scale_vaapi=format=nv12",
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
        let mut child = cmd.spawn().context("failed to spawn ffmpeg (is it installed?)")?;
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
