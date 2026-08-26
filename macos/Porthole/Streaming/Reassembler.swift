import Foundation
import os

/// Reassembles fragmented access units from video datagrams, applying the
/// receiver rules from docs/protocol.md: a frame is decodable only when all
/// fragments are present, stale partial frames are dropped (loss), and a gap
/// in completed frame sequences means whole frames were lost.
final class Reassembler {
    /// Matches the agent's encoded-frame ceiling. Besides rejecting corrupt
    /// bookkeeping, this prevents one spoofed UDP header from reserving an
    /// unbounded access-unit buffer.
    private static let maxAccessUnitBytes = 16 * 1024 * 1024
    private static let repairPrefixBytes = 2

    struct AccessUnit {
        let sequence: UInt64
        let timestampMicros: UInt64
        let isKeyframe: Bool
        /// Compressed bytes, fragments concatenated in order.
        let data: Data
        let sampleFormat: AnnexB.SampleFormat
    }

    enum Event {
        case completed(AccessUnit)
        /// Whole frames were lost (gap) or a partial frame went stale.
        case loss(frameCount: UInt64)
    }

    /// Partial frames older than this are swept and counted as lost.
    var staleTimeout: Duration = .milliseconds(500)

    private struct PartialFrame {
        let fragmentCount: Int
        let timestampMicros: UInt64
        let isKeyframe: Bool
        let firstSeen: ContinuousClock.Instant
        /// Normal LAN delivery is ordered, so bytes append once into their
        /// final allocation. Only genuinely early fragments need a temporary
        /// `Data` while their predecessor is missing.
        var data: Data
        var nextFragment: Int
        var outOfOrder: [Int: Data]
        var bufferedBytes: Int
        var repair: RepairShard?
        var secondaryRepair: RepairShard?
    }

    private struct RepairShard {
        let finalFragmentBytes: Int
        let parity: Data
    }

    private let logger = Logger(subsystem: "com.porthole.mac", category: "video")
    private var partials: [UInt64: PartialFrame] = [:]
    private var highestCompleted: UInt64?
    private var lastSweep = ContinuousClock.now

    // The ordered append, repair, completion, and CoW lifetime deliberately
    // share one scope so the receive hot path never copies its growing Data.
    // swiftlint:disable cyclomatic_complexity function_body_length
    /// Feed one datagram. Returns completion/loss events in arrival order.
    func ingest(header: WireProtocol.DatagramHeader,
                payload: UnsafeRawBufferPointer) -> [Event] {
        var events: [Event] = []

        // Data can complete before its trailing repair datagram arrives.
        // Ignore that now-redundant shard instead of creating a stale partial
        // frame that would later be misreported as packet loss.
        if header.isRepair, let highestCompleted, header.frameSequence <= highestCompleted {
            return sweepStale()
        }

        var frame = partials[header.frameSequence]
        if frame == nil {
            frame = PartialFrame(fragmentCount: Int(header.fragmentCount),
                                 timestampMicros: header.timestampMicros,
                                 isKeyframe: header.isKeyframe,
                                 firstSeen: ContinuousClock.now,
                                 data: Data(capacity: min(Self.maxAccessUnitBytes,
                                                         payload.count * Int(header.fragmentCount))),
                                 nextFragment: 0,
                                 outOfOrder: [:],
                                 bufferedBytes: 0,
                                 repair: nil,
                                 secondaryRepair: nil)
        }
        guard var partial = frame,
              partial.fragmentCount == Int(header.fragmentCount),
              partial.timestampMicros == header.timestampMicros,
              partial.isKeyframe == header.isKeyframe else {
            // Conflicting bookkeeping for the same sequence: corrupt; drop it
            // and count the frame as lost rather than decode garbage.
            partials.removeValue(forKey: header.frameSequence)
            events.append(.loss(frameCount: 1))
            return events
        }
        // `frame` and the dictionary entry otherwise keep CoW references to
        // the same Data while the completed buffer is rewritten in place.
        frame = nil

        if header.isRepair {
            guard payload.count > Self.repairPrefixBytes,
                  let baseAddress = payload.baseAddress else {
                partials.removeValue(forKey: header.frameSequence)
                events.append(.loss(frameCount: 1))
                return events
            }
            let finalFragmentBytes = Int(payload[0]) << 8 | Int(payload[1])
            let parityBytes = payload.count - Self.repairPrefixBytes
            guard finalFragmentBytes > 0, finalFragmentBytes <= parityBytes else {
                partials.removeValue(forKey: header.frameSequence)
                events.append(.loss(frameCount: 1))
                return events
            }
            let repair = RepairShard(
                finalFragmentBytes: finalFragmentBytes,
                parity: Data(bytes: baseAddress.advanced(by: Self.repairPrefixBytes),
                             count: parityBytes)
            )
            if header.isSecondaryRepair {
                partial.secondaryRepair = repair
            } else {
                partial.repair = repair
            }
        } else {
            let index = Int(header.fragmentIndex)
            let duplicate = index < partial.nextFragment || partial.outOfOrder[index] != nil
            if !duplicate {
                guard payload.count <= Self.maxAccessUnitBytes - partial.bufferedBytes else {
                    partials.removeValue(forKey: header.frameSequence)
                    events.append(.loss(frameCount: 1))
                    return events
                }
                partial.bufferedBytes += payload.count
                if index == partial.nextFragment {
                    Self.append(payload, to: &partial.data)
                    partial.nextFragment += 1
                    while let queued = partial.outOfOrder.removeValue(forKey: partial.nextFragment) {
                        partial.data.append(queued)
                        partial.nextFragment += 1
                    }
                } else {
                    partial.outOfOrder[index] = Data(payload)
                }
            }
        }

        if let recovered = Self.recoverMissingFragments(in: &partial) {
            logger.info("recovered frame \(header.frameSequence) fragments \(recovered) without retransmission")
        }

        if partial.nextFragment == partial.fragmentCount {
            partials.removeValue(forKey: header.frameSequence)
            let sampleFormat: AnnexB.SampleFormat =
                AnnexB.rewriteFourByteStartCodesAsLengths(in: &partial.data)
                    ? .lengthPrefixed
                    : .annexB
            let sequence = header.frameSequence
            if let highest = highestCompleted, sequence > highest + 1 {
                events.append(.loss(frameCount: sequence - highest - 1))
            }
            highestCompleted = max(highestCompleted ?? 0, sequence)
            events.append(.completed(AccessUnit(sequence: sequence,
                                                timestampMicros: partial.timestampMicros,
                                                isKeyframe: partial.isKeyframe,
                                                data: partial.data,
                                                sampleFormat: sampleFormat)))
        } else {
            partials[header.frameSequence] = partial
        }

        events.append(contentsOf: sweepStale())
        return events
    }
    // swiftlint:enable cyclomatic_complexity function_body_length

