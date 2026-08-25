# Porthole for Mac

Native macOS client for Porthole. It receives a streamed Linux desktop over LAN
and renders it with Metal and VideoToolbox, and it sends keyboard, mouse, and
trackpad input back so the remote machine is fully controllable from the
window. See `../tasks/prd-porthole.md` for the full PRD.

Status: PRD stories US-004 through US-006 work. The app connects to a running
porthole-agent over the wire protocol in `../docs/protocol.md`, decodes the
H.264 stream with VideoToolbox, renders it letterboxed at the drawable's
native resolution, and forwards input over the same control connection. When
disconnected, the surface shows a procedural test pattern with selectable
60/120/144 fps pacing.

## Requirements

- Xcode (developed against Xcode 26.x, Swift 6.3 toolchain, Swift 5 language mode)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Deployment target: macOS 14.0
- VideoToolbox works headless, so the decode gate below runs fine in CI.

## Build & run

```sh
xcodegen generate        # regenerates Porthole.xcodeproj from project.yml
xcodebuild -scheme Porthole -configuration Debug build
```

Or open `Porthole.xcodeproj` and press Cmd-R. `Porthole.xcodeproj` is a
generated artifact, so edit `project.yml`, never the project file, and re-run
`xcodegen generate` after adding or removing source files.

Headless gates (no GUI needed):

```sh
xcodebuild -scheme porthole-decode-test -configuration Debug build
# reads /tmp/porthole-lan.h264 by default; pass a path to override
"$(xcodebuild -scheme porthole-decode-test -configuration Debug -showBuildSettings | awk '/ TARGET_BUILD_DIR /{print $3}')"/porthole-decode-test [dump.h264]

xcodebuild -scheme porthole-input-test -configuration Debug build
# byte-exact translation tests (factory NSEvents to wire bytes)
"$(xcodebuild -scheme porthole-input-test -configuration Debug -showBuildSettings | awk '/ TARGET_BUILD_DIR /{print $3}')"/porthole-input-test local
# live mode sends real input to a running agent:
#   porthole-input-test live <host> move-abs <x> <y> | click <x> <y> | type <text>
```

The decode gate decodes a recorded Annex B dump (capture one with the agent's
reference receiver: `cargo run --example receiver -- <agent-ip> --dump
/tmp/porthole-lan.h264`) and fails unless more than 100 frames decode at
2560x1440. The input gate checks the exact control-channel bytes produced for
keys, modifiers, scroll, buttons, and letterbox mapping; its live mode is how
the end-to-end verification on the box was driven (`hyprctl cursorpos`, typed
files, `hyprctl activewindow`).

## Connecting

The session chrome has a host field and a Connect button. The last host is
persisted (`lastHost` default, currently the dev box's Tailscale address
100.105.41.71) and the app auto-connects to it on launch until US-012 owns
machine management. The agent must stream h264 (the default); hevc is rejected
with an error until a later story adds it.

Once per second while connected, stats go to os_log (subsystem
`com.porthole.mac`, category `session`) and are appended to
`/tmp/porthole-mac-stats.log`: decoded fps, average decode milliseconds,
reassembly loss percent, and decode queue depth. The US-013 debug overlay will
surface these in the UI.

## Input (US-006)

Input flows only while the Metal surface holds focus: click the stream to
capture, click anywhere else to release. A green "input captured" chip in the
chrome shows the state. The focusing click also acts on the remote desktop,
the way other remote desktop clients behave.

Mapping and behavior:

- Mouse motion maps through the inverse of the renderer's aspect-fit letterbox
  into remote output pixels (pointer_motion_abs); points in the bars send
  nothing.
- Buttons send evdev codes: left 0x110, right 0x111, middle 0x112, plus back
  0x113 and forward 0x114 for other-mouse buttons 3 and 4.
- Trackpad scroll uses scrollingDelta with hasPreciseScrollingDeltas for
  pixel-precise values, converted to the protocol's 1/256 px units; momentum
  arrives as continued deltas with source continuous, finger contact as finger,
  mouse wheels as wheel clicks of 10 px. Positive macOS deltas (up/left) flip
  sign to wl_pointer's positive-down/right convention.
- Keyboard translates macOS virtual key codes to evdev KEY_* codes through a
  documented table in `KeyMap.swift` (US layout, digits, punctuation, F1-F12,
  navigation, arrows, modifiers, keypad). Cmd maps to Super, Option to Alt.
  The table is positional (kVK codes are US-position), so non-US Mac layouts
  get US behavior, matching the agent's evdev/pc105/us keymap. Auto-repeat is
  faked as down/up pairs because the virtual keyboard has no repeat of its own.
- Modifier state is tracked from flagsChanged and sent as key_modifiers (0x15)
  before dependent keys, so uppercase and shifted symbols work; the wire mask
  uses the classic X11/xkb bit order (Shift 1, Lock 2, Control 4, Alt 8, Super
  64), which matches the agent's keymap indices. Focus loss releases all held
  modifiers remotely so Shift never strands on the Linux side.

Chrome toggles (both persisted):

