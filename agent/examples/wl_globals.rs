//! List the Wayland globals the compositor advertises. Support tool: run it
//! on the Linux machine to see which capture, input, and cursor protocols
//! porthole-agent can use there.
//!
//! Usage: cargo run --example wl_globals

#[cfg(target_os = "linux")]
fn main() -> anyhow::Result<()> {
    use wayland_client::protocol::wl_registry;
    use wayland_client::{Connection, Dispatch, QueueHandle};

    struct Globals(Vec<(String, u32)>);

    impl Dispatch<wl_registry::WlRegistry, ()> for Globals {
        fn event(
            state: &mut Self,
            _: &wl_registry::WlRegistry,
            event: wl_registry::Event,
            _: &(),
            _: &Connection,
            _: &QueueHandle<Self>,
        ) {
            if let wl_registry::Event::Global {
                interface, version, ..
            } = event
            {
                state.0.push((interface, version));
            }
        }
    }

    let conn = Connection::connect_to_env()?;
    let display = conn.display();
    let mut queue = conn.new_event_queue();
    let _registry = display.get_registry(&queue.handle(), ());
    let mut globals = Globals(Vec::new());
    queue.roundtrip(&mut globals)?;
    globals.0.sort();
    for (interface, version) in globals.0 {
        println!("{interface} v{version}");
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("wl_globals only runs on Linux (Wayland)");
}
