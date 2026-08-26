import Foundation

/// Estimates the agent pipeline clock minus the client clock from pong
/// samples (docs/protocol.md "ping"), so a datagram timestamp can be mapped
/// onto the client timeline: client time = agent time - offset.
///
/// The offset in use comes from the lowest-RTT sample in a sliding window
/// of the last 60 pongs rather than an all-time minimum. Both clocks are
/// monotonic but they drift apart by tens of ppm, which is a few
/// milliseconds per hour; an all-time minimum would pin the offset to a
/// sample from the start of the session and every latency figure would
/// creep upward with that drift. Sixty samples is about a minute at the
/// steady one-pong-per-second rate.
struct ClockOffset {
    struct Sample {
        let rttMicros: UInt64
        /// agent timestamp minus estimated client timestamp at the agent.
        let offsetMicros: Int64
    }

    static let windowSize = 60

    private var samples: [Sample] = []

    /// Offset of the lowest-RTT sample in the window; nil until the first
    /// pong (an agent that predates ping never produces one).
    var offsetMicros: Int64? {
        samples.min { $0.rttMicros < $1.rttMicros }?.offsetMicros
    }

    /// RTT of the most recent pong, for the stats line.
    var latestRttMicros: UInt64? {
        samples.last?.rttMicros
    }

    /// Record one pong. `receivedMicros` is the client clock when the pong
    /// was parsed, stamped before any queue hop so decode work in flight
    /// does not inflate the RTT.
    mutating func addPong(_ pong: Pong, receivedMicros: UInt64) {
        guard receivedMicros >= pong.clientTimestampMicros else { return }
        let rtt = receivedMicros - pong.clientTimestampMicros
        let clientAtAgent = Int64(pong.clientTimestampMicros) + Int64(rtt / 2)
        let offset = Int64(pong.agentTimestampMicros) - clientAtAgent
        samples.append(Sample(rttMicros: rtt, offsetMicros: offset))
        if samples.count > Self.windowSize {
            samples.removeFirst(samples.count - Self.windowSize)
        }
    }

    /// Map an agent capture timestamp onto the client clock. Nil until the
    /// offset is known.
    func clientMicros(forAgentMicros agentMicros: UInt64) -> Int64? {
        offsetMicros.map { Int64(agentMicros) - $0 }
    }

    mutating func reset() {
        samples.removeAll()
    }
}
