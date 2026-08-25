# porthole-agent

Linux agent for **Porthole**. It captures the desktop, hardware-encodes it on
the machine's NVIDIA dGPU (NVENC) or on the Ryzen iGPU (VAAPI, selectable via
`--encoder`), and streams it over LAN to the native Mac client. See
`tasks/prd-porthole.md` for the full PRD.

Current state: screen capture (US-001) works on Wayland via
wlr-screencopy (tested on Hyprland at 1920x1080, 60 fps). Hardware encode
(US-002), transport (US-003), input (US-006), and audio (US-009) are still
trait stubs with TODOs.

## Build

```sh
cargo build            # debug
cargo build --release  # release binary at target/release/porthole-agent
```

The crate builds on macOS and Linux; capture is cfg-gated and only active on
Linux (macOS keeps a noop backend for development). The encode pipeline will
need system packages installed before its crates land (not required yet):

- GStreamer dev: `libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev`
  (Debian/Ubuntu), for the hardware encode pipeline
- `libevdev`/`uinput` headers (input injection, US-006)
- An NVIDIA GPU with NVENC and the proprietary driver (default encoder), or a
  Ryzen iGPU with VAAPI support for the `--encoder vaapi` path

## Run

```sh
cargo run -- --help
cargo run -- --config config.example.toml --codec hevc --bitrate-mbps 60
RUST_LOG=debug cargo run
```

The agent logs its version and effective configuration on startup, then idles
with a debug heartbeat every 5s until Ctrl+C, which triggers a clean shutdown.

## Configuration

Single TOML file (PRD FR-11); every field is optional. Precedence:
built-in defaults < config file < CLI flags. See `config.example.toml`.

| Flag              | Default | Description                       |
|-------------------|---------|-----------------------------------|
| `--config`        | none    | Path to TOML config file          |
| `--port-video`    | 52800   | UDP port for the video stream     |
| `--port-control`  | 52801   | TCP port for the control channel  |
| `--port-audio`    | 52802   | UDP port for the audio stream     |
| `--bitrate-mbps`  | 40      | Encoder target bitrate            |
| `--codec`         | h264    | `h264` or `hevc`                  |
| `--encoder`       | nvenc   | `nvenc` (dGPU) or `vaapi` (iGPU)  |
| `--fps`           | 60      | `60`, `120`, or `144`             |

## systemd (user service)

```sh
install -Dm755 target/release/porthole-agent /usr/local/bin/porthole-agent
install -Dm644 packaging/porthole-agent.service ~/.config/systemd/user/porthole-agent.service
systemctl --user daemon-reload
systemctl --user enable --now porthole-agent
journalctl --user -u porthole-agent -f
```

Edit the unit to point `--config` at your TOML file if you use one.

## Development

```sh
cargo clippy -- -D warnings
cargo test
```

Module map: `capture` (wlr-screencopy on Wayland, US-001), `encode` (NVENC or
VAAPI, H.264/HEVC, US-002), `transport` (TCP control + UDP video/audio,
US-003), `input` (uinput keyboard/mouse/gamepad, US-006/US-014), `audio`
(Opus over UDP, US-009).
