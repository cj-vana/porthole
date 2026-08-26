//! GPU-resident capture and encoding through gpu-screen-recorder.
//!
//! The regular encoder path asks the compositor for a 14.7 MiB BGRA SHM
//! image every frame, then uploads it to an encoder GPU. GSR instead imports
//! PipeWire dma-bufs directly into the compositor GPU's VAAPI encoder. Its RTP
//! output is deliberately loopback-only: the RTP marker bit is an immediate,
//! exact access-unit boundary, and this module converts the payload back to
//! Annex B for Porthole's existing low-MTU LAN transport.

use std::collections::VecDeque;
use std::net::{Ipv4Addr, SocketAddrV4, UdpSocket};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{bail, Context};
use socket2::{Domain, Protocol, SockAddr, Socket, Type};

use super::annexb::access_unit_is_keyframe;
use super::{Codec, EncodedFrame, Encoder, EncoderBackend};
use crate::capture::RawFrame;
use crate::config::Config;

const RTP_PAYLOAD_TYPE: u8 = 96;
const RTP_PACKET_BYTES: usize = 65_536;
const RTP_PAYLOAD_BYTES: usize = 60_000;
const RTP_RECEIVE_BUFFER_BYTES: usize = 8 * 1024 * 1024;
const MAX_ENCODED_FRAME_BYTES: usize = 16 * 1024 * 1024;
const FIRST_FRAME_TIMEOUT: Duration = Duration::from_secs(4);
const SOCKET_READ_TIMEOUT: Duration = Duration::from_millis(100);
/// GSR's 90 kHz RTP clock identifies frame cadence but not the portal's
/// monotonic-clock epoch. Anchor it just before the first completed packet.
/// The estimate only affects telemetry/timestamps, never scheduling.
const CAPTURE_TO_RTP_ESTIMATE: Duration = Duration::from_micros(1_000);
const RTP_CLOCK_HZ: u64 = 90_000;
/// The optional Porthole helper is upstream GSR 6.0.1 plus the small patch in
/// `agent/patches`: SIGRTMIN+7 atomically marks the next frame as an IDR.
/// Keep it app-owned so a distro package update cannot silently replace the
/// signaling contract. Machines without it retain the restart fallback.
const PORTHOLE_GSR_PATH: &str = "/usr/local/libexec/porthole/gpu-screen-recorder";
const FORCE_KEYFRAME_SIGNAL_OFFSET: i32 = 7;

pub struct GsrEncoder {
    codec: Codec,
    child: Child,
    rx: mpsc::Receiver<EncodedFrame>,
    pending: VecDeque<EncodedFrame>,
    reader_stop: Arc<AtomicBool>,
    reader_thread: Option<thread::JoinHandle<()>>,
    supports_in_process_keyframes: bool,
}

impl GsrEncoder {
    pub fn new(cfg: &Config) -> anyhow::Result<Self> {
        let token_path = cfg
            .gsr_restore_token
            .as_deref()
            .context("the gsr backend requires --gsr-restore-token")?;
        let token_metadata = std::fs::metadata(token_path).with_context(|| {
            format!(
                "cannot access GSR portal restore token {}",
                token_path.display()
            )
        })?;
        if !token_metadata.is_file() {
            bail!(
                "GSR portal restore token is not a file: {}",
                token_path.display()
            );
        }

        let socket = bind_rtp_socket()?;
        let port = socket
            .local_addr()
            .context("cannot read GSR RTP socket address")?
            .port();
        let output_url = format!("rtp://127.0.0.1:{port}?pkt_size={RTP_PAYLOAD_BYTES}");
        let bitrate_kbps = cfg.bitrate_mbps.saturating_mul(1_000).to_string();
        let fps = cfg.fps.get().to_string();
        let keyframe_interval = cfg.keyframe_interval_secs.to_string();

        let (tx, rx) = mpsc::channel();
        let reader_stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&reader_stop);
        let codec = cfg.codec;
        let reader_thread = thread::Builder::new()
            .name("gsr-rtp-reader".into())
            .spawn(move || read_rtp_access_units(socket, codec, tx, thread_stop))
            .context("failed to spawn GSR RTP reader thread")?;

