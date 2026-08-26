//! Video encoding (US-002).
//!
//! Frames from [`crate::capture`] are hardware-encoded on the Linux machine
//! by one of two selectable backends ([`EncoderBackend`]):
//!
//! - NVENC on the NVIDIA dGPU: FFmpeg `h264_nvenc` / `hevc_nvenc`. Default.
//! - VAAPI on the Ryzen iGPU (RDNA2): FFmpeg `h264_vaapi` / `hevc_vaapi` on
//!   the iGPU's by-path `/dev/dri` render node. Keeps the dGPU fully free
//!   for gaming.
//!
//! Integration is an ffmpeg subprocess per encoder session (see the
//! `ffmpeg` module, Linux only): raw bgra frames are piped to stdin, Annex B
//! access units return through a packet-preserving Unix socket. Chosen over
//! linking libavcodec because the box runs FFmpeg 9, far newer than the
//! available Rust bindings support, and a subprocess needs no new system
//! packages.
//!
//! Note: when the screen is captured from the dGPU but encoded on the iGPU,
//! frames cross the PCIe bus through system memory (shm capture plus pipe).
//! A dma-buf zero-copy path is a later optimization story.

#[cfg(any(target_os = "linux", test))]
mod annexb;
#[cfg(target_os = "linux")]
mod ffmpeg;

use std::fmt;
use std::str::FromStr;

use anyhow::bail;
use clap::ValueEnum;
use serde::{Deserialize, Serialize};

/// Video codec for the encoded stream.
///
/// H.264 is the default; HEVC is the optional path for gaming mode (US-013).
/// AV1 is explicitly out of scope for v1 (PRD Non-Goals).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum Codec {
    #[default]
    H264,
    Hevc,
}

impl fmt::Display for Codec {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::H264 => write!(f, "h264"),
            Self::Hevc => write!(f, "hevc"),
        }
    }
}

impl FromStr for Codec {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_ascii_lowercase().as_str() {
            "h264" => Ok(Self::H264),
            "hevc" => Ok(Self::Hevc),
            other => bail!("unknown codec {other:?} (expected \"h264\" or \"hevc\")"),
        }
    }
}

/// Hardware encoder backend.
///
/// `nvenc` (default) encodes on the NVIDIA dGPU; `vaapi` offloads encode to
/// the Ryzen iGPU so the dGPU stays free for gaming. See module docs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum EncoderBackend {
    #[default]
    Nvenc,
    Vaapi,
}

impl fmt::Display for EncoderBackend {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Nvenc => write!(f, "nvenc"),
            Self::Vaapi => write!(f, "vaapi"),
        }
    }
}

impl FromStr for EncoderBackend {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_ascii_lowercase().as_str() {
            "nvenc" => Ok(Self::Nvenc),
            "vaapi" => Ok(Self::Vaapi),
            other => bail!("unknown encoder backend {other:?} (expected \"nvenc\" or \"vaapi\")"),
        }
    }
}

/// An encoded access unit ready for packetization by [`crate::transport`].
pub struct EncodedFrame {
    /// Per-session output order, assigned by the encoder. The transport
    /// assigns the wire-visible sequence (monotonic across restarts).
    pub sequence: u64,
    /// Annex B bitstream for one access unit (starts with an AUD NAL).
    pub data: Vec<u8>,
    /// Whether this access unit contains an IDR (decoder can resync from it).
    pub is_keyframe: bool,
    /// When the access unit was cut from the encoder's output. The pipeline
    /// drains once per captured frame, so measuring encode latency at drain
    /// time would report the capture cadence rather than the encoder.
    pub ready_at: std::time::Instant,
}

/// A hardware encoder instance (NVENC on the dGPU, or VAAPI on the iGPU).
///
/// Implemented by `ffmpeg::FfmpegEncoder` on Linux; configurable bitrate,
/// codec, and keyframe interval come from [`crate::config::Config`]
/// (PRD FR-2). `request_keyframe` backs FR-4 (client reports decode-fatal
/// loss -> emit IDR immediately); the subprocess encoder cannot force an IDR
/// mid-session yet, see its TODO.
pub trait Encoder: Send {
    /// Submit one raw frame for encoding.
    fn encode(&mut self, frame: &crate::capture::RawFrame) -> anyhow::Result<()>;

    /// Drain all access units produced since the last call. The transport
    /// (US-003) will consume these.
    fn drain(&mut self) -> Vec<EncodedFrame>;

    /// Force the next output frame to be a keyframe (IDR). Unused until the
    /// transport's loss handling (US-003) calls it.
    #[allow(dead_code)]
    fn request_keyframe(&mut self) -> anyhow::Result<()>;

    /// Codec this encoder instance produces.
    fn codec(&self) -> Codec;

    /// Backend this encoder instance runs on.
    fn backend(&self) -> EncoderBackend;
}

/// Linux gets the ffmpeg subprocess encoder; everything else (or an encoder
/// startup failure) gets the null encoder, which drops frames.
pub fn create(
    cfg: &crate::config::Config,
    format: &crate::capture::CaptureFormat,
) -> Box<dyn Encoder> {
    #[cfg(target_os = "linux")]
    {
        match ffmpeg::FfmpegEncoder::new(cfg, format) {
            Ok(enc) => {
                tracing::info!(
                    backend = %enc.backend(),
                    codec = %enc.codec(),
                    "encoder started"
                );
                return Box::new(enc);
            }
            Err(err) => tracing::error!("{err:#}: encoder startup failed, frames will be dropped"),
        }
    }
    let _ = format; // used only by the Linux encoder
    Box::new(NullEncoder::new(cfg.codec, cfg.encoder))
}

/// Placeholder for non-Linux builds and encoder-startup failure. Accepts
/// frames and drops them.
pub struct NullEncoder {
    codec: Codec,
    backend: EncoderBackend,
}

impl NullEncoder {
    pub fn new(codec: Codec, backend: EncoderBackend) -> Self {
        Self { codec, backend }
    }
}

impl Encoder for NullEncoder {
    fn encode(&mut self, _frame: &crate::capture::RawFrame) -> anyhow::Result<()> {
        Ok(())
    }

    fn drain(&mut self) -> Vec<EncodedFrame> {
        Vec::new()
    }

    fn request_keyframe(&mut self) -> anyhow::Result<()> {
        Ok(())
    }

    fn codec(&self) -> Codec {
        self.codec
    }

    fn backend(&self) -> EncoderBackend {
        self.backend
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codec_from_str() {
        assert_eq!("h264".parse::<Codec>().unwrap(), Codec::H264);
        assert_eq!("HEVC".parse::<Codec>().unwrap(), Codec::Hevc);
        assert!("av1".parse::<Codec>().is_err());
    }

    #[test]
    fn encoder_backend_from_str() {
        assert_eq!(
            "nvenc".parse::<EncoderBackend>().unwrap(),
            EncoderBackend::Nvenc
        );
        assert_eq!(
            "VAAPI".parse::<EncoderBackend>().unwrap(),
            EncoderBackend::Vaapi
        );
        assert!("qsv".parse::<EncoderBackend>().is_err());
    }
}
