# Porthole wire protocol (v1)

Implemented by `porthole-agent` (Rust, `agent/src/protocol.rs` is the
reference implementation) and the Porthole Mac client. Version 1 covers
video, control, input, and latency stats; audio rides its own UDP port
later (US-009). Both sides ignore control message types they do not know,
so additions within version 1 stay compatible.

Two channels:

- Video: UDP datagrams, default port 52800 (agent `--port-video`).
- Control: TCP, default port 52801 (agent `--port-control`). The agent is the
  server; the client connects.

All multi-byte integers are big-endian.

## Control channel (TCP)

Messages are length-prefixed frames:

```
offset  size  field
0       4     payload length in bytes, including the 1-byte type (BE u32)
4       1     message type
5       n     payload
```

One client at a time: a new control connection replaces the old one (the
agent drops the old connection and redirects video to the new peer).

### hello (type 0x01, agent -> client, sent on connect)

```
offset  size  field
0       1     codec: 0 = h264, 1 = hevc
1       4     width (BE u32)
5       4     height (BE u32)
9       4     configured capture ceiling in fps (BE u32; not a measured rate)
13      4     bitrate in Mbps (BE u32)
17      4     keyframe interval in seconds (BE u32)
21      2     video port (BE u16): the UDP port the agent sends video to
```

Payload length is 23. Video datagrams are sent to the control peer's IP
address at this port.

### keyframe_request (type 0x02, client -> agent)

Empty payload. Send this whenever the decoder cannot make progress without a
fresh IDR: on connect (joining mid-GOP), or after decode-fatal packet loss.
The agent answers by restarting its encoder session, so the next access unit
on the wire is an IDR. Tradeoff: a session restart costs roughly a frame or
two of gap and a bitrate spike from the IDR; periodic IDRs (every
`keyframe interval` seconds) bound the worst case when no request arrives.

The video sequence number is NOT reset by an encoder restart; receivers
should treat it as one continuous stream.

### ping (type 0x03, client -> agent) and pong (type 0x04, agent -> client)

Round-trip and clock-offset probe for the latency stats. The client sends
ping with its own monotonic timestamp; the agent answers as soon as the
control reader decodes it (no trip through the video pipeline) with that
timestamp echoed and its own pipeline clock, the same clock the video
datagram timestamps use. Both ends set TCP_NODELAY on the control
connection; without it, Nagle plus delayed ACKs batch the small input and
probe messages into 40 ms clumps.

ping payload:

```
offset  size  field
0       8     client timestamp (BE u64, microseconds, any monotonic clock)
```

pong payload:

```
offset  size  field
0       8     echoed client timestamp (BE u64)
8       8     agent timestamp (BE u64, microseconds since pipeline start)
```

Client math: `rtt = now - echoed`; `offset = agent_ts - (echoed + rtt / 2)`
(agent clock minus client clock). Keep the offset from the lowest-RTT
sample within a sliding window of recent pongs (the two monotonic clocks
drift by tens of ppm, so an all-time minimum slowly reports phantom
latency growth). A frame captured at datagram timestamp `t` then maps to
client time `t - offset`, so `present_time - (t - offset)` is
capture-to-present latency. The reference client sends a short burst of
pings on connect so the estimate converges quickly, then one per second.
A client talking to an agent that predates this message gets no pong and
should leave the offset-based fields blank rather than guess.

### agent_stats (type 0x05, agent -> client, once per second)

The agent's side of the per-second stats, so the client can split its
capture-to-arrival measurement into encode and transport.

```
offset  size  field
0       2     capture fps (BE u16)
2       2     encoded fps (BE u16)
4       4     encode latency (BE u32, microseconds): mean over the last
              second from frame submit to access unit ready
8       4     transmit rate (BE u32, kbit/s)
12      2     keyframes encoded in the last second (BE u16)
```

Payload length is 14. Sent only while a client is connected.

### settings (type 0x06, client -> agent, US-013)

Reconfigure the live stream: gaming mode selects a higher capture ceiling, the
low-latency encoder bias, and optionally HEVC.

```
offset  size  field
0       2     fps (BE u16): 60, 120, 144, 180, or 288
2       1     codec: 0 = h264, 1 = hevc
3       2     bitrate in Mbps (BE u16)
5       1     low_latency: 1 biases the encoder toward latency over quality
```

