import Foundation

/// Annex B byte-stream helpers for H.264 and HEVC: start-code splitting,
/// access unit grouping (AUD-delimited, the agent encodes with `-aud 1`),
/// and conversion to the length-prefixed (AVCC) form VideoToolbox expects
/// in sample buffers.
enum AnnexB {
    /// Which bitstream convention the NAL header byte follows. H.264 keeps
    /// the type in the low five bits of a one-byte header; HEVC's two-byte
    /// header puts it in bits 6..1 of the first byte.
    enum Codec {
        case h264
        case hevc

        /// Access unit delimiter type (H.264 AUD is 9, HEVC AUD is 35).
        var audType: UInt8 {
            switch self {
            case .h264: return NALType.aud.rawValue
            case .hevc: return HEVCNALType.aud.rawValue
            }
        }

        func nalType(fromHeaderByte byte: UInt8) -> UInt8 {
            switch self {
            case .h264: return byte & 0x1F
            case .hevc: return (byte >> 1) & 0x3F
            }
        }
    }

    enum NALType: UInt8 {
        case sliceNonIDR = 1
        case sliceIDR = 5
        case sei = 6
        case sps = 7
        case pps = 8
        case aud = 9
    }

    /// The HEVC NAL types the client cares about (H.265 table 7-1). IRAP
    /// pictures span types 16 through 21; the agent's encoders emit 19/20
    /// as the keyframes its datagram flag marks.
    enum HEVCNALType: UInt8 {
        case idrWithRADL = 19
        case idrNoLeading = 20
        case vps = 32
        case sps = 33
        case pps = 34
        case aud = 35
    }

    /// One NAL unit located inside a larger buffer, start code excluded.
    struct NALUnit {
        let type: UInt8
        let range: Range<Int>
    }

    /// Locate all NAL units in `data` (byte ranges relative to `data`,
    /// start codes excluded). Handles 3-byte and 4-byte start codes.
    static func locateNALUnits(in data: Data, codec: Codec = .h264) -> [NALUnit] {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [NALUnit] in
            guard raw.count >= 4 else { return [] }
            let count = raw.count

            // Offset of every start code, counting an optional leading zero.
            var starts: [Int] = []
            var index = 0
            while index + 3 <= count {
                if raw[index] == 0, raw[index + 1] == 0, raw[index + 2] == 1 {
                    let start = (index > 0 && raw[index - 1] == 0) ? index - 1 : index
                    if starts.last != start {
                        starts.append(start)
                    }
                    index += 3
                } else {
                    index += 1
                }
            }

            var units: [NALUnit] = []
            for (position, start) in starts.enumerated() {
                var payloadStart = start + 3
                if payloadStart < count, raw[start] == 0, raw[start + 1] == 0,
                   raw[start + 2] == 0, raw[start + 3] == 1 {
                    payloadStart = start + 4
                }
                let payloadEnd = position + 1 < starts.count ? starts[position + 1] : count
                guard payloadStart < payloadEnd else { continue }
                units.append(NALUnit(type: codec.nalType(fromHeaderByte: raw[payloadStart]),
                                     range: payloadStart..<payloadEnd))
            }
            return units
        }
    }

    /// NAL payloads (start codes stripped) of one access unit or stream chunk.
    static func nalPayloads(in data: Data, codec: Codec = .h264) -> [(type: UInt8, payload: Data)] {
        locateNALUnits(in: data, codec: codec).map { ($0.type, data.subdata(in: $0.range)) }
    }

    /// Does this access unit contain an IDR slice (H.264 type 5; HEVC
    /// types 19 and 20)?
    static func containsIDR(_ accessUnit: Data, codec: Codec = .h264) -> Bool {
        locateNALUnits(in: accessUnit, codec: codec).contains { unit in
            switch codec {
            case .h264:
                return unit.type == NALType.sliceIDR.rawValue
            case .hevc:
                return unit.type == HEVCNALType.idrWithRADL.rawValue
                    || unit.type == HEVCNALType.idrNoLeading.rawValue
            }
        }
    }

    /// Group a whole Annex B elementary stream into access units using AUD
    /// NALs as delimiters. The AUD belongs to the AU it opens. Streams
    /// without AUDs come back as a single AU; the agent encodes with
    /// `-aud 1`, so its dumps always carry delimiters.
    static func accessUnits(in stream: Data, codec: Codec = .h264) -> [Data] {
        let units = locateNALUnits(in: stream, codec: codec)
        var result: [Data] = []
        var auStart: Int?
        for unit in units {
            if unit.type == codec.audType, let open = auStart {
                result.append(stream.subdata(in: open..<unit.range.lowerBound))
                auStart = unit.range.lowerBound
            } else if auStart == nil {
                auStart = unit.range.lowerBound
            }
        }
        if let open = auStart, open < stream.count {
            result.append(stream.subdata(in: open..<stream.count))
        }
        return result
    }

    /// Convert one Annex B access unit to length-prefixed form for
    /// VideoToolbox: [4-byte BE length][NAL]... AUD NALs are dropped;
    /// parameter sets stay (the decoder tolerates them in-band).
    static func avccPayload(fromAccessUnit accessUnit: Data, codec: Codec = .h264) -> Data {
        var output = Data()
        for nal in nalPayloads(in: accessUnit, codec: codec) where nal.type != codec.audType {
            output.appendUInt32BE(UInt32(nal.payload.count))
            output.append(nal.payload)
        }
        return output
    }
}
