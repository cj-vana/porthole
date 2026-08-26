//! LAN stream transport (US-003).
//!
//! Wire format lives in [`porthole_agent::protocol`] (and docs/protocol.md).
//! This module is the runtime plumbing: a TCP control listener (one client
//! at a time; a new connection replaces the old one) and a UDP sender that
//! fragments encoded access units, sized to the configured MTU, and paces
//! each burst at the connected client. Loss recovery (FR-4) is the client's
//! `keyframe_request` message, surfaced here as
//! [`ControlEvent::KeyframeRequest`]; the pipeline answers it by restarting
//! the encoder session, which yields a fresh IDR.
//!
//! Each control connection has exactly one writer: a thread that owns the
//! write side and drains a bounded channel of framed messages. The hello,
//! pong answers from the reader thread, and the pipeline's per-second
//! `agent_stats` (via [`ControlSender`]) all go through that channel, so
//! frames from different threads can never interleave on the wire.

use std::io::{self, Write as _};
use std::net::{IpAddr, SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use porthole_agent::protocol::{self, Hello, InputEvent};

use crate::config::Config;
use crate::encode::EncodedFrame;

/// Peak send rate for one access unit's datagram burst. Well above any
/// configured bitrate (the burst still finishes in a few milliseconds) but
/// below what the sender's NIC can push, which is what matters: see
/// [`VideoSender::send`].
const PACING_RATE_BPS: f64 = 400e6;
/// Sleeps shorter than this are skipped; the deficit carries into the next
/// datagram's check, so they accumulate rather than vanish.
const MIN_PACING_SLEEP: Duration = Duration::from_micros(50);
/// Framed messages the writer thread can hold before senders start
/// dropping. Stats and pongs are tiny and best effort; a full queue means
/// the client stopped reading.
const WRITER_QUEUE_DEPTH: usize = 64;

/// Events from the control channel toward the capture/encode pipeline.
#[derive(Debug)]
pub enum ControlEvent {
    /// A client connected; video datagrams go to this IP on the configured
    /// video port. `generation` numbers accepted connections from 1.
    ClientConnected { generation: u64, ip: IpAddr },
    /// The client of that generation went away. A replaced connection's
    /// reader reports this after the new one already connected, so the
    /// pipeline ignores generations older than its current client.
    ClientDisconnected { generation: u64 },
    /// The client needs a fresh IDR (decode-fatal loss, FR-4).
    KeyframeRequest,
    /// The client asked to reconfigure the stream (gaming mode, US-013).
    Settings(protocol::Settings),
}

/// The current connection's writer queue, tagged with its generation so a
/// reader thread exiting late cannot clear a newer connection's slot.
type WriterSlot = Arc<Mutex<Option<(u64, mpsc::SyncSender<Vec<u8>>)>>>;

/// The hello sent to each new connection. Shared so a settings reconfigure
/// (US-013) updates what later clients are told, not just the connected one.
type HelloSlot = Arc<Mutex<Hello>>;

/// Handle for agent -> client messages outside the control listener (the
/// pipeline's `agent_stats`). Cloneable; sends never block.
#[derive(Clone)]
pub struct ControlSender {
    slot: WriterSlot,
    hello: HelloSlot,
}

impl ControlSender {
    /// Queue one framed message for the connected client. Dropped silently
    /// when no client is connected or the writer queue is full: stats are
    /// best effort and must never stall the capture loop.
    pub fn try_send(&self, msg_type: u8, payload: &[u8]) {
        let slot = self.slot.lock().expect("control writer slot poisoned");
        if let Some((_, tx)) = slot.as_ref() {
            let _ = tx.try_send(protocol::encode_control_message(msg_type, payload));
        }
    }

    /// Update the hello future connections receive (US-013 reconfigure), so
    /// a client that connects after a settings change is told the current
    /// codec and framerate, not the startup ones.
    pub fn update_hello(&self, hello: Hello) {
        *self.hello.lock().expect("hello slot poisoned") = hello;
    }
}

/// Spawn the TCP control listener. Pipeline events go to the returned
/// receiver; decoded input events go straight to `input_tx` (the input
/// session's channel) when input injection is available, otherwise they
/// are logged and dropped. `pipeline_start` is the clock pong answers
/// carry, the same one the video datagram timestamps use.
pub fn spawn_control_listener(
    cfg: &Config,
    hello: Hello,
    input_tx: Option<mpsc::Sender<InputEvent>>,
    pipeline_start: Instant,
) -> anyhow::Result<(mpsc::Receiver<ControlEvent>, ControlSender)> {
    let listener = TcpListener::bind(cfg.control_addr()).map_err(|e| {
        anyhow::anyhow!("failed to bind control channel {}: {e}", cfg.control_addr())
    })?;
    tracing::info!(addr = %cfg.control_addr(), "control channel listening");
    let (tx, rx) = mpsc::channel();
    let slot: WriterSlot = Arc::default();
    let hello_slot: HelloSlot = Arc::new(Mutex::new(hello));
    let control = ControlSender {
        slot: slot.clone(),
        hello: hello_slot.clone(),
    };
    thread::Builder::new()
        .name("control-listener".into())
        .spawn(move || accept_loop(listener, hello_slot, tx, input_tx, slot, pipeline_start))?;
    Ok((rx, control))
}

fn accept_loop(
    listener: TcpListener,
    hello_slot: HelloSlot,
    tx: mpsc::Sender<ControlEvent>,
    input_tx: Option<mpsc::Sender<InputEvent>>,
    slot: WriterSlot,
    pipeline_start: Instant,
) {
    let mut current: Option<TcpStream> = None;
    let mut generation = 0u64;
    for stream in listener.incoming() {
        let stream = match stream {
            Ok(s) => s,
            Err(err) => {
                tracing::warn!(%err, "control accept failed");
                continue;
            }
        };
        let peer = match stream.peer_addr() {
            Ok(p) => p,
            Err(err) => {
                tracing::warn!(%err, "control connection without peer address");
                continue;
            }
        };
        // Input and probe messages are a few bytes each; Nagle plus delayed
        // ACKs would clump them into 40 ms batches.
        if let Err(err) = stream.set_nodelay(true) {
            tracing::warn!(%err, %peer, "failed to set TCP_NODELAY on control connection");
        }
        let (write_side, read_side) = match (stream.try_clone(), stream.try_clone()) {
            (Ok(w), Ok(r)) => (w, r),
            (Err(err), _) | (_, Err(err)) => {
                tracing::warn!(%err, %peer, "failed to clone control stream");
                continue;
            }
        };
        generation += 1;
        let (writer_tx, writer_rx) = mpsc::sync_channel::<Vec<u8>>(WRITER_QUEUE_DEPTH);
        // Hello is queued before anything else can reach the writer, so it
        // is the first frame on the wire. Read the live hello so a client
        // that joins after a settings reconfigure is told the current codec.
        let hello = *hello_slot.lock().expect("hello slot poisoned");
        let _ = writer_tx.send(protocol::encode_control_message(
            protocol::CONTROL_MSG_HELLO,
            &hello.encode(),
        ));
        if !spawn_writer(write_side, peer.ip(), generation, writer_rx) {
            continue;
        }
        // One client at a time: a new connection replaces the old one. The
        // slot swap drops the old queue's sender here, the shutdown makes
        // the old reader return and drop its clone, and with no senders
        // left the old writer's recv fails and that thread exits too.
        *slot.lock().expect("control writer slot poisoned") = Some((generation, writer_tx.clone()));
        tracing::info!(peer = %peer, generation, "client connected, hello queued");
        // Connected goes out before the old socket is shut down, so the old
        // reader's disconnect event always trails it in the pipeline's
        // queue and the generation check there discards it.
        if tx
            .send(ControlEvent::ClientConnected {
                generation,
                ip: peer.ip(),
            })
            .is_err()
        {
            return; // pipeline gone
        }
        if let Some(old) = current.take() {
            tracing::info!(peer = %peer, generation, "new control connection replaces the old one");
            let _ = old.shutdown(std::net::Shutdown::Both);
        }
        spawn_reader(ReaderArgs {
            stream: read_side,
            peer: peer.ip(),
            generation,
            tx: tx.clone(),
            input_tx: input_tx.clone(),
            writer_tx,
            slot: slot.clone(),
            pipeline_start,
        });
        current = Some(stream);
    }
}

/// Writer thread: the only place that writes to this connection. Exits when
/// every sender is gone (connection replaced or reader finished) or a write
/// fails (peer gone), and shuts the socket down either way.
fn spawn_writer(
    mut stream: TcpStream,
    peer: IpAddr,
    generation: u64,
    rx: mpsc::Receiver<Vec<u8>>,
) -> bool {
    let spawned = thread::Builder::new()
        .name("control-writer".into())
        .spawn(move || {
            for msg in rx {
                if let Err(err) = stream.write_all(&msg) {
                    tracing::debug!(%peer, generation, %err, "control write failed");
                    break;
                }
            }
            let _ = stream.shutdown(std::net::Shutdown::Both);
            tracing::debug!(%peer, generation, "control writer exited");
        });
    match spawned {
        Ok(_) => true,
        Err(err) => {
            tracing::error!(%err, "failed to spawn control writer thread");
            false
        }
    }
}

struct ReaderArgs {
    stream: TcpStream,
    peer: IpAddr,
    generation: u64,
    tx: mpsc::Sender<ControlEvent>,
    input_tx: Option<mpsc::Sender<InputEvent>>,
    writer_tx: mpsc::SyncSender<Vec<u8>>,
    slot: WriterSlot,
    pipeline_start: Instant,
}

fn spawn_reader(args: ReaderArgs) {
    let spawned = thread::Builder::new()
        .name("control-reader".into())
        .spawn(move || read_loop(args));
    if let Err(err) = spawned {
        tracing::error!(%err, "failed to spawn control reader thread");
    }
}

fn read_loop(args: ReaderArgs) {
    let ReaderArgs {
        mut stream,
        peer,
        generation,
        tx,
        input_tx,
        writer_tx,
        slot,
        pipeline_start,
    } = args;
    loop {
        match protocol::read_control_message(&mut stream) {
            Ok(Some((protocol::CONTROL_MSG_KEYFRAME_REQUEST, _))) => {
                tracing::info!(%peer, "client requested keyframe");
                if tx.send(ControlEvent::KeyframeRequest).is_err() {
                    break;
                }
            }
            Ok(Some((protocol::CONTROL_MSG_PING, payload))) => {
                // Answered right here rather than through the pipeline so the
                // round trip measures the network, not the frame schedule.
                // Pongs are dropped when the writer queue is full: the reader
                // also carries input, and must not block on a slow peer.
                if let Some(ping) = protocol::Ping::decode(&payload) {
                    let pong = protocol::Pong {
                        client_timestamp_us: ping.client_timestamp_us,
                        agent_timestamp_us: pipeline_start.elapsed().as_micros() as u64,
                    };
                    let _ = writer_tx.try_send(protocol::encode_control_message(
                        protocol::CONTROL_MSG_PONG,
                        &pong.encode(),
                    ));
                } else {
                    tracing::debug!(%peer, len = payload.len(), "malformed ping, ignored");
                }
            }
            Ok(Some((protocol::CONTROL_MSG_SETTINGS, payload))) => {
                match protocol::Settings::decode(&payload) {
                    Some(settings) => {
                        tracing::info!(%peer, ?settings, "client requested settings");
                        if tx.send(ControlEvent::Settings(settings)).is_err() {
                            break;
                        }
                    }
                    None => {
                        tracing::debug!(%peer, len = payload.len(), "malformed settings, ignored")
                    }
                }
            }
            Ok(Some((msg_type, payload))) => {
                if let Some(event) = InputEvent::decode(msg_type, &payload) {
                    tracing::debug!(%peer, ?event, "input event");
                    match &input_tx {
                        Some(input_tx) => {
                            if input_tx.send(event).is_err() {
                                tracing::warn!("input session gone, dropping input event");
                            }
                        }
                        None => {
                            tracing::debug!("input injection unavailable, dropping input event");
                        }
                    }
                } else {
                    tracing::debug!(%peer, msg_type, len = payload.len(), "unknown control message, ignored");
                }
            }
            Ok(None) => {
                tracing::info!(%peer, generation, "client disconnected");
                break;
            }
            Err(err) => {
                tracing::warn!(%peer, generation, %err, "control read failed, dropping client");
                break;
            }
        }
    }
    // Only this generation's slot is ours to clear; a replaced connection's
    // reader gets here after the accept loop already installed the new one.
    {
        let mut slot = slot.lock().expect("control writer slot poisoned");
        if slot.as_ref().is_some_and(|(g, _)| *g == generation) {
            *slot = None;
        }
    }
    let _ = tx.send(ControlEvent::ClientDisconnected { generation });
}

/// UDP sender for fragmented access units.
pub struct VideoSender {
    socket: UdpSocket,
    video_port: u16,
    /// Datagram size (header plus payload) derived from the configured MTU.
    datagram_size: usize,
    client: Option<SocketAddr>,
    /// Next access-unit sequence number; monotonic across encoder restarts.
    sequence: u64,
    /// Datagrams sent since the last reset of these counters.
    pub datagrams_sent: u64,
    /// UDP payload+header bytes sent since the last reset of these counters.
    pub bytes_sent: u64,
}

impl VideoSender {
    pub fn new(cfg: &Config) -> anyhow::Result<Self> {
        let socket = UdpSocket::bind(cfg.video_addr()).map_err(|e| {
            anyhow::anyhow!("failed to bind video socket {}: {e}", cfg.video_addr())
        })?;
        let datagram_size = protocol::datagram_size_for_mtu(usize::from(cfg.mtu.get()));
        tracing::info!(
            mtu = cfg.mtu.get(),
            datagram_size,
            "video datagrams sized for MTU"
        );
        Ok(Self {
            socket,
            video_port: cfg.port_video,
            datagram_size,
            client: None,
            sequence: 0,
            datagrams_sent: 0,
            bytes_sent: 0,
        })
    }

    /// Point video at the given client IP (or nobody).
    pub fn set_client(&mut self, ip: Option<IpAddr>) {
        self.client = ip.map(|ip| SocketAddr::new(ip, self.video_port));
    }

    pub fn client(&self) -> Option<SocketAddr> {
        self.client
    }

    /// Fragment and send one access unit, pacing the burst at
    /// [`PACING_RATE_BPS`]. Returns the assigned sequence number, or None
    /// when no client is connected (frame dropped; the client requests a
    /// keyframe on connect, so it can always start decoding).
    ///
    /// A keyframe is several hundred datagrams, and firing them at NIC speed
    /// loses the tail of the burst two ways. macOS charges 2 KB of mbuf per
    /// received datagram regardless of size, so 400 datagrams overflow the
    /// default 786 KB UDP socket buffer before the client reads any. And a
    /// userspace tunnel (WireGuard, Tailscale) queues datagrams in a small
    /// ring between the kernel and its own thread, which a line-rate burst
    /// overruns. Spreading the burst over a few milliseconds keeps both
    /// queues short without adding a frame of delay.
    pub fn send(&mut self, frame: &EncodedFrame, timestamp_us: u64) -> io::Result<Option<u64>> {
        // The sequence advances whether or not a client is connected, so it
        // stays monotonic across client reconnects and encoder restarts.
        let seq = self.sequence;
        self.sequence += 1;
        let Some(client) = self.client else {
            return Ok(None);
        };
        let burst_start = Instant::now();
        let mut burst_bytes = 0u64;
        for dgram in protocol::fragment(
            &frame.data,
            seq,
            timestamp_us,
            frame.is_keyframe,
            self.datagram_size,
        ) {
            // The schedule is absolute from the first datagram, so a sleep
            // skipped for being too short is not lost: the deficit shows up
            // in the next check and is slept once it is worth the syscall.
            if burst_bytes > 0 {
                let due = Duration::from_secs_f64(burst_bytes as f64 * 8.0 / PACING_RATE_BPS);
                let behind = due.saturating_sub(burst_start.elapsed());
                if behind >= MIN_PACING_SLEEP {
                    thread::sleep(behind);
                }
            }
            self.socket.send_to(&dgram, client)?;
            burst_bytes += dgram.len() as u64;
            self.datagrams_sent += 1;
            self.bytes_sent += dgram.len() as u64;
        }
        Ok(Some(seq))
    }
}
