import Foundation

/// Reassembles fragmented access units from video datagrams, applying the
/// receiver rules from docs/protocol.md: a frame is decodable only when all
/// fragments are present, stale partial frames are dropped (loss), and a gap
/// in completed frame sequences means whole frames were lost.
final class Reassembler {
    struct AccessUnit {
        let sequence: UInt64
        let timestampMicros: UInt64
        let isKeyframe: Bool
        /// Annex B bytes, fragments concatenated in order.
        let data: Data
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
        var fragments: [Data?]
        var received: Int
    }

    private var partials: [UInt64: PartialFrame] = [:]
    private var highestCompleted: UInt64?
    private var lastSweep = ContinuousClock.now

    /// Feed one datagram. Returns completion/loss events in arrival order.
    func ingest(header: WireProtocol.DatagramHeader, payload: Data) -> [Event] {
        var events: [Event] = []

        var frame = partials[header.frameSequence]
        if frame == nil {
            frame = PartialFrame(fragmentCount: Int(header.fragmentCount),
                                 timestampMicros: header.timestampMicros,
                                 isKeyframe: header.isKeyframe,
                                 firstSeen: ContinuousClock.now,
                                 fragments: [Data?](repeating: nil, count: Int(header.fragmentCount)),
                                 received: 0)
        }
        guard var partial = frame,
              partial.fragmentCount == Int(header.fragmentCount),
              partial.timestampMicros == header.timestampMicros else {
            // Conflicting bookkeeping for the same sequence: corrupt; drop it
            // and count the frame as lost rather than decode garbage.
            partials.removeValue(forKey: header.frameSequence)
            events.append(.loss(frameCount: 1))
            return events
        }

        let index = Int(header.fragmentIndex)
        if partial.fragments[index] == nil {
            partial.fragments[index] = payload
            partial.received += 1
        }

        if partial.received == partial.fragmentCount {
            var data = Data()
            data.reserveCapacity(partial.fragments.reduce(0) { $0 + ($1?.count ?? 0) })
            for fragment in partial.fragments {
                if let fragment { data.append(fragment) }
            }
            partials.removeValue(forKey: header.frameSequence)
            let sequence = header.frameSequence
            if let highest = highestCompleted, sequence > highest + 1 {
                events.append(.loss(frameCount: sequence - highest - 1))
            }
            highestCompleted = max(highestCompleted ?? 0, sequence)
            events.append(.completed(AccessUnit(sequence: sequence,
                                                timestampMicros: partial.timestampMicros,
                                                isKeyframe: partial.isKeyframe,
                                                data: data)))
        } else {
            partials[header.frameSequence] = partial
        }

        events.append(contentsOf: sweepStale())
        return events
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
