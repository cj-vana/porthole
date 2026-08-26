//! Porthole wire protocol (US-003). See docs/protocol.md for the prose spec.
//!
//! Two channels: UDP video datagrams (fragmented access units) and a TCP
//! control channel (length-prefixed messages). All multi-byte integers are
//! big-endian.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::time::{Duration, Instant};

/// Magic bytes at the start of every video datagram: "PHV".
pub const VIDEO_MAGIC: [u8; 3] = *b"PHV";
/// Wire format version.
pub const PROTOCOL_VERSION: u8 = 1;
/// Video datagram header length in bytes.
pub const VIDEO_HEADER_LEN: usize = 25;
/// Video header flag: the access unit is independently decodable.
pub const VIDEO_FLAG_KEYFRAME: u8 = 1 << 0;
/// Video header flag: this datagram is the XOR repair shard for the frame.
/// Its fragment index equals (rather than precedes) `frag_count`.
pub const VIDEO_FLAG_REPAIR: u8 = 1 << 1;
/// Repair payload prefix containing the true final-fragment byte count.
pub const VIDEO_REPAIR_PREFIX_LEN: usize = 2;
/// Datagram size ceiling; safe under a 1500-byte MTU. Receivers accept
/// anything up to this.
pub const MAX_DATAGRAM_SIZE: usize = 1400;
/// Largest access-unit payload per datagram at the ceiling.
pub const MAX_FRAGMENT_PAYLOAD: usize = MAX_DATAGRAM_SIZE - VIDEO_HEADER_LEN;
/// Smallest datagram size worth fragmenting at (header plus some payload).
pub const MIN_DATAGRAM_SIZE: usize = 200;
/// IPv4 header (20) plus UDP header (8): the bytes an MTU spends before
/// the datagram payload starts.
pub const IP_UDP_OVERHEAD: usize = 28;

/// Datagram size for a path MTU, clamped to the protocol's bounds. The
/// default agent MTU of 1280 (IPv6 minimum, WireGuard/Tailscale tunnel
/// MTU) gives 1252-byte datagrams.
pub fn datagram_size_for_mtu(mtu: usize) -> usize {
    mtu.saturating_sub(IP_UDP_OVERHEAD)
        .clamp(MIN_DATAGRAM_SIZE, MAX_DATAGRAM_SIZE)
}

/// Magic bytes at the start of every audio datagram: "PHA" (US-009).
pub const AUDIO_MAGIC: [u8; 3] = *b"PHA";
/// Audio datagram header length: magic(3) + version(1) + seq(4) + ts(8).
pub const AUDIO_HEADER_LEN: usize = 16;

/// Build one audio datagram: header + one Opus packet. `timestamp_us` is
/// microseconds on the agent pipeline clock (the same clock as the video
/// datagram timestamps and pong answers), so the client can line audio up
/// with video.
pub fn audio_datagram(sequence: u32, timestamp_us: u64, opus: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(AUDIO_HEADER_LEN + opus.len());
    out.extend_from_slice(&AUDIO_MAGIC);
    out.push(PROTOCOL_VERSION);
    out.extend_from_slice(&sequence.to_be_bytes());
    out.extend_from_slice(&timestamp_us.to_be_bytes());
    out.extend_from_slice(opus);
    out
}

/// Parse one audio datagram into (sequence, timestamp_us, Opus packet).
/// None when the magic, version, or length is wrong.
pub fn parse_audio_datagram(bytes: &[u8]) -> Option<(u32, u64, &[u8])> {
    if bytes.len() <= AUDIO_HEADER_LEN || bytes[0..3] != AUDIO_MAGIC || bytes[3] != PROTOCOL_VERSION
    {
        return None;
    }
    let sequence = u32::from_be_bytes(bytes[4..8].try_into().ok()?);
    let timestamp_us = u64::from_be_bytes(bytes[8..16].try_into().ok()?);
    Some((sequence, timestamp_us, &bytes[AUDIO_HEADER_LEN..]))
}

/// Control message type: server -> client stream parameters.
pub const CONTROL_MSG_HELLO: u8 = 1;
/// Control message type: client -> server, please send a fresh IDR.
pub const CONTROL_MSG_KEYFRAME_REQUEST: u8 = 2;
/// Control message type: client -> agent latency probe.
pub const CONTROL_MSG_PING: u8 = 3;
/// Control message type: agent -> client answer to a ping.
pub const CONTROL_MSG_PONG: u8 = 4;
/// Control message type: agent -> client per-second pipeline stats.
pub const CONTROL_MSG_AGENT_STATS: u8 = 5;
/// Control message type: client -> agent stream reconfiguration (US-013).
pub const CONTROL_MSG_SETTINGS: u8 = 6;

/// settings payload length.
pub const SETTINGS_PAYLOAD_LEN: usize = 6;

/// Stream reconfiguration a client asks for at runtime (gaming mode,
/// US-013): a different framerate, codec, or bitrate, and whether to bias
/// the encoder toward latency over quality. The agent applies it by
/// restarting the encoder and answering with a fresh [`Hello`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Settings {
    pub fps: u16,
    pub codec: CodecTag,
    pub bitrate_mbps: u16,
    /// Bias the encoder toward latency (gaming) rather than quality.
    pub low_latency: bool,
}

impl Settings {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(SETTINGS_PAYLOAD_LEN);
        out.extend_from_slice(&self.fps.to_be_bytes());
        out.push(self.codec as u8);
        out.extend_from_slice(&self.bitrate_mbps.to_be_bytes());
        out.push(u8::from(self.low_latency));
        out
    }

    pub fn decode(payload: &[u8]) -> Option<Self> {
        if payload.len() != SETTINGS_PAYLOAD_LEN {
            return None;
        }
        Some(Self {
            fps: u16::from_be_bytes(payload[0..2].try_into().ok()?),
            codec: CodecTag::from_u8(payload[2])?,
            bitrate_mbps: u16::from_be_bytes(payload[3..5].try_into().ok()?),
            low_latency: payload[5] != 0,
        })
    }
}

