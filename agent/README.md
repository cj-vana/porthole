# porthole-agent

Linux agent for **Porthole**. It captures the desktop, hardware-encodes it on
the machine's NVIDIA dGPU (NVENC) or on the Ryzen iGPU (VAAPI, selectable via
`--encoder`), and streams it over LAN to the native Mac client. See
`tasks/prd-porthole.md` for the full PRD.

Current state: screen capture (US-001) works on Wayland via
wlr-screencopy, headless virtual displays (US-015) work on Hyprland,
hardware encode (US-002) works with NVENC or VAAPI via an ffmpeg subprocess,
LAN transport (US-003) streams fragmented UDP video with a TCP control
channel, and input injection (US-006a) drives a virtual pointer and keyboard
on the Linux session from control-channel messages. Discovery (US-007a)
announces the agent via mDNS and serves one-shot thumbnails for the picker,
and desktop audio (US-009) is captured, Opus-encoded, and streamed over UDP.

## Build

```sh
cargo build            # debug
cargo build --release  # release binary at target/release/porthole-agent
```

The crate builds on macOS and Linux; capture and encode are cfg-gated and
only active on Linux (macOS keeps noop versions for development). Runtime
requirement on Linux: `ffmpeg` with the `h264_nvenc`/`hevc_nvenc` and
`h264_vaapi`/`hevc_vaapi` encoders, plus `libxkbcommon` (input injection,
already present wherever Hyprland runs). Later stories will need:

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
(capture fps, encode in/out fps, encoded kbps, keyframes, and
`enc_latency_ms`: the mean time from frame submit to access unit ready).
The same numbers go to the connected client once per second as an
`agent_stats` control message, so the client can split its glass-to-glass
measurement into encode and transport. Ctrl+C triggers a clean shutdown.
Set `PORTHOLE_DUMP_VIDEO=/path/out.h264` to write the encoded Annex B
stream to a file for inspection with ffprobe.

### Encoder architecture (US-002)

Encoding runs in an ffmpeg subprocess per session: raw bgra frames are piped
to stdin, Annex B access units are read from stdout and cut at access unit
delimiters (`-aud 1`). Chosen over linking libavcodec (via the ffmpeg-next
crate) because the target box runs FFmpeg 9, far newer than those bindings
support, and a subprocess needs no new system packages and survives FFmpeg
upgrades. NVENC takes bgra input and converts on-GPU; VAAPI uses
`hwupload,scale_vaapi=format=nv12` on the iGPU's render node, so no CPU
pixel conversion runs on either backend. The VAAPI node is picked at
encoder start unless `--vaapi-device` names one: the agent lists
`/dev/dri/renderD*`, reads each node's driver from
`/sys/class/drm/<node>/device/driver`, skips nvidia, and prefers amdgpu,
then i915, then xe. Keyframes: periodic IDRs come from
`--keyframe-interval-secs`; a client `keyframe_request` (FR-4) restarts the
encoder session, since a subprocess ffmpeg cannot force an IDR mid-session.

Both backends run with their latency knobs turned down. ffmpeg's `-delay`
option for NVENC defaults to INT_MAX, which queues several frames inside
the encoder before the first one comes out, so NVENC gets `-delay 0` with
`-zerolatency 1`, `-bf 0`, and `-rc cbr` on top of `-preset p3 -tune ll`.
VAAPI gets `-bf 0`, `-async_depth 1` (one frame in flight instead of two),
and `-rc_mode CBR`. No B-frames means no frame ever waits on a later one,
and constant bitrate keeps per-frame size, and so transmit time, steady.

### Transport (US-003)

The wire format is specified in `../docs/protocol.md` and implemented once
in `src/protocol.rs` (shared with the example receiver). TCP control on
52801: the agent sends a hello (codec, resolution, fps, bitrate, keyframe
interval, video port) on connect; the client can send `keyframe_request`,
input, and `ping`, which the agent answers with `pong` straight from the
control reader (no trip through the video pipeline). UDP video on 52800:
each access unit is fragmented into datagrams sized from `--mtu` (MTU minus
28 bytes of IP and UDP headers, so 1252 bytes at the default 1280) with a
25-byte header (magic, version, frame sequence, capture timestamp,
fragment index/count, keyframe flag), all big-endian. A datagram larger
than the path MTU gets IP-fragmented, and losing any piece loses the whole
datagram; that is what made keyframe bursts unrecoverable over a
WireGuard tunnel with the old fixed 1400-byte size. One client at a time; a
new control connection replaces the old one. Video goes to the control
peer's IP at the negotiated port, so anything LAN-like (including
Tailscale) works.

A keyframe is several hundred datagrams, and firing them at NIC speed
loses the tail of the burst two ways: macOS charges 2 KB of mbuf per
received datagram regardless of size, so 400 datagrams overflow the default
786 KB UDP socket buffer before the client reads any, and a userspace
tunnel's ring between the kernel and its own thread overruns at line rate.
The sender therefore paces each access unit's burst at 400 Mbit/s, sleeping
only once the deficit reaches 50 microseconds, so a 500 KB IDR takes about
10 ms to leave instead of a fraction of one.

The control channel has TCP_NODELAY set and exactly one writer per
connection: a thread that owns the write side and drains a bounded queue
of framed messages. The hello, the reader thread's pong answers, and the
pipeline's per-second `agent_stats` all go through that queue, so nothing
can interleave on the wire and the capture loop never blocks on a slow
peer (stats are dropped when the queue is full or no client is
connected). Accepted connections are numbered, and connect/disconnect
events carry that generation, so the pipeline can tell a replaced
connection's late disconnect from the current client going away. Verify
with the reference receiver: `cargo run --example receiver -- <agent-ip>
--dump out.h264`, then `ffprobe out.h264`; it prints each pong's round
trip and the agent's stats as they arrive.

