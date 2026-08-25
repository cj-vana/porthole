//! Video encoding (US-002).
//!
//! Frames from [`crate::capture`] are hardware-encoded on the Linux machine
//! by one of two selectable backends ([`EncoderBackend`]):
//!
//! - NVENC on the NVIDIA dGPU: GStreamer `nvh264enc` / `nvh265enc`, or
//!   FFmpeg `h264_nvenc` / `hevc_nvenc`. The PRD-recommended default.
//! - VAAPI on the Ryzen iGPU (RDNA2): GStreamer `vah264enc` / `vah265enc`,
//!   or FFmpeg `h264_vaapi` / `hevc_vaapi` on the iGPU's
//!   `/dev/dri/renderD*` node. Keeps the dGPU fully free for gaming.
//!
//! Note: when the screen is captured from the dGPU but encoded on the iGPU,
//! frames may need a cross-GPU buffer copy; prefer dma-buf import where
//! possible to avoid the PCIe round trip.
//!
//! GStreamer is the PRD-recommended pipeline; the `gstreamer` crate needs
//! Linux system dev packages (`libgstreamer1.0-dev`,
//! `libgstreamer-plugins-base1.0-dev`), so it is intentionally not a
//! dependency yet (see Cargo.toml TODO).

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
    /// Annex B / length-prefixed bitstream payload, per negotiated format.
    pub data: Vec<u8>,
    /// Whether this frame starts with an IDR (decoder can resync from it).
    pub is_keyframe: bool,
    /// Presentation timestamp in microseconds since stream start.
    pub pts_us: u64,
}

/// A hardware encoder instance (NVENC on the dGPU, or VAAPI on the iGPU).
///
/// TODO(US-002): implement a GStreamer-based encoder per selected
/// [`EncoderBackend`], with configurable bitrate and keyframe interval
/// (PRD FR-2):
/// - Nvenc: `capture ! nvh264enc/nvh265enc bitrate=<bps> ! appsink`
/// - Vaapi: `capture ! vah264enc/vah265enc bitrate=<bps> ! appsink` bound to
///   the iGPU's `/dev/dri/renderD*` node; cross-GPU frames may need a buffer
///   copy (dma-buf import where possible)
///
/// `request_keyframe` backs FR-4 (client reports decode-fatal loss -> emit
/// IDR immediately).
pub trait Encoder: Send {
    /// Encode one raw frame; returns `Ok(None)` if the encoder is buffering.
    fn encode(&mut self, frame: &crate::capture::RawFrame) -> anyhow::Result<Option<EncodedFrame>>;

    /// Force the next output frame to be a keyframe (IDR).
    fn request_keyframe(&mut self) -> anyhow::Result<()>;

    /// Codec this encoder instance produces.
    fn codec(&self) -> Codec;

    /// Backend this encoder instance runs on.
    fn backend(&self) -> EncoderBackend;
}

/// Placeholder encoder used until US-002 lands. Accepts frames and drops them.
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
    fn encode(&mut self, _frame: &crate::capture::RawFrame) -> anyhow::Result<Option<EncodedFrame>> {
        // TODO(US-002): hand the frame to the selected hardware backend.
        Ok(None)
    }

    fn request_keyframe(&mut self) -> anyhow::Result<()> {
        // TODO(US-002): force IDR on the next encoded frame.
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
        assert_eq!("nvenc".parse::<EncoderBackend>().unwrap(), EncoderBackend::Nvenc);
        assert_eq!("VAAPI".parse::<EncoderBackend>().unwrap(), EncoderBackend::Vaapi);
        assert!("qsv".parse::<EncoderBackend>().is_err());
    }
}
