//! Discovery (US-007a): mDNS announce (FR-8) and the thumbnail endpoint
//! (FR-10). Wire details are in docs/protocol.md, "Discovery and thumbnails".
//!
//! The announcement lives and dies with the agent process. The thumbnail
//! endpoint is a separate one-shot TCP service so the picker never touches
//! the single-client control channel or disturbs an active session.

use std::io::Write as _;
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::thread;

use anyhow::Context;
use mdns_sd::{ServiceDaemon, ServiceInfo, TxtProperty};
use porthole_agent::thumbnail;

use crate::config::{self, Config};

/// The mDNS service type advertised by agents.
const SERVICE_TYPE: &str = "_porthole._tcp.local.";

/// Latest captured frame, shared between the capture thread and the
/// thumbnail endpoint: (bgra data, width, height, stride).
pub type LatestFrame = Arc<Mutex<Option<(Vec<u8>, u32, u32, usize)>>>;

/// A live mDNS announcement; dropping it unregisters the service.
pub struct Announcement {
    daemon: ServiceDaemon,
    fullname: String,
}

/// Advertise `_porthole._tcp.local.` with the agent's name, ports, and
/// capabilities. Returns None (with a warning) when mDNS setup fails.
pub fn announce(cfg: &Config) -> Option<Announcement> {
    match announce_inner(cfg) {
        Ok(a) => {
            tracing::info!(name = %cfg.name, fullname = %a.fullname, "announcing via mDNS");
            Some(a)
        }
        Err(err) => {
            tracing::warn!("{err:#}: mDNS announce failed, discovery unavailable");
            None
        }
    }
}

fn announce_inner(cfg: &Config) -> anyhow::Result<Announcement> {
    let daemon = ServiceDaemon::new().context("failed to start mDNS daemon")?;
    let caps = format!("{},h264,hevc,180", cfg.encoder);
    let properties: Vec<TxtProperty> = vec![
        ("v".to_string(), "1".to_string()),
        ("name".to_string(), cfg.name.clone()),
        ("control_port".to_string(), cfg.port_control.to_string()),
        ("video_port".to_string(), cfg.port_video.to_string()),
        ("thumb_port".to_string(), cfg.port_thumbnail.to_string()),
        ("caps".to_string(), caps),
    ]
    .into_iter()
    .map(TxtProperty::from)
    .collect();
    let host_name = format!("{}.local.", config::hostname());
    let info = ServiceInfo::new(
        SERVICE_TYPE,
        &cfg.name,
        &host_name,
        "", // empty: advertise on all interface addresses
        cfg.port_control,
        properties,
    )
    .context("failed to build mDNS service info")?
    // With no explicit addresses this flag is required, otherwise the
    // service is never announced (mdns-sd leaves addr_auto off by default).
    .enable_addr_auto();
    let fullname = info.get_fullname().to_string();
    daemon
        .register(info)
        .context("failed to register mDNS service")?;
    Ok(Announcement { daemon, fullname })
}

impl Drop for Announcement {
    fn drop(&mut self) {
        if let Err(err) = self.daemon.unregister(&self.fullname) {
            tracing::warn!(%err, "mDNS unregister failed");
        }
        if let Err(err) = self.daemon.shutdown() {
            tracing::warn!(%err, "mDNS daemon shutdown failed");
        }
    }
}

/// Serve one-shot thumbnails: accept a connection, immediately write one
/// length-prefixed thumbnail (4-byte BE length + payload per protocol.md),
/// close. A zero-length payload means no frame captured yet.
pub fn spawn_thumbnail_server(cfg: &Config, latest: LatestFrame) -> anyhow::Result<()> {
    let listener = TcpListener::bind(cfg.thumbnail_addr()).map_err(|e| {
        anyhow::anyhow!(
            "failed to bind thumbnail endpoint {}: {e}",
            cfg.thumbnail_addr()
        )
    })?;
    tracing::info!(addr = %cfg.thumbnail_addr(), "thumbnail endpoint listening");
    thread::Builder::new()
        .name("thumbnail-server".into())
        .spawn(move || {
            for stream in listener.incoming() {
                match stream {
                    Ok(mut stream) => {
                        let payload = {
                            let snapshot = latest.lock().expect("thumbnail slot poisoned").clone();
                            snapshot.and_then(|(data, w, h, stride)| {
                                thumbnail::downscale_bgra_to_rgba(&data, w, h, stride).map(
                                    |(tw, th, rgba)| thumbnail::encode_thumbnail(tw, th, &rgba),
                                )
                            })
                        }
                        .unwrap_or_default();
                        let len = (payload.len() as u32).to_be_bytes();
                        if let Err(err) = stream
                            .write_all(&len)
                            .and_then(|()| stream.write_all(&payload))
                        {
                            tracing::debug!(%err, "thumbnail write failed");
                        }
                        // Connection closes on drop.
                    }
                    Err(err) => tracing::warn!(%err, "thumbnail accept failed"),
                }
            }
        })
        .context("failed to spawn thumbnail server")?;
    Ok(())
}
