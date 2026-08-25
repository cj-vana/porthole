# PRD: Porthole, a beautiful native Mac client for controlling a Linux machine

## Introduction/Overview

Porthole is a native macOS screen sharing / remote desktop app for controlling a Linux machine from a Mac, built to fix everything that sucks about existing tools: ugly dated UI, clunky connection flows (typing IPs and ports), laggy/blurry video, and non-native Mac behavior (bad trackpad handling, bad Retina scaling, broken shortcuts).

It consists of two components we build ourselves:

- **Porthole Agent**, a small Rust service running on the Linux machine. Captures the screen, hardware-encodes it on the machine's NVIDIA GPU (NVENC) or on the Ryzen iGPU (VAAPI) when the dGPU should stay free for games, streams it over the LAN, and injects received input (keyboard/mouse/gamepad) back into Linux.
- **Porthole for Mac**, a native Swift/SwiftUI app. Discovers agents on the network, renders the stream with Metal + VideoToolbox hardware decoding, captures local input, and provides the "cool options": clipboard sync, audio, file drag & drop, display modes, and a low-latency gaming mode.

Primary use case: hours-long coding/dev sessions (so text must be razor sharp) plus occasional gaming (so there must be a high-framerate, low-latency mode).

"Porthole" is a working name and can be renamed anytime; the codename only affects the folder/bundle names.

## Goals

- One-click connect to a Linux machine in under 3 seconds, with zero typing of IPs/ports.
- Sustain 1440p (2560×1440) streaming at 60fps on a LAN with hardware encode (Linux, NVENC or VAAPI) and hardware decode (Mac/VideoToolbox), plus selectable 120fps and 144fps modes for high-refresh displays.
- Glass-to-glass latency under 40ms in the default "quality" mode; target under 25ms in "gaming" mode at up to 144fps.
- Text in a code editor is crisp and comfortable for multi-hour sessions at 1:1 scaling on a Retina display.
- Feel 100% native on macOS: trackpad scroll/gestures, system shortcuts, fullscreen spaces, Retina rendering.
- Ship the extras that make it a daily driver: clipboard sync, audio, file drag & drop, gamepad passthrough.

## User Stories

### Phase 1: see it and control it (MVP)

### US-001: Linux agent scaffold with screen capture
Description: As a developer, I need a Rust binary on Linux that captures the primary display so I have raw frames to encode.

Acceptance Criteria:
- [ ] Rust binary `porthole-agent` runs on the Linux machine and captures the primary display at 30+ fps
- [ ] Capture path selected automatically: wlr-screencopy or PipeWire on Wayland, with X11 fallback
- [ ] Logs negotiated resolution, framerate, and capture backend on startup
- [ ] `cargo clippy` passes with no warnings

### US-002: Hardware encoding (NVENC or Ryzen iGPU VAAPI)
Description: As a developer, I need captured frames encoded to H.264 on a GPU so the CPU stays free for actual work, with the encoder backend selectable so the NVIDIA dGPU can stay fully free for games.

Acceptance Criteria:
- [ ] Frames encoded to H.264 via NVENC (GStreamer `nvh264enc` or FFmpeg `h264_nvenc`) as the default backend
- [ ] Alternative VAAPI backend encoding on the Ryzen iGPU (GStreamer `vah264enc` or FFmpeg `h264_vaapi`), selectable via config/CLI
- [ ] 1440p60 (2560×1440) encode on the default backend with visible encoder load in `nvidia-smi` and low CPU usage
- [ ] With the VAAPI backend active, encoder load shows on the iGPU's `/dev/dri` node and `nvidia-smi` shows no encoder session
- [ ] Keyframe interval and bitrate are configurable via CLI flags
- [ ] `cargo clippy` passes with no warnings

### US-003: LAN stream transport
Description: As a developer, I need an encoded stream sent over the LAN so a client can receive it.

Acceptance Criteria:
- [ ] Encoded frames sent as sequence-numbered UDP datagrams; control channel over TCP (handshake, stream parameters, keyframe requests)
- [ ] Receiver can reassemble frames and tolerate loss by requesting a new keyframe
- [ ] Default ports configurable; handshake negotiates resolution/codec/fps
- [ ] `cargo clippy` passes with no warnings

### US-004: Mac app shell with Metal rendering surface
Description: As a user, I want a native Mac window that will display the remote screen.