Payload length is 6. The fps value is a ceiling: variable-frame-rate capture
only emits real compositor frames, and `agent_stats` is the source of measured
capture/encode rates. The agent applies settings by restarting its encoder
with the new parameters and sending a fresh `hello`, so the next access unit
is an IDR in the requested codec. The client should re-init its decoder for
the requested codec as soon as it sends this, rather than waiting for the
hello, because the hello is advisory (a dropped hello must not strand the
client on the old codec).

### display_resize (type 0x09, client -> agent)

Resize the headless output owned by the agent after the client viewport has
settled. Agents that do not own a virtual display ignore this message; they
never resize a physical monitor. Unknown-message handling makes this backward
compatible with older agents.

```
offset  size  field
0       4     width in pixels (BE u32)
4       4     height in pixels (BE u32)
```

Payload length is 8. Both dimensions must be even; width must be 320..8192
and height 180..8192. A valid resize stops capture, reconfigures the virtual
output, recreates capture and encoder resources, updates absolute-pointer
geometry, and sends a fresh `hello`. The first new access unit is an IDR.
Clients should deduplicate and debounce interactive window resizing. When a
settings change and resize are part of one action, send them consecutively so
the agent can coalesce them into one pipeline rebuild.

### desktop_bar (type 0x0A, either direction)

Query, hide, or restore a supported remote desktop bar without restarting the
desktop shell. The payload is exactly one byte. Client-to-agent values are:

```
value   command
0       query current state
1       show
2       hide
```

The agent answers every valid request on the same message type after applying
it:

```
value   state
0       unavailable on this desktop
1       visible
2       hidden
```

The reference agent supports Omarchy's Quickshell bar through its idempotent
`omarchy-toggle-bar` helper. It changes the shell's watched state flag rather
than killing Quickshell. The operation runs off the control-reader thread so
desktop tooling cannot delay input messages. Older agents ignore 0x0A; clients
should omit or disable the control until an acknowledgement arrives.

### Input messages (client -> agent, US-006)

One control connection carries hello + keyframe_request + input for one
client. Input messages are fixed-size, applied to a virtual pointer and
virtual keyboard on the agent's seat as they arrive (no batching). All
coordinates are for the output the agent captures (the one in hello).

#### pointer_motion_abs (type 0x10)

```
offset  size  field
0       4     x (BE i32, output pixels)
4       4     y (BE i32, output pixels)
```

#### pointer_motion_rel (type 0x11)

```
offset  size  field
0       4     dx (BE i32, 1/256 pixel units; see below)
4       4     dy (BE i32, 1/256 pixel units)
```

#### pointer_button (type 0x12)

```
offset  size  field
0       2     button (BE u16, evdev BTN_* code; 0x110 left, 0x111 right,
              0x112 middle)
2       1     state: 1 = pressed, 0 = released
```

#### pointer_axis (type 0x13)

```
offset  size  field
0       1     axis: 0 = vertical, 1 = horizontal (matches wl_pointer.axis)
1       1     source: 0 = wheel, 1 = finger, 2 = continuous, 3 = wheel tilt
              (matches wl_pointer.axis_source)
2       4     value (BE i32, 1/256 pixel units; see below)
```

Relative motion and axis values are fixed-point pixels in the wl_fixed
convention: divide by 256 to get pixels. This is pixel-precise, which the
Mac trackpad scroll path (pixel deltas, momentum) maps onto directly. For
axis source 0 (wheel), one click is 10 pixels (value 2560). Positive
vertical values scroll down.

#### key (type 0x14)

```
offset  size  field
0       2     key (BE u16, evdev KEY_* code, e.g. 30 = KEY_A)
2       1     state: 1 = pressed, 0 = released
```

The virtual keyboard runs the evdev/pc105/us xkb keymap. Modifier state is
not derived from key events; it is applied through the virtual-keyboard
`modifiers` request, which the wire format carries as key_modifiers below.
Send it before the key events it should affect, and again to release.

#### key_modifiers (type 0x15)

```
offset  size  field
0       4     depressed (BE u32, xkb modifier mask)
4       4     latched (BE u32)
8       4     locked (BE u32)
12      4     group (BE u32)
```

