import Foundation

/// Porthole wire protocol v1. Spec: docs/protocol.md; reference
/// implementation: agent/src/protocol.rs. All multi-byte integers are
/// big-endian.
enum WireProtocol {
    /// TCP control channel port (agent is the server, client connects).
    static let controlPort: UInt16 = 52801
    /// Default UDP video port; the authoritative value arrives in `hello`.
    static let defaultVideoPort: UInt16 = 52800
    /// UDP audio port (agent `--port-audio`, US-009). `hello` carries no
    /// audio port, so the default is assumed rather than negotiated.
    static let audioPort: UInt16 = 52802
    /// TCP file transfer port (agent `--port-files`, US-011). Each dropped
    /// file rides its own connection here, off the video path.
    static let filePort: UInt16 = 52804
    /// Protocol version byte in every video and audio datagram.
    static let version: UInt8 = 1
}

/// Control message types (TCP, length-prefixed frames).
enum ControlMessageType: UInt8 {
    /// agent -> client, sent on connect. Payload is 23 bytes.
    case hello = 0x01
    /// client -> agent, empty payload. Ask for a fresh IDR.
    case keyframeRequest = 0x02
    /// client -> agent latency probe: 8-byte client monotonic timestamp (us).
    case ping = 0x03
    /// agent -> client answer to ping: echoed client timestamp + agent
    /// pipeline timestamp (the video datagram clock), 16 bytes.
    case pong = 0x04
    /// agent -> client once per second: capture/encode fps, encode latency,
    /// transmit rate, keyframes. 14 bytes.
    case agentStats = 0x05
    /// client -> agent (US-013): reconfigure the live stream. 6 bytes; the
    /// agent restarts its encoder and answers with a fresh hello.
    case settings = 0x06
    /// either direction (US-008): clipboard text, UTF-8 payload.
    case clipboard = 0x07
    /// client -> agent (US-014): gamepad state, 17-byte payload.
    case gamepad = 0x08
    // Input messages (client -> agent, US-006). Layouts in docs/protocol.md.
    case pointerMotionAbs = 0x10
    case pointerMotionRel = 0x11
    case pointerButton = 0x12
    case pointerAxis = 0x13
    case key = 0x14
    case keyModifiers = 0x15
}

/// Parsed `hello` message (agent -> client).
///
/// ```
/// offset  size  field
/// 0       1     codec: 0 = h264, 1 = hevc
/// 1       4     width (BE u32)
/// 5       4     height (BE u32)
/// 9       4     fps (BE u32)
/// 13      4     bitrate in Mbps (BE u32)
/// 17      4     keyframe interval in seconds (BE u32)
/// 21      2     video port (BE u16): UDP port the agent sends video to
/// ```
struct Hello: Equatable {
    enum Codec: UInt8 {
        case h264 = 0
        case hevc = 1
    }

    static let payloadLength = 23

    let codec: Codec
    let width: UInt32
    let height: UInt32
    let fps: UInt32
    let bitrateMbps: UInt32
    let keyframeIntervalSecs: UInt32
    let videoPort: UInt16

    init?(payload: Data) {
        guard payload.count >= Self.payloadLength,
              let codec = Codec(rawValue: payload[0]) else {
            return nil
        }
        self.codec = codec
        width = payload.readUInt32BE(at: 1)
        height = payload.readUInt32BE(at: 5)
        fps = payload.readUInt32BE(at: 9)
        bitrateMbps = payload.readUInt32BE(at: 13)
        keyframeIntervalSecs = payload.readUInt32BE(at: 17)
        videoPort = payload.readUInt16BE(at: 21)
    }
}

/// Parsed `pong` (agent -> client).
///
/// ```
/// offset  size  field
/// 0       8     echoed client timestamp (BE u64, microseconds)
/// 8       8     agent timestamp (BE u64, microseconds since pipeline start)
/// ```
struct Pong: Equatable {
    static let payloadLength = 16

    let clientTimestampMicros: UInt64
    let agentTimestampMicros: UInt64

    init?(payload: Data) {
        guard payload.count == Self.payloadLength else { return nil }
        clientTimestampMicros = payload.readUInt64BE(at: 0)
        agentTimestampMicros = payload.readUInt64BE(at: 8)
    }
}

/// Parsed `agent_stats` (agent -> client, once per second).
///
/// ```
/// offset  size  field
/// 0       2     capture fps (BE u16)
/// 2       2     encoded fps (BE u16)
/// 4       4     encode latency, microseconds (BE u32), mean over the second
/// 8       4     transmit rate, kbit/s (BE u32)
/// 12      2     keyframes encoded in the second (BE u16)
/// ```
struct AgentStats: Equatable {
    static let payloadLength = 14

