//! LAN stream transport (US-003).
//!
//! Wire format lives in [`porthole_agent::protocol`] (and docs/protocol.md).
//! This module is the runtime plumbing: a TCP control listener (one client
//! at a time; a new connection replaces the old one) and a UDP sender that
//! fragments and fires encoded access units at the connected client with no
//! added buffering. Loss recovery (FR-4) is the client's `keyframe_request`
//! message, surfaced here as [`ControlEvent::KeyframeRequest`]; the pipeline
//! answers it by restarting the encoder session, which yields a fresh IDR.

use std::io;
use std::net::{IpAddr, SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::sync::mpsc;
use std::thread;

use porthole_agent::protocol::{self, Hello};

use crate::config::Config;
use crate::encode::EncodedFrame;

/// Events from the control channel toward the capture/encode pipeline.
#[derive(Debug)]
pub enum ControlEvent {
    /// A client connected; video datagrams go to this IP on the configured
    /// video port.
    ClientConnected(IpAddr),
    /// The current client disconnected.
    ClientDisconnected,
    /// The client needs a fresh IDR (decode-fatal loss, FR-4).
    KeyframeRequest,
}

/// Spawn the TCP control listener. Produces events until the channel closes.
pub fn spawn_control_listener(cfg: &Config, hello: Hello) -> anyhow::Result<mpsc::Receiver<ControlEvent>> {
    let listener = TcpListener::bind(cfg.control_addr())
        .map_err(|e| anyhow::anyhow!("failed to bind control channel {}: {e}", cfg.control_addr()))?;
    tracing::info!(addr = %cfg.control_addr(), "control channel listening");
    let (tx, rx) = mpsc::channel();
    thread::Builder::new()
        .name("control-listener".into())
        .spawn(move || accept_loop(listener, hello, tx))?;
    Ok(rx)
}

fn accept_loop(listener: TcpListener, hello: Hello, tx: mpsc::Sender<ControlEvent>) {
    let mut current: Option<TcpStream> = None;
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
        // One client at a time: a new connection replaces the old one.
        if let Some(old) = current.take() {
            tracing::info!(peer = %peer, "new control connection replaces the old one");
            let _ = old.shutdown(std::net::Shutdown::Both);
        }
        let mut writer = match stream.try_clone() {
            Ok(s) => s,
            Err(err) => {
                tracing::warn!(%err, "failed to clone control stream");
                continue;
            }
        };
        if let Err(err) = protocol::write_control_message(&mut writer, protocol::CONTROL_MSG_HELLO, &hello.encode()) {
            tracing::warn!(%err, %peer, "failed to send hello");
            continue;
        }
        tracing::info!(peer = %peer, "client connected, hello sent");
        if tx.send(ControlEvent::ClientConnected(peer.ip())).is_err() {
            return; // pipeline gone
        }
        match stream.try_clone() {
            Ok(read_side) => {
                spawn_reader(read_side, peer.ip(), tx.clone());
                current = Some(stream);
            }
            Err(err) => {
                tracing::warn!(%err, "failed to clone control stream for reader");
            }
        }
    }
}

fn spawn_reader(stream: TcpStream, peer: IpAddr, tx: mpsc::Sender<ControlEvent>) {
    let spawned = thread::Builder::new()
        .name("control-reader".into())
        .spawn(move || {
            let mut stream = stream;
            loop {
                match protocol::read_control_message(&mut stream) {
                    Ok(Some((protocol::CONTROL_MSG_KEYFRAME_REQUEST, _))) => {
                        tracing::info!(%peer, "client requested keyframe");
                        if tx.send(ControlEvent::KeyframeRequest).is_err() {
                            return;
                        }
                    }
                    Ok(Some((other, payload))) => {
                        tracing::debug!(%peer, msg_type = other, len = payload.len(), "unknown control message, ignored");
                    }
                    Ok(None) => {
                        tracing::info!(%peer, "client disconnected");
                        let _ = tx.send(ControlEvent::ClientDisconnected);
                        return;
                    }
                    Err(err) => {
                        tracing::warn!(%peer, %err, "control read failed, dropping client");
                        let _ = tx.send(ControlEvent::ClientDisconnected);
                        return;
                    }
                }
            }
        });
    if let Err(err) = spawned {
        tracing::error!(%err, "failed to spawn control reader thread");
    }
}

/// UDP sender for fragmented access units.
pub struct VideoSender {
    socket: UdpSocket,
    video_port: u16,
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
        let socket = UdpSocket::bind(cfg.video_addr())
            .map_err(|e| anyhow::anyhow!("failed to bind video socket {}: {e}", cfg.video_addr()))?;
        Ok(Self {
            socket,
            video_port: cfg.port_video,
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

    /// Fragment and immediately send one access unit. Returns the assigned
    /// sequence number, or None when no client is connected (frame dropped;
    /// the client requests a keyframe on connect, so it can always start
    /// decoding).
    pub fn send(&mut self, frame: &EncodedFrame, timestamp_us: u64) -> io::Result<Option<u64>> {
        // The sequence advances whether or not a client is connected, so it
        // stays monotonic across client reconnects and encoder restarts.
        let seq = self.sequence;
        self.sequence += 1;
        let Some(client) = self.client else {
            return Ok(None);
        };
        for dgram in protocol::fragment(&frame.data, seq, timestamp_us, frame.is_keyframe) {
            self.socket.send_to(&dgram, client)?;
            self.datagrams_sent += 1;
            self.bytes_sent += dgram.len() as u64;
        }
        Ok(Some(seq))
    }
}
