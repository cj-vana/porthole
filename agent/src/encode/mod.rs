//! Video encoding (US-002).
//!
//! Frames from [`crate::capture`] will be hardware-encoded on the Linux
//! machine's NVIDIA GPU via NVENC (GStreamer `nvh264enc` / `nvh265enc`, or
//! FFmpeg `h264_nvenc` / `hevc_nvenc`). GStreamer is the PRD-recommended
//! pipeline; the `gstreamer` crate needs Linux system dev packages
//! (`libgstreamer1.0-dev`, `libgstreamer-plugins-base1.0-dev`), so it is
//! intentionally not a dependency yet (see Cargo.toml TODO).

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

/// An encoded access unit ready for packetization by [`crate::transport`].
pub struct EncodedFrame {
    /// Annex B / length-prefixed bitstream payload, per negotiated format.
    pub data: Vec<u8>,
    /// Whether this frame starts with an IDR (decoder can resync from it).
    pub is_keyframe: bool,
    /// Presentation timestamp in microseconds since stream start.
    pub pts_us: u64,
}

/// A hardware encoder instance (NVENC on Linux).
///
/// TODO(US-002): implement a GStreamer-based encoder:
/// `videotestsrc/capture ! nvh264enc bitrate=<bps> ! appsink`, with
/// configurable bitrate and keyframe interval (PRD FR-2). `request_keyframe`
/// backs FR-4 (client reports decode-fatal loss -> emit IDR immediately).
pub trait Encoder: Send {
    /// Encode one raw frame; returns `Ok(None)` if the encoder is buffering.
    fn encode(&mut self, frame: &crate::capture::RawFrame) -> anyhow::Result<Option<EncodedFrame>>;

    /// Force the next output frame to be a keyframe (IDR).
    fn request_keyframe(&mut self) -> anyhow::Result<()>;

    /// Codec this encoder instance produces.
    fn codec(&self) -> Codec;
}

/// Placeholder encoder used until US-002 lands. Accepts frames and drops them.
pub struct NullEncoder {
    codec: Codec,
}

impl NullEncoder {
    pub fn new(codec: Codec) -> Self {
        Self { codec }
    }
}

impl Encoder for NullEncoder {
    fn encode(&mut self, _frame: &crate::capture::RawFrame) -> anyhow::Result<Option<EncodedFrame>> {
        // TODO(US-002): hand the frame to NVENC.
        Ok(None)
    }

    fn request_keyframe(&mut self) -> anyhow::Result<()> {
        // TODO(US-002): force IDR on the next encoded frame.
        Ok(())
    }

    fn codec(&self) -> Codec {
        self.codec
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
}
