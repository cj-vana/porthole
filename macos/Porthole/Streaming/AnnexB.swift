import Foundation

/// H.264 Annex B byte-stream helpers: start-code splitting, access unit
/// grouping (AUD-delimited, the agent encodes with `-aud 1`), and conversion
/// to the length-prefixed (AVCC) form VideoToolbox expects in sample buffers.
enum AnnexB {
    enum NALType: UInt8 {
        case sliceNonIDR = 1
        case sliceIDR = 5
        case sei = 6
        case sps = 7
        case pps = 8
        case aud = 9
    }

    /// One NAL unit located inside a larger buffer, start code excluded.
    struct NALUnit {
        let type: UInt8
        let range: Range<Int>
    }

    /// Locate all NAL units in `data` (byte ranges relative to `data`,
    /// start codes excluded). Handles 3-byte and 4-byte start codes.
    static func locateNALUnits(in data: Data) -> [NALUnit] {
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
                units.append(NALUnit(type: raw[payloadStart] & 0x1F,
                                     range: payloadStart..<payloadEnd))
            }
            return units
        }
    }

    /// NAL payloads (start codes stripped) of one access unit or stream chunk.
    static func nalPayloads(in data: Data) -> [(type: UInt8, payload: Data)] {
        locateNALUnits(in: data).map { ($0.type, data.subdata(in: $0.range)) }
    }

    /// Does this access unit contain an IDR slice (NAL type 5)?
    static func containsIDR(_ accessUnit: Data) -> Bool {
        locateNALUnits(in: accessUnit).contains { $0.type == NALType.sliceIDR.rawValue }
    }

    /// Group a whole Annex B elementary stream into access units using AUD
    /// NALs (type 9) as delimiters. The AUD belongs to the AU it opens.
    /// Streams without AUDs come back as a single AU; the agent encodes with
    /// `-aud 1`, so its dumps always carry delimiters.
    static func accessUnits(in stream: Data) -> [Data] {
        let units = locateNALUnits(in: stream)
        var result: [Data] = []
        var auStart: Int?
        for unit in units {
            if unit.type == NALType.aud.rawValue, let open = auStart {
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
    /// VideoToolbox: [4-byte BE length][NAL]... AUD NALs are dropped; SPS and
    /// PPS stay (the decoder tolerates them in-band).
    static func avccPayload(fromAccessUnit accessUnit: Data) -> Data {
        var output = Data()
        for nal in nalPayloads(in: accessUnit) where nal.type != NALType.aud.rawValue {
            output.appendUInt32BE(UInt32(nal.payload.count))
            output.append(nal.payload)
        }
        return output
    }
}
