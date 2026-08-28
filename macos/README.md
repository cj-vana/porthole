# Porthole for Mac

Native macOS client for Porthole. It receives a streamed Linux desktop over LAN
and renders it with Metal and VideoToolbox, and it sends keyboard, mouse, and
trackpad input back so the remote machine is fully controllable from the
window. See `../tasks/prd-porthole.md` for the full PRD.

Status: PRD stories US-004 through US-007 work. The picker finds agents over
mDNS, the app connects to a running porthole-agent over the wire protocol in
`../docs/protocol.md`, decodes H.264 or HEVC with VideoToolbox, renders it
letterboxed at the drawable's native resolution, forwards input over the same
control connection, and correlates capture, arrival, decode, GPU, presentation,
and nominal output-target timestamps against the agent's clock. When
disconnected, the surface shows a procedural test pattern with Auto/60/120/144
fps pacing.

## Requirements

- Xcode (developed against Xcode 26.x, Swift 6.3 toolchain, Swift 5 language mode)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- [SwiftLint](https://github.com/realm/SwiftLint): `brew install swiftlint`
  (`swiftlint lint --strict` from this directory is a gate)
- Deployment target: macOS 14.0
- VideoToolbox works headless, so the decode gate below runs fine in CI.
- The optional Shortcuts mode needs Accessibility access so its active event
  tap can prevent macOS from consuming remote keyboard chords. Porthole asks
  only when Shortcuts is first enabled and links directly to the correct
  Privacy & Security pane if access is missing.

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

The picker screen lists machines found over mDNS (`_porthole._tcp`) plus
pinned and manually added ones, each with a thumbnail polled every 10 s from
the agent's thumb port. Clicking a card switches the app's single window to
the session and dials.

Dialing walks the machine's addresses in order, one second per attempt: the
host that most recently answered a thumbnail poll first (remembered per
machine as `preferredHost` in machines.json, so a filtered LAN address does
not cost a timeout on every connect), then the mDNS-resolved LAN addresses,
then the machine name as a bare host name, which is what reaches a Tailscale
machine through MagicDNS. The first address to bring the control channel up
wins and the walk stops. The session chrome keeps a host field as the manual
escape hatch: edit it and Connect dials exactly what was typed. The client
accepts both protocol codecs and switches its VideoToolbox decoder as soon as
gaming mode requests HEVC.

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
stats fps=216 gpu_fps=144 present_fps=144 prep_ms=0.01 decode_ms=1.77 rtt_ms=0.64 enc_ms=1.00 cap_arrive_ms=2.0 cap_decoded_ms=3.6 cap_present_ms=12.1 cap_gpu_ms=7.1 decoded_draw_ms=2.36 draw_present_ms=6.07 submit_present_ms=6.07 submit_gpu_ms=1.06 jitter_ms=0.01/0.14/0.22/0.45/2.50 max_gap_ms=4.7/5.0/5.2/9.6/18.4 loss=0.00% queue=0 agent_fps=216/216 tx_kbps=50660 audio_buf_ms=85 audio_pkts=51 audio_lost=0 audio_drop_ms=0 audio_underrun=0 present_driver=core_video_latch pacer=155/144/144/0 hold=0 lookahead_ms=9.06 latch_wait_ms=6.55 drawable_wait_ms=0.03 drawable_policy=adaptive_late_acquire_3 recovery=0/0 recovery_signal=0 servo_ms=0.002/0.22/0.25 cap_target_ms=9.65 present_phase_ms=2.42 latch_lead_ms=4.00/5.00 phase_offset_ms=1.50 deadline_resync=0 deadline_deficit_ms=0.00/0.00 stale_retry=0/0 surface=active1,visible1,window1,key1,space1,full1,screen144,view144,sync0,buf3,hidden0
```

- `fps`: frames decoded this second. `gpu_fps` is successful Metal command
  completion; `present_fps` counts drawables with a compositor-reported
  presentation time. `decode_ms`: mean VideoToolbox decode time per frame.
- `rtt_ms`: control-channel round trip of the most recent ping/pong.
- `enc_ms`, `agent_fps`, `tx_kbps`: the agent's side, from its most recent
  `agent_stats` message: mean encode latency, capture/encoded fps, and
  transmit rate.
- `cap_arrive_ms`: agent capture to the access unit completing reassembly
  here. `cap_decoded_ms`: capture to decode finished. `cap_gpu_ms`: capture
  to successful Metal completion. `cap_present_ms` is capture to the
  `CAMetalDrawable.presentedTime` reported by the compositor and is the best
  non-optical end-to-end measurement here. `cap_target_ms` is capture to the
  pacer's nominal output target; it diagnoses scheduling but is not proof that
  the drawable appeared then. Capture fields are means on the client clock:
  each frame's agent timestamp is mapped through the offset
  estimated from pongs (`agent - (send + rtt/2)`, from the lowest-RTT pong of
  the last 60; a sliding window rather than an all-time minimum because the
  two clocks drift apart by tens of ppm, and an all-time minimum would show
  that drift as latency growing over hours).
- `drawable_policy=adaptive_late_acquire_3` means Gaming acquires from a
  three-surface pool only after its content latch. `recovery` is frames using
  the temporary wider latch / recovery activations; `recovery_signal` counts
  drawable waits that requested one. No decoded frame is prefetched.
- `loss`: lost frames as a percentage of frames seen (reassembly gaps, stale
  partials, backlog drops). `queue`: datagrams waiting for the decode queue.
- `pacer` is hardware callbacks / phase-locked cadence ticks / committed
  frames / ticks skipped after a late wake. The following fields expose
  forecast horizon, late-latch wait, drawable acquisition, deadline recovery,
  and capture-to-nominal-target. `hold` is local redraws of the previous real
  source frame: they keep an acquired two-buffer drawable recycling when the
  source misses a tick, without adding a network frame or video queue.
  `stale_retry` is ticks recovered / ticks retried by the bounded final late
  latch.
- `present_driver=core_video_latch` identifies the active presentation path.
  `present_phase_ms` is actual compositor presentation minus the nominal
  target. `servo_ms` is signed mean / absolute mean / maximum phase correction
  applied per tick from fresh Core Video forecasts. `latch_lead_ms` records the
  steady/recovery leads; `phase_offset_ms` records the target phase.
- `surface` records whether the app, window, Space, native Full state, screen
  rate, MTKView rate, layer synchronization, drawable count, and visibility
  made the sample valid. Use active native-Full samples for timing comparisons.
- `audio_*`: the audio channel's second (US-009): jitter buffer depth, Opus
  packets received, packets lost to sequence gaps, milliseconds dropped to
  keep the buffer under its cap, and playback underruns. All zeros until
  audio packets flow.

Until the first pong arrives, or against an agent that predates ping, `rtt_ms`
and the ordinary `cap_*` fields print `n/a` rather than a guess; the agent fields
do the same until the first `agent_stats`. Read the line as a chain:
`cap_arrive_ms` minus `enc_ms` is roughly transport, `cap_decoded_ms` minus
`cap_arrive_ms` is queueing plus decode. In gaming mode `cap_present_ms` is the
end-to-end result reported by the compositor. It still is not an optical
glass-to-glass measurement; validating photons requires a high-speed camera
or photodiode.

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

- "Shortcuts" installs an Accessibility-authorized, head-insert session event
  tap. While Porthole is active and the stream surface has focus, key down,
  key up, and modifier events go exclusively through `InputController` and do
  not reach macOS. Command-Space becomes remote Super-Space instead of local
  Spotlight; Command-Tab, Command-Q, Control-arrow, function-key shortcuts,
  normal typing, and their key-up events use the same path. Turning the toggle
  off, moving focus to Porthole's chrome, or deactivating the app restores
  ordinary local input immediately. Unmodified Escape remains local as the
  pointer-lock and native-fullscreen safety key.
- "Pointer lock" hides the local cursor and switches motion to
  pointer_motion_rel deltas (NSEvent deltaX/deltaY, 1/256 px units) for games
  and 3D apps. It engages only while the surface has focus and Esc releases it.

## Display size and frame rates

Fit and Full both report the Metal surface's backing-pixel viewport to the
agent. After a 300 ms resize settle, an agent-owned Hyprland headless output
is reconfigured to that geometry; capture, encoding, absolute-pointer mapping,
and the decoder's fresh IDR then move together. Agents never resize physical
monitors. A legacy stored 1:1 preference migrates to Fit automatically.

The "Local display" control in the session chrome sets the display link that
drives the Metal surface: Auto (the default), 60, 120, or 144, persisted
across launches. Auto resolves to the maximum refresh rate of the screen the
window is on and is re-evaluated when the view lands in a window and whenever
the window changes screen, so a 144 Hz panel gets a 144 Hz display link
without anyone picking it and a drag to a 60 Hz panel drops back. A fixed rate
above the panel's maximum is clamped by the display link, and the test
pattern's ticker shows it: cells advance at the selected rate while only 60
draws happen per second, so the clamp appears as skipped cells.

Gaming has a separate capture-ceiling control. Max 288 requests 288 Hz HEVC even
on a 120/144 Hz client panel; VFR sends only real frames (about 214 Hz on the
2560x1440 test host). The labels deliberately say Max: this is not a claim
that 288 frames were delivered. Stats reports measured source, encoded,
decoded, and presented rates separately. The deliberate oversampling prevents independent
capture and scanout clocks from slowly beating into doubled and missed frames.
Core Video supplies the physical display's phase and period once; an
independent mach-time cadence wheel then remains evenly phase-locked even when
display-link callbacks bunch under WindowServer load. A high-priority worker
reserves the next two-buffer drawable ahead of time, while the newest decoded
frame is selected only at the late latch. A reservation that misses its
acquisition deadline remains available for the next tick instead of forcing a
late blocking submission. The wheel advances 2.5 ms from Core Video's nominal
phase to account for the repeatable gap to the compositor-reported presentation
slot while retaining the measured render margin. If no new generation lands by
the final latch, the renderer redraws the last real frame into the drawable it
already acquired. The pixels would be held either way; presenting the hold
prevents that drawable from starving the next real frame.

Metal submission remains asynchronous after each command-buffer commit.
Waiting synchronously for the command buffer to become scheduled places the
cadence worker behind WindowServer's present handshake; at native 1440p that
handshake can cross a refresh boundary and collapse an otherwise 144 Hz path
to 60 Hz.

On the tested fixed-144 Hz panel, Gaming + Auto stays at native 144 Hz. A
clean 67-second native-Full 2560x1440 soak with a 214-215 fps real VFR source
averaged 141.4 compositor-reported presentations/s with a 144 fps median.
Capture-to-present latency averaged 10.49 ms, with a 10.50 ms median, 11.50 ms
p95, and 9.70-12.70 ms range. Stream loss and deadline resynchronizations were
both zero. Those are software timestamps, not an optical measurement.

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

- `Porthole/PortholeApp.swift` holds the `@main` app: one dark root window that
  switches between picker and session content, avoiding hidden restored
  windows that compete with fullscreen presentation.
- `Porthole/PickerView.swift` is the machine picker: a card grid of discovered
  and pinned machines with live thumbnails, manual add by address, rename,
  pin, remove, and auto-reconnect to the last session.
- `Porthole/Discovery/` browses `_porthole._tcp` (`DiscoveryService`), models
  a machine and its dial order (`Machine`), persists pinned machines and polls
  thumbnails (`MachineStore`), and fetches one thumbnail over the thumb port
  (`ThumbnailFetcher`).
- `Porthole/SessionView.swift` is the session screen: Metal surface, floating
  chrome with status text and the latency readout, captured/lock indicators,
  Fit/Full sizing, the Auto/60/120/144 Hz local-display control, the
  Max 120/144/180/288 capture-ceiling control, measured-rate Stats, collapsible
  controls, input toggles, acknowledged remote desktop-bar control, audio
  controls, host field, and connect button. Hide controls collapses both
  chrome rows to an explicit Controls tab; Full + Gaming stays entirely clean
  and Escape returns to Fit and the controls.
- `Porthole/Streaming/WireProtocol.swift` implements the v1 wire format:
  length-prefixed TCP control frames, `hello`, `pong`, and `agent_stats`
  parsing, `ping`, settings, display-resize, and desktop-bar encoding, the message type
  table including the 0x10-0x15 input types, the 25-byte video datagram header, and the 16-byte audio
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
  per the protocol's receiver rules. Two trailing zero-wait parity shards
  recover any two missing data datagrams without retransmission; complete
  data frames never wait for them. Unrecoverable frames are dropped after
  500 ms, and sequence gaps and stale frames count as loss.
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
- `Porthole/Input/SystemShortcutCapture.swift` owns the active Core Graphics
  session event tap, permission gate, focus checks, system-event suppression,
  and automatic recovery if macOS disables a slow tap.
- `Porthole/Input/SessionSurfaceView.swift` is the MTKView subclass that takes
  first responder on click, forwards NSEvents to the controller, resolves the
  Auto frame rate against its window's screen, and installs the transparent
  cursor rect while captured.
- `Porthole/Rendering/MetalRenderer.swift` wraps `MTKView`. Live frames are
  converted to Metal textures via CVMetalTextureCache and drawn aspect-fit;
  YCbCr to RGB conversion runs in the fragment shader. Gaming mode seeds a
  mach-time cadence wheel from the physical display, then late-selects the
  newest decoded frame on each fixed tick. Drawable reservation runs ahead on
  a separate high-priority queue, but the layer has only two buffers and the
  video mailbox never becomes a queue. A local hold redraw prevents a source
  gap from abandoning an acquired surface. Immediate asynchronous presentation
  avoids both another refresh of timed-present latency and a synchronous
  WindowServer scheduling fence. Presented and GPU-completed handlers produce
  `cap_present_ms` and `cap_gpu_ms`; with no stream, it draws the test pattern.
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
- Debug and headless-test builds use ad hoc signing (`CODE_SIGN_IDENTITY = "-"`)
  so ordinary LAN development needs no certificate. Release app builds use the
  project's Developer ID identity and hardened runtime without debug
  entitlements; that stable designated requirement lets macOS Accessibility
  approval survive subsequent app updates.
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
