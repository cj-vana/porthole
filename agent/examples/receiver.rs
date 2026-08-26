//! Reference receiver for the Porthole wire protocol (docs/protocol.md).
//! Cross-platform, std only: connects TCP to the agent, reads the hello,
//! receives fragmented UDP video, reassembles access units, requests a
//! keyframe when it needs one, probes round-trip time with ping once per
//! second, and logs receive stats (plus the agent's own encode latency from
//! its agent_stats messages) once per second.
//!
//! Usage: cargo run --example receiver -- <agent-ip> [--dump out.h264]

use std::net::{TcpStream, UdpSocket};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;
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

    /// After hello, send a settings message (US-013), e.g. "144,hevc,80,ll"
    /// (fps, codec h264|hevc, bitrate Mbps, "ll" for low latency).
    #[arg(long, value_name = "FPS,CODEC,MBPS[,ll]")]
    settings: Option<String>,
}

fn parse_settings(spec: &str) -> anyhow::Result<protocol::Settings> {
    let parts: Vec<&str> = spec.split(',').collect();
    if parts.len() < 3 {
        bail!("settings needs at least fps,codec,mbps");
    }
    let codec = match parts[1].to_ascii_lowercase().as_str() {
        "h264" => protocol::CodecTag::H264,
        "hevc" => protocol::CodecTag::Hevc,
        other => bail!("unknown codec {other:?}"),
    };
    Ok(protocol::Settings {
        fps: parts[0].parse().context("bad fps")?,
        codec,
        bitrate_mbps: parts[2].parse().context("bad bitrate")?,
        low_latency: parts.get(3).is_some_and(|s| *s == "ll"),
    })
}

/// What the control reader thread learned most recently, for the per-second
/// stats line.
#[derive(Default, Clone, Copy)]
struct AgentSide {
    rtt_us: Option<u64>,
    stats: Option<protocol::AgentStats>,
}

fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    // The client clock for pings: microseconds since the receiver started.
    let start = Instant::now();

    let mut control = TcpStream::connect((args.host.as_str(), args.port_control))
        .with_context(|| format!("failed to connect to {}:{}", args.host, args.port_control))?;
    // Pings and keyframe requests are a few bytes each; without this Nagle
    // holds them for the delayed ACK and the round trip reads 40 ms high.
    control.set_nodelay(true)?;
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

    // Everything the agent sends after hello is read on its own thread; the
    // main loop keeps the only write handle (pings and keyframe requests).
    let agent_side = Arc::new(Mutex::new(AgentSide::default()));
    spawn_control_reader(control.try_clone()?, start, agent_side.clone());

    if let Some(spec) = &args.settings {
        let settings = parse_settings(spec)?;
        protocol::write_control_message(
            &mut control,
            protocol::CONTROL_MSG_SETTINGS,
            &settings.encode(),
        )?;
        println!("sent settings: {settings:?}");
    }

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
    let mut last_ping = Instant::now() - Duration::from_secs(1);
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
                highest_seen =
                    Some(highest_seen.map_or(header.frame_seq, |hi| hi.max(header.frame_seq)));
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

        if last_ping.elapsed() >= Duration::from_secs(1) {
            let ping = protocol::Ping {
                client_timestamp_us: start.elapsed().as_micros() as u64,
            };
            protocol::write_control_message(
                &mut control,
                protocol::CONTROL_MSG_PING,
                &ping.encode(),
            )?;
            last_ping = Instant::now();
        }

        let elapsed = window_start.elapsed();
        if elapsed >= Duration::from_secs(1) {
            let secs = elapsed.as_secs_f64();
            let total = completed + lost;
            let loss_pct = if total > 0 {
                lost as f64 * 100.0 / total as f64
            } else {
                0.0
            };
            let agent = *agent_side.lock().expect("agent side poisoned");
            let rtt = agent.rtt_us.map_or("rtt n/a".to_string(), |us| {
                format!("rtt {:.2} ms", us as f64 / 1000.0)
            });
            let enc = agent.stats.map_or("agent encode n/a".to_string(), |s| {
                format!("agent encode {:.2} ms", s.encode_latency_us as f64 / 1000.0)
            });
            println!(
                "recv: {:.0} fps, loss {:.2}%, {:.0} kbps ({} incomplete frames pending), {rtt}, {enc}",
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

/// Read agent -> client control messages until the connection closes:
/// print each pong's round trip and each agent_stats, and keep the latest
/// of both for the main loop's stats line.
fn spawn_control_reader(mut stream: TcpStream, start: Instant, agent_side: Arc<Mutex<AgentSide>>) {
    thread::spawn(move || loop {
        match protocol::read_control_message(&mut stream) {
            Ok(Some((protocol::CONTROL_MSG_PONG, payload))) => {
                let Some(pong) = protocol::Pong::decode(&payload) else {
                    println!("malformed pong ({} bytes)", payload.len());
                    continue;
                };
                let now_us = start.elapsed().as_micros() as u64;
                let rtt_us = now_us.saturating_sub(pong.client_timestamp_us);
                println!(
                    "pong: rtt {:.2} ms (agent clock {} us)",
                    rtt_us as f64 / 1000.0,
                    pong.agent_timestamp_us
                );
                agent_side.lock().expect("agent side poisoned").rtt_us = Some(rtt_us);
            }
            Ok(Some((protocol::CONTROL_MSG_AGENT_STATS, payload))) => {
                let Some(stats) = protocol::AgentStats::decode(&payload) else {
                    println!("malformed agent_stats ({} bytes)", payload.len());
                    continue;
                };
                println!(
                    "agent_stats: capture {} fps, encode {} fps, encode latency {:.2} ms, tx {} kbps, {} keyframes",
                    stats.capture_fps,
                    stats.encode_fps,
                    stats.encode_latency_us as f64 / 1000.0,
                    stats.tx_kbps,
                    stats.keyframes
                );
                agent_side.lock().expect("agent side poisoned").stats = Some(stats);
            }
            Ok(Some((protocol::CONTROL_MSG_HELLO, payload))) => {
                match protocol::Hello::decode(&payload) {
                    Some(hello) => println!(
                        "hello (reconfigured): codec={:?} {}x{} @{} fps, {} Mbps",
                        hello.codec, hello.width, hello.height, hello.fps, hello.bitrate_mbps
                    ),
                    None => println!("malformed hello ({} bytes)", payload.len()),
                }
            }
            Ok(Some((msg_type, payload))) => {
                println!(
                    "control message type {msg_type} ({} bytes), ignored",
                    payload.len()
                );
            }
            Ok(None) => {
                println!("agent closed the control channel");
                return;
            }
            Err(err) => {
                println!("control read failed: {err}");
                return;
            }
        }
    });
}

/// Send a keyframe request, throttled to one per second (loss bursts produce
/// many lost frames; one IDR fixes all of them).
fn request_keyframe(control: &mut TcpStream, last: &mut Instant) {
    if last.elapsed() >= Duration::from_secs(1)
        && protocol::write_control_message(control, protocol::CONTROL_MSG_KEYFRAME_REQUEST, &[])
            .is_ok()
    {
        println!("sent keyframe_request (loss detected)");
        *last = Instant::now();
    }
}
