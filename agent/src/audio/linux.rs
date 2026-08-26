//! Linux desktop audio capture and Opus streaming (US-009).
//!
//! The capture thread reads Opus packets from the ffmpeg source and sends
//! each as one UDP datagram to the client the control channel last reported.

use std::net::{IpAddr, SocketAddr, UdpSocket};
use std::sync::mpsc;
use std::thread;

use super::ffmpeg_source::FfmpegAudioSource;

/// Opus sample rate. 48 kHz is Opus's native rate and what the client
/// decodes at.
pub const SAMPLE_RATE: u32 = 48_000;
/// Opus frame duration in milliseconds. 20 ms is the Opus default and a
/// good latency/overhead tradeoff for desktop audio.
pub const FRAME_MS: u32 = 20;
/// Samples per Opus frame at [`SAMPLE_RATE`] and [`FRAME_MS`].
pub const SAMPLES_PER_FRAME: u64 = (SAMPLE_RATE as u64 * FRAME_MS as u64) / 1000;

/// One encoded Opus packet with its pipeline-clock timestamp.
pub struct AudioPacket {
    pub data: Vec<u8>,
    pub timestamp_us: u64,
}

/// Blocking source of Opus packets.
pub trait AudioSource: Send {
    /// Block for the next packet; `Ok(None)` at end of stream.
    fn next_packet(&mut self) -> anyhow::Result<Option<AudioPacket>>;
}

/// Start the capture thread. Returns the channel used to point audio at a
/// client IP, or None when the ffmpeg source could not start.
pub fn spawn(port_audio: u16, pipeline_epoch_us: u64) -> Option<mpsc::Sender<Option<IpAddr>>> {
    // ffmpeg is not started here; capture is tied to client presence (see
    // run), so an idle agent runs no audio process and, more importantly, a
    // monitor is opened while a client is connected and about to play sound,
    // not while the sink sits suspended.
    let (client_tx, client_rx) = mpsc::channel::<Option<IpAddr>>();
    let spawned = thread::Builder::new()
        .name("audio".into())
        .spawn(move || run(port_audio, pipeline_epoch_us, client_rx));
    match spawned {
        Ok(_) => Some(client_tx),
        Err(err) => {
            tracing::error!(%err, "failed to spawn audio thread");
            None
        }
    }
}

fn run(port_audio: u16, pipeline_epoch_us: u64, client_rx: mpsc::Receiver<Option<IpAddr>>) {
    let socket = match UdpSocket::bind(("0.0.0.0", 0)) {
        Ok(socket) => socket,
        Err(err) => {
            tracing::error!(%err, "audio socket bind failed, audio disabled");
            return;
        }
    };
    let mut client: Option<SocketAddr> = None;
    let mut source: Option<Box<dyn AudioSource>> = None;
    let mut sequence: u32 = 0;
    loop {
        if client.is_none() {
            // Park until a client connects; drop any capture in the meantime.
            source = None;
            match client_rx.recv() {
                Ok(ip) => client = ip.map(|ip| SocketAddr::new(ip, port_audio)),
                Err(_) => return, // pipeline gone
            }
            if let Some(client) = client {
                match FfmpegAudioSource::new() {
                    Ok(new_source) => {
                        tracing::info!(%client, "audio capture started for client");
                        source = Some(Box::new(new_source));
                    }
                    Err(err) => {
                        tracing::warn!("{err:#}: audio capture unavailable, video only");
                        // Keep the client set so we do not spin retrying; a
                        // reconnect re-enters this path.
                    }
                }
            }
            continue;
        }

        // A client change (disconnect or replacement) takes effect at once.
        while let Ok(ip) = client_rx.try_recv() {
            let next = ip.map(|ip| SocketAddr::new(ip, port_audio));
            if next != client {
                client = next;
                source = None; // rebuild capture for the new client, or stop
            }
        }
        let Some(current_source) = source.as_mut() else {
            continue; // re-enter the top to (re)build for the current client
        };
        let Some(client_addr) = client else {
            continue;
        };
        match current_source.next_packet() {
            Ok(Some(packet)) => {
                let datagram = porthole_agent::protocol::audio_datagram(
                    sequence,
                    pipeline_epoch_us + packet.timestamp_us,
                    &packet.data,
                );
                match socket.send_to(&datagram, client_addr) {
                    Ok(_) if sequence % 250 == 0 => {
                        tracing::debug!(sequence, bytes = packet.data.len(), "audio streaming")
                    }
                    Ok(_) => {}
                    Err(err) => tracing::debug!(%err, "audio send failed"),
                }
                sequence = sequence.wrapping_add(1);
            }
            Ok(None) => {
                tracing::info!("audio source ended, will restart on next packet demand");
                source = None;
            }
            Err(err) => {
                tracing::error!("{err:#}: audio capture failed, dropping the source");
                source = None;
            }
        }
    }
}
