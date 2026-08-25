# Porthole for Mac

Native macOS client for Porthole. It receives a streamed Linux desktop over LAN
and renders it with Metal and VideoToolbox. See `../tasks/prd-porthole.md` for
the full PRD.

Status: PRD stories US-004 and US-005 work. The app connects to a running
porthole-agent over the wire protocol in `../docs/protocol.md`, decodes the
H.264 stream with VideoToolbox, and renders it letterboxed at the drawable's
native resolution. When disconnected, the surface shows a procedural test
pattern with selectable 60/120/144 fps pacing.

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

Headless decode gate (US-005 acceptance, no GUI needed):

```sh
xcodebuild -scheme porthole-decode-test -configuration Debug build
# reads /tmp/porthole-lan.h264 by default; pass a path to override
"$(xcodebuild -scheme porthole-decode-test -configuration Debug -showBuildSettings | awk '/ TARGET_BUILD_DIR /{print $3}')"/porthole-decode-test [dump.h264]
```

It decodes a recorded Annex B dump (capture one with the agent's reference
receiver: `cargo run --example receiver -- <agent-ip> --dump /tmp/porthole-lan.h264`)
and fails unless more than 100 frames decode at 2560x1440.

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

## What exists

- `Porthole/PortholeApp.swift` holds the `@main` app, a dark, title-bar-hidden window titled "Porthole".
- `Porthole/SessionView.swift` is the session screen: Metal surface, floating
  chrome with status text, 60/120/144 fps segmented control (persisted via
  `@AppStorage`, applied live), host field, and connect button.
- `Porthole/Streaming/WireProtocol.swift` implements the v1 wire format:
  length-prefixed TCP control frames, `hello` parsing, `keyframe_request`
  encoding, and the 25-byte video datagram header.
- `Porthole/Streaming/ControlChannel.swift` is the TCP client (Network.framework),
  with keyframe requests throttled to one per second except on join.
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
  reassembly, decode, loss recovery, and stats. Any loss is decode-fatal:
  it requests a keyframe and waits for the next IDR, per the protocol.
- `Porthole/Rendering/MetalRenderer.swift` wraps `MTKView`. Live frames are
  converted to Metal textures via CVMetalTextureCache and drawn aspect-fit;
  YCbCr to RGB conversion runs in the fragment shader. With no stream, it
  draws the test pattern.
- `Porthole/Rendering/Shaders.metal` has the test pattern shaders (SMPTE-style
  bars, frame-pacing ticker sized to the selected rate, time-derived marker)
  and the video shaders (letterboxed fullscreen triangle, NV12 to RGB).
- `Porthole/Info.plist` includes `NSBonjourServices` (`_porthole._tcp`) and
  `NSLocalNetworkUsageDescription` now, ahead of US-007 discovery.
- `DecodeTest/main.swift` is the headless decode gate described above.

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
  range from video_full_range_flag. The agent's ffmpeg/NVENC output currently
  declares bt470bg (BT.601), and the render matches it.
- Video decodes to NV12 and converts in the shader, not to BGRA in
  VideoToolbox. That keeps the decode output zero-copy and the color math
  explicit and testable.

## What's next (PRD phase 1)

- US-006 adds keyboard/mouse/trackpad capture in the session window.
- US-007 adds Bonjour discovery of `_porthole._tcp` agents and one-click
  connect, replacing the host field (plist keys for this are already in place).