Payload length is 16. Masks use the classic X11/xkb bit order: bit 0 Shift,
bit 1 Lock (Caps Lock), bit 2 Control, bit 3 Mod1 (Alt), bit 6 Mod4 (Super).
Example: holding shift is `depressed=1, latched=0, locked=0, group=0`.

### clipboard (type 0x07, either direction, US-008)

Clipboard text sync. Either side sends this when its own clipboard changes;
the payload is the UTF-8 text with no trailing NUL (an empty payload clears
the selection). To avoid a sync loop, the receiver remembers the text it was
handed and does not send an identical value back out.

### gamepad_state (type 0x08, client -> agent, US-014)

The client sends the full controller state whenever any control changes; the
agent maps it onto a virtual uinput gamepad.

```
offset  size  field
0       4     buttons (BE u32): bitmask, SDL GameController button order
              (0 A, 1 B, 2 X, 3 Y, 4 back, 5 guide, 6 start, 7 left stick,
              8 right stick, 9 left shoulder, 10 right shoulder)
4       2     left stick x (BE i16, -32768..32767)
6       2     left stick y (BE i16)
8       2     right stick x (BE i16)
10      2     right stick y (BE i16)
12      2     left trigger (BE i16, 0..32767)
14      2     right trigger (BE i16, 0..32767)
16      1     hat: 0 centered, bit 0 up, bit 1 right, bit 2 down, bit 3 left
```

Payload length is 17.

## File transfer (TCP, US-011)

Files dragged onto the session window are sent over their own TCP connection
to the file port (default 52804, agent `--port-files`), one connection per
file, so a large transfer never competes with the video path. The client
connects and writes:

```
offset  size  field
0       2     name length in bytes (BE u16)
2       n     file name (UTF-8, no path separators; the agent strips any)
2+n     8     file size in bytes (BE u64)
10+n    size  file contents
```

The agent writes the file into its configured transfer folder (default
`~/Downloads`, agent `--transfer-dir`) under a temporary name and renames it
into place once the full size has arrived, so a partial transfer never
leaves a file that looks complete. When the whole file is safely on disk the
agent writes one acknowledgement byte (0x01) and closes the connection; the
client waits for that byte before reporting the transfer done. This channel
carries no video or control traffic.

## Video channel (UDP)

Each encoded access unit (Annex B h264/hevc) is split into data fragments with
a fixed 25-byte header, followed by two zero-wait repair shards. The datagram
size ceiling is 1400 bytes (safe under a 1500-byte MTU). Repair metadata takes
two bytes and the GF(2^16) symbols require an even size, so the largest data
fragment payload is 1372 bytes. The agent
sizes datagrams from its `mtu` setting (default 1280, the IPv6 minimum and
the WireGuard/Tailscale tunnel MTU): datagram size = mtu - 28 (IPv4 + UDP
headers), so 1252-byte datagrams with 1224-byte data shards by default. A datagram that has to be
IP-fragmented in transit is lost when any piece is lost, which is what
made keyframe bursts unrecoverable over a 1280-byte tunnel with
1400-byte datagrams. Receivers accept any size up to the ceiling.

Keyframe access units are several hundred datagrams; the agent paces those
bursts (see `transport`) so a 1 Gbit link or a userspace tunnel does not
drop the tail of the burst.

```
offset  size  field
0       3     magic: "PHV" (0x50 0x48 0x56)
3       1     protocol version (1)
4       8     frame sequence (BE u64): per access unit, monotonic for the
              lifetime of the agent, across encoder restarts
12      8     timestamp (BE u64): microseconds since the agent's pipeline
              start, taken from the captured frame this access unit encodes
20      2     fragment index (BE u16, 0-based)
22      2     fragment count (BE u16)
24      1     flags: bit 0 = access unit contains an IDR (keyframe)
                    bit 1 = repair shard
                    bit 2 = secondary weighted repair shard (requires bit 1)
25      n     fragment payload
```

`fragment count` counts data shards only. Their indices are `0 ..< count`.
The primary repair shard has index `count`; the secondary repair shard has
index `count + 1`. Each repair payload starts with the true final-data-shard
length as a big-endian u16, followed by one padded shard:

