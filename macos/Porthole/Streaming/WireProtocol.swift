import Foundation

/// Porthole wire protocol v1. Spec: docs/protocol.md; reference
/// implementation: agent/src/protocol.rs. All multi-byte integers are
/// big-endian.
enum WireProtocol {
    /// TCP control channel port (agent is the server, client connects).
    static let controlPort: UInt16 = 52801
    /// Default UDP video port; the authoritative value arrives in `hello`.
    static let defaultVideoPort: UInt16 = 52800
    /// Protocol version byte in every video datagram.
    static let version: UInt8 = 1
}

/// Control message types (TCP, length-prefixed frames).
enum ControlMessageType: UInt8 {
    /// agent -> client, sent on connect. Payload is 23 bytes.
    case hello = 0x01
    /// client -> agent, empty payload. Ask for a fresh IDR.
    case keyframeRequest = 0x02
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

extension WireProtocol {
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
    /// 24      1     flags: bit 0 = access unit contains an IDR
    /// ```
    struct DatagramHeader {
        static let length = 25
        static let maxDatagramSize = 1400

        let frameSequence: UInt64
        let timestampMicros: UInt64
        let fragmentIndex: UInt16
        let fragmentCount: UInt16
        let isKeyframe: Bool
    }

    /// Parse one UDP datagram into header + payload. Returns nil for
    /// malformed datagrams (wrong magic, version, size, or fragment bounds).
    static func parseDatagram(_ data: Data) -> (header: DatagramHeader, payload: Data)? {
        guard data.count > DatagramHeader.length,
              data[0] == 0x50, data[1] == 0x48, data[2] == 0x56, // "PHV"
              data[3] == version else {
            return nil
        }
        let fragmentIndex = data.readUInt16BE(at: 20)
        let fragmentCount = data.readUInt16BE(at: 22)
        guard fragmentCount > 0, fragmentIndex < fragmentCount,
              data.count <= DatagramHeader.maxDatagramSize else {
            return nil
        }
        let header = DatagramHeader(
            frameSequence: data.readUInt64BE(at: 4),
            timestampMicros: data.readUInt64BE(at: 12),
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
            isKeyframe: data[24] & 0x01 != 0
        )
        return (header, data.subdata(in: DatagramHeader.length..<data.count))
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
}
