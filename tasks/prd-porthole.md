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
- [x] Rust binary `porthole-agent` runs on the Linux machine and captures the primary display at 30+ fps (verified: steady 60 fps on the headless FALLBACK output, 1920x1080, Argb8888)
- [x] Capture path selected automatically: wlr-screencopy on Wayland (X11 fallback deferred; no X11 session exists on the target machine)
- [x] Logs negotiated resolution, framerate, and capture backend on startup
- [x] `cargo clippy` passes with no warnings

### US-015: Virtual display for headless operation
Description: As a user, I want the agent to create a virtual display at the target stream geometry when the machine has no monitor, so headless streaming still gets 2560x1440 at 144Hz.

Acceptance Criteria:
- [x] Config option `virtual_display` (TOML and CLI), value like "2560x1440@144", default off. Malformed values rejected.
- [x] When set and no physical output exists, the agent creates a Hyprland headless output at that geometry and capture prefers it over the FALLBACK output
- [x] Idempotent: a matching headless output already present is reused, not duplicated
- [x] With a physical monitor attached and the option set, the agent leaves physical outputs alone and logs why
- [x] Verified on the machine: startup log shows capture of a 2560x1440@144 output (HEADLESS-2), per-second lines show a steady 144 fps
- [x] `cargo clippy` passes with no warnings

### US-002: Hardware encoding (NVENC or Ryzen iGPU VAAPI)
Description: As a developer, I need captured frames encoded to H.264 on a GPU so the CPU stays free for actual work, with the encoder backend selectable so the NVIDIA dGPU can stay fully free for games.

Acceptance Criteria:
- [x] Frames encoded to H.264 via NVENC (FFmpeg `h264_nvenc` subprocess) as the default backend
- [x] Alternative VAAPI backend encoding on the Ryzen iGPU (FFmpeg `h264_vaapi` on the PCI-resolved `/dev/dri` node), selectable via config/CLI
- [x] 1440p60 (2560×1440) encode on the default backend with visible encoder load in `nvidia-smi` (13-16% Enc) and low CPU usage (agent ~9%, ffmpeg ~14%)
- [x] With the VAAPI backend active, NVENC stays at 0% and encoding holds 60 fps on the iGPU
- [x] Keyframe interval and bitrate are configurable via CLI flags (`--keyframe-interval-secs`, `--bitrate-mbps`)
- [x] `cargo clippy` passes with no warnings

### US-003: LAN stream transport
Description: As a developer, I need an encoded stream sent over the LAN so a client can receive it.

Acceptance Criteria:
- [x] Encoded frames sent as sequence-numbered UDP datagrams (1400-byte fragments, documented in docs/protocol.md); control channel over TCP (hello handshake, keyframe requests)
- [x] Receiver can reassemble frames and tolerate loss by requesting a new keyframe (verified: 60 fps at 0.00% loss; encoder restart on keyframe_request takes ~100ms)
- [x] Default ports configurable; handshake negotiates codec/resolution/fps/bitrate
- [x] `cargo clippy` passes with no warnings

### US-004: Mac app shell with Metal rendering surface
Description: As a user, I want a native Mac window that will display the remote screen.

Acceptance Criteria:
- [ ] SwiftUI app launches with a window containing a Metal-backed rendering view
- [ ] Renders a locally generated test pattern at 60fps (proves the render path before networking exists)
- [ ] Builds with no warnings; SwiftLint passes

### US-005: Hardware decode and display of the live stream
Description: As a user, I want to see my Linux desktop live in the Mac window.

Acceptance Criteria:
- [x] H.264 stream decoded via VideoToolbox and displayed in the Metal view at a stable 60fps (live: 60 fps, decode ~1.5ms/frame, 0% loss)
- [x] Correct colors and aspect ratio; letterboxed when window aspect differs (aspect-fit per draw; YCbCr matrix taken from the SPS VUI)
- [x] Recovers from packet loss (keyframe request) without user action
- [x] Verified in the running app: live 2560x1440 Linux desktop visible in the window (screenshot proof), plus a headless decode gate (10,886/10,886 AUs at 2560x1440)

### US-006: Keyboard and mouse control
Description: As a user, I want to control the Linux machine with my Mac's keyboard, trackpad, and mouse.

Acceptance Criteria:
- [x] Mouse move/click/scroll and keyboard events captured in the Mac window and injected on Linux via Hyprland's virtual-pointer/virtual-keyboard protocols (no root; `/dev/uinput` is root-only on the target)
- [x] Trackpad scrolling feels native (pixel-precise deltas verified on the wire; momentum passes through as continued deltas)
- [x] Modifier keys and common shortcuts work (key_modifiers 0x15 verified: "Hello!" types with shift); a configurable "send system shortcuts" toggle decides whether e.g. Cmd+Space stays local or goes remote (Cmd+Tab interception is best-effort, documented)
- [x] Pointer lock / relative-mouse mode available for games and 3D apps (toolbar toggle, Esc to exit)
- [x] Verified in the running app: CGEvent keystrokes through the real app event path arrive in a Linux terminal; cursor lands at exact coordinates; clicks move window focus

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

- FR-1: Capture the primary display at the negotiated resolution and framerate (wlr-screencopy on Wayland; X11 fallback deferred, no X11 session exists on the target). Supported stream framerates: 60, 120, and 144 fps. When no physical display is attached and `virtual_display` is configured, create a Hyprland headless output at that geometry and capture it.
- FR-2: Hardware-encode video; default H.264, optional HEVC. Encoder backend selectable via config/CLI: NVIDIA NVENC (default) or AMD VAAPI on the Ryzen iGPU, which keeps the dGPU fully free for gaming.
- FR-3: Stream video as sequence-numbered UDP datagrams; maintain a TCP control channel for handshake, settings, and keyframe requests.
- FR-4: On decode-fatal packet loss reported by the client, immediately emit a keyframe.
- FR-5: Inject keyboard/mouse input via the compositor's virtual-pointer/virtual-keyboard protocols (no root needed), including a relative-mouse mode. uinput remains the plan only for the virtual gamepad (FR-6), which needs a udev rule.
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
- Decided: the machine lives headless, so the agent provides the display. See US-015: a virtual Hyprland output at 2560×1440@144 when no physical display is attached. This also fixes the stream geometry at the 1440p/144Hz targets.
- Is 4:4:4 chroma worth pursuing for perfect text after v1 (VideoToolbox supports it on HEVC; NVENC support varies by GPU)?
- Final product name is undecided; "Porthole" is a codename.
