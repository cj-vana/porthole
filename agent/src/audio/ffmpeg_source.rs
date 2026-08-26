//! ffmpeg-backed desktop audio capture (US-009, Linux only).
//!
//! Captures the PulseAudio/PipeWire default sink monitor and encodes Opus,
//! muxed as Ogg on stdout. The default sink's monitor is what "record what
//! is playing" means on PulseAudio; passing `default` as the device and
//! letting ffmpeg's pulse input follow the server default avoids hardcoding
//! a device name (the box's sink is an HDMI output whose name is not
//! portable).

use std::io::Read;
use std::process::{Child, ChildStdout, Command, Stdio};

use anyhow::{Context, Result};

use super::linux::{AudioPacket, AudioSource, FRAME_MS, SAMPLES_PER_FRAME, SAMPLE_RATE};
use super::ogg::OggReader;

pub struct FfmpegAudioSource {
    child: Child,
    stdout: ChildStdout,
    reader: OggReader,
    pending: std::collections::VecDeque<Vec<u8>>,
    chunk: [u8; 8192],
    /// Encoded Opus frames so far; the timestamp counts samples, not wall
    /// clock, so it is jitter-free.
    frames_sent: u64,
    /// True once the two Opus header packets (OpusHead, OpusTags) are seen.
    header_dropped: usize,
}

/// The monitor source to capture: the default sink's monitor, resolved with
/// `pactl get-default-sink`. That monitor is what "record what is playing"
/// means on PulseAudio/PipeWire, and resolving it at runtime avoids
/// hardcoding a device name that differs per machine. Falls back to the
/// literal "default" (the default source) when pactl is unavailable.
fn default_monitor() -> String {
    let output = Command::new("pactl").arg("get-default-sink").output();
    if let Ok(output) = output {
        if output.status.success() {
            let sink = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !sink.is_empty() {
                return format!("{sink}.monitor");
            }
        }
    }
    tracing::warn!("could not resolve the default sink monitor, using the default source");
    "default".to_string()
}

impl FfmpegAudioSource {
    pub fn new() -> Result<Self> {
        let monitor = default_monitor();
        tracing::info!(device = %monitor, "capturing desktop audio");
        let mut cmd = Command::new("ffmpeg");
        cmd.args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "pulse",
            "-i",
            &monitor,
            "-ac",
            "2",
            "-ar",
            &SAMPLE_RATE.to_string(),
            "-c:a",
            "libopus",
            "-application",
            "lowdelay",
            "-frame_duration",
            &FRAME_MS.to_string(),
            "-b:a",
            "128k",
            "-f",
            "ogg",
            "-",
        ]);
        cmd.stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        tracing::debug!(command = ?cmd, "spawning ffmpeg audio capture");
        let mut child = cmd
            .spawn()
            .context("failed to spawn ffmpeg for audio (is it installed?)")?;
        let stdout = child
            .stdout
            .take()
            .context("ffmpeg audio stdout not piped")?;
        Ok(Self {
            child,
            stdout,
            reader: OggReader::default(),
            pending: std::collections::VecDeque::new(),
            chunk: [0u8; 8192],
            frames_sent: 0,
            header_dropped: 0,
        })
    }

    fn timestamp_us(&self) -> u64 {
        // Samples elapsed at 48 kHz, converted to microseconds.
        self.frames_sent * SAMPLES_PER_FRAME * 1_000_000 / u64::from(SAMPLE_RATE)
    }
}

impl AudioSource for FfmpegAudioSource {
    fn next_packet(&mut self) -> Result<Option<AudioPacket>> {
        loop {
            if let Some(opus) = self.pending.pop_front() {
                // The first two packets are OpusHead and OpusTags, not audio.
                if self.header_dropped < 2 {
                    self.header_dropped += 1;
                    continue;
                }
                let timestamp_us = self.timestamp_us();
                self.frames_sent += 1;
                return Ok(Some(AudioPacket {
                    data: opus,
                    timestamp_us,
                }));
            }
            let read = self
                .stdout
                .read(&mut self.chunk)
                .context("reading ffmpeg audio output")?;
            if read == 0 {
                return Ok(None); // ffmpeg exited
            }
            for packet in self.reader.feed(&self.chunk[..read]) {
                self.pending.push_back(packet);
            }
        }
    }
}

impl Drop for FfmpegAudioSource {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
