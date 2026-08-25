//! Thumbnail fetcher for the Porthole discovery endpoint (docs/protocol.md).
//! Cross-platform: connects to the agent's thumbnail port, reads one
//! length-prefixed thumbnail, writes it as PNG.
//!
//! Usage: cargo run --example thumb_fetch -- <agent-ip> <out.png>

use std::io::Read;
use std::net::TcpStream;
use std::path::PathBuf;

use anyhow::{bail, Context};
use clap::Parser;
use porthole_agent::thumbnail;

/// Porthole thumbnail fetcher (verification tool for FR-10).
#[derive(Parser)]
#[command(name = "thumb_fetch", about)]
struct Args {
    /// Agent host.
    host: String,

    /// Output PNG path.
    out: PathBuf,

    /// Agent thumbnail port [default: 52803]
    #[arg(long, default_value_t = 52803)]
    port_thumbnail: u16,
}

fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let mut stream = TcpStream::connect((args.host.as_str(), args.port_thumbnail))
        .with_context(|| format!("failed to connect to {}:{}", args.host, args.port_thumbnail))?;

    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf)?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len == 0 {
        bail!("agent has no thumbnail yet (no frame captured)");
    }
    if len > 4 + 4096 * 4096 * 4 {
        bail!("implausible thumbnail length {len}");
    }
    let mut payload = vec![0u8; len];
    stream.read_exact(&mut payload)?;

    let (width, height, rgba) =
        thumbnail::decode_thumbnail(&payload).context("malformed thumbnail payload")?;

    let file = std::fs::File::create(&args.out)
        .with_context(|| format!("failed to create {}", args.out.display()))?;
    let mut encoder = png::Encoder::new(std::io::BufWriter::new(file), u32::from(width), u32::from(height));
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header()?;
    writer.write_image_data(rgba)?;

    println!("wrote {} ({}x{})", args.out.display(), width, height);
    Ok(())
}
