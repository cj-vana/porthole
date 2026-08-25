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
/// Maximum UDP payload (datagram) size; safe under a 1500-byte MTU.
pub const MAX_DATAGRAM_SIZE: usize = 1400;
/// Maximum access-unit payload per datagram.
pub const MAX_FRAGMENT_PAYLOAD: usize = MAX_DATAGRAM_SIZE - VIDEO_HEADER_LEN;

/// Control message type: server -> client stream parameters.
pub const CONTROL_MSG_HELLO: u8 = 1;
/// Control message type: client -> server, please send a fresh IDR.
pub const CONTROL_MSG_KEYFRAME_REQUEST: u8 = 2;

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
                [
                    &[axis, source][..],
                    value256.to_be_bytes().as_slice(),
                ]
                .concat(),
            ),
            Self::Key { code, pressed } => (
                CONTROL_MSG_KEY,
                [code.to_be_bytes().as_slice(), &[u8::from(pressed)]].concat(),
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
}

/// Fragment one access unit into MTU-safe datagrams (header + payload each).
pub fn fragment(au: &[u8], frame_seq: u64, timestamp_us: u64, is_keyframe: bool) -> Vec<Vec<u8>> {
    let frag_count = au.len().div_ceil(MAX_FRAGMENT_PAYLOAD).max(1) as u16;
    let mut out = Vec::with_capacity(frag_count as usize);
    for (index, chunk) in au.chunks(MAX_FRAGMENT_PAYLOAD).enumerate() {
        let mut dgram = Vec::with_capacity(VIDEO_HEADER_LEN + chunk.len());
        dgram.extend_from_slice(&VIDEO_MAGIC);
        dgram.push(PROTOCOL_VERSION);
        dgram.extend_from_slice(&frame_seq.to_be_bytes());
        dgram.extend_from_slice(&timestamp_us.to_be_bytes());
        dgram.extend_from_slice(&(index as u16).to_be_bytes());
        dgram.extend_from_slice(&frag_count.to_be_bytes());
        dgram.push(u8::from(is_keyframe));
        dgram.extend_from_slice(chunk);
        out.push(dgram);
    }
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
    let is_keyframe = bytes[24] & 1 != 0;
    if frag_count == 0 || frag_index >= frag_count {
        return None;
    }
    let payload = &bytes[VIDEO_HEADER_LEN..];
    if payload.is_empty() {
        return None;
    }
    Some((
        VideoHeader {
            frame_seq,
            timestamp_us,
            frag_index,
            frag_count,
            is_keyframe,
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
    first_seen: Instant,
}

/// Reassembles fragmented access units. A frame is dropped (counted lost)
/// when a fragment is missing and the frame goes stale.
pub struct Reassembler {
    frames: HashMap<u64, PartialFrame>,
    /// Frame seqs older than this without completing are dropped as lost.
    pub max_frame_age: Duration,
}

impl Default for Reassembler {
    fn default() -> Self {
        Self {
            frames: HashMap::new(),
            max_frame_age: Duration::from_millis(500),
        }
    }
}

impl Reassembler {
    /// Push one datagram. Returns the assembled access unit when this
    /// fragment completes its frame.
    pub fn push(&mut self, header: VideoHeader, payload: &[u8]) -> Option<AssembledFrame> {
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
                first_seen: Instant::now(),
            });
        // Consistency: conflicting metadata for the same seq means loss or
        // corruption; drop the frame.
        if entry.frag_count != header.frag_count {
            self.frames.remove(&header.frame_seq);
            return None;
        }
        let slot = &mut entry.fragments[header.frag_index as usize];
        if slot.is_none() {
            *slot = Some(payload.to_vec());
            entry.received += 1;
            entry.total_bytes += payload.len();
        }
        if entry.received == entry.frag_count {
            let entry = self.frames.remove(&header.frame_seq).expect("present");
            let mut data = Vec::with_capacity(entry.total_bytes);
            for frag in entry.fragments.into_iter() {
                data.extend_from_slice(&frag.expect("all fragments present"));
            }
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
pub fn write_control_message(stream: &mut impl Write, msg_type: u8, payload: &[u8]) -> std::io::Result<()> {
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
        let datagrams = fragment(&au, 42, 123_456_789, true);
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
    fn dropped_fragment_loses_frame() {
        let au = sample_au(MAX_FRAGMENT_PAYLOAD * 2);
        let datagrams = fragment(&au, 7, 1000, false);
        assert_eq!(datagrams.len(), 2);

        let mut re = Reassembler::default();
        let (header, payload) = parse_datagram(&datagrams[0]).unwrap();
        assert!(re.push(header, payload).is_none(), "incomplete without fragment 1");

        // Frame goes stale and is swept as lost.
        re.frames.get_mut(&7).unwrap().first_seen = Instant::now() - Duration::from_secs(1);
        assert_eq!(re.sweep(), vec![7]);
        assert_eq!(re.pending(), 0);
    }

    #[test]
    fn out_of_order_and_duplicate_fragments() {
        let au = sample_au(MAX_FRAGMENT_PAYLOAD + 5);
        let datagrams = fragment(&au, 9, 0, false);
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
        let mut dgram = fragment(&au, 1, 0, false).remove(0);
        dgram[0] = b'X'; // bad magic
        assert!(parse_datagram(&dgram).is_none());
        let mut dgram = fragment(&au, 1, 0, false).remove(0);
        dgram[3] = 99; // bad version
        assert!(parse_datagram(&dgram).is_none());
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
            InputEvent::PointerMotionRel { dx256: 256, dy256: -128 },
            InputEvent::PointerButton { button: 0x110, pressed: true },
            InputEvent::PointerButton { button: 0x111, pressed: false },
            InputEvent::PointerAxis { axis: AXIS_VERTICAL, source: AXIS_SOURCE_CONTINUOUS, value256: 4250 },
            InputEvent::PointerAxis { axis: AXIS_HORIZONTAL, source: AXIS_SOURCE_WHEEL, value256: -2560 },
            InputEvent::Key { code: 35, pressed: true },  // KEY_H
            InputEvent::Key { code: 28, pressed: false }, // KEY_ENTER
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
        assert!(InputEvent::decode(0x7f, &[0; 8]).is_none());
    }
}