- Primary P parity is the bytewise XOR of every data shard.
- Secondary Q parity treats adjacent bytes as big-endian GF(2^16) symbols and
  XORs data shard `i` multiplied by coefficient `i + 1`. The field polynomial
  is x^16 + x^12 + x^3 + x + 1.

P and Q solve any two missing data shards. Either shard can solve one missing
data shard, so losing one repair datagram does not remove single-loss
protection. Both repairs follow all data: the normal ordered, loss-free path
completes on its final data datagram and pays no repair wait or decode latency.
Receivers that only understand P ignore Q by its out-of-range index.

Receiver rules:

- Reassemble per frame sequence; a frame is decodable only when all
  fragments are present.
- Recreate one or two missing data fragments from P/Q as soon as enough
  shards arrive. Do not delay a complete data frame to wait for repair.
- Drop a frame when missing data exceeds available repair capacity (stale
  partial frames; the reference receiver uses 500 ms).
- A gap in completed frame sequences means whole frames were lost.
- An unrepaired loss is decode-fatal until the next IDR: send
  `keyframe_request`. The reference receiver throttles requests to 1/second.
- Start decoding (or dumping) from the first keyframe access unit.

Reference receiver: `cargo run --example receiver -- <agent-ip> [--dump
out.h264]`. Scripted input sender: `cargo run --example input_sender --
<agent-ip> <move-abs|move-rel|click|scroll|type> ...`. Compositor protocol
listing: `cargo run --example wl_globals` on the Linux machine.

## Discovery and thumbnails (US-007a)

### mDNS announce (FR-8)

Agents advertise `_porthole._tcp.local.` while running, with the service
port set to the control port. The instance name is the configured machine
name (`--name`, default: system hostname). TXT records:

```
v=1                                    protocol version
name=<machine name>                    picker display name
control_port=52801                     TCP control channel
video_port=52800                       UDP video datagrams
thumb_port=52803                       TCP thumbnail endpoint (see below)
caps=<encoder>,h264,hevc,288           capabilities, e.g. "gsr,h264,hevc,288"
```

The announcement is withdrawn when the agent exits.

### Thumbnail endpoint (FR-10)

The machine picker wants a recent frame per agent without disturbing an
active session. The control channel is single-client, so thumbnails do NOT
go through it; the picker polls a separate one-shot TCP service on
`thumb_port` (default 52803) instead of the agent pushing on a timer.

Flow: connect, agent immediately writes one message, connection closes.
Framing matches the control channel minus the type byte:

```
offset  size  field
0       4     payload length in bytes (BE u32); 0 means no frame captured yet
4       n     payload
```

Payload:

```
offset  size  field
0       2     width (BE u16)
2       2     height (BE u16)
4       n     width*height*4 bytes of RGBA8 pixels
```

The thumbnail is the latest captured frame downscaled to 320 px wide
(nearest neighbor). Freshness: the capture thread refreshes the source frame
every 30 frames (a few times per second); a thumbnail is at most a second
stale in practice. Fetcher: `cargo run --example thumb_fetch -- <agent-ip>
out.png`.

## Audio channel (UDP, US-009)

Desktop audio is captured from the machine's default sink monitor, encoded
as Opus (48 kHz stereo, 20 ms frames, 128 kbit/s), and sent as UDP datagrams
on the audio port (default 52802, agent `--port-audio`) to the same client
the control channel connected. One Opus packet per datagram; packets are
small, so no fragmentation.

```
offset  size  field
0       3     magic: "PHA" (0x50 0x48 0x41)
3       1     protocol version (1)
4       4     sequence (BE u32): per packet, from 0
8       8     timestamp (BE u64): microseconds on the agent pipeline clock,
              the same clock as the video datagram timestamps, so the client
              can line audio up with video
16      n     one Opus packet
```

The timestamp counts encoded samples at 48 kHz rather than wall clock, so it
carries no scheduling jitter; the client turns it into a play time through
the same clock offset it measures with ping/pong, and absorbs the fixed
capture-to-play delay in a small jitter buffer. Audio flows only while a
client is connected. There is no separate handshake: the Opus parameters are
fixed by this spec.

## Notes for later versions

- The transport behind `protocol.rs` is deliberately simple so a WebRTC or
  QUIC transport can replace it for internet play later; nothing here
  assumes more than "UDP + TCP reachability", so Tailscale already works.