/// ping payload: the client's own monotonic timestamp in microseconds.
pub const PING_PAYLOAD_LEN: usize = 8;
/// pong payload: echoed client timestamp + agent pipeline timestamp.
pub const PONG_PAYLOAD_LEN: usize = 16;
/// agent_stats payload length.
pub const AGENT_STATS_PAYLOAD_LEN: usize = 14;

/// Client latency probe (docs/protocol.md "ping").
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ping {
    pub client_timestamp_us: u64,
}

impl Ping {
    pub fn encode(&self) -> Vec<u8> {
        self.client_timestamp_us.to_be_bytes().to_vec()
    }

    pub fn decode(payload: &[u8]) -> Option<Self> {
        if payload.len() != PING_PAYLOAD_LEN {
            return None;
        }
        Some(Self {
            client_timestamp_us: u64::from_be_bytes(payload[0..8].try_into().ok()?),
        })
    }
}

/// Agent answer to a ping: the client's timestamp back, plus the agent's
/// pipeline clock (same clock as the video datagram timestamps).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Pong {
    pub client_timestamp_us: u64,
    pub agent_timestamp_us: u64,
}

impl Pong {
    pub fn encode(&self) -> Vec<u8> {
        [
            self.client_timestamp_us.to_be_bytes(),
            self.agent_timestamp_us.to_be_bytes(),
        ]
        .concat()
    }

    pub fn decode(payload: &[u8]) -> Option<Self> {
        if payload.len() != PONG_PAYLOAD_LEN {
            return None;
        }
        Some(Self {
            client_timestamp_us: u64::from_be_bytes(payload[0..8].try_into().ok()?),
            agent_timestamp_us: u64::from_be_bytes(payload[8..16].try_into().ok()?),
        })
    }
}

/// Per-second agent pipeline stats (docs/protocol.md "agent_stats").
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct AgentStats {
    pub capture_fps: u16,
    pub encode_fps: u16,
    /// Mean submit-to-access-unit latency over the last second.
    pub encode_latency_us: u32,
    pub tx_kbps: u32,
    pub keyframes: u16,
}

impl AgentStats {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(AGENT_STATS_PAYLOAD_LEN);
        out.extend_from_slice(&self.capture_fps.to_be_bytes());
        out.extend_from_slice(&self.encode_fps.to_be_bytes());
        out.extend_from_slice(&self.encode_latency_us.to_be_bytes());
        out.extend_from_slice(&self.tx_kbps.to_be_bytes());
        out.extend_from_slice(&self.keyframes.to_be_bytes());
        out
    }

    pub fn decode(payload: &[u8]) -> Option<Self> {
        if payload.len() != AGENT_STATS_PAYLOAD_LEN {
            return None;
        }
        Some(Self {
            capture_fps: u16::from_be_bytes(payload[0..2].try_into().ok()?),
            encode_fps: u16::from_be_bytes(payload[2..4].try_into().ok()?),
            encode_latency_us: u32::from_be_bytes(payload[4..8].try_into().ok()?),
            tx_kbps: u32::from_be_bytes(payload[8..12].try_into().ok()?),
            keyframes: u16::from_be_bytes(payload[12..14].try_into().ok()?),
        })
    }
}

/// Control message type: clipboard text, either direction (US-008).
pub const CONTROL_MSG_CLIPBOARD: u8 = 7;
/// Control message type: client -> agent gamepad state (US-014).
pub const CONTROL_MSG_GAMEPAD: u8 = 8;

/// Clipboard text sync (US-008). Sent by whichever side's clipboard changed;
/// the payload is UTF-8 text (no trailing NUL). Loop prevention is the
/// receiver's job: it remembers the text it was handed and does not echo an
/// identical value back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Clipboard {
    pub text: String,
}

impl Clipboard {
    pub fn encode(&self) -> Vec<u8> {
        self.text.as_bytes().to_vec()
    }

    pub fn decode(payload: &[u8]) -> Option<Self> {
        Some(Self {
            text: String::from_utf8(payload.to_vec()).ok()?,
        })
    }
}

/// gamepad_state payload length: buttons(4) + 6 axes(2 each) + hat(1).
pub const GAMEPAD_PAYLOAD_LEN: usize = 4 + 12 + 1;

/// Gamepad state (US-014), sent by the client whenever a control changes.
/// The agent maps it onto a virtual uinput gamepad.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct GamepadState {
    /// Bitmask of pressed buttons; bit order matches the SDL/XInput layout
    /// documented in docs/protocol.md.
    pub buttons: u32,
    /// Left stick x/y, right stick x/y, left trigger, right trigger, each
    /// -32768..32767 (triggers use 0..32767).
    pub axes: [i16; 6],
    /// D-pad hat: 0 centered, 1 up, 2 right, 4 down, 8 left, combined for
    /// diagonals (matches the common 8-way encoding).
    pub hat: u8,
}

impl GamepadState {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(GAMEPAD_PAYLOAD_LEN);
        out.extend_from_slice(&self.buttons.to_be_bytes());
        for axis in self.axes {
            out.extend_from_slice(&axis.to_be_bytes());
        }
        out.push(self.hat);
        out
    }

    pub fn decode(payload: &[u8]) -> Option<Self> {
        if payload.len() != GAMEPAD_PAYLOAD_LEN {
            return None;
        }
        let buttons = u32::from_be_bytes(payload[0..4].try_into().ok()?);
        let mut axes = [0i16; 6];
        for (index, axis) in axes.iter_mut().enumerate() {
            let start = 4 + index * 2;
            *axis = i16::from_be_bytes(payload[start..start + 2].try_into().ok()?);
        }
        Some(Self {
            buttons,
            axes,
            hat: payload[16],
        })
    }
}