### Input injection (US-006a)

/dev/uinput is root-only, so pointer and keyboard events from the client
ride the control channel (message types 0x10-0x14, see `../docs/protocol.md`)
and are injected through Hyprland's Wayland protocols:
zwlr_virtual_pointer_v1 (absolute/relative motion, buttons, axis) and
virtual-keyboard-unstable-v1 (evdev key codes, with an evdev/pc105/us xkb
keymap uploaded from a memfd via libxkbcommon). The virtual-keyboard
bindings are generated from a vendored XML copy
(`protocols/virtual-keyboard-unstable-v1.xml`, from Hyprland's tree) because
the wayland-protocols crate no longer ships that protocol. Modifier state
for shifted characters rides the key_modifiers message (type 0x15).
Verify without a Mac:
`cargo run --example input_sender -- <agent-ip> type 'Hello!'`.

### Discovery (US-007a)

While running, the agent announces `_porthole._tcp.local.` via mDNS (pure
Rust mdns-sd crate, no system services) with TXT records for name, ports,
and capabilities; see `../docs/protocol.md`. The name comes from `--name`
(TOML `name`), default the system hostname. For the machine picker there is
a one-shot thumbnail endpoint on `--port-thumbnail` (default 52803):
connect, get one length-prefixed 320px RGBA thumbnail, close. It never
touches the single-client control channel, so polling cannot disturb an
active session. Verify with `cargo run --example thumb_fetch -- <agent-ip>
out.png`.

### Audio (US-009)

Desktop audio is captured from the PulseAudio/PipeWire default sink monitor
(resolved at runtime with `pactl get-default-sink`) and encoded to Opus by
an ffmpeg subprocess, the same integration as video. Each Opus packet is
sent as one UDP datagram on `--port-audio` (default 52802) to the connected
client, tagged with a pipeline-clock timestamp so the client can line audio
up with video (wire format in `../docs/protocol.md`). Audio flows only while
a client is connected; on a machine without ffmpeg or an audio server the
agent logs a warning and streams video only. Capture is Linux only.

### Gamepad (US-014)

A controller plugged into the Mac shows up on the Linux machine as a standard
gamepad. The client sends the full controller state (protocol message 0x08,
docs/protocol.md) and the agent maps it onto a virtual device with the evdev
crate through `/dev/uinput`. uinput is root-only by default, so grant the
`input` group access with a udev rule:

```sh
echo 'KERNEL=="uinput", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput"' \
  | sudo tee /etc/udev/rules.d/99-porthole-uinput.rules
sudo udevadm control --reload-rules
sudo modprobe uinput   # or reboot, so the rule applies to the node
```

Make sure your user is in the `input` group (`sudo usermod -aG input $USER`,
then log out and back in). Without a writable `/dev/uinput` the agent logs a
warning and runs without the gamepad; the rest of the session is unaffected.
Verify with `evtest`: the device shows up as "Porthole Gamepad".

### File transfer (US-011)

Files dragged onto the Mac window arrive on their own TCP endpoint
(`--port-files`, default 52804), one connection per file, so a large
transfer never competes with the video stream. Each file is written to the
transfer folder (`--transfer-dir`, default `~/Downloads`) under a temporary
name and renamed into place only once the whole file has arrived, so a
partial transfer never leaves a file that looks complete. Names are reduced
to their base name, so a transfer cannot write outside the folder. Wire
format is in `../docs/protocol.md`.

### Clipboard (US-008)

Text copied on either machine appears on the other. On Linux the backend is
the `wl-clipboard` tools: the agent runs `wl-paste --watch` to observe the
Wayland selection and `wl-copy` to set it, so no new library is needed on a
wlroots desktop. Loop prevention lives in the agent: the text it last set
from the client is not sent straight back. Install `wl-clipboard`
(`wl-copy`, `wl-paste`) for this; without it the agent logs a warning and
runs without clipboard sync. Clipboard rides the control channel (message
type 0x07, either direction); see `../docs/protocol.md`.

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
| `--port-thumbnail`  | 52803   | TCP port for the thumbnail endpoint        |
| `--port-files`      | 52804   | TCP port for the file-transfer endpoint    |
| `--transfer-dir`    | ~/Downloads | Folder dragged files are written to     |
| `--name`            | hostname | Machine name for mDNS and the picker      |
| `--bitrate-mbps`    | 40      | Encoder target bitrate                     |
| `--codec`           | h264    | `h264` or `hevc`                           |
| `--encoder`         | nvenc   | `nvenc` (dGPU) or `vaapi` (iGPU)           |
| `--fps`             | 60      | `60`, `120`, or `144`                      |
| `--keyframe-interval-secs` | 2 | Seconds between IDR keyframes        |
| `--virtual-display` | off     | `WxH@Hz`, e.g. `2560x1440@144` (see below) |
| `--mtu`             | 1280    | Path MTU video datagrams are sized for (576 to 9000); 1500 on plain Ethernet |
| `--vaapi-device`    | auto    | DRM render node for VAAPI, e.g. `/dev/dri/renderD129` |

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
VAAPI, H.264/HEVC, US-002), `transport` (TCP control + UDP video, US-003),
`input` (zwlr_virtual_pointer_v1 + virtual-keyboard-v1, US-006a), `audio`
(Opus over UDP, US-009), `clipboard` (wl-clipboard subprocess, US-008), `transfer` (file drag and
drop endpoint, US-011), `gamepad` (virtual uinput gamepad, US-014). The wire format itself lives in the library target
(`src/lib.rs` + `src/protocol.rs`), shared with `examples/receiver.rs`.
`examples/wl_globals.rs` lists the compositor's advertised protocols, for
checking what a session offers before pointing the agent at it.
