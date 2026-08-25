# porthole-agent

Linux agent for **Porthole**. It captures the desktop, hardware-encodes it on
the machine's NVIDIA dGPU (NVENC) or on the Ryzen iGPU (VAAPI, selectable via
`--encoder`), and streams it over LAN to the native Mac client. See
`tasks/prd-porthole.md` for the full PRD.

Current state: screen capture (US-001) works on Wayland via
wlr-screencopy, headless virtual displays (US-015) work on Hyprland, and
hardware encode (US-002) works with NVENC or VAAPI via an ffmpeg subprocess
(tested: 2560x1440 at 60 fps in and out, H.264 and HEVC). Transport
(US-003), input (US-006), and audio (US-009) are still trait stubs with
TODOs.

## Build

```sh
cargo build            # debug
cargo build --release  # release binary at target/release/porthole-agent
```

The crate builds on macOS and Linux; capture and encode are cfg-gated and
only active on Linux (macOS keeps noop versions for development). Runtime
requirement on Linux: `ffmpeg` with the `h264_nvenc`/`hevc_nvenc` and
`h264_vaapi`/`hevc_vaapi` encoders. Later stories will need:

- `libevdev`/`uinput` headers (input injection, US-006)
- An NVIDIA GPU with NVENC and the proprietary driver (default encoder), or a
  Ryzen iGPU with VAAPI support for the `--encoder vaapi` path

## Run

```sh
cargo run -- --help
cargo run -- --config config.example.toml --codec hevc --bitrate-mbps 60
RUST_LOG=debug cargo run
```

The agent logs its version and effective configuration on startup, then runs
the capture/encode pipeline, logging a combined stats line once per second
(capture fps, encode in/out fps, encoded kbps, keyframes). Ctrl+C triggers a
clean shutdown. Set `PORTHOLE_DUMP_VIDEO=/path/out.h264` to write the encoded
Annex B stream to a file for inspection with ffprobe.

### Encoder architecture (US-002)

Encoding runs in an ffmpeg subprocess per session: raw bgra frames are piped
to stdin, Annex B access units are read from stdout and cut at access unit
delimiters (`-aud 1`). Chosen over linking libavcodec (via the ffmpeg-next
crate) because the target box runs FFmpeg 9, far newer than those bindings
support, and a subprocess needs no new system packages and survives FFmpeg
upgrades. NVENC takes bgra input and converts on-GPU; VAAPI uses
`hwupload,scale_vaapi=format=nv12` on the iGPU's by-path render node
(`/dev/dri/by-path/pci-0000:0b:00.0-render`), so no CPU pixel conversion runs
on either backend. One known gap: `request_keyframe` (FR-4) cannot force an
IDR mid-session in a subprocess; periodic IDRs come from
`--keyframe-interval-secs` until the transport story revisits this.

## Configuration

Single TOML file (PRD FR-11); every field is optional. Precedence:
built-in defaults < config file < CLI flags. See `config.example.toml`.
Without `--config`, the agent loads
`$XDG_CONFIG_HOME/porthole-agent/config.toml` (or
`~/.config/porthole-agent/config.toml`) when it exists.

| Flag                | Default | Description                                |
|---------------------|---------|--------------------------------------------|
| `--config`          | none    | Path to TOML config file                   |
| `--port-video`      | 52800   | UDP port for the video stream              |
| `--port-control`    | 52801   | TCP port for the control channel           |
| `--port-audio`      | 52802   | UDP port for the audio stream              |
| `--bitrate-mbps`    | 40      | Encoder target bitrate                     |
| `--codec`           | h264    | `h264` or `hevc`                           |
| `--encoder`         | nvenc   | `nvenc` (dGPU) or `vaapi` (iGPU)           |
| `--fps`             | 60      | `60`, `120`, or `144`                      |
| `--keyframe-interval-secs` | 2 | Seconds between IDR keyframes        |
| `--virtual-display` | off     | `WxH@Hz`, e.g. `2560x1440@144` (see below) |

### Virtual display (headless operation, US-015)

The feature is Hyprland-specific: the agent shells out to `hyprctl`, so it
needs a running Hyprland session. When `virtual_display` is set and no
physical monitor is attached, the agent creates a headless output at the
configured geometry and captures it. An existing headless output at that
geometry is reused (one at another geometry is reconfigured), so repeated
starts never duplicate outputs. With a physical monitor attached, outputs are
left alone and the agent logs why. Session environment (XDG_RUNTIME_DIR,
HYPRLAND_INSTANCE_SIGNATURE) is discovered at runtime, so this works over SSH
and under systemd.

## systemd (user service)

```sh
install -Dm755 target/release/porthole-agent /usr/local/bin/porthole-agent
install -Dm644 packaging/porthole-agent.service ~/.config/systemd/user/porthole-agent.service
systemctl --user daemon-reload
systemctl --user enable --now porthole-agent
journalctl --user -u porthole-agent -f
```

Edit the unit to point `--config` at your TOML file if you use one; otherwise
the default `~/.config/porthole-agent/config.toml` is picked up.

## Development

```sh
cargo clippy -- -D warnings
cargo test
```

Module map: `capture` (wlr-screencopy on Wayland, US-001), `virtual_display`
(Hyprland headless outputs, US-015), `encode` (ffmpeg subprocess: NVENC or
VAAPI, H.264/HEVC, US-002), `transport` (TCP control + UDP video/audio,
US-003), `input` (uinput keyboard/mouse/gamepad, US-006/US-014), `audio`
(Opus over UDP, US-009).