// Input messages (client -> agent, US-006). All are fixed-size.
/// Pointer moved to absolute output pixel coordinates.
pub const CONTROL_MSG_POINTER_MOTION_ABS: u8 = 0x10;
/// Pointer moved by a relative delta, in 1/256 pixel units (wl_fixed).
pub const CONTROL_MSG_POINTER_MOTION_REL: u8 = 0x11;
/// Pointer button press/release (evdev BTN_* code).
pub const CONTROL_MSG_POINTER_BUTTON: u8 = 0x12;
/// Pointer scroll/axis event.
pub const CONTROL_MSG_POINTER_AXIS: u8 = 0x13;
/// Keyboard key press/release (evdev KEY_* code).
pub const CONTROL_MSG_KEY: u8 = 0x14;
/// Keyboard modifier state (xkb masks: depressed/latched/locked/group).
pub const CONTROL_MSG_KEY_MODIFIERS: u8 = 0x15;

/// Axis identifiers for pointer_axis (values match wl_pointer.axis).
pub const AXIS_VERTICAL: u8 = 0;
pub const AXIS_HORIZONTAL: u8 = 1;

/// Axis sources for pointer_axis (values match wl_pointer.axis_source).
pub const AXIS_SOURCE_WHEEL: u8 = 0;
pub const AXIS_SOURCE_FINGER: u8 = 1;
pub const AXIS_SOURCE_CONTINUOUS: u8 = 2;

/// One input event from the client. Encoded as fixed-size control message
/// payloads; see docs/protocol.md for the layout.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputEvent {
    /// Absolute position in output pixels.
    PointerMotionAbs { x: i32, y: i32 },
    /// Relative delta in 1/256 pixel units.
    PointerMotionRel { dx256: i32, dy256: i32 },
    /// evdev BTN_* code (e.g. 0x110 = left), pressed = true on press.
    PointerButton { button: u16, pressed: bool },
    /// Scroll: axis (AXIS_VERTICAL/HORIZONTAL), source (AXIS_SOURCE_*),
    /// value in 1/256 pixel units (2560 = one wheel click, 10 px).
    PointerAxis { axis: u8, source: u8, value256: i32 },
    /// evdev KEY_* code, pressed = true on press.
    Key { code: u16, pressed: bool },
    /// xkb modifier masks, matching virtual-keyboard modifiers().
    /// Bit order is the classic X11/xkb order: 0 Shift, 1 Lock,
    /// 2 Control, 3 Mod1 (Alt), 6 Mod4 (Super).
    KeyModifiers {
        depressed: u32,
        latched: u32,
        locked: u32,
        group: u32,
    },
}

impl InputEvent {
    /// Encode to (message type, payload).
    pub fn encode(&self) -> (u8, Vec<u8>) {
        match *self {
            Self::PointerMotionAbs { x, y } => (
                CONTROL_MSG_POINTER_MOTION_ABS,
                [x.to_be_bytes(), y.to_be_bytes()].concat(),
            ),
            Self::PointerMotionRel { dx256, dy256 } => (
                CONTROL_MSG_POINTER_MOTION_REL,
                [dx256.to_be_bytes(), dy256.to_be_bytes()].concat(),
            ),
            Self::PointerButton { button, pressed } => (
                CONTROL_MSG_POINTER_BUTTON,
                [button.to_be_bytes().as_slice(), &[u8::from(pressed)]].concat(),
            ),
            Self::PointerAxis {
                axis,
                source,
                value256,
            } => (
                CONTROL_MSG_POINTER_AXIS,
                [&[axis, source][..], value256.to_be_bytes().as_slice()].concat(),
            ),
            Self::Key { code, pressed } => (
                CONTROL_MSG_KEY,
                [code.to_be_bytes().as_slice(), &[u8::from(pressed)]].concat(),
            ),
            Self::KeyModifiers {
                depressed,
                latched,
                locked,
                group,
            } => (
                CONTROL_MSG_KEY_MODIFIERS,
                [
                    depressed.to_be_bytes(),
                    latched.to_be_bytes(),
                    locked.to_be_bytes(),
                    group.to_be_bytes(),
                ]
                .concat(),
            ),
        }
    }

    /// Decode from (message type, payload); None for unknown types or wrong
    /// payload lengths.
    pub fn decode(msg_type: u8, payload: &[u8]) -> Option<Self> {
        let i32_at = |i: usize| -> Option<i32> {
            Some(i32::from_be_bytes(payload.get(i..i + 4)?.try_into().ok()?))
        };
        let u16_at = |i: usize| -> Option<u16> {
            Some(u16::from_be_bytes(payload.get(i..i + 2)?.try_into().ok()?))
        };
        let u32_at = |i: usize| -> Option<u32> {
            Some(u32::from_be_bytes(payload.get(i..i + 4)?.try_into().ok()?))
        };
        match msg_type {
            CONTROL_MSG_POINTER_MOTION_ABS if payload.len() == 8 => Some(Self::PointerMotionAbs {
                x: i32_at(0)?,
                y: i32_at(4)?,
            }),
            CONTROL_MSG_POINTER_MOTION_REL if payload.len() == 8 => Some(Self::PointerMotionRel {
                dx256: i32_at(0)?,
                dy256: i32_at(4)?,
            }),
            CONTROL_MSG_POINTER_BUTTON if payload.len() == 3 => Some(Self::PointerButton {
                button: u16_at(0)?,
                pressed: payload[2] != 0,
            }),
            CONTROL_MSG_POINTER_AXIS if payload.len() == 6 => Some(Self::PointerAxis {
                axis: payload[0],
                source: payload[1],
                value256: i32_at(2)?,
            }),
            CONTROL_MSG_KEY if payload.len() == 3 => Some(Self::Key {
                code: u16_at(0)?,
                pressed: payload[2] != 0,
            }),
            CONTROL_MSG_KEY_MODIFIERS if payload.len() == 16 => Some(Self::KeyModifiers {
                depressed: u32_at(0)?,
                latched: u32_at(4)?,
                locked: u32_at(8)?,
                group: u32_at(12)?,
            }),
            _ => None,
        }
    }
}

/// Write one input event as a framed control message.
pub fn write_input_event(stream: &mut impl Write, event: &InputEvent) -> std::io::Result<()> {
    let (msg_type, payload) = event.encode();
    write_control_message(stream, msg_type, &payload)
}

/// Codec tag on the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodecTag {
    H264 = 0,
    Hevc = 1,
}

