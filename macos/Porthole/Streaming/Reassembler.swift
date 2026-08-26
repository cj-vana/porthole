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
    }

    private struct RepairShard {
        let finalFragmentBytes: Int
        let parity: Data
    }

    private let logger = Logger(subsystem: "com.porthole.mac", category: "video")
    private var partials: [UInt64: PartialFrame] = [:]
    private var highestCompleted: UInt64?
    private var lastSweep = ContinuousClock.now

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
                                 repair: nil)
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
            partial.repair = RepairShard(
                finalFragmentBytes: finalFragmentBytes,
                parity: Data(bytes: baseAddress.advanced(by: Self.repairPrefixBytes),
                             count: parityBytes)
            )
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

        if let missing = Self.recoverSingleMissingFragment(in: &partial) {
            logger.info("recovered frame \(header.frameSequence) fragment \(missing) without retransmission")
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

    private static func append(_ bytes: UnsafeRawBufferPointer, to data: inout Data) {
        guard let baseAddress = bytes.baseAddress else { return }
        data.append(baseAddress.assumingMemoryBound(to: UInt8.self), count: bytes.count)
    }

    /// Recreate one missing data fragment from the XOR repair shard. Ordered
    /// LAN traffic makes `nextFragment` the first missing index; every later
    /// fragment already lives in `outOfOrder`, so no fragment table or extra
    /// copy is needed on the loss-free hot path.
    private static func recoverSingleMissingFragment(in partial: inout PartialFrame) -> Int? {
        guard let repair = partial.repair,
              partial.nextFragment + partial.outOfOrder.count + 1 == partial.fragmentCount else {
            return nil
        }
        let missing = partial.nextFragment
        let shardBytes = repair.parity.count
        guard shardBytes > 0,
              partial.data.count == missing * shardBytes else {
            return nil
        }
        for (index, fragment) in partial.outOfOrder {
            let expected = index + 1 == partial.fragmentCount
                ? repair.finalFragmentBytes
                : shardBytes
            guard fragment.count == expected else { return nil }
        }

        var recovered = repair.parity
        recovered.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            partial.data.withUnsafeBytes { received in
                for offset in received.indices {
                    output[offset % shardBytes] ^= received[offset]
                }
            }
            for fragment in partial.outOfOrder.values {
                fragment.withUnsafeBytes { received in
                    for offset in received.indices {
                        output[offset] ^= received[offset]
                    }
                }
            }
        }
        let recoveredBytes = missing + 1 == partial.fragmentCount
            ? repair.finalFragmentBytes
            : shardBytes
        guard recoveredBytes <= Self.maxAccessUnitBytes - partial.bufferedBytes else {
            return nil
        }
        recovered.count = recoveredBytes
        partial.bufferedBytes += recoveredBytes
        partial.data.append(recovered)
        partial.nextFragment += 1
        while let queued = partial.outOfOrder.removeValue(forKey: partial.nextFragment) {
            partial.data.append(queued)
            partial.nextFragment += 1
        }
        partial.repair = nil
        return missing
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