    private static func append(_ bytes: UnsafeRawBufferPointer, to data: inout Data) {
        guard let baseAddress = bytes.baseAddress else { return }
        data.append(baseAddress.assumingMemoryBound(to: UInt8.self), count: bytes.count)
    }

    // Keeping the one-loss and two-loss equations adjacent makes their
    // coefficient ordering auditable against docs/protocol.md.
    // swiftlint:disable function_body_length
    /// Recreate one or two missing data fragments from the trailing parity
    /// shards. Ordered LAN traffic still appends directly on the loss-free
    /// path; all field arithmetic and temporary buffers are loss-only work.
    private static func recoverMissingFragments(in partial: inout PartialFrame) -> [Int]? {
        var missing: [Int] = []
        for index in partial.nextFragment..<partial.fragmentCount
        where partial.outOfOrder[index] == nil {
            missing.append(index)
            if missing.count > 2 { return nil }
        }
        guard !missing.isEmpty else { return nil }

        let recovered: [(Int, Data)]?
        let finalFragmentBytes: Int
        if missing.count == 1, let repair = partial.repair {
            finalFragmentBytes = repair.finalFragmentBytes
            recovered = residualParity(in: partial, repair: repair, weighted: false)
                .map { [(missing[0], $0)] }
        } else if missing.count == 1, let repair = partial.secondaryRepair,
                  let inverse = gfInverse(UInt16(missing[0] + 1)) {
            finalFragmentBytes = repair.finalFragmentBytes
            recovered = residualParity(in: partial, repair: repair, weighted: true)
                .map { [(missing[0], scaled($0, by: inverse))] }
        } else if missing.count == 2,
                  let primary = partial.repair,
                  let secondary = partial.secondaryRepair,
                  primary.finalFragmentBytes == secondary.finalFragmentBytes,
                  primary.parity.count == secondary.parity.count,
                  let primaryResidual = residualParity(in: partial,
                                                       repair: primary,
                                                       weighted: false),
                  var secondaryResidual = residualParity(in: partial,
                                                         repair: secondary,
                                                         weighted: true),
                  let inverse = gfInverse(UInt16(missing[0] + 1) ^ UInt16(missing[1] + 1)) {
            finalFragmentBytes = primary.finalFragmentBytes
            xorScaled(&secondaryResidual, primaryResidual, by: UInt16(missing[1] + 1))
            let first = scaled(secondaryResidual, by: inverse)
            var second = primaryResidual
            xor(&second, first)
            recovered = [(missing[0], first), (missing[1], second)]
        } else {
            return nil
        }

        guard let recovered else { return nil }
        var recoveredIndices: [Int] = []
        for (index, padded) in recovered {
            let byteCount = expectedFragmentBytes(index: index,
                                                  fragmentCount: partial.fragmentCount,
                                                  shardBytes: padded.count,
                                                  finalFragmentBytes: finalFragmentBytes)
            guard byteCount <= Self.maxAccessUnitBytes - partial.bufferedBytes else {
                return nil
            }
            var fragment = padded
            fragment.count = byteCount
            partial.bufferedBytes += byteCount
            partial.outOfOrder[index] = fragment
            recoveredIndices.append(index)
        }
        while let queued = partial.outOfOrder.removeValue(forKey: partial.nextFragment) {
            partial.data.append(queued)
            partial.nextFragment += 1
        }
        partial.repair = nil
        partial.secondaryRepair = nil
        return recoveredIndices
    }
    // swiftlint:enable function_body_length