        let supports_in_process_keyframes = std::path::Path::new(PORTHOLE_GSR_PATH).is_file();
        let binary = if supports_in_process_keyframes {
            PORTHOLE_GSR_PATH
        } else {
            "gpu-screen-recorder"
        };
        let mut command = Command::new(binary);
        command
            .args(["-w", "portal"])
            .args(["-restore-portal-session", "yes"])
            .arg("-portal-session-token-filepath")
            .arg(token_path)
            .args(["-f", &fps])
            // PipeWire is already driven by the 144 Hz compositor. VFR emits
            // each real dma-buf immediately; CFR can manufacture a train of
            // duplicate catch-up frames after a short driver stall, creating
            // decoder backlog without making motion any smoother.
            .args(["-fm", "vfr"])
            .args(["-cursor", "no"])
            .args(["-k", &cfg.codec.to_string()])
            .args(["-bm", "cbr"])
            .args(["-q", &bitrate_kbps])
            .args(["-tune", "performance"])
            .args(["-keyint", &keyframe_interval])
            .args(["-c", "rtp"])
            .args(["-ffmpeg-video-opts", "aud=1"])
            .args(["-ffmpeg-opts", "flush_packets=1"])
            .arg("-o")
            .arg(&output_url)
            .args(["-v", "no"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit());

        // SIGTERM does not unwind Rust, so service restarts cannot rely on
        // `Drop` to reap the recorder. An orphan GSR keeps the portal and GPU
        // busy indefinitely; a second instance then loses source frames.
        crate::subprocess::die_with_parent(&mut command);

        tracing::debug!(command = ?command, "spawning GPU-resident portal encoder");
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(err) => {
                reader_stop.store(true, Ordering::Release);
                let _ = reader_thread.join();
                return Err(err).context("failed to spawn gpu-screen-recorder");
            }
        };

        // A successful exec is not enough: a stale portal token or unsupported
        // codec makes GSR exit asynchronously. Receiving the first complete AU
        // proves the restored portal session, dma-buf import, encoder, and RTP
        // boundary path all work before wlr-screencopy is suspended.
        let first = match rx.recv_timeout(FIRST_FRAME_TIMEOUT) {
            Ok(frame) => frame,
            Err(err) => {
                let status = child
                    .try_wait()
                    .ok()
                    .flatten()
                    .map(|status| status.to_string())
                    .unwrap_or_else(|| "still running without video".into());
                reader_stop.store(true, Ordering::Release);
                let _ = child.kill();
                let _ = child.wait();
                let _ = reader_thread.join();
                bail!("GSR produced no complete frame within {FIRST_FRAME_TIMEOUT:?} ({status}; {err})");
            }
        };

        tracing::info!(
            rtp_port = port,
            first_frame_bytes = first.data.len(),
            codec = %cfg.codec,
            fps = cfg.fps.get(),
            bitrate_mbps = cfg.bitrate_mbps,
            in_process_keyframes = supports_in_process_keyframes,
            "GSR dma-buf capture verified"
        );
        Ok(Self {
            codec: cfg.codec,
            child,
            rx,
            pending: VecDeque::from([first]),
            reader_stop,
            reader_thread: Some(reader_thread),
            supports_in_process_keyframes,
        })
    }
}

impl Encoder for GsrEncoder {
    fn encode(&mut self, _frame: &RawFrame) -> anyhow::Result<()> {
        Ok(())
    }

    fn drain(&mut self) -> Vec<EncodedFrame> {
        self.pending.extend(self.rx.try_iter());
        self.pending.drain(..).collect()
    }

    fn request_keyframe(&mut self) -> anyhow::Result<()> {
        if !self.supports_in_process_keyframes {
            bail!("installed gpu-screen-recorder has no force-IDR signal");
        }
        let signal = libc::SIGRTMIN() + FORCE_KEYFRAME_SIGNAL_OFFSET;
        // Safety: `child.id()` is the live subprocess PID. kill(2) only
        // delivers the app-private signal; it does not access Rust memory.
        let result = unsafe { libc::kill(self.child.id() as libc::pid_t, signal) };
        if result != 0 {
            return Err(std::io::Error::last_os_error()).context("cannot signal GSR for an IDR");
        }
        tracing::debug!(signal, "requested in-process GSR keyframe");
        Ok(())
    }

    fn codec(&self) -> Codec {
        self.codec
    }

    fn backend(&self) -> EncoderBackend {
        EncoderBackend::Gsr
    }

    fn needs_raw_frames(&self) -> bool {
        false
    }
}