    let captureFps: UInt16
    let encodeFps: UInt16
    let encodeLatencyMicros: UInt32
    let txKbps: UInt32
    let keyframes: UInt16

    init?(payload: Data) {
        guard payload.count == Self.payloadLength else { return nil }
        captureFps = payload.readUInt16BE(at: 0)
        encodeFps = payload.readUInt16BE(at: 2)
        encodeLatencyMicros = payload.readUInt32BE(at: 4)
        txKbps = payload.readUInt32BE(at: 8)
        keyframes = payload.readUInt16BE(at: 12)
    }
}

extension WireProtocol {
    /// Encode a `ping` control frame carrying the client's monotonic clock.
    static func encodePing(clientTimestampMicros: UInt64) -> Data {
        var payload = Data(capacity: 8)
        payload.appendUInt64BE(clientTimestampMicros)
        return encodeControlMessage(.ping, payload: payload)
    }

    /// Encode a `settings` control frame (US-013):
    ///
    /// ```
    /// offset  size  field
    /// 0       2     fps (BE u16): 60, 120, 144, 180, or 288
    /// 2       1     codec: 0 = h264, 1 = hevc
    /// 3       2     bitrate in Mbps (BE u16)
    /// 5       1     low_latency: 1 biases the encoder toward latency
    /// ```
    static func encodeSettings(fps: UInt16, codec: Hello.Codec,
                               bitrateMbps: UInt16, lowLatency: Bool) -> Data {
        var payload = Data(capacity: 6)
        payload.appendUInt16BE(fps)
        payload.append(codec.rawValue)
        payload.appendUInt16BE(bitrateMbps)
        payload.append(lowLatency ? 1 : 0)
        return encodeControlMessage(.settings, payload: payload)
    }

    /// Encode a `gamepad_state` control frame (US-014):
    ///
    /// ```
    /// offset  size  field
    /// 0       4     buttons (BE u32, SDL GameController bit order)
    /// 4       12    six axes (BE i16 each): left stick x/y, right stick
    ///               x/y, left trigger, right trigger
    /// 16      1     hat: bit 0 up, 1 right, 2 down, 3 left
    /// ```
    ///
    /// The payload is fixed at 17 bytes, so exactly six axis values are
    /// framed; a short `axes` array reads as centered for the remainder.
    static func encodeGamepad(buttons: UInt32, axes: [Int16], hat: UInt8) -> Data {
        var payload = Data(capacity: 17)
        payload.appendUInt32BE(buttons)
        for index in 0..<6 {
            payload.appendUInt16BE(UInt16(bitPattern: index < axes.count ? axes[index] : 0))
        }
        payload.append(hat)
        return encodeControlMessage(.gamepad, payload: payload)
    }

    /// Header of one video datagram fragment (25 bytes, fixed):
    ///
    /// ```
    /// offset  size  field
    /// 0       3     magic: "PHV"
    /// 3       1     protocol version (1)
    /// 4       8     frame sequence (BE u64), per access unit
    /// 12      8     timestamp (BE u64), microseconds since pipeline start
    /// 20      2     fragment index (BE u16, 0-based)
    /// 22      2     fragment count (BE u16)
    /// 24      1     flags: bit 0 = IDR, bit 1 = repair, bit 2 = secondary repair
    /// ```
    /// The XOR shard uses `fragmentIndex == fragmentCount`; the weighted
    /// shard uses `fragmentCount + 1`. Data fragments remain strictly below.
    struct DatagramHeader {
        static let length = 25
        static let maxDatagramSize = 1400

        let frameSequence: UInt64
        let timestampMicros: UInt64
        let fragmentIndex: UInt16
        let fragmentCount: UInt16
        let isKeyframe: Bool
        let isRepair: Bool
        let isSecondaryRepair: Bool
    }

    /// Parse one UDP datagram into header + payload. Returns nil for
    /// malformed datagrams (wrong magic, version, size, or fragment bounds).
    static func parseDatagram(_ data: Data) -> (header: DatagramHeader, payload: Data)? {
        let header = data.withUnsafeBytes { parseDatagramHeader($0) }
        guard let header else { return nil }
        return (header, data.subdata(in: DatagramHeader.length..<data.count))
    }