impl CodecTag {
    pub fn from_u8(v: u8) -> Option<Self> {
        match v {
            0 => Some(Self::H264),
            1 => Some(Self::Hevc),
            _ => None,
        }
    }
}

/// Video datagram header (parsed or about-to-send).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VideoHeader {
    /// Access unit sequence number (monotonic, survives encoder restarts).
    pub frame_seq: u64,
    /// Sender timestamp: microseconds since the agent's pipeline start,
    /// taken from the captured frame this AU encodes.
    pub timestamp_us: u64,
    pub frag_index: u16,
    pub frag_count: u16,
    pub is_keyframe: bool,
    pub is_repair: bool,
}

/// Fragment one access unit into datagrams of at most `datagram_size`
/// bytes (header + payload each). Sizes outside the protocol bounds are
/// clamped; see [`datagram_size_for_mtu`].
pub fn fragment(
    au: &[u8],
    frame_seq: u64,
    timestamp_us: u64,
    is_keyframe: bool,
    datagram_size: usize,
) -> Vec<Vec<u8>> {
    let payload_size = datagram_size.clamp(MIN_DATAGRAM_SIZE, MAX_DATAGRAM_SIZE) - VIDEO_HEADER_LEN;
    let frag_count = au.len().div_ceil(payload_size).max(1) as u16;
    let mut out = Vec::with_capacity(frag_count as usize);
    for (index, chunk) in au.chunks(payload_size).enumerate() {
        let mut dgram = Vec::with_capacity(VIDEO_HEADER_LEN + chunk.len());
        dgram.extend_from_slice(&VIDEO_MAGIC);
        dgram.push(PROTOCOL_VERSION);
        dgram.extend_from_slice(&frame_seq.to_be_bytes());
        dgram.extend_from_slice(&timestamp_us.to_be_bytes());
        dgram.extend_from_slice(&(index as u16).to_be_bytes());
        dgram.extend_from_slice(&frag_count.to_be_bytes());
        dgram.push(if is_keyframe { VIDEO_FLAG_KEYFRAME } else { 0 });
        dgram.extend_from_slice(chunk);
        out.push(dgram);
    }
    out
}

/// Fragment one access unit and append a zero-wait XOR repair shard.
///
/// Losing any one data datagram no longer loses the frame: the receiver XORs
/// the remaining fragments with the repair payload to recreate it locally.
/// The repair shard is sent after the data, so loss-free frames complete on
/// the exact same datagram as before and pay no extra receive-side latency.
/// Two bytes are reserved from each path-sized payload so the repair shard can
/// carry the true final-fragment length without exceeding the configured MTU.
/// Old receivers ignore the repair datagram (its index is outside their
/// accepted data range) and still decode every data fragment normally.
pub fn fragment_with_repair(
    au: &[u8],
    frame_seq: u64,
    timestamp_us: u64,
    is_keyframe: bool,
    datagram_size: usize,
) -> Vec<Vec<u8>> {
    let datagram_size = datagram_size.clamp(MIN_DATAGRAM_SIZE, MAX_DATAGRAM_SIZE);
    let payload_size = datagram_size - VIDEO_HEADER_LEN - VIDEO_REPAIR_PREFIX_LEN;
    let frag_count = au.len().div_ceil(payload_size).max(1) as u16;
    let flags = if is_keyframe { VIDEO_FLAG_KEYFRAME } else { 0 };
    let mut repair = vec![0u8; payload_size];
    let mut out = Vec::with_capacity(frag_count as usize + 1);

    for index in 0..usize::from(frag_count) {
        let start = index * payload_size;
        let end = (start + payload_size).min(au.len());
        let chunk = &au[start..end];
        for (parity, byte) in repair.iter_mut().zip(chunk) {
            *parity ^= *byte;
        }

        let mut dgram = Vec::with_capacity(VIDEO_HEADER_LEN + chunk.len());
        dgram.extend_from_slice(&VIDEO_MAGIC);
        dgram.push(PROTOCOL_VERSION);
        dgram.extend_from_slice(&frame_seq.to_be_bytes());
        dgram.extend_from_slice(&timestamp_us.to_be_bytes());
        dgram.extend_from_slice(&(index as u16).to_be_bytes());
        dgram.extend_from_slice(&frag_count.to_be_bytes());
        dgram.push(flags);
        dgram.extend_from_slice(chunk);
        out.push(dgram);
    }

    let final_len = au
        .len()
        .saturating_sub(usize::from(frag_count.saturating_sub(1)) * payload_size);
    let mut repair_dgram = Vec::with_capacity(datagram_size);
    repair_dgram.extend_from_slice(&VIDEO_MAGIC);
    repair_dgram.push(PROTOCOL_VERSION);
    repair_dgram.extend_from_slice(&frame_seq.to_be_bytes());
    repair_dgram.extend_from_slice(&timestamp_us.to_be_bytes());
    repair_dgram.extend_from_slice(&frag_count.to_be_bytes());
    repair_dgram.extend_from_slice(&frag_count.to_be_bytes());
    repair_dgram.push(flags | VIDEO_FLAG_REPAIR);
    repair_dgram.extend_from_slice(&(final_len as u16).to_be_bytes());
    repair_dgram.extend_from_slice(&repair);
    out.push(repair_dgram);
    out
}

/// Parse a video datagram into (header, payload). Returns None on malformed
/// input (short, wrong magic, wrong version, bad fragment fields).
pub fn parse_datagram(bytes: &[u8]) -> Option<(VideoHeader, &[u8])> {
    if bytes.len() < VIDEO_HEADER_LEN {
        return None;
    }
    if bytes[0..3] != VIDEO_MAGIC || bytes[3] != PROTOCOL_VERSION {
        return None;
    }
    let frame_seq = u64::from_be_bytes(bytes[4..12].try_into().ok()?);
    let timestamp_us = u64::from_be_bytes(bytes[12..20].try_into().ok()?);
    let frag_index = u16::from_be_bytes(bytes[20..22].try_into().ok()?);
    let frag_count = u16::from_be_bytes(bytes[22..24].try_into().ok()?);
    let flags = bytes[24];
    let is_keyframe = flags & VIDEO_FLAG_KEYFRAME != 0;
    let is_repair = flags & VIDEO_FLAG_REPAIR != 0;
    if frag_count == 0
        || (!is_repair && frag_index >= frag_count)
        || (is_repair && frag_index != frag_count)
    {
        return None;
    }
    let payload = &bytes[VIDEO_HEADER_LEN..];
    if payload.is_empty() || (is_repair && payload.len() <= VIDEO_REPAIR_PREFIX_LEN) {
        return None;
    }
    Some((
        VideoHeader {
            frame_seq,
            timestamp_us,
            frag_index,
            frag_count,
            is_keyframe,
            is_repair,
        },
        payload,
    ))
}

