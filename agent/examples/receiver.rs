//! Reference receiver for the Porthole wire protocol (docs/protocol.md).
//! Cross-platform, std only: connects TCP to the agent, reads the hello,
//! receives fragmented UDP video, reassembles access units, requests a
//! keyframe when it needs one, and logs receive stats once per second.
//!
//! Usage: cargo run --example receiver -- <agent-ip> [--dump out.h264]

use std::net::{TcpStream, UdpSocket};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{bail, Context};
use clap::Parser;
use porthole_agent::protocol::{self, Reassembler};

/// Porthole reference receiver (verification tool for US-003).
#[derive(Parser)]
#[command(name = "receiver", about)]
struct Args {
    /// Agent host (its control channel address).
    host: String,

    /// Agent control port [default: 52801]
    #[arg(long, default_value_t = 52801)]
    port_control: u16,

    /// Write the reassembled Annex B stream (from the first keyframe on) to
    /// this file.
    #[arg(long, value_name = "PATH")]
    dump: Option<PathBuf>,
}

fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    let mut control = TcpStream::connect((args.host.as_str(), args.port_control))
        .with_context(|| format!("failed to connect to {}:{}", args.host, args.port_control))?;
    let (msg_type, payload) = protocol::read_control_message(&mut control)?
        .context("agent closed the control channel before hello")?;
    if msg_type != protocol::CONTROL_MSG_HELLO {
        bail!("expected hello (type 1), got message type {msg_type}");
    }
    let hello = protocol::Hello::decode(&payload).context("malformed hello payload")?;
    println!(
        "hello: codec={:?} {}x{} @{} fps, {} Mbps, keyframe every {}s, video port {}",
        hello.codec,
        hello.width,
        hello.height,
        hello.fps,
        hello.bitrate_mbps,
        hello.keyframe_interval_secs,
        hello.video_port
    );

    // We join mid-GOP and have no reference frames: ask for a fresh IDR.
    protocol::write_control_message(&mut control, protocol::CONTROL_MSG_KEYFRAME_REQUEST, &[])?;
    println!("sent keyframe_request");

    let udp = UdpSocket::bind(("0.0.0.0", hello.video_port))
        .with_context(|| format!("failed to bind UDP port {}", hello.video_port))?;
    udp.set_read_timeout(Some(Duration::from_millis(100)))?;
    println!("listening for video on UDP {}", hello.video_port);

    let mut dump = args
        .dump
        .as_ref()
        .map(|path| {
            std::fs::File::create(path)
                .map(std::io::BufWriter::new)
                .with_context(|| format!("failed to create {}", path.display()))
        })
        .transpose()?;

    let mut reassembler = Reassembler::default();
    let mut buf = [0u8; 2048];
    let mut completed = 0u64;
    let mut lost = 0u64;
    let mut bytes = 0u64;
    let mut highest_seen: Option<u64> = None;
    let mut dumping = false;
    let mut last_keyframe_request = Instant::now();
    let mut window_start = Instant::now();

    loop {
        match udp.recv_from(&mut buf) {
            Ok((n, _from)) => {
                let Some((header, payload)) = protocol::parse_datagram(&buf[..n]) else {
                    continue; // not ours / malformed
                };
                // A gap in frame seqs means whole frames were lost.
                if let Some(hi) = highest_seen {
                    if header.frame_seq > hi + 1 {
                        let gap = header.frame_seq - hi - 1;
                        lost += gap;
                        request_keyframe(&mut control, &mut last_keyframe_request);
                    }
                }
                highest_seen = Some(highest_seen.map_or(header.frame_seq, |hi| hi.max(header.frame_seq)));
                if let Some(frame) = reassembler.push(header, payload) {
                    completed += 1;
                    bytes += frame.data.len() as u64;
                    if frame.is_keyframe {
                        dumping = true;
                    }
                    if let (Some(f), true) = (dump.as_mut(), dumping) {
                        use std::io::Write;
                        f.write_all(&frame.data)?;
                    }
                }
            }
            Err(err)
                if err.kind() == std::io::ErrorKind::WouldBlock
                    || err.kind() == std::io::ErrorKind::TimedOut => {}
            Err(err) => return Err(err).context("UDP receive failed"),
        }

        // Stale incomplete frames are lost; we need an IDR to recover.
        for _seq in reassembler.sweep() {
            lost += 1;
            request_keyframe(&mut control, &mut last_keyframe_request);
        }

        let elapsed = window_start.elapsed();
        if elapsed >= Duration::from_secs(1) {
            let secs = elapsed.as_secs_f64();
            let total = completed + lost;
            let loss_pct = if total > 0 { lost as f64 * 100.0 / total as f64 } else { 0.0 };
            println!(
                "recv: {:.0} fps, loss {:.2}%, {:.0} kbps ({} incomplete frames pending)",
                completed as f64 / secs,
                loss_pct,
                bytes as f64 * 8.0 / secs / 1000.0,
                reassembler.pending()
            );
            completed = 0;
            lost = 0;
            bytes = 0;
            window_start = Instant::now();
        }
    }
}

/// Send a keyframe request, throttled to one per second (loss bursts produce
/// many lost frames; one IDR fixes all of them).
fn request_keyframe(control: &mut TcpStream, last: &mut Instant) {
    if last.elapsed() >= Duration::from_secs(1)
        && protocol::write_control_message(control, protocol::CONTROL_MSG_KEYFRAME_REQUEST, &[]).is_ok()
    {
        println!("sent keyframe_request (loss detected)");
        *last = Instant::now();
    }
}