- "Shortcuts" sends Cmd chords to the remote machine instead of keeping them
  local. Limits: Cmd+Tab is intercepted by the Window Server before any app
  sees it, Spotlight's Cmd+Space is eaten system-wide when enabled, and menu
  equivalents like Cmd+Q act locally first. On means best effort, not full
  interception.
- "Pointer lock" hides the local cursor and switches motion to
  pointer_motion_rel deltas (NSEvent deltaX/deltaY, 1/256 px units) for games
  and 3D apps. It engages only while the surface has focus and Esc releases it.

## What exists

- `Porthole/PortholeApp.swift` holds the `@main` app, a dark, title-bar-hidden window titled "Porthole".
- `Porthole/SessionView.swift` is the session screen: Metal surface, floating
  chrome with status text, captured/lock indicators, 60/120/144 fps segmented
  control (persisted via `@AppStorage`, applied live), the two input toggles,
  host field, and connect button.
- `Porthole/Streaming/WireProtocol.swift` implements the v1 wire format:
  length-prefixed TCP control frames, `hello` parsing, message type table
  including the 0x10-0x15 input types, and the 25-byte video datagram header.
- `Porthole/Streaming/ControlChannel.swift` is the TCP client
  (Network.framework). keyframe_request throttled to one per second except on
  join; input frames share the same connection via `sendInput`.
- `Porthole/Streaming/VideoReceiver.swift` is the UDP listener for video
  datagrams, bound to the port from `hello`.
- `Porthole/Streaming/Reassembler.swift` reassembles fragmented access units
  per the protocol's receiver rules: incomplete frames are dropped after
  500 ms, sequence gaps and stale frames count as loss.
- `Porthole/Streaming/AnnexB.swift` splits Annex B streams into NAL units and
  access units and converts access units to the length-prefixed form
  VideoToolbox expects.
- `Porthole/Streaming/H264SPS.swift` parses the SPS for crop-adjusted
  dimensions and VUI color description (Exp-Golomb bit reader included).
- `Porthole/Streaming/H264Decoder.swift` wraps VTDecompressionSession. It
  builds the CMVideoFormatDescription from in-band SPS/PPS and rebuilds the
  session whenever the parameter set bytes change (encoder restarts, resolution
  changes). Output is NV12 CVPixelBuffers.
- `Porthole/Streaming/StreamSession.swift` coordinates connect/disconnect,
  reassembly, decode, loss recovery, stats, and owns the InputController.
  Any loss is decode-fatal: it requests a keyframe and waits for the next IDR.
- `Porthole/Input/InputMessages.swift` encodes the 0x10-0x15 wire messages and
  holds the letterbox coordinate mapping.
- `Porthole/Input/KeyMap.swift` is the documented keyCode-to-evdev table plus
  a US character table for scripted typing.
- `Porthole/Input/InputController.swift` translates NSEvents to wire messages:
  modifier tracking with key_modifiers ordering, pointer lock, scroll source
  and sign conventions, focus capture state, and release-on-focus-loss.
- `Porthole/Input/SessionSurfaceView.swift` is the MTKView subclass that takes
  first responder on click and forwards NSEvents to the controller.
- `Porthole/Rendering/MetalRenderer.swift` wraps `MTKView`. Live frames are
  converted to Metal textures via CVMetalTextureCache and drawn aspect-fit;
  YCbCr to RGB conversion runs in the fragment shader. With no stream, it
  draws the test pattern.
- `Porthole/Rendering/Shaders.metal` has the test pattern shaders (SMPTE-style
  bars, frame-pacing ticker sized to the selected rate, time-derived marker)
  and the video shaders (letterboxed fullscreen triangle, NV12 to RGB).
- `Porthole/Info.plist` includes `NSBonjourServices` (`_porthole._tcp`) and
  `NSLocalNetworkUsageDescription` now, ahead of US-007 discovery.
- `DecodeTest/main.swift` and `InputTest/main.swift` are the headless gates
  described above.

Rates above 60 fps only become visible on a ProMotion or high-refresh display.
On a 60 Hz panel the display link clamps to 60 fps, and the ticker shows it:
cells then advance at the selected (higher) target rate while only 60 draws
happen per second, so the clamp appears as skipped cells.

## Deliberate decisions

- App sandbox is off. The client needs raw UDP/TCP sockets (video 52800/UDP,
  control 52801/TCP, audio 52802/UDP per the PRD) and GameController framework
  access. Revisit the minimal entitlement set (network client, local network,
  gamepad) before anything ships.
- Ad hoc signing (`CODE_SIGN_IDENTITY = "-"`, Sign to Run Locally) so LAN dev
  builds need no developer certificate.
- `Porthole.xcodeproj` is generated by XcodeGen from `project.yml`.
- Color comes from the stream: the SPS VUI matrix is honored when present,
  otherwise BT.709 is assumed for HD and BT.601 for SD, with limited or full
  range from video_full_range_flag. The agent's output was re-tagged BT.709
  during US-006a, and the render honors it.
- Video decodes to NV12 and converts in the shader, not to BGRA in
  VideoToolbox. That keeps the decode output zero-copy and the color math
  explicit and testable.

## What's next (PRD phase 1)

- US-007 adds Bonjour discovery of `_porthole._tcp` agents and one-click
  connect, replacing the host field (plist keys for this are already in place).