/// A fully reassembled access unit.
#[derive(Debug)]
pub struct AssembledFrame {
    pub frame_seq: u64,
    pub timestamp_us: u64,
    pub is_keyframe: bool,
    pub data: Vec<u8>,
}

struct PartialFrame {
    timestamp_us: u64,
    is_keyframe: bool,
    frag_count: u16,
    received: u16,
    total_bytes: usize,
    fragments: Vec<Option<Vec<u8>>>,
    repair: Option<(usize, Vec<u8>)>,
    first_seen: Instant,
}

/// Reassembles fragmented access units. A frame is dropped (counted lost)
/// when a fragment is missing and the frame goes stale.
pub struct Reassembler {
    frames: HashMap<u64, PartialFrame>,
    highest_completed: Option<u64>,
    /// Frame seqs older than this without completing are dropped as lost.
    pub max_frame_age: Duration,
}

impl Default for Reassembler {
    fn default() -> Self {
        Self {
            frames: HashMap::new(),
            highest_completed: None,
            max_frame_age: Duration::from_millis(500),
        }
    }
}

impl Reassembler {
    /// Push one datagram. Returns the assembled access unit when this
    /// fragment completes its frame.
    pub fn push(&mut self, header: VideoHeader, payload: &[u8]) -> Option<AssembledFrame> {
        if header.is_repair
            && self
                .highest_completed
                .is_some_and(|seq| header.frame_seq <= seq)
        {
            return None;
        }
        let entry = self
            .frames
            .entry(header.frame_seq)
            .or_insert_with(|| PartialFrame {
                timestamp_us: header.timestamp_us,
                is_keyframe: header.is_keyframe,
                frag_count: header.frag_count,
                received: 0,
                total_bytes: 0,
                fragments: vec![None; header.frag_count as usize],
                repair: None,
                first_seen: Instant::now(),
            });
        // Consistency: conflicting metadata for the same seq means loss or
        // corruption; drop the frame.
        if entry.frag_count != header.frag_count {
            self.frames.remove(&header.frame_seq);
            return None;
        }
        if header.is_repair {
            let final_len = usize::from(u16::from_be_bytes([payload[0], payload[1]]));
            let parity = &payload[VIDEO_REPAIR_PREFIX_LEN..];
            if final_len == 0 || final_len > parity.len() {
                self.frames.remove(&header.frame_seq);
                return None;
            }
            entry.repair = Some((final_len, parity.to_vec()));
        } else {
            let slot = &mut entry.fragments[header.frag_index as usize];
            if slot.is_none() {
                *slot = Some(payload.to_vec());
                entry.received += 1;
                entry.total_bytes += payload.len();
            }
        }

        if entry.received + 1 == entry.frag_count {
            let missing = entry.fragments.iter().position(Option::is_none);
            if let (Some(missing), Some((final_len, parity))) = (missing, entry.repair.as_ref()) {
                let mut recovered = parity.clone();
                let mut valid = true;
                for (index, fragment) in entry.fragments.iter().enumerate() {
                    let Some(fragment) = fragment else { continue };
                    let expected_len = if index + 1 == entry.fragments.len() {
                        *final_len
                    } else {
                        parity.len()
                    };
                    if fragment.len() != expected_len {
                        valid = false;
                        break;
                    }
                    for (byte, received) in recovered.iter_mut().zip(fragment) {
                        *byte ^= *received;
                    }
                }
                if valid {
                    let recovered_len = if missing + 1 == entry.fragments.len() {
                        *final_len
                    } else {
                        parity.len()
                    };
                    recovered.truncate(recovered_len);
                    entry.total_bytes += recovered.len();
                    entry.fragments[missing] = Some(recovered);
                    entry.received += 1;
                }
            }
        }
        if entry.received == entry.frag_count {
            let entry = self.frames.remove(&header.frame_seq).expect("present");
            let mut data = Vec::with_capacity(entry.total_bytes);
            for frag in entry.fragments.into_iter() {
                data.extend_from_slice(&frag.expect("all fragments present"));
            }
            self.highest_completed = Some(
                self.highest_completed
                    .map_or(header.frame_seq, |seq| seq.max(header.frame_seq)),
            );
            return Some(AssembledFrame {
                frame_seq: header.frame_seq,
                timestamp_us: entry.timestamp_us,
                is_keyframe: entry.is_keyframe,
                data,
            });
        }
        None
    }

    /// Drop and return the seqs of frames that went stale incomplete (lost).
    pub fn sweep(&mut self) -> Vec<u64> {
        let stale: Vec<u64> = self
            .frames
            .iter()
            .filter(|(_, f)| f.first_seen.elapsed() > self.max_frame_age)
            .map(|(&seq, _)| seq)
            .collect();
        for seq in &stale {
            self.frames.remove(seq);
        }
        stale
    }

    /// Number of frames currently held incomplete.
    pub fn pending(&self) -> usize {
        self.frames.len()
    }
}

/// Hello payload layout (after the 1-byte type):
/// codec u8, width u32, height u32, fps u32, bitrate_mbps u32,
/// keyframe_interval_secs u32, video_port u16. All big-endian.
pub const HELLO_PAYLOAD_LEN: usize = 23;

/// Stream parameters sent by the agent on control connect.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Hello {
    pub codec: CodecTag,
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub bitrate_mbps: u32,
    pub keyframe_interval_secs: u32,
    /// UDP port the agent sends video to on the client's address.
    pub video_port: u16,
}