impl Drop for GsrEncoder {
    fn drop(&mut self) {
        self.reader_stop.store(true, Ordering::Release);
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(handle) = self.reader_thread.take() {
            let _ = handle.join();
        }
    }
}

fn bind_rtp_socket() -> anyhow::Result<UdpSocket> {
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))
        .context("cannot create GSR RTP socket")?;
    socket
        .set_recv_buffer_size(RTP_RECEIVE_BUFFER_BYTES)
        .context("cannot size GSR RTP receive buffer")?;
    socket
        .set_read_timeout(Some(SOCKET_READ_TIMEOUT))
        .context("cannot set GSR RTP read timeout")?;
    let address = SockAddr::from(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0));
    socket
        .bind(&address)
        .context("cannot bind GSR loopback RTP socket")?;
    let granted = socket.recv_buffer_size().unwrap_or_default();
    tracing::info!(
        requested_bytes = RTP_RECEIVE_BUFFER_BYTES,
        granted_bytes = granted,
        "configured GSR RTP receive buffer"
    );
    Ok(socket.into())
}

fn read_rtp_access_units(
    socket: UdpSocket,
    codec: Codec,
    tx: mpsc::Sender<EncodedFrame>,
    stop: Arc<AtomicBool>,
) {
    let mut buffer = vec![0u8; RTP_PACKET_BYTES];
    let mut assembler = RtpAccessUnitAssembler::new(codec);
    while !stop.load(Ordering::Acquire) {
        let size = match socket.recv(&mut buffer) {
            Ok(size) => size,
            Err(err)
                if matches!(
                    err.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                continue;
            }
            Err(err) => {
                if !stop.load(Ordering::Acquire) {
                    tracing::error!(%err, "GSR RTP receive failed");
                }
                break;
            }
        };
        // Take the timestamp after recv; on loopback this is also the first
        // instant at which the complete datagram is available to Porthole.
        let received_at = Instant::now();
        let packet = match RtpPacket::parse(&buffer[..size]) {
            Ok(packet) => packet,
            Err(err) => {
                tracing::warn!(%err, bytes = size, "discarding malformed GSR RTP packet");
                continue;
            }
        };
        if packet.payload_type != RTP_PAYLOAD_TYPE {
            tracing::debug!(
                payload_type = packet.payload_type,
                "ignoring non-video GSR RTP packet"
            );
            continue;
        }
        match assembler.push(&packet, received_at) {
            Ok(Some(frame)) => {
                if tx.send(frame).is_err() {
                    return;
                }
            }
            Ok(None) => {}
            Err(err) => {
                tracing::warn!(
                    %err,
                    sequence = packet.sequence,
                    timestamp = packet.timestamp,
                    "damaged GSR RTP access unit dropped"
                );
            }
        }
    }
}

struct RtpPacket<'a> {
    marker: bool,
    payload_type: u8,
    sequence: u16,
    timestamp: u32,
    payload: &'a [u8],
}

impl<'a> RtpPacket<'a> {
    fn parse(packet: &'a [u8]) -> anyhow::Result<Self> {
        if packet.len() < 12 {
            bail!("RTP packet shorter than the fixed header");
        }
        if packet[0] >> 6 != 2 {
            bail!("unsupported RTP version {}", packet[0] >> 6);
        }

        let has_padding = packet[0] & 0x20 != 0;
        let has_extension = packet[0] & 0x10 != 0;
        let csrc_count = usize::from(packet[0] & 0x0f);
        let mut header_len = 12usize
            .checked_add(csrc_count * 4)
            .context("RTP header length overflow")?;
        if packet.len() < header_len {
            bail!("RTP packet truncates its CSRC list");
        }
        if has_extension {
            if packet.len() < header_len + 4 {
                bail!("RTP packet truncates its extension header");
            }
            let extension_words = usize::from(u16::from_be_bytes([
                packet[header_len + 2],
                packet[header_len + 3],
            ]));
            header_len = header_len
                .checked_add(4 + extension_words * 4)
                .context("RTP extension length overflow")?;
        }
        if packet.len() < header_len {
            bail!("RTP packet truncates its extension data");
        }

        let mut payload_end = packet.len();
        if has_padding {
            let padding = usize::from(*packet.last().expect("fixed header exists"));
            if padding == 0 || padding > payload_end.saturating_sub(header_len) {
                bail!("invalid RTP padding length {padding}");
            }
            payload_end -= padding;
        }
        if header_len >= payload_end {
            bail!("RTP packet has no payload");
        }

        Ok(Self {
            marker: packet[1] & 0x80 != 0,
            payload_type: packet[1] & 0x7f,
            sequence: u16::from_be_bytes([packet[2], packet[3]]),
            timestamp: u32::from_be_bytes([packet[4], packet[5], packet[6], packet[7]]),
            payload: &packet[header_len..payload_end],
        })
    }
}

