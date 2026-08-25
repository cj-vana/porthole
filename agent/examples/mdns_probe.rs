//! mDNS browse probe: listens for _porthole._tcp services for a few seconds
//! and prints what it finds. Dev/debug tool (dev machines, the Linux box).
//!
//! Usage: cargo run --example mdns_probe -- [seconds]

use std::time::Duration;

fn main() -> anyhow::Result<()> {
    let secs: u64 = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(5);
    let register_test = std::env::args().any(|a| a == "--announce-test");
    let daemon = mdns_sd::ServiceDaemon::new()?;
    let mut test_fullname = None;
    if register_test {
        // Register a scratch service, to verify announce works at all.
        let info = mdns_sd::ServiceInfo::new(
            "_porthole._tcp.local.",
            "mdns-probe-test",
            "probe.local.",
            "",
            52999,
            &[("v", "1")][..],
        )?
        .enable_addr_auto();
        test_fullname = Some(info.get_fullname().to_string());
        daemon.register(info)?;
        println!("registered test service");
    }
    let receiver = daemon.browse("_porthole._tcp.local.")?;
    let deadline = std::time::Instant::now() + Duration::from_secs(secs);
    while std::time::Instant::now() < deadline {
        if let Ok(event) = receiver.recv_timeout(Duration::from_millis(500)) {
            match event {
                mdns_sd::ServiceEvent::ServiceResolved(info) => {
                    println!(
                        "resolved: {} -> {}:{} ({:?})",
                        info.get_fullname(),
                        info.get_hostname(),
                        info.get_port(),
                        info.get_properties()
                    );
                }
                other => println!("event: {other:?}"),
            }
        }
        // Err is a timeout or disconnect; keep waiting until the deadline.
    }
    if let Some(fullname) = test_fullname {
        let _ = daemon.unregister(&fullname);
    }
    daemon.shutdown()?;
    Ok(())
}