impl Hello {
    pub fn encode(&self) -> Vec<u8> {
        let mut payload = Vec::with_capacity(HELLO_PAYLOAD_LEN);
        payload.push(self.codec as u8);
        payload.extend_from_slice(&self.width.to_be_bytes());
        payload.extend_from_slice(&self.height.to_be_bytes());
        payload.extend_from_slice(&self.fps.to_be_bytes());
        payload.extend_from_slice(&self.bitrate_mbps.to_be_bytes());
        payload.extend_from_slice(&self.keyframe_interval_secs.to_be_bytes());
        payload.extend_from_slice(&self.video_port.to_be_bytes());
        payload
    }

    pub fn decode(payload: &[u8]) -> Option<Self> {
        if payload.len() != HELLO_PAYLOAD_LEN {
            return None;
        }
        Some(Self {
            codec: CodecTag::from_u8(payload[0])?,
            width: u32::from_be_bytes(payload[1..5].try_into().ok()?),
            height: u32::from_be_bytes(payload[5..9].try_into().ok()?),
            fps: u32::from_be_bytes(payload[9..13].try_into().ok()?),
            bitrate_mbps: u32::from_be_bytes(payload[13..17].try_into().ok()?),
            keyframe_interval_secs: u32::from_be_bytes(payload[17..21].try_into().ok()?),
            video_port: u16::from_be_bytes(payload[21..23].try_into().ok()?),
        })
    }
}

/// Serialize one control message: 4-byte BE payload length (including the
/// 1-byte type) + type + payload.
pub fn encode_control_message(msg_type: u8, payload: &[u8]) -> Vec<u8> {
    let len = (payload.len() + 1) as u32;
    let mut out = Vec::with_capacity(4 + len as usize);
    out.extend_from_slice(&len.to_be_bytes());
    out.push(msg_type);
    out.extend_from_slice(payload);
    out
}

/// Write one framed control message to a stream.
pub fn write_control_message(
    stream: &mut impl Write,
    msg_type: u8,
    payload: &[u8],
) -> std::io::Result<()> {
    stream.write_all(&encode_control_message(msg_type, payload))
}

