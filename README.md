# Porthole

A native macOS app for controlling a Linux machine over the local network,
with its own streaming stack instead of VNC or RDP.

This exists because every screen sharing tool I tried feels bad on a Mac:
dated UI, typing IP addresses to connect, blurry compressed video, and
trackpad and keyboard behavior that does not act like a Mac app. Porthole is
my attempt at one that does. It is built for two kinds of session: long
coding sessions where text has to stay sharp, and occasional gaming where
latency has to stay low.

It is two programs that share one wire protocol:

- `agent/`: a small Rust service on the Linux machine. It captures the screen
  with wlr-screencopy, hardware-encodes it (NVENC on an NVIDIA GPU, or VAAPI
  on an AMD iGPU to keep the dGPU free for games), and streams it over the
  LAN. It injects the keyboard, mouse, and gamepad input the Mac sends,
  streams desktop audio, and syncs the clipboard.
- `macos/`: a SwiftUI and Metal app. It finds agents on the network with
  Bonjour, decodes with VideoToolbox, renders with Metal, captures native Mac
  input, and hosts the machine picker, the session toolbar, and the extras.

## What works

- One-click connect from a machine picker with live thumbnails; no typing an
  IP address on the LAN. Off-LAN machines (over Tailscale) are added by
  address once.
- 1440p H.264 or HEVC over the LAN with GPU-resident capture/encode and
  VideoToolbox decode. Direct private-LAN traffic is paced for 2.5 GbE;
  tunnel/public peers retain a conservative 1 Gb/s burst ceiling.
- A Maximum gaming mode that requests a 288 Hz VFR source and late-latches the
  freshest real frame onto the physical display. On the fixed-144 Hz test
  panel, Gaming + Auto now phase-locks to the native 144 Hz cadence. A clean
  67-second native-Full 2560x1440 soak with a 214-215 fps real VFR source
  averaged 141.4 actual presentations/s and had a 144 fps median. Measured
  capture-to-present latency averaged 10.49 ms, with a 10.50 ms median,
  11.50 ms p95, and 9.70-12.70 ms range; loss and deadline resynchronizations
  were both zero. Presentation time is reported by the Metal drawable; it is
  a compositor timestamp, not an optical glass-to-glass measurement. The
  latter needs a high-speed camera or photodiode rig.
- Native Mac input: pixel-precise trackpad scrolling, modifier keys, exclusive
  remote shortcut capture (including Command-Space and Command-Tab), a
  pointer-lock mode for games, and a single on-screen cursor.
- Display modes: adaptive Fit and native Full. The Linux headless output
  follows the settled Mac viewport in backing pixels instead of encoding a
  fixed source only to rescale it locally.
- The session controls can collapse to a small reopen tab. On Omarchy hosts,
  a separately acknowledged Remote bar switch hides and restores the Linux
  panel without killing or restarting Quickshell.
- Two-way clipboard sync, desktop audio (Opus), file drag and drop, and
  gamepad passthrough.

The status of each phased user story, with its acceptance criteria, is in
[tasks/prd-porthole.md](tasks/prd-porthole.md).

## Requirements

The Linux machine runs a wlroots-based Wayland compositor (developed on
Hyprland) with an NVIDIA or AMD GPU, `ffmpeg` (with NVENC or VAAPI and
libopus), and, for the extras, `wl-clipboard` (clipboard) and a writable
`/dev/uinput` (gamepad; see [SECURITY.md](SECURITY.md) and
[agent/README.md](agent/README.md)). It can run headless: the agent creates a
virtual display at the target geometry.

The Mac runs macOS 14 or newer. Building it needs Xcode 26 or newer and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Building

The agent builds on macOS for development and runs on Linux; the capture,
encode, and injection paths are Linux-only and compiled out elsewhere.

```sh
cd agent
cargo build
cargo test
```

The Mac app:

```sh
cd macos
xcodegen generate
xcodebuild -scheme Porthole -configuration Debug build
```

Open `Porthole.xcodeproj` in Xcode after generating it, or press Cmd-R.
The xcodeproj is generated from `project.yml` and is not committed.

## Running

On the Linux machine, build and start the agent (`cargo run --release`, or
install it as a systemd user service with the unit in `agent/packaging`).
See [agent/README.md](agent/README.md) for the config file, the ports, and
the one-time udev step gamepad support needs. Then launch the Mac app: the
machine appears in the picker, and one click connects.

## Security

Version 1 has no authentication: anyone who can reach the agent is in
control. Run it only on a network you control, a LAN or a private Tailscale
or WireGuard tunnel, never exposed to the internet. The trust model, the
ports, and what the agent can do to the machine are in
[SECURITY.md](SECURITY.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the setup, the gates CI runs, and
the protocol-first convention for wire changes. The wire format is specified
in [docs/protocol.md](docs/protocol.md).

## License

MIT. See [LICENSE](LICENSE).