    private static func residualParity(in partial: PartialFrame,
                                       repair: RepairShard,
                                       weighted: Bool) -> Data? {
        let shardBytes = repair.parity.count
        guard shardBytes > 0,
              partial.data.count == partial.nextFragment * shardBytes else {
            return nil
        }
        var residual = repair.parity
        for index in 0..<partial.nextFragment {
            let start = index * shardBytes
            let fragment = partial.data.subdata(in: start..<(start + shardBytes))
            if weighted {
                xorScaled(&residual, fragment, by: UInt16(index + 1))
            } else {
                xor(&residual, fragment)
            }
        }
        for (index, fragment) in partial.outOfOrder {
            let expected = expectedFragmentBytes(index: index,
                                                 fragmentCount: partial.fragmentCount,
                                                 shardBytes: shardBytes,
                                                 finalFragmentBytes: repair.finalFragmentBytes)
            guard fragment.count == expected else { return nil }
            if weighted {
                xorScaled(&residual, fragment, by: UInt16(index + 1))
            } else {
                xor(&residual, fragment)
            }
        }
        return residual
    }

    private static func expectedFragmentBytes(index: Int,
                                              fragmentCount: Int,
                                              shardBytes: Int,
                                              finalFragmentBytes: Int) -> Int {
        index + 1 == fragmentCount ? finalFragmentBytes : shardBytes
    }

    private static func xor(_ output: inout Data, _ input: Data) {
        output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
            input.withUnsafeBytes { source in
                for offset in source.indices {
                    destination[offset] ^= source[offset]
                }
            }
        }
    }

    private static func xorScaled(_ output: inout Data, _ input: Data, by coefficient: UInt16) {
        output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
            input.withUnsafeBytes { source in
                for offset in stride(from: 0, to: source.count, by: 2) {
                    let low = offset + 1 < source.count ? source[offset + 1] : 0
                    let symbol = UInt16(source[offset]) << 8 | UInt16(low)
                    let coded = gfMultiply(coefficient, symbol)
                    destination[offset] ^= UInt8(truncatingIfNeeded: coded >> 8)
                    if offset + 1 < destination.count {
                        destination[offset + 1] ^= UInt8(truncatingIfNeeded: coded)
                    }
                }
            }
        }
    }

    private static func scaled(_ input: Data, by coefficient: UInt16) -> Data {
        var output = Data(count: input.count)
        xorScaled(&output, input, by: coefficient)
        return output
    }

    /// GF(2^16), primitive polynomial x^16 + x^12 + x^3 + x + 1.
    private static func gfMultiply(_ lhs: UInt16, _ rhs: UInt16) -> UInt16 {
        var left = lhs
        var right = rhs
        var product: UInt16 = 0
        for _ in 0..<16 {
            if right & 1 != 0 { product ^= left }
            let carry = left & 0x8000 != 0
            left <<= 1
            if carry { left ^= 0x100b }
            right >>= 1
        }
        return product
    }

    private static func gfInverse(_ value: UInt16) -> UInt16? {
        guard value != 0 else { return nil }
        var base = value
        var exponent: UInt32 = 65_534
        var result: UInt16 = 1
        while exponent > 0 {
            if exponent & 1 != 0 { result = gfMultiply(result, base) }
            base = gfMultiply(base, base)
            exponent >>= 1
        }
        return result
    }

    /// Sweep partial frames older than the stale timeout. Called on ingest;
    /// also call it on a timer if ingest may stop entirely.
    func sweepStale() -> [Event] {
        let now = ContinuousClock.now
        guard now - lastSweep > .milliseconds(100) else { return [] }
        lastSweep = now
        var events: [Event] = []
        for (sequence, frame) in partials where now - frame.firstSeen > staleTimeout {
            partials.removeValue(forKey: sequence)
            events.append(.loss(frameCount: 1))
        }
        return events
    }

    func reset() {
        partials.removeAll()
        highestCompleted = nil
    }
}
