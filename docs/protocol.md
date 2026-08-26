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
9       4     fps (BE u32)
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

Reconfigure the live stream: gaming mode selects a higher framerate, the
low-latency encoder bias, and optionally HEVC.

```
offset  size  field
0       2     fps (BE u16): 60, 120, or 144
2       1     codec: 0 = h264, 1 = hevc
3       2     bitrate in Mbps (BE u16)
5       1     low_latency: 1 biases the encoder toward latency over quality
```

Payload length is 6. The agent applies it by restarting its encoder with
the new parameters and sending a fresh `hello`, so the next access unit is
an IDR in the requested codec. The client should re-init its decoder for
the requested codec as soon as it sends this, rather than waiting for the
hello, because the hello is advisory (a dropped hello must not strand the
client on the old codec).

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

## Video channel (UDP)

Each encoded access unit (Annex B h264/hevc) is split into fragments with a
fixed 25-byte header. The datagram size ceiling is 1400 bytes (safe under a
1500-byte MTU), so the largest fragment payload is 1375 bytes. The agent
sizes datagrams from its `mtu` setting (default 1280, the IPv6 minimum and
the WireGuard/Tailscale tunnel MTU): datagram size = mtu - 28 (IPv4 + UDP
headers), so 1252-byte datagrams by default. A datagram that has to be
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
25      n     fragment payload
```

Receiver rules:

- Reassemble per frame sequence; a frame is decodable only when all
  fragments are present.
- Drop a frame when any fragment is missing (stale partial frames; the
  reference receiver uses 500 ms).
- A gap in completed frame sequences means whole frames were lost.
- Any loss is decode-fatal until the next IDR: send keyframe_request. The
  reference receiver throttles requests to 1/second.
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
caps=<encoder>,h264,hevc,144           capabilities, e.g. "nvenc,h264,hevc,144"
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

## Notes for later versions

- Audio (Opus over UDP 52802) is specified in US-009, not yet on the wire.
- The transport behind `protocol.rs` is deliberately simple so a WebRTC or
  QUIC transport can replace it for internet play later; nothing here
  assumes more than "UDP + TCP reachability", so Tailscale already works.