/// Read one framed control message; Ok(None) on clean EOF.
pub fn read_control_message(stream: &mut impl Read) -> std::io::Result<Option<(u8, Vec<u8>)>> {
    let mut len_buf = [0u8; 4];
    match stream.read_exact(&mut len_buf) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_be_bytes(len_buf) as usize;
    // Sanity bound: control payloads are tiny; 1 MiB is already absurd.
    if len == 0 || len > 1024 * 1024 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("implausible control message length {len}"),
        ));
    }
    let mut buf = vec![0u8; len];
    stream.read_exact(&mut buf)?;
    Ok(Some((buf[0], buf.split_off(1))))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_au(len: usize) -> Vec<u8> {
        (0..len).map(|i| (i % 251) as u8).collect()
    }

    #[test]
    fn fragment_reassemble_round_trip() {
        let au = sample_au(MAX_FRAGMENT_PAYLOAD * 3 + 17);
        let datagrams = fragment(&au, 42, 123_456_789, true, MAX_DATAGRAM_SIZE);
        assert_eq!(datagrams.len(), 4);

        let mut re = Reassembler::default();
        let mut assembled = None;
        for dgram in &datagrams {
            let (header, payload) = parse_datagram(dgram).expect("valid datagram");
            assert_eq!(header.frame_seq, 42);
            assert_eq!(header.timestamp_us, 123_456_789);
            assert!(header.is_keyframe);
            assert_eq!(header.frag_count, 4);
            if let Some(frame) = re.push(header, payload) {
                assembled = Some(frame);
            }
        }
        let frame = assembled.expect("frame complete");
        assert_eq!(frame.frame_seq, 42);
        assert!(frame.is_keyframe);
        assert_eq!(frame.data, au);
    }

    #[test]
    fn repair_shard_recovers_any_single_missing_fragment() {
        let au = sample_au(MAX_FRAGMENT_PAYLOAD * 4 + 73);
        let datagrams = fragment_with_repair(&au, 43, 987_654, true, MAX_DATAGRAM_SIZE);
        let (repair_header, repair_payload) = parse_datagram(datagrams.last().unwrap()).unwrap();
        assert!(repair_header.is_repair);
        assert!(repair_header.is_keyframe);
        assert_eq!(repair_header.frag_index, repair_header.frag_count);
        assert_eq!(repair_payload.len() + VIDEO_HEADER_LEN, MAX_DATAGRAM_SIZE);
        assert!(datagrams
            .iter()
            .all(|dgram| dgram.len() <= MAX_DATAGRAM_SIZE));

        let data_fragments = usize::from(repair_header.frag_count);
        for missing in 0..data_fragments {
            let mut reassembler = Reassembler::default();
            let mut assembled = None;
            for (index, datagram) in datagrams.iter().enumerate() {
                if index == missing {
                    continue;
                }
                let (header, payload) = parse_datagram(datagram).unwrap();
                if let Some(frame) = reassembler.push(header, payload) {
                    assembled = Some(frame);
                }
            }
            let frame = assembled.unwrap_or_else(|| panic!("fragment {missing} was not repaired"));
            assert_eq!(frame.frame_seq, 43);
            assert_eq!(frame.timestamp_us, 987_654);
            assert!(frame.is_keyframe);
            assert_eq!(frame.data, au);
            assert_eq!(reassembler.pending(), 0);
        }
    }

    #[test]
    fn repair_shard_is_redundant_when_data_is_complete() {
        let au = sample_au(MAX_FRAGMENT_PAYLOAD * 2 + 9);
        let datagrams = fragment_with_repair(&au, 44, 1, false, MAX_DATAGRAM_SIZE);
        let mut reassembler = Reassembler::default();
        let mut completed = 0;
        for datagram in &datagrams {
            let (header, payload) = parse_datagram(datagram).unwrap();
            if let Some(frame) = reassembler.push(header, payload) {
                completed += 1;
                assert_eq!(frame.data, au);
            }
        }
        assert_eq!(completed, 1);
        assert_eq!(reassembler.pending(), 0);
    }

    #[test]
    fn dropped_fragment_loses_frame() {
        let au = sample_au(MAX_FRAGMENT_PAYLOAD * 2);
        let datagrams = fragment(&au, 7, 1000, false, MAX_DATAGRAM_SIZE);
        assert_eq!(datagrams.len(), 2);

        let mut re = Reassembler::default();
        let (header, payload) = parse_datagram(&datagrams[0]).unwrap();
        assert!(
            re.push(header, payload).is_none(),
            "incomplete without fragment 1"
        );

        // Frame goes stale and is swept as lost.
        re.frames.get_mut(&7).unwrap().first_seen = Instant::now() - Duration::from_secs(1);
        assert_eq!(re.sweep(), vec![7]);
        assert_eq!(re.pending(), 0);
    }

    #[test]
    fn out_of_order_and_duplicate_fragments() {
        let au = sample_au(MAX_FRAGMENT_PAYLOAD + 5);
        let datagrams = fragment(&au, 9, 0, false, MAX_DATAGRAM_SIZE);
        let mut re = Reassembler::default();
        let (h1, p1) = parse_datagram(&datagrams[1]).unwrap();
        let (h0, p0) = parse_datagram(&datagrams[0]).unwrap();
        assert!(re.push(h1, p1).is_none());
        assert!(re.push(h1, p1).is_none(), "duplicate is idempotent");
        let frame = re.push(h0, p0).expect("completed out of order");
        assert_eq!(frame.data, au);
    }

    #[test]
    fn rejects_malformed_datagrams() {
        assert!(parse_datagram(b"short").is_none());
        let au = sample_au(10);
        let mut dgram = fragment(&au, 1, 0, false, MAX_DATAGRAM_SIZE).remove(0);
        dgram[0] = b'X'; // bad magic
        assert!(parse_datagram(&dgram).is_none());
        let mut dgram = fragment(&au, 1, 0, false, MAX_DATAGRAM_SIZE).remove(0);
        dgram[3] = 99; // bad version
        assert!(parse_datagram(&dgram).is_none());
    }

    #[test]
    fn fragment_honors_datagram_size() {
        let au = sample_au(5000);
        let small = fragment(&au, 1, 0, false, 500);
        assert!(small.iter().all(|d| d.len() <= 500));
        assert_eq!(small.len(), 5000_usize.div_ceil(500 - VIDEO_HEADER_LEN));
        // Below the floor and above the ceiling both clamp.
        assert!(fragment(&au, 1, 0, false, 10)
            .iter()
            .all(|d| d.len() <= MIN_DATAGRAM_SIZE));
        assert!(fragment(&au, 1, 0, false, 9000)
            .iter()
            .all(|d| d.len() <= MAX_DATAGRAM_SIZE));
        let mut re = Reassembler::default();
        let mut assembled = None;
        for dgram in &small {
            let (header, payload) = parse_datagram(dgram).unwrap();
            if let Some(frame) = re.push(header, payload) {
                assembled = Some(frame);
            }
        }
        assert_eq!(assembled.unwrap().data, au);
    }

    #[test]
    fn datagram_size_tracks_mtu() {
        assert_eq!(datagram_size_for_mtu(1280), 1252);
        assert_eq!(datagram_size_for_mtu(1500), 1400, "ceiling wins over 1472");
        assert_eq!(datagram_size_for_mtu(9000), MAX_DATAGRAM_SIZE);
        assert_eq!(datagram_size_for_mtu(100), MIN_DATAGRAM_SIZE);
        assert_eq!(datagram_size_for_mtu(0), MIN_DATAGRAM_SIZE);
    }

    #[test]
    fn audio_datagram_round_trip() {
        let opus = sample_au(180);
        let dgram = audio_datagram(7, 123_456, &opus);
        assert_eq!(dgram.len(), AUDIO_HEADER_LEN + opus.len());
        let (seq, ts, payload) = parse_audio_datagram(&dgram).expect("valid");
        assert_eq!(seq, 7);
        assert_eq!(ts, 123_456);
        assert_eq!(payload, &opus[..]);
        // Wrong magic, version, or an empty payload are rejected.
        let mut bad = dgram.clone();
        bad[0] = b'X';
        assert!(parse_audio_datagram(&bad).is_none());
        let mut bad = dgram.clone();
        bad[3] = 9;
        assert!(parse_audio_datagram(&bad).is_none());
        assert!(parse_audio_datagram(&audio_datagram(1, 0, &[])).is_none());
    }

    #[test]
    fn clipboard_and_gamepad_round_trip() {
        let clip = Clipboard {
            text: "hello \u{1f600} world".to_string(),
        };
        assert_eq!(Clipboard::decode(&clip.encode()), Some(clip.clone()));
        // Empty clipboard is valid (a cleared selection).
        assert_eq!(
            Clipboard::decode(&[]),
            Some(Clipboard {
                text: String::new()
            })
        );
        // Invalid UTF-8 is rejected.
        assert!(Clipboard::decode(&[0xff, 0xfe]).is_none());

        let pad = GamepadState {
            buttons: 0x0000_1234,
            axes: [-32768, 32767, 0, -1, 100, 200],
            hat: 6,
        };
        let payload = pad.encode();
        assert_eq!(payload.len(), GAMEPAD_PAYLOAD_LEN);
        assert_eq!(GamepadState::decode(&payload), Some(pad));
        assert!(GamepadState::decode(&[0; GAMEPAD_PAYLOAD_LEN - 1]).is_none());
        // Framed through the control channel.
        let framed = encode_control_message(CONTROL_MSG_GAMEPAD, &payload);
        let mut cursor = std::io::Cursor::new(framed);
        let (t, p) = read_control_message(&mut cursor).unwrap().expect("message");
        assert_eq!(t, CONTROL_MSG_GAMEPAD);
        assert_eq!(GamepadState::decode(&p), Some(pad));
    }

    #[test]
    fn settings_round_trip() {
        let settings = Settings {
            fps: 144,
            codec: CodecTag::Hevc,
            bitrate_mbps: 80,
            low_latency: true,
        };
        let payload = settings.encode();
        assert_eq!(payload.len(), SETTINGS_PAYLOAD_LEN);
        assert_eq!(Settings::decode(&payload), Some(settings));
        assert!(Settings::decode(&[0; 5]).is_none());
        assert!(Settings::decode(&[0; 7]).is_none());
        // Unknown codec tag is rejected.
        assert!(Settings::decode(&[0, 60, 9, 0, 40, 0]).is_none());
        // Framed through the control channel.
        let framed = encode_control_message(CONTROL_MSG_SETTINGS, &payload);
        let mut cursor = std::io::Cursor::new(framed);
        let (t, p) = read_control_message(&mut cursor).unwrap().expect("message");
        assert_eq!(t, CONTROL_MSG_SETTINGS);
        assert_eq!(Settings::decode(&p), Some(settings));
    }

    #[test]
    fn ping_pong_stats_round_trip() {
        let ping = Ping {
            client_timestamp_us: 0x0102_0304_0506_0708,
        };
        assert_eq!(ping.encode().len(), PING_PAYLOAD_LEN);
        assert_eq!(Ping::decode(&ping.encode()), Some(ping));
        assert!(Ping::decode(&[0; 7]).is_none());

        let pong = Pong {
            client_timestamp_us: 42,
            agent_timestamp_us: u64::MAX,
        };
        assert_eq!(pong.encode().len(), PONG_PAYLOAD_LEN);
        assert_eq!(Pong::decode(&pong.encode()), Some(pong));
        assert!(Pong::decode(&[0; 17]).is_none());

        let stats = AgentStats {
            capture_fps: 144,
            encode_fps: 60,
            encode_latency_us: 4_321,
            tx_kbps: 41_000,
            keyframes: 1,
        };
        let payload = stats.encode();
        assert_eq!(payload.len(), AGENT_STATS_PAYLOAD_LEN);
        assert_eq!(&payload[0..2], &[0, 144]);
        assert_eq!(AgentStats::decode(&payload), Some(stats));
        assert!(AgentStats::decode(&[0; 13]).is_none());

        // Framed through the control channel like the real thing.
        let framed = encode_control_message(CONTROL_MSG_PONG, &pong.encode());
        let mut cursor = std::io::Cursor::new(framed);
        let (t, p) = read_control_message(&mut cursor).unwrap().expect("message");
        assert_eq!(t, CONTROL_MSG_PONG);
        assert_eq!(Pong::decode(&p), Some(pong));
    }

    #[test]
    fn control_hello_round_trip() {
        let hello = Hello {
            codec: CodecTag::Hevc,
            width: 2560,
            height: 1440,
            fps: 60,
            bitrate_mbps: 40,
            keyframe_interval_secs: 2,
            video_port: 52800,
        };
        let framed = encode_control_message(CONTROL_MSG_HELLO, &hello.encode());
        let mut cursor = std::io::Cursor::new(framed);
        let (msg_type, payload) = read_control_message(&mut cursor).unwrap().expect("message");
        assert_eq!(msg_type, CONTROL_MSG_HELLO);
        assert_eq!(Hello::decode(&payload), Some(hello));
    }

    #[test]
    fn control_keyframe_request_round_trip() {
        let framed = encode_control_message(CONTROL_MSG_KEYFRAME_REQUEST, &[]);
        let mut cursor = std::io::Cursor::new(framed);
        let (msg_type, payload) = read_control_message(&mut cursor).unwrap().expect("message");
        assert_eq!(msg_type, CONTROL_MSG_KEYFRAME_REQUEST);
        assert!(payload.is_empty());
    }

    #[test]
    fn input_events_round_trip() {
        let events = [
            InputEvent::PointerMotionAbs { x: 500, y: 400 },
            InputEvent::PointerMotionAbs { x: -1, y: 0 },
            InputEvent::PointerMotionRel {
                dx256: 256,
                dy256: -128,
            },
            InputEvent::PointerButton {
                button: 0x110,
                pressed: true,
            },
            InputEvent::PointerButton {
                button: 0x111,
                pressed: false,
            },
            InputEvent::PointerAxis {
                axis: AXIS_VERTICAL,
                source: AXIS_SOURCE_CONTINUOUS,
                value256: 4250,
            },
            InputEvent::PointerAxis {
                axis: AXIS_HORIZONTAL,
                source: AXIS_SOURCE_WHEEL,
                value256: -2560,
            },
            InputEvent::Key {
                code: 35,
                pressed: true,
            }, // KEY_H
            InputEvent::Key {
                code: 28,
                pressed: false,
            }, // KEY_ENTER
            InputEvent::KeyModifiers {
                depressed: 1,
                latched: 0,
                locked: 0,
                group: 0,
            }, // shift
            InputEvent::KeyModifiers {
                depressed: 0,
                latched: 0,
                locked: 2,
                group: 1,
            }, // caps lock, group 1
        ];
        for event in events {
            let (msg_type, payload) = event.encode();
            assert_eq!(InputEvent::decode(msg_type, &payload), Some(event));
            // Full framed round-trip through a stream.
            let framed = encode_control_message(msg_type, &payload);
            let mut cursor = std::io::Cursor::new(framed);
            let (t, p) = read_control_message(&mut cursor).unwrap().expect("message");
            assert_eq!(InputEvent::decode(t, &p), Some(event));
        }
    }

    #[test]
    fn input_events_reject_malformed() {
        assert!(InputEvent::decode(CONTROL_MSG_POINTER_MOTION_ABS, &[0; 7]).is_none());
        assert!(InputEvent::decode(CONTROL_MSG_KEY, &[0; 2]).is_none());
        assert!(InputEvent::decode(CONTROL_MSG_KEY, &[0; 4]).is_none());
        assert!(InputEvent::decode(CONTROL_MSG_KEY_MODIFIERS, &[0; 15]).is_none());
        assert!(InputEvent::decode(CONTROL_MSG_KEY_MODIFIERS, &[0; 17]).is_none());
        assert!(InputEvent::decode(0x7f, &[0; 8]).is_none());
    }
}
