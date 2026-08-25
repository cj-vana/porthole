# Porthole

A native macOS app for controlling a Linux machine over the local network, with its own streaming stack instead of VNC or RDP.

This exists because every screen sharing tool I've tried feels bad on a Mac: dated UI, typing IP addresses to connect, blurry compressed video, and trackpad and keyboard behavior that doesn't act like a Mac app. Porthole is my attempt at one that does.

It's built for two kinds of sessions: long coding sessions where text has to stay sharp, and occasional gaming where latency has to stay low.

## Status

Early scaffold. What exists today:

- `agent/`: Rust service for the Linux machine. Captures the screen via wlr-screencopy (60fps verified on Hyprland), with CLI, config file, and module skeletons for encoding, transport, input injection, and audio. Encoding and streaming are next.
- `macos/`: SwiftUI + Metal app shell. Renders an animated test pattern at a selectable 60/120/144 fps to prove the render path. No networking yet.

The full plan, with phased user stories and acceptance criteria, is in [tasks/prd-porthole.md](tasks/prd-porthole.md).

## How it will work

- The agent captures the Linux screen (primary display, 2560×1440), encodes H.264 or HEVC with NVENC on the NVIDIA GPU or with VAAPI on the Ryzen iGPU (for keeping the dGPU free for games), and sends it over UDP. Input travels back over a TCP control channel and gets injected with uinput.
- The Mac app discovers agents with Bonjour, decodes with VideoToolbox, and renders with Metal. Clipboard sync, audio, file drag and drop, and gamepad passthrough are planned phases, not current features.
- LAN only for now. Running over Tailscale later should work without changes.

## Building

The agent develops on macOS and runs on Linux:

```sh
cd agent
cargo build
cargo test
```

The Mac app requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
cd macos
xcodegen generate
xcodebuild -scheme Porthole -configuration Debug build
```

You can also open `Porthole.xcodeproj` in Xcode after generating it. The xcodeproj is generated from `project.yml` and intentionally not committed.

## License

MIT