Acceptance Criteria:
- [ ] SwiftUI app launches with a window containing a Metal-backed rendering view
- [ ] Renders a locally generated test pattern at 60fps (proves the render path before networking exists)
- [ ] Builds with no warnings; SwiftLint passes

### US-005: Hardware decode and display of the live stream
Description: As a user, I want to see my Linux desktop live in the Mac window.

Acceptance Criteria:
- [ ] H.264 stream decoded via VideoToolbox and displayed in the Metal view at a stable 60fps
- [ ] Correct colors and aspect ratio; letterboxed when window aspect differs
- [ ] Recovers from packet loss (keyframe request) without user action
- [ ] Verify in the running app: remote desktop visible and responsive to on-screen changes

### US-006: Keyboard and mouse control
Description: As a user, I want to control the Linux machine with my Mac's keyboard, trackpad, and mouse.

Acceptance Criteria:
- [ ] Mouse move/click/scroll and keyboard events captured in the Mac window and injected on Linux via `uinput`
- [ ] Trackpad scrolling feels native (pixel-precise, momentum)
- [ ] Modifier keys and common shortcuts work; a configurable "send system shortcuts" toggle decides whether e.g. Cmd+Space stays local or goes remote
- [ ] Pointer lock / relative-mouse mode available for games and 3D apps
- [ ] Verify in the running app: can open a terminal on Linux and type entirely from the Mac

### US-007: Zero-config discovery and one-click connect
Description: As a user, I want my Linux machine to just appear in the app so I never type an IP address.

Acceptance Criteria:
- [ ] Agent announces itself via mDNS/Bonjour; Mac app lists discovered machines automatically
- [ ] Machine picker shows name, status, and a live-updating thumbnail of its screen
- [ ] Clicking a machine connects and shows the desktop in under 3 seconds on LAN
- [ ] Machines can be pinned/renamed and are remembered between launches
- [ ] Verify in the running app: full flow from cold launch to controlling the desktop, one click

### Phase 2: daily-driver polish

### US-008: Two-way clipboard sync
Description: As a user, I want copy/paste to work across both machines so dev work feels like it's happening on one machine.

