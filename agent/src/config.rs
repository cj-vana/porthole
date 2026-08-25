//! Agent configuration: TOML file + CLI overrides (PRD FR-11).
//!
//! Precedence: built-in defaults < TOML file < CLI flags. Every TOML field
//! is optional so users only write what they want to change.

use std::fmt;
use std::net::SocketAddr;
use std::path::Path;
use std::str::FromStr;

use anyhow::{bail, Context};
use serde::{Deserialize, Serialize};

use crate::encode::Codec;

pub const DEFAULT_PORT_VIDEO: u16 = 52800;
pub const DEFAULT_PORT_CONTROL: u16 = 52801;
pub const DEFAULT_PORT_AUDIO: u16 = 52802;
pub const DEFAULT_BITRATE_MBPS: u32 = 40;
pub const DEFAULT_FPS: u16 = 60;

/// Framerates the agent will stream at (PRD: 60 quality mode; 120 targeted by
/// gaming mode US-013; 144 for high-refresh displays).
pub const ALLOWED_FPS: [u16; 3] = [60, 120, 144];

/// A validated stream framerate. Only 60, 120, or 144 are accepted, from
/// both the CLI (via `FromStr`) and the TOML file (via `Deserialize`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Fps(u16);

impl Fps {
    pub fn new(value: u16) -> anyhow::Result<Self> {
        if ALLOWED_FPS.contains(&value) {
            Ok(Self(value))
        } else {
            bail!("invalid fps {value} (expected one of {ALLOWED_FPS:?})");
        }
    }

    pub fn get(self) -> u16 {
        self.0
    }
}

impl Default for Fps {
    fn default() -> Self {
        Self(DEFAULT_FPS)
    }
}

impl fmt::Display for Fps {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl FromStr for Fps {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let value: u16 = s
            .parse()
            .map_err(|_| anyhow::anyhow!("invalid fps {s:?} (expected one of {ALLOWED_FPS:?})"))?;
        Self::new(value)
    }
}

impl Serialize for Fps {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_u16(self.0)
    }
}

impl<'de> Deserialize<'de> for Fps {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = u16::deserialize(deserializer)?;
        Self::new(value).map_err(serde::de::Error::custom)
    }
}

/// Effective agent configuration after defaults, file, and CLI are merged.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    /// UDP port for the video datagram stream (default 52800).
    pub port_video: u16,
    /// TCP port for the control channel: handshake, settings, keyframe
    /// requests, clipboard, file transfer (default 52801).
    pub port_control: u16,
    /// UDP port for the Opus audio stream (default 52802).
    pub port_audio: u16,
    /// NVENC target bitrate in Mbps (default 40, per PRD for 1440p LAN quality mode).
    pub bitrate_mbps: u32,
    /// Video codec (default h264; hevc optional, US-013).
    pub codec: Codec,
    /// Stream framerate (default 60; gaming mode selects 120 or 144, US-013).
    pub fps: Fps,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            port_video: DEFAULT_PORT_VIDEO,
            port_control: DEFAULT_PORT_CONTROL,
            port_audio: DEFAULT_PORT_AUDIO,
            bitrate_mbps: DEFAULT_BITRATE_MBPS,
            codec: Codec::default(),
            fps: Fps::default(),
        }
    }
}

impl Config {
    pub fn video_addr(&self) -> SocketAddr {
        SocketAddr::from(([0, 0, 0, 0], self.port_video))
    }

    pub fn control_addr(&self) -> SocketAddr {
        SocketAddr::from(([0, 0, 0, 0], self.port_control))
    }

    pub fn audio_addr(&self) -> SocketAddr {
        SocketAddr::from(([0, 0, 0, 0], self.port_audio))
    }
}

/// Partial config as deserialized from a TOML file; all fields optional.
#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct FileConfig {
    pub port_video: Option<u16>,
    pub port_control: Option<u16>,
    pub port_audio: Option<u16>,
    pub bitrate_mbps: Option<u32>,
    pub codec: Option<Codec>,
    pub fps: Option<Fps>,
    // TODO(FR-11): display index/output name, file-transfer folder (US-011,
    // default ~/Downloads), mDNS service name (US-007).
}

impl FileConfig {
    pub fn merge_into(self, cfg: &mut Config) {
        if let Some(v) = self.port_video {
            cfg.port_video = v;
        }
        if let Some(v) = self.port_control {
            cfg.port_control = v;
        }
        if let Some(v) = self.port_audio {
            cfg.port_audio = v;
        }
        if let Some(v) = self.bitrate_mbps {
            cfg.bitrate_mbps = v;
        }
        if let Some(v) = self.codec {
            cfg.codec = v;
        }
        if let Some(v) = self.fps {
            cfg.fps = v;
        }
    }
}

/// Load the effective config: defaults, then the TOML file if given.
/// CLI overrides are applied afterwards by the caller ([`crate::Cli`]).
pub fn load(path: Option<&Path>) -> anyhow::Result<Config> {
    let mut cfg = Config::default();
    if let Some(path) = path {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("failed to read config file {}", path.display()))?;
        let file_cfg: FileConfig = toml::from_str(&text)
            .with_context(|| format!("failed to parse config file {}", path.display()))?;
        file_cfg.merge_into(&mut cfg);
    }
    Ok(cfg)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_match_prd() {
        let cfg = Config::default();
        assert_eq!(cfg.port_video, 52800);
        assert_eq!(cfg.port_control, 52801);
        assert_eq!(cfg.port_audio, 52802);
        assert_eq!(cfg.bitrate_mbps, 40);
        assert_eq!(cfg.codec, Codec::H264);
        assert_eq!(cfg.fps.get(), 60);
    }

    #[test]
    fn fps_from_str_valid_values() {
        assert_eq!("60".parse::<Fps>().unwrap().get(), 60);
        assert_eq!("120".parse::<Fps>().unwrap().get(), 120);
        assert_eq!("144".parse::<Fps>().unwrap().get(), 144);
    }

    #[test]
    fn fps_rejects_invalid_values() {
        assert!("90".parse::<Fps>().is_err());
        assert!("sixty".parse::<Fps>().is_err());
        // Same validation from the TOML side.
        assert!(toml::from_str::<FileConfig>("fps = 90").is_err());
        let file_cfg: FileConfig = toml::from_str("fps = 144").unwrap();
        assert_eq!(file_cfg.fps.unwrap().get(), 144);
    }

    #[test]
    fn toml_parse_partial_and_override() {
        let file_cfg: FileConfig = toml::from_str(
            r#"
            port_video = 53900
            codec = "hevc"
            "#,
        )
        .unwrap();

        let mut cfg = Config::default();
        file_cfg.merge_into(&mut cfg);

        assert_eq!(cfg.port_video, 53900);
        assert_eq!(cfg.codec, Codec::Hevc);
        // Untouched fields keep their defaults.
        assert_eq!(cfg.port_control, 52801);
        assert_eq!(cfg.bitrate_mbps, 40);
    }
}
