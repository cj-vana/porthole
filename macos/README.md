# Porthole for Mac

Native macOS client for Porthole. It receives a streamed Linux desktop over LAN
and renders it with Metal and VideoToolbox, and it sends keyboard, mouse, and
trackpad input back so the remote machine is fully controllable from the
window. See `../tasks/prd-porthole.md` for the full PRD.

Status: PRD stories US-004 through US-007 work. The picker finds agents over
mDNS, the app connects to a running porthole-agent over the wire protocol in
`../docs/protocol.md`, decodes the H.264 stream with VideoToolbox, renders it
letterboxed at the drawable's native resolution, forwards input over the same
control connection, and measures capture-to-glass latency against the agent's
clock. When disconnected, the surface shows a procedural test pattern with
Auto/60/120/144 fps pacing.

## Requirements

- Xcode (developed against Xcode 26.x, Swift 6.3 toolchain, Swift 5 language mode)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- [SwiftLint](https://github.com/realm/SwiftLint): `brew install swiftlint`
  (`swiftlint lint --strict` from this directory is a gate)
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

The picker window lists machines found over mDNS (`_porthole._tcp`) plus
pinned and manually added ones, each with a thumbnail polled every 10 s from
the agent's thumb port. Clicking a card opens the session window and dials.

Dialing walks the machine's addresses in order, one second per attempt: the
host that most recently answered a thumbnail poll first (remembered per
machine as `preferredHost` in machines.json, so a filtered LAN address does
not cost a timeout on every connect), then the mDNS-resolved LAN addresses,
then the machine name as a bare host name, which is what reaches a Tailscale
machine through MagicDNS. The first address to bring the control channel up
wins and the walk stops. The session chrome keeps a host field as the manual
escape hatch: edit it and Connect dials exactly what was typed. The agent
must stream h264 (the default); hevc is rejected with an error until a later
story adds it.

The control connection sets TCP_NODELAY. Input and probe messages are a few
bytes each, and with Nagle on the kernel held each one for the peer's delayed
ACK, so mouse motion reached the agent in 40 ms clumps.

Video arrives on a BSD UDP socket with an 8 MB receive buffer (SO_RCVBUF;
the size actually granted is logged at bind). Network.framework's listener
has no way to raise its buffer, and the macOS default of 786 KB, charged at
about 2 KB of mbuf per datagram, overflowed on a 400-datagram keyframe burst.
That loss then forced the next keyframe, which is the worst place to lose
packets.

### Stats line

Once per second while connected, one line goes to os_log (subsystem
`com.porthole.mac`, category `session`) and is appended to
`/tmp/porthole-mac-stats.log`:

```
stats fps=143 decode_ms=1.84 rtt_ms=0.81 enc_ms=3.20 cap_arrive_ms=9.4 cap_decoded_ms=11.6 cap_present_ms=19.8 loss=0.00% queue=0 agent_fps=144/143 tx_kbps=38210 audio_buf_ms=41 audio_pkts=50 audio_lost=0 audio_drop_ms=0 audio_underrun=0
```

- `fps`: frames decoded this second. `decode_ms`: mean VideoToolbox decode
  time per frame.
- `rtt_ms`: control-channel round trip of the most recent ping/pong.
- `enc_ms`, `agent_fps`, `tx_kbps`: the agent's side, from its most recent
  `agent_stats` message: mean encode latency, capture/encoded fps, and
  transmit rate.
- `cap_arrive_ms`: agent capture to the access unit completing reassembly
  here. `cap_decoded_ms`: capture to decode finished. `cap_present_ms`:
  capture to the pixels presented on this display, taken from the Metal
  drawable's presented time. All three are means over the second on the
  client clock: each frame's agent timestamp is mapped through the offset
  estimated from pongs (`agent - (send + rtt/2)`, from the lowest-RTT pong of
  the last 60; a sliding window rather than an all-time minimum because the
  two clocks drift apart by tens of ppm, and an all-time minimum would show
  that drift as latency growing over hours).
- `loss`: lost frames as a percentage of frames seen (reassembly gaps, stale
  partials, backlog drops). `queue`: datagrams waiting for the decode queue.
- `audio_*`: the audio channel's second (US-009): jitter buffer depth, Opus
  packets received, packets lost to sequence gaps, milliseconds dropped to
  keep the buffer under its cap, and playback underruns. All zeros until
  audio packets flow.

Until the first pong arrives, or against an agent that predates ping, `rtt_ms`
and the three `cap_*` fields print `n/a` rather than a guess; the agent fields
do the same until the first `agent_stats`. Read the line as a chain:
`cap_arrive_ms` minus `enc_ms` is roughly transport, `cap_decoded_ms` minus
`cap_arrive_ms` is queueing plus decode, and `cap_present_ms` minus
`cap_decoded_ms` is the wait for the next display refresh. The session header
shows the short form ("31 ms to glass, rtt 0.8 ms") while live.

## Input (US-006)

Input flows only while the Metal surface holds focus: click the stream to
capture, click anywhere else to release. A green "input captured" chip in the
chrome shows the state. The focusing click also acts on the remote desktop,
the way other remote desktop clients behave.

While input is captured and pointer lock is off, the local cursor is
transparent over the surface. The remote cursor is composited into the stream
(headless outputs have no hardware cursor plane), so with the local arrow
visible as well there are two cursors on screen and any latency looks worse
than it is. This is a cursor rect on the surface view, which is window-scoped
and stateless: release focus or leave the surface and the arrow is back with
no hide/unhide bookkeeping. Pointer lock still hides the cursor outright.

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

## Frame rate

The "Frame rate" control in the session chrome sets the display link that
drives the Metal surface: Auto (the default), 60, 120, or 144, persisted
across launches. Auto resolves to the maximum refresh rate of the screen the
window is on and is re-evaluated when the view lands in a window and whenever
the window changes screen, so a 144 Hz panel gets a 144 Hz display link
without anyone picking it and a drag to a 60 Hz panel drops back. A fixed rate
above the panel's maximum is clamped by the display link, and the test
pattern's ticker shows it: cells advance at the selected rate while only 60
draws happen per second, so the clamp appears as skipped cells.

## Audio (US-009)

Desktop audio arrives as Opus over UDP, 48 kHz stereo in 20 ms packets, on
port 52802 (the `hello` message does not negotiate an audio port, so the
default is assumed). The receiver is the same BSD-socket-on-a-thread shape
as the video receiver, minus the large receive buffer: fifty small
datagrams per second need no tuning. Each packet decodes through an
AudioToolbox AudioConverter with input format `kAudioFormatOpus` to
interleaved float PCM on a dedicated audio queue, never on the video decode
queue.

Playback is an AVAudioSourceNode pulled by AVAudioEngine into the default
output device. Between decode and render sits a jitter buffer: playback
starts once about 40 ms is buffered, an underrun plays silence and re-arms
that gate so a late burst refills before resuming, and growth past about
200 ms drops the oldest audio so latency cannot accumulate. A short
sequence gap is concealed as one packet's worth of silence per lost packet
(AudioConverter exposes no Opus packet-loss concealment); a long jump reads
as a stream restart and resyncs the buffer. Sync with video is best effort:
the buffer smooths arrival jitter, and the fixed capture-to-play delay it
adds is the price of glitch-free sound.

The session chrome has a speaker button to mute and a small slider for
volume, both persisted across launches. Mute keeps the slider position and
drives the mixer to zero. Audio failing to start (port taken, no output
device) is logged and costs sound only; the session stays up on video.

## What exists

- `Porthole/PortholeApp.swift` holds the `@main` app: the picker window and
  the single session window, both dark with hidden title bars.
- `Porthole/PickerView.swift` is the machine picker: a card grid of discovered
  and pinned machines with live thumbnails, manual add by address, rename,
  pin, remove, and auto-reconnect to the last session.
- `Porthole/Discovery/` browses `_porthole._tcp` (`DiscoveryService`), models
  a machine and its dial order (`Machine`), persists pinned machines and polls
  thumbnails (`MachineStore`), and fetches one thumbnail over the thumb port
  (`ThumbnailFetcher`).
- `Porthole/SessionView.swift` is the session screen: Metal surface, floating
  chrome with status text and the latency readout, captured/lock indicators,
  the Auto/60/120/144 frame rate control, the two input toggles, the audio
  mute and volume controls, host field, and connect button.
- `Porthole/Streaming/WireProtocol.swift` implements the v1 wire format:
  length-prefixed TCP control frames, `hello`, `pong`, and `agent_stats`
  parsing, `ping` encoding, the message type table including the 0x10-0x15
  input types, the 25-byte video datagram header, and the 16-byte audio
  datagram header.
- `Porthole/Streaming/ControlChannel.swift` is the TCP client
  (Network.framework, TCP_NODELAY). keyframe_request throttled to one per
  second except on join; input frames share the same connection via
  `sendInput`; `sendPing` and `sendPingBurst` drive the latency probe.
- `Porthole/Streaming/VideoReceiver.swift` is the UDP receiver for video
  datagrams: a BSD socket bound to the port from `hello` with an 8 MB receive
  buffer, read by a dedicated thread.
- `Porthole/Streaming/AudioReceiver.swift`, `OpusDecoder.swift`, and
  `AudioPlayer.swift` are the audio channel (US-009): the UDP receiver, the
  AudioConverter Opus decode, and the jitter buffer feeding an
  AVAudioSourceNode, as described above.
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
  reassembly, decode, loss recovery, latency stats, and owns the
  InputController. Any loss is decode-fatal: it requests a keyframe and waits
  for the next IDR.
- `Porthole/Streaming/ClientClock.swift` is the client clock every latency
  figure uses (CACurrentMediaTime, the base of Metal's presented time).
- `Porthole/Streaming/ClockOffset.swift` estimates the agent clock offset
  from a sliding window of pongs.
- `Porthole/Streaming/SessionStats.swift` holds the per-second counters, the
  stats line formatter, the published `LatencyStats`, and the stats file log.
- `Porthole/Streaming/DialWalker.swift` walks address candidates with a
  timeout per attempt; `DecodeBacklog.swift` bounds datagrams in flight to
  the decode queue.
- `Porthole/Input/InputMessages.swift` encodes the 0x10-0x15 wire messages and
  holds the letterbox coordinate mapping.
- `Porthole/Input/KeyMap.swift` is the documented keyCode-to-evdev table plus
  a US character table for scripted typing.
- `Porthole/Input/InputController.swift` translates NSEvents to wire messages:
  modifier tracking with key_modifiers ordering, pointer lock, scroll source
  and sign conventions, focus capture state, and release-on-focus-loss.
- `Porthole/Input/SessionSurfaceView.swift` is the MTKView subclass that takes
  first responder on click, forwards NSEvents to the controller, resolves the
  Auto frame rate against its window's screen, and installs the transparent
  cursor rect while captured.
- `Porthole/Rendering/MetalRenderer.swift` wraps `MTKView`. Live frames are
  converted to Metal textures via CVMetalTextureCache and drawn aspect-fit;
  YCbCr to RGB conversion runs in the fragment shader. Each new decoded frame
  registers a presented handler on its drawable, which is where
  `cap_present_ms` comes from. With no stream, it draws the test pattern.
- `Porthole/Rendering/Shaders.metal` has the test pattern shaders (SMPTE-style
  bars, frame-pacing ticker sized to the selected rate, time-derived marker)
  and the video shaders (letterboxed fullscreen triangle, NV12 to RGB).
- `Porthole/Info.plist` includes `NSBonjourServices` (`_porthole._tcp`) and
  `NSLocalNetworkUsageDescription` for discovery.
- `DecodeTest/main.swift` and `InputTest/main.swift` are the headless gates
  described above.

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
- Latency is measured against the agent's clock, not guessed from local
  timings. A client talking to an agent without ping support shows `n/a`
  instead of a number that would be wrong.

## What's next (PRD phase 1)

- US-013 turns the stats line into the gaming-mode overlay and adds the
  display-mode toggles to the session toolbar.