    /// Pointer-based parser for the receive hot path. The caller owns the
    /// bytes; no `Data` is created just to validate a 25-byte header.
    static func parseDatagramHeader(_ bytes: UnsafeRawBufferPointer) -> DatagramHeader? {
        guard bytes.count > DatagramHeader.length,
              bytes.count <= DatagramHeader.maxDatagramSize,
              bytes[0] == 0x50, bytes[1] == 0x48, bytes[2] == 0x56, // "PHV"
              bytes[3] == version else {
            return nil
        }
        let fragmentIndex = UInt16(bytes[20]) << 8 | UInt16(bytes[21])
        let fragmentCount = UInt16(bytes[22]) << 8 | UInt16(bytes[23])
        let isRepair = bytes[24] & 0x02 != 0
        let isSecondaryRepair = bytes[24] & 0x04 != 0
        let (secondaryIndex, secondaryOverflow) = fragmentCount.addingReportingOverflow(1)
        let validRepairIndex = isSecondaryRepair
            ? isRepair && !secondaryOverflow && fragmentIndex == secondaryIndex
            : isRepair && fragmentIndex == fragmentCount
        guard fragmentCount > 0,
              isRepair ? validRepairIndex : fragmentIndex < fragmentCount,
              isRepair || !isSecondaryRepair else {
            return nil
        }

        var frameSequence: UInt64 = 0
        var timestampMicros: UInt64 = 0
        for offset in 4..<12 {
            frameSequence = frameSequence << 8 | UInt64(bytes[offset])
        }
        for offset in 12..<20 {
            timestampMicros = timestampMicros << 8 | UInt64(bytes[offset])
        }
        return DatagramHeader(frameSequence: frameSequence,
                              timestampMicros: timestampMicros,
                              fragmentIndex: fragmentIndex,
                              fragmentCount: fragmentCount,
                              isKeyframe: bytes[24] & 0x01 != 0,
                              isRepair: isRepair,
                              isSecondaryRepair: isSecondaryRepair)
    }

    /// One audio datagram (US-009): a 16-byte header, then one Opus packet
    /// (48 kHz stereo, 20 ms frames).
    ///
    /// ```
    /// offset  size  field
    /// 0       3     magic: "PHA"
    /// 3       1     protocol version (1)
    /// 4       4     sequence (BE u32), per packet, from 0
    /// 8       8     timestamp (BE u64), microseconds on the agent pipeline
    ///               clock, the same clock as the video timestamps
    /// 16      n     one Opus packet
    /// ```
    struct AudioDatagram {
        static let headerLength = 16

        let sequence: UInt32
        let timestampMicros: UInt64
        let opus: Data
    }

    /// Parse one audio UDP datagram. Returns nil for malformed datagrams
    /// (wrong magic, version, or an empty payload).
    static func parseAudioDatagram(_ data: Data) -> AudioDatagram? {
        guard data.count > AudioDatagram.headerLength,
              data[0] == 0x50, data[1] == 0x48, data[2] == 0x41, // "PHA"
              data[3] == version else {
            return nil
        }
        return AudioDatagram(
            sequence: data.readUInt32BE(at: 4),
            timestampMicros: data.readUInt64BE(at: 8),
            opus: data.subdata(in: AudioDatagram.headerLength..<data.count)
        )
    }

    /// Encode one length-prefixed control frame: 4-byte BE length including
    /// the 1-byte type, then type, then payload.
    static func encodeControlMessage(_ type: ControlMessageType, payload: Data = Data()) -> Data {
        var frame = Data(capacity: 5 + payload.count)
        frame.appendUInt32BE(UInt32(1 + payload.count))
        frame.append(type.rawValue)
        frame.append(payload)
        return frame
    }
}

/// Accumulates bytes from the TCP control stream and yields complete
/// length-prefixed frames.
struct ControlFrameParser {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [(type: ControlMessageType, payload: Data)] {
        buffer.append(data)
        var frames: [(ControlMessageType, Data)] = []
        while buffer.count >= 5 {
            let length = Int(buffer.readUInt32BE(at: 0))
            guard length >= 1, buffer.count >= 4 + length else { break }
            let type = buffer[4]
            let payload = buffer.subdata(in: 5..<(4 + length))
            buffer = buffer.subdata(in: (4 + length)..<buffer.count)
            if let messageType = ControlMessageType(rawValue: type) {
                frames.append((messageType, payload))
            }
        }
        return frames
    }
}

extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    func readUInt16BE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }

    func readUInt64BE(at offset: Int) -> UInt64 {
        UInt64(readUInt32BE(at: offset)) << 32 | UInt64(readUInt32BE(at: offset + 4))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        appendUInt32BE(UInt32(truncatingIfNeeded: value >> 32))
        appendUInt32BE(UInt32(truncatingIfNeeded: value))
    }
}
