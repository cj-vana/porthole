# Porthole wire protocol (v1)

Implemented by `porthole-agent` (Rust, `agent/src/protocol.rs` is the
reference implementation) and the Porthole Mac client. Version 1 covers
video only; audio rides its own UDP port later (US-009).

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

## Video channel (UDP)

Each encoded access unit (Annex B h264/hevc) is split into fragments with a
fixed 25-byte header. Max datagram size is 1400 bytes (safe under a
1500-byte MTU), so max fragment payload is 1375 bytes.

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
out.h264]`.

## Notes for later versions

- Audio (Opus over UDP 52802) is specified in US-009, not yet on the wire.
- The transport behind `protocol.rs` is deliberately simple so a WebRTC or
  QUIC transport can replace it for internet play later; nothing here
  assumes more than "UDP + TCP reachability", so Tailscale already works.