struct RtpAccessUnitAssembler {
    codec: Codec,
    expected_sequence: Option<u16>,
    timestamp: Option<u32>,
    current: Vec<u8>,
    damaged: bool,
    fu_in_progress: bool,
    output_sequence: u64,
    clock: RtpClock,
}

impl RtpAccessUnitAssembler {
    fn new(codec: Codec) -> Self {
        Self {
            codec,
            expected_sequence: None,
            timestamp: None,
            current: Vec::with_capacity(128 * 1024),
            damaged: false,
            fu_in_progress: false,
            output_sequence: 0,
            clock: RtpClock::default(),
        }
    }

    fn push(
        &mut self,
        packet: &RtpPacket<'_>,
        received_at: Instant,
    ) -> anyhow::Result<Option<EncodedFrame>> {
        let sequence_gap = self
            .expected_sequence
            .is_some_and(|expected| expected != packet.sequence);
        self.expected_sequence = Some(packet.sequence.wrapping_add(1));

        if self.timestamp != Some(packet.timestamp) {
            if self.timestamp.is_some() && !self.current.is_empty() {
                tracing::debug!("RTP timestamp changed before marker; dropping incomplete AU");
            }
            self.reset_access_unit();
            self.timestamp = Some(packet.timestamp);
            self.damaged = sequence_gap;
        } else if sequence_gap {
            self.damaged = true;
        }

        let append_result = match self.codec {
            Codec::H264 => self.append_h264(packet.payload),
            Codec::Hevc => self.append_hevc(packet.payload),
        };
        if let Err(err) = append_result {
            self.damaged = true;
            if packet.marker {
                self.reset_access_unit();
            }
            return Err(err);
        }
        if self.current.len() > MAX_ENCODED_FRAME_BYTES {
            self.damaged = true;
        }

        if !packet.marker {
            return Ok(None);
        }
        if self.fu_in_progress {
            self.damaged = true;
        }

        let timestamp = packet.timestamp;
        let complete = !self.damaged && !self.current.is_empty();
        let data = complete.then(|| std::mem::take(&mut self.current));
        self.reset_access_unit();
        let Some(data) = data else {
            return Ok(None);
        };

        let ready_at = received_at;
        let captured_at = self.clock.capture_time(timestamp, ready_at);
        let frame = EncodedFrame {
            sequence: self.output_sequence,
            is_keyframe: access_unit_is_keyframe(&data, self.codec),
            data,
            ready_at,
            captured_at: Some(captured_at),
        };
        self.output_sequence += 1;
        Ok(Some(frame))
    }

    fn reset_access_unit(&mut self) {
        self.timestamp = None;
        self.current.clear();
        self.damaged = false;
        self.fu_in_progress = false;
    }

    fn append_h264(&mut self, payload: &[u8]) -> anyhow::Result<()> {
        let first = *payload.first().context("empty H.264 RTP payload")?;
        match first & 0x1f {
            1..=23 => {
                self.require_no_fragment()?;
                append_annex_b_nal(&mut self.current, payload);
            }
            24 => {
                self.require_no_fragment()?;
                append_aggregation(&mut self.current, &payload[1..])?;
            }
            28 => {
                if payload.len() < 3 {
                    bail!("truncated H.264 FU-A payload");
                }
                let fu_header = payload[1];
                let start = fu_header & 0x80 != 0;
                let end = fu_header & 0x40 != 0;
                if start {
                    if self.fu_in_progress {
                        bail!("H.264 FU-A start arrived inside another fragment");
                    }
                    let nal_header = (payload[0] & 0xe0) | (fu_header & 0x1f);
                    append_annex_b_nal(&mut self.current, &[nal_header]);
                    self.current.extend_from_slice(&payload[2..]);
                    self.fu_in_progress = !end;
                } else {
                    if !self.fu_in_progress {
                        bail!("H.264 FU-A continuation arrived without a start");
                    }
                    self.current.extend_from_slice(&payload[2..]);
                    if end {
                        self.fu_in_progress = false;
                    }
                }
            }
            kind => bail!("unsupported H.264 RTP packetization type {kind}"),
        }
        Ok(())
    }

