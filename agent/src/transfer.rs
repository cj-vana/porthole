//! File transfer endpoint (US-011, FR-19).
//!
//! Files dragged onto the Mac window arrive here over their own TCP
//! connection, one per file, so a large transfer never competes with the
//! video path. Wire format (docs/protocol.md "File transfer"): a 2-byte
//! big-endian name length, the UTF-8 file name, an 8-byte big-endian size,
//! then the file bytes. The file lands in the configured transfer folder
//! (default the user's Downloads) under a temporary name and is renamed into
//! place only once the whole size has arrived, so a partial transfer never
//! leaves a file that looks complete.

use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;

use anyhow::Context;

use crate::config::Config;

/// Distinguishes concurrent transfers' temporary files so two drops of the
/// same name never write the same `.part` path.
static TRANSFER_SEQ: AtomicU64 = AtomicU64::new(0);

/// Bytes copied per read from the socket to the file.
const COPY_CHUNK: usize = 64 * 1024;
/// Refuse absurd names and sizes rather than trusting the peer.
const MAX_NAME_LEN: usize = 4096;

/// Start the file-transfer listener. Each accepted connection is handled on
/// its own thread and receives exactly one file.
pub fn spawn_file_server(cfg: &Config) -> anyhow::Result<()> {
    let listener = TcpListener::bind(cfg.files_addr())
        .with_context(|| format!("failed to bind file transfer endpoint {}", cfg.files_addr()))?;
    let dir = transfer_dir(cfg);
    tracing::info!(addr = %cfg.files_addr(), dir = %dir.display(), "file transfer endpoint listening");
    thread::Builder::new()
        .name("file-server".into())
        .spawn(move || {
            for stream in listener.incoming() {
                match stream {
                    Ok(stream) => {
                        let dir = dir.clone();
                        thread::Builder::new()
                            .name("file-receive".into())
                            .spawn(move || {
                                if let Err(err) = receive_file(stream, &dir) {
                                    tracing::warn!("{err:#}: file transfer failed");
                                }
                            })
                            .ok();
                    }
                    Err(err) => tracing::warn!(%err, "file transfer accept failed"),
                }
            }
        })
        .context("failed to spawn file transfer server")?;
    Ok(())
}

/// The folder received files are written to: the configured `transfer_dir`,
/// else `$HOME/Downloads`, else the current directory.
fn transfer_dir(cfg: &Config) -> PathBuf {
    if let Some(dir) = &cfg.transfer_dir {
        return dir.clone();
    }
    std::env::var_os("HOME")
        .map(|home| PathBuf::from(home).join("Downloads"))
        .unwrap_or_else(|| PathBuf::from("."))
}

fn receive_file(mut stream: TcpStream, dir: &Path) -> anyhow::Result<()> {
    let peer = stream.peer_addr().ok();
    let mut len_buf = [0u8; 2];
    stream
        .read_exact(&mut len_buf)
        .context("reading name length")?;
    let name_len = u16::from_be_bytes(len_buf) as usize;
    if name_len == 0 || name_len > MAX_NAME_LEN {
        anyhow::bail!("implausible file name length {name_len}");
    }
    let mut name_buf = vec![0u8; name_len];
    stream.read_exact(&mut name_buf).context("reading name")?;
    let raw_name = String::from_utf8(name_buf).context("file name is not UTF-8")?;
    let name = sanitize_name(&raw_name);

    let mut size_buf = [0u8; 8];
    stream.read_exact(&mut size_buf).context("reading size")?;
    let size = u64::from_be_bytes(size_buf);

    fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    // A per-transfer temporary name so two drops of the same file name do not
    // write the same partial file; the final name is chosen at rename time,
    // after the bytes are on disk, so concurrent drops never collide.
    let seq = TRANSFER_SEQ.fetch_add(1, Ordering::Relaxed);
    let part_path = dir.join(format!(".porthole-{}-{}.part", std::process::id(), seq));

    tracing::info!(peer = ?peer, name = %name, size, "receiving file");

    let received = copy_exact(&mut stream, &part_path, size)?;
    if received != size {
        let _ = fs::remove_file(&part_path);
        anyhow::bail!("file truncated: got {received} of {size} bytes");
    }
    let final_path = unique_path(dir, &name);
    if let Err(err) = fs::rename(&part_path, &final_path) {
        let _ = fs::remove_file(&part_path);
        return Err(err).with_context(|| format!("renaming into {}", final_path.display()));
    }
    tracing::info!(dest = %final_path.display(), size, "file received");
    // A one-byte ack lets the client show success; ignore write errors (the
    // file is already safe on disk).
    let _ = stream.write_all(&[1u8]);
    Ok(())
}

/// Copy exactly `size` bytes from the stream into a new file, returning how
/// many were actually read (short means the peer hung up early).
fn copy_exact(stream: &mut TcpStream, path: &Path, size: u64) -> anyhow::Result<u64> {
    let mut file =
        fs::File::create(path).with_context(|| format!("creating {}", path.display()))?;
    let mut remaining = size;
    let mut buf = vec![0u8; COPY_CHUNK];
    while remaining > 0 {
        let want = remaining.min(COPY_CHUNK as u64) as usize;
        let read = stream.read(&mut buf[..want])?;
        if read == 0 {
            break;
        }
        file.write_all(&buf[..read])?;
        remaining -= read as u64;
    }
    file.flush()?;
    Ok(size - remaining)
}

/// Strip any directory components a peer put in the name; keep just the file
/// name so a transfer can never escape the destination folder.
fn sanitize_name(raw: &str) -> String {
    let base = Path::new(raw)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("");
    if base.is_empty() || base == "." || base == ".." {
        "porthole-file".to_string()
    } else {
        base.to_string()
    }
}

/// A path that does not collide with an existing file: `name`, then
/// `name (1)`, `name (2)`, and so on.
fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let candidate = dir.join(name);
    if !candidate.exists() {
        return candidate;
    }
    let path = Path::new(name);
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or(name);
    let ext = path.extension().and_then(|e| e.to_str());
    for n in 1..10_000 {
        let candidate_name = match ext {
            Some(ext) => format!("{stem} ({n}).{ext}"),
            None => format!("{stem} ({n})"),
        };
        let candidate = dir.join(candidate_name);
        if !candidate.exists() {
            return candidate;
        }
    }
    dir.join(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_strips_paths() {
        assert_eq!(sanitize_name("../../etc/passwd"), "passwd");
        assert_eq!(sanitize_name("plain.txt"), "plain.txt");
        assert_eq!(sanitize_name("/abs/path/file.bin"), "file.bin");
        assert_eq!(sanitize_name(".."), "porthole-file");
        assert_eq!(sanitize_name(""), "porthole-file");
    }

    #[test]
    fn unique_path_avoids_collisions() {
        let dir =
            std::env::temp_dir().join(format!("porthole-transfer-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let first = unique_path(&dir, "a.txt");
        assert_eq!(first, dir.join("a.txt"));
        fs::write(&first, b"x").unwrap();
        let second = unique_path(&dir, "a.txt");
        assert_eq!(second, dir.join("a (1).txt"));
        fs::remove_dir_all(&dir).ok();
    }
}
