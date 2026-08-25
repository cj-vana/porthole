//! Scripted input sender for the Porthole wire protocol (docs/protocol.md).
//! Cross-platform, std only: connects to the agent's control channel and
//! sends one scripted input action. Used to verify US-006a without a Mac.
//!
//! Usage: cargo run --example input_sender -- <agent-ip> <subcommand>

use std::net::TcpStream;
use std::thread;
use std::time::Duration;

use anyhow::{bail, Context};
use clap::Parser;
use porthole_agent::protocol::{self, InputEvent};

const BTN_LEFT: u16 = 0x110;
const BTN_RIGHT: u16 = 0x111;
const BTN_MIDDLE: u16 = 0x112;
/// xkb modifier bit for Shift (bit order: 0 Shift, 1 Lock, 2 Control, ...).
const MOD_SHIFT: u32 = 1;

/// Porthole scripted input sender (verification tool for US-006a).
#[derive(Parser)]
#[command(name = "input_sender", about)]
struct Args {
    /// Agent host (its control channel address).
    host: String,

    /// Agent control port [default: 52801]
    #[arg(long, default_value_t = 52801)]
    port_control: u16,

    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(clap::Subcommand)]
enum Cmd {
    /// Move the pointer to absolute output pixel coordinates.
    MoveAbs { x: i32, y: i32 },
    /// Move the pointer by a relative delta, in pixels.
    MoveRel { dx: f64, dy: f64 },
    /// Click a button: left (default), right, middle.
    #[command(name = "click")]
    Click { button: Option<String> },
    /// Scroll vertically by N pixels (negative scrolls the other way).
    Scroll { amount: f64 },
    /// Type an ASCII string (uppercase and shifted punctuation via
    /// key_modifiers messages).
    Type { text: String },
}

fn connect(host: &str, port: u16) -> anyhow::Result<TcpStream> {
    let mut stream = TcpStream::connect((host, port))
        .with_context(|| format!("failed to connect to {host}:{port}"))?;
    // The hello arrives first; consume and discard it.
    let (msg_type, _payload) = protocol::read_control_message(&mut stream)?
        .context("agent closed the control channel before hello")?;
    if msg_type != protocol::CONTROL_MSG_HELLO {
        bail!("expected hello (type 1), got message type {msg_type}");
    }
    Ok(stream)
}

fn send(stream: &mut TcpStream, event: &InputEvent) -> anyhow::Result<()> {
    protocol::write_input_event(stream, event).context("failed to send input event")
}

fn key_press(stream: &mut TcpStream, code: u16) -> anyhow::Result<()> {
    send(stream, &InputEvent::Key { code, pressed: true })?;
    thread::sleep(Duration::from_millis(20));
    send(stream, &InputEvent::Key { code, pressed: false })?;
    Ok(())
}

/// ASCII to evdev key codes. Returns (code, needs_shift).
fn ascii_to_key(c: char) -> Option<(u16, bool)> {
    let plain = match c {
        'a'..='z' => Some(match c {
            'a' => 30, 'b' => 48, 'c' => 46, 'd' => 32, 'e' => 18, 'f' => 33, 'g' => 34,
            'h' => 35, 'i' => 23, 'j' => 36, 'k' => 37, 'l' => 38, 'm' => 50, 'n' => 49,
            'o' => 24, 'p' => 25, 'q' => 16, 'r' => 19, 's' => 31, 't' => 20, 'u' => 22,
            'v' => 47, 'w' => 17, 'x' => 45, 'y' => 21, 'z' => 44,
            _ => unreachable!(),
        }),
        '1'..='9' => Some(c as u16 - b'1' as u16 + 2),
        '0' => Some(11),
        ' ' => Some(57),
        '\n' => Some(28),
        '-' => Some(12),
        '=' => Some(13),
        '.' => Some(52),
        ',' => Some(51),
        '/' => Some(53),
        ';' => Some(39),
        '\'' => Some(40),
        '\t' => Some(15),
        _ => None,
    };
    if let Some(code) = plain {
        return Some((code, false));
    }
    match c {
        'A'..='Z' => ascii_to_key(c.to_ascii_lowercase()).map(|(code, _)| (code, true)),
        // Shifted digit row: ! @ # $ % ^ & * ( )
        c if "!@#$%^&*()".contains(c) => {
            let idx = "!@#$%^&*()".find(c)? as u16;
            Some((idx + 2, true)) // shift + KEY_1..KEY_0
        }
        _ => None,
    }
}

fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let mut stream = connect(&args.host, args.port_control)?;

    match args.cmd {
        Cmd::MoveAbs { x, y } => send(&mut stream, &InputEvent::PointerMotionAbs { x, y })?,
        Cmd::MoveRel { dx, dy } => send(
            &mut stream,
            &InputEvent::PointerMotionRel {
                dx256: (dx * 256.0).round() as i32,
                dy256: (dy * 256.0).round() as i32,
            },
        )?,
        Cmd::Click { button } => {
            let button = match button.as_deref().unwrap_or("left") {
                "left" => BTN_LEFT,
                "right" => BTN_RIGHT,
                "middle" => BTN_MIDDLE,
                other => bail!("unknown button {other:?} (left/right/middle)"),
            };
            send(&mut stream, &InputEvent::PointerButton { button, pressed: true })?;
            thread::sleep(Duration::from_millis(30));
            send(&mut stream, &InputEvent::PointerButton { button, pressed: false })?;
        }
        Cmd::Scroll { amount } => send(
            &mut stream,
            &InputEvent::PointerAxis {
                axis: protocol::AXIS_VERTICAL,
                source: protocol::AXIS_SOURCE_CONTINUOUS,
                value256: (amount * 256.0).round() as i32,
            },
        )?,
        Cmd::Type { text } => {
            for c in text.chars() {
                let (code, shift) = ascii_to_key(c)
                    .with_context(|| format!("no key mapping for {c:?} (small ASCII table only)"))?;
                // Modifier state goes through key_modifiers messages; the
                // virtual keyboard protocol does not derive it from key
                // events (docs/protocol.md, type 0x15).
                if shift {
                    send(&mut stream, &InputEvent::KeyModifiers { depressed: MOD_SHIFT, latched: 0, locked: 0, group: 0 })?;
                    thread::sleep(Duration::from_millis(10));
                }
                key_press(&mut stream, code)?;
                if shift {
                    send(&mut stream, &InputEvent::KeyModifiers { depressed: 0, latched: 0, locked: 0, group: 0 })?;
                }
                thread::sleep(Duration::from_millis(20));
            }
        }
    }
    println!("sent");
    Ok(())
}