Acceptance Criteria:
- [ ] Text copied on either machine is pasteable on the other within ~1s
- [ ] No sync loops (setting the remote clipboard doesn't retrigger a send)
- [ ] Toggle in settings to disable
- [ ] Verify in the running app: copy a URL on Mac, paste into Linux browser, and vice versa

### US-009: Audio streaming
Description: As a user, I want to hear the Linux machine's audio on my Mac.

Acceptance Criteria:
- [ ] Linux desktop audio captured (PipeWire/PulseAudio) and streamed as Opus over UDP
- [ ] Plays on the Mac in sync with video (no perceptible drift over 10 minutes)
- [ ] Volume/mute control in the Mac app
- [ ] Verify in the running app: play a video on Linux, audio is heard on the Mac

### US-010: Display and scaling modes
Description: As a user, I want control over how the remote screen maps to my Retina display so text is always crisp.

Acceptance Criteria:
- [ ] Modes: fit-to-window, 1:1 pixels, and native macOS fullscreen (own Space)
- [ ] HiDPI/Retina rendering path so 1:1 text is sharp, not upscaled-blurry
- [ ] Mode switchable from the in-session toolbar and persisted per machine
- [ ] Verify in the running app: 6pt code font comfortably readable in 1:1 mode

### US-011: File drag & drop
Description: As a user, I want to drag a file onto the stream window to send it to the Linux machine.

Acceptance Criteria:
- [ ] Dragging a file onto the window transfers it to a configurable folder on Linux (default: `~/Downloads`)
- [ ] Progress indicator in the Mac UI; large files (>1GB) transfer without UI stalls
- [ ] Transfer happens on a separate channel so it never stalls the video stream
- [ ] Verify in the running app: drag a file, confirm it lands on Linux intact (checksum)

### US-012: Machine management UI
Description: As a user, I want a beautiful launcher window for my machines so the app feels like a product, not a utility.

Acceptance Criteria:
- [ ] Machine picker is a card grid with live thumbnails, names, online/offline state
- [ ] Add machine manually by address as a fallback to discovery; edit/remove/rename saved machines
- [ ] Auto-reconnect to the last machine on launch (optional setting)
- [ ] Verify in the running app: quit and relaunch, saved machines persist with correct state

### Phase 3: gaming mode

### US-013: Low-latency gaming mode
Description: As a user, I want a turbo mode that trades a bit of image polish for minimum latency so games feel playable.

Acceptance Criteria:
- [ ] One-toggle "Gaming mode" in the session toolbar: minimal buffering, selectable 120fps or 144fps stream, encoder low-latency preset
- [ ] Optional HEVC encode/decode path selectable in settings
- [ ] Stats overlay (fps, encode ms, network ms, decode ms) toggleable for verification
- [ ] Glass-to-glass latency ≤ 25ms on LAN per overlay measurement
- [ ] Verify in the running app: play a fast-paced game for 5 minutes without motion sickness or rage

### US-014: Gamepad passthrough
Description: As a user, I want a controller plugged into my Mac to work in games on the Linux machine.

Acceptance Criteria:
- [ ] macOS GameController framework input forwarded to the agent, which exposes a virtual gamepad via `uinput`
- [ ] Recognized by Linux as a standard gamepad (visible in `evtest` / Steam controller settings)
- [ ] Works in Gaming mode without adding measurable input latency
- [ ] Verify in the running app: play a game on Linux using only the Mac-attached controller

## Functional Requirements

Agent (Linux):

- FR-1: Capture the primary display at the negotiated resolution and framerate (PipeWire on Wayland, X11 fallback). Supported stream framerates: 60, 120, and 144 fps.
- FR-2: Hardware-encode video; default H.264, optional HEVC. Encoder backend selectable via config/CLI: NVIDIA NVENC (default) or AMD VAAPI on the Ryzen iGPU, which keeps the dGPU fully free for gaming.
- FR-3: Stream video as sequence-numbered UDP datagrams; maintain a TCP control channel for handshake, settings, and keyframe requests.
- FR-4: On decode-fatal packet loss reported by the client, immediately emit a keyframe.
- FR-5: Inject keyboard/mouse input via `uinput`, including a relative-mouse mode.
- FR-6: Expose a virtual gamepad device via `uinput` and map forwarded controller state onto it.
- FR-7: Capture desktop audio and stream it as Opus over UDP.
- FR-8: Announce itself via mDNS (`_porthole._tcp`) with machine name and capabilities.
- FR-9: Accept clipboard set/get and file transfers over the control channel.
- FR-10: Send a periodic low-resolution thumbnail for the machine picker (every ~10s while idle).
- FR-11: Run as a systemd user service; single config file for ports, bitrate, display, and transfer folder.

Mac app:

- FR-12: Discover agents via Bonjour and show them in a card-grid machine picker with live thumbnails.
- FR-13: Connect on click; complete handshake and show video in under 3 seconds on LAN.
- FR-14: Decode H.264/HEVC with VideoToolbox and render via Metal with correct color and aspect.
- FR-15: Capture keyboard/mouse/trackpad input with native feel; configurable handling of macOS system shortcuts.
- FR-16: Provide display modes (fit, 1:1, fullscreen Space), persisted per machine.
- FR-17: Sync clipboard both ways with loop prevention and a settings toggle.
- FR-18: Play the audio stream with volume/mute controls.
- FR-19: Accept file drags onto the session window and transfer with progress, off the video path.
- FR-20: Provide a Gaming mode toggle with a 60/120/144 fps selector and a stats overlay (fps, encode/network/decode latency).
- FR-21: Forward GameController input when Gaming mode or gamepad mapping is active.
- FR-22: Persist machines, per-machine settings, and window state across launches.

## Non-Goals (Out of Scope)

- Internet access / NAT traversal / relays. LAN-only for v1. The transport must not hardcode LAN assumptions that would block running over Tailscale later (Tailscale gives us "internet later" for free, since it's just another LAN-like interface).
- Multi-monitor capture. v1 captures the primary display only.
- Multi-user, session sharing, or viewing-only "watch" links.
- Recording, screenshots tooling, or annotation.
- iOS/iPadOS/Windows/web clients; Windows agent.
- AV1 codec (revisit later; requires RTX 40-series for NVENC AV1).
- 4:4:4 chroma "perfect text" path. v1 achieves crispness via high bitrate + 1:1 Retina scaling; 4:4:4 is an open question below, not a commitment.
- Wake-on-LAN, agent auto-update, and any account/cloud sign-in.

## Design Considerations

- The Mac app is the product: dark, glassy, modern macOS design language; no gray enterprise toolbars.
- Machine picker is the emotional centerpiece, a card grid with live-updating thumbnails of each machine's screen.
- In-session UI is a floating toolbar that auto-hides and appears on pointer hover at the screen edge; nothing obscures the remote desktop by default.
- Native everything: trackpad momentum scrolling, pinch-to-zoom on the stream (view zoom, not re-encode), fullscreen as its own Space, standard macOS settings window.
- Stats overlay styled like a heads-up display, not a debug console.

## Technical Considerations

- Agent language: Rust. Single static-ish binary, strong GStreamer/FFmpeg bindings, safe `uinput` handling. GStreamer recommended for the capture+encode pipeline (best PipeWire and NVENC element integration).
- Capture: the target machine is Hyprland/Wayland, so the primary path is native Wayland capture via wlr-screencopy / ext-image-copy-capture (the approach wl-screenrec uses), which avoids portal permission dialogs and provides damage tracking. PipeWire via xdg-desktop-portal-hyprland is the alternative. X11 (XShm/XDamage) fallback stays for non-Wayland setups.
- Encode: H.264 default, HEVC optional; low-latency presets for Gaming mode; configurable bitrate (default ~40 Mbps for 1440p60 LAN quality mode). Two encoder backends: NVENC (default) and VAAPI on the Ryzen iGPU (GStreamer `vah264enc`/`vah265enc` or FFmpeg `*_vaapi` on the iGPU's `/dev/dri/renderD*` node). When capture runs on the dGPU and encode on the iGPU, expect one cross-GPU buffer copy; use dma-buf import where the stack allows it.
- High refresh: 120/144fps modes raise bitrate budgets (expect roughly 60-80 Mbps for H.264 at 1440p144) and require the Linux display to actually run at that refresh rate. HEVC earns its keep here.
- Decode/render (Mac): VideoToolbox → Metal. Render at the drawable's native resolution for Retina sharpness.
- Protocol: TCP control channel (binary or length-prefixed messages) + UDP for video/audio datagrams carrying sequence numbers and timestamps. Keep the transport interface behind a trait/abstraction so a WebRTC or QUIC transport can replace it later for internet play.
- Gamepad: macOS GameController framework → control channel → virtual `uinput` gamepad.
- Agent packaging: start with `cargo build` + a systemd user unit file; pretty packaging (deb/AppImage) is later.
- Defaults: video UDP 52800, control TCP 52801, audio UDP 52802 (all configurable).

## Success Metrics

- Cold launch → controlling the Linux desktop in < 3 seconds, one click, zero typing.
- 1440p60 sustained for 30 minutes with no dropped-frame storms and < 5% CPU on the Mac client.
- 1440p at 120fps and at 144fps sustained in Gaming mode on a 144Hz display (10-minute spot check each).
- Glass-to-glass latency < 40ms (quality mode) and ≤ 25ms (gaming mode) measured by the stats overlay.
- A 6pt code font is comfortably readable at 1:1 scaling on a Retina display (subjective pass/fail by the user).
- Copy/paste works both directions in < 1s without ever creating a sync loop.
- The user's verdict: "I'd rather use this than any screen share app I've tried."

## Open Questions

- Answered: Omarchy (Arch-based), Hyprland on Wayland (verified over SSH). Capture goes through wlr-screencopy or PipeWire; the X11 fallback stays for other setups.
- Answered: the Ryzen iGPU is enabled. /dev/dri shows both render nodes (NVIDIA pci-0000:01:00.0, AMD pci-0000:0b:00.0), so the VAAPI backend has a device. GStreamer's va plugin is not installed on the box (nvcodec is); FFmpeg is.
- Resolution confirmed: 2560×1440. Still open: the display's maximum refresh rate (xrandr reports nothing under Wayland; check `hyprctl monitors` on the machine).
- Is 4:4:4 chroma worth pursuing for perfect text after v1 (VideoToolbox supports it on HEVC; NVENC support varies by GPU)?
- Headless operation: should the agent be able to create a virtual display when no monitor is attached to the Linux box?
- Final product name is undecided; "Porthole" is a codename.