    fn append_hevc(&mut self, payload: &[u8]) -> anyhow::Result<()> {
        if payload.len() < 2 {
            bail!("truncated HEVC RTP payload header");
        }
        let kind = (payload[0] >> 1) & 0x3f;
        match kind {
            0..=47 => {
                self.require_no_fragment()?;
                append_annex_b_nal(&mut self.current, payload);
            }
            48 => {
                self.require_no_fragment()?;
                append_aggregation(&mut self.current, &payload[2..])?;
            }
            49 => {
                if payload.len() < 4 {
                    bail!("truncated HEVC fragmentation-unit payload");
                }
                let fu_header = payload[2];
                let start = fu_header & 0x80 != 0;
                let end = fu_header & 0x40 != 0;
                if start {
                    if self.fu_in_progress {
                        bail!("HEVC FU start arrived inside another fragment");
                    }
                    let nal_header = [(payload[0] & 0x81) | ((fu_header & 0x3f) << 1), payload[1]];
                    append_annex_b_nal(&mut self.current, &nal_header);
                    self.current.extend_from_slice(&payload[3..]);
                    self.fu_in_progress = !end;
                } else {
                    if !self.fu_in_progress {
                        bail!("HEVC FU continuation arrived without a start");
                    }
                    self.current.extend_from_slice(&payload[3..]);
                    if end {
                        self.fu_in_progress = false;
                    }
                }
            }
            kind => bail!("unsupported HEVC RTP packetization type {kind}"),
        }
        Ok(())
    }

    fn require_no_fragment(&self) -> anyhow::Result<()> {
        if self.fu_in_progress {
            bail!("complete NAL arrived before fragmented NAL ended");
        }
        Ok(())
    }
}

fn append_annex_b_nal(output: &mut Vec<u8>, nal: &[u8]) {
    output.extend_from_slice(&[0, 0, 0, 1]);
    output.extend_from_slice(nal);
}

fn append_aggregation(output: &mut Vec<u8>, mut payload: &[u8]) -> anyhow::Result<()> {
    if payload.is_empty() {
        bail!("empty RTP aggregation packet");
    }
    while !payload.is_empty() {
        if payload.len() < 2 {
            bail!("truncated RTP aggregation length");
        }
        let nal_len = usize::from(u16::from_be_bytes([payload[0], payload[1]]));
        payload = &payload[2..];
        if nal_len == 0 || payload.len() < nal_len {
            bail!("invalid RTP aggregation NAL length {nal_len}");
        }
        append_annex_b_nal(output, &payload[..nal_len]);
        payload = &payload[nal_len..];
    }
    Ok(())
}

#[derive(Default)]
struct RtpClock {
    anchor: Option<(u32, Instant)>,
}

impl RtpClock {
    fn capture_time(&mut self, timestamp: u32, ready_at: Instant) -> Instant {
        let fallback = ready_at
            .checked_sub(CAPTURE_TO_RTP_ESTIMATE)
            .unwrap_or(ready_at);
        let Some((anchor_timestamp, anchor_capture)) = self.anchor else {
            self.anchor = Some((timestamp, fallback));
            return fallback;
        };

        let ticks = u64::from(timestamp.wrapping_sub(anchor_timestamp));
        // Re-anchor well before the 32-bit 90 kHz clock wraps (~13.3 hours).
        // This also treats a discontinuity/restarted RTP clock conservatively.
        if ticks > RTP_CLOCK_HZ * 60 * 60 {
            self.anchor = Some((timestamp, fallback));
            return fallback;
        }
        let micros = ticks.saturating_mul(1_000_000) / RTP_CLOCK_HZ;
        let predicted = anchor_capture + Duration::from_micros(micros);
        if predicted > ready_at {
            // CFR timestamps can lead packet availability by a fraction of a
            // frame. Never claim capture occurred in the future.
            self.anchor = Some((timestamp, fallback));
            fallback
        } else {
            predicted
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rtp(sequence: u16, timestamp: u32, marker: bool, payload: &[u8]) -> Vec<u8> {
        let mut packet = vec![0x80, RTP_PAYLOAD_TYPE | if marker { 0x80 } else { 0 }];
        packet.extend_from_slice(&sequence.to_be_bytes());
        packet.extend_from_slice(&timestamp.to_be_bytes());
        packet.extend_from_slice(&0x1234_5678u32.to_be_bytes());
        packet.extend_from_slice(payload);
        packet
    }

    fn push(
        assembler: &mut RtpAccessUnitAssembler,
        bytes: &[u8],
    ) -> anyhow::Result<Option<EncodedFrame>> {
        let packet = RtpPacket::parse(bytes)?;
        assembler.push(&packet, Instant::now())
    }

    #[test]
    fn parses_csrc_extension_and_padding() {
        let mut packet = vec![0xb1, 0x80 | RTP_PAYLOAD_TYPE, 0, 7, 0, 0, 0, 9];
        packet.extend_from_slice(&0x0102_0304u32.to_be_bytes());
        packet.extend_from_slice(&0x0506_0708u32.to_be_bytes()); // one CSRC
        packet.extend_from_slice(&[0xbe, 0xde, 0, 1, 1, 2, 3, 4]);
        packet.extend_from_slice(&[0x26, 1, 0xaa]);
        packet.extend_from_slice(&[0, 0, 0, 4]);
        let parsed = RtpPacket::parse(&packet).unwrap();
        assert_eq!(parsed.sequence, 7);
        assert_eq!(parsed.timestamp, 9);
        assert!(parsed.marker);
        assert_eq!(parsed.payload, &[0x26, 1, 0xaa]);
    }

    #[test]
    fn reassembles_hevc_aggregation_and_fragmentation() {
        let mut assembler = RtpAccessUnitAssembler::new(Codec::Hevc);
        // AP containing a VPS (NAL type 32).
        let ap = [0x60, 1, 0, 3, 0x40, 1, 0xaa];
        assert!(push(&mut assembler, &rtp(10, 9000, false, &ap))
            .unwrap()
            .is_none());
        // HEVC FU for an IDR_W_RADL (type 19).
        let start = [0x62, 1, 0x80 | 19, 0x11, 0x22];
        let end = [0x62, 1, 0x40 | 19, 0x33, 0x44];
        assert!(push(&mut assembler, &rtp(11, 9000, false, &start))
            .unwrap()
            .is_none());
        let frame = push(&mut assembler, &rtp(12, 9000, true, &end))
            .unwrap()
            .unwrap();
        assert_eq!(
            frame.data,
            [0, 0, 0, 1, 0x40, 1, 0xaa, 0, 0, 0, 1, 0x26, 1, 0x11, 0x22, 0x33, 0x44]
        );
        assert!(frame.is_keyframe);
        assert!(frame.captured_at.is_some());
    }

    #[test]
    fn reassembles_h264_stap_and_fragmentation() {
        let mut assembler = RtpAccessUnitAssembler::new(Codec::H264);
        let stap = [24, 0, 2, 0x67, 0xaa, 0, 2, 0x68, 0xbb];
        push(&mut assembler, &rtp(20, 12_000, false, &stap)).unwrap();
        let start = [0x7c, 0x80 | 5, 0x11];
        let end = [0x7c, 0x40 | 5, 0x22];
        push(&mut assembler, &rtp(21, 12_000, false, &start)).unwrap();
        let frame = push(&mut assembler, &rtp(22, 12_000, true, &end))
            .unwrap()
            .unwrap();
        assert_eq!(
            frame.data,
            [0, 0, 0, 1, 0x67, 0xaa, 0, 0, 0, 1, 0x68, 0xbb, 0, 0, 0, 1, 0x65, 0x11, 0x22]
        );
        assert!(frame.is_keyframe);
    }

    #[test]
    fn sequence_gap_drops_access_unit_and_recovers_on_next_marker() {
        let mut assembler = RtpAccessUnitAssembler::new(Codec::Hevc);
        let start = [0x62, 1, 0x80 | 1, 0xaa];
        let end = [0x62, 1, 0x40 | 1, 0xbb];
        push(&mut assembler, &rtp(1, 100, false, &start)).unwrap();
        assert!(push(&mut assembler, &rtp(3, 100, true, &end))
            .unwrap()
            .is_none());

        let single = [0x02, 1, 0xcc];
        let recovered = push(&mut assembler, &rtp(4, 725, true, &single))
            .unwrap()
            .unwrap();
        assert_eq!(recovered.data, [0, 0, 0, 1, 0x02, 1, 0xcc]);
    }
}
