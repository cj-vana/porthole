import Foundation

/// The per-second latency figures StreamSession publishes for the session
/// chrome. Optionals are unknown values: no pong yet (older agent, or the
/// first second of a session) leaves every offset-based field nil.
struct LatencyStats: Equatable {
    /// Capture on the agent to pixels presented on this display.
    var capturePresentMs: Double?
    var rttMs: Double?

    static let empty = LatencyStats()

    /// One-line readout for the header, safe when nothing is known yet.
    var summary: String {
        var parts: [String] = []
        if let capturePresentMs {
            parts.append(String(format: "%.0f ms to glass", capturePresentMs))
        }
        if let rttMs {
            parts.append(String(format: "rtt %.1f ms", rttMs))
        }
        return parts.isEmpty ? "latency n/a" : parts.joined(separator: ", ")
    }
}

/// One second of session counters. StreamSession mutates it on the decode
/// queue and calls `line` from the stats timer, then `reset`.
struct StatsWindow {
    /// Sum and count of a per-frame latency, averaged when the second ends.
    struct Average {
        private var sumMicros: Int64 = 0
        private var samples = 0

        mutating func add(_ micros: Int64) {
            sumMicros += micros
            samples += 1
        }

        var milliseconds: Double? {
            samples > 0 ? Double(sumMicros) / Double(samples) / 1000 : nil
        }
    }

    var decoded = 0
    var decodeMilliseconds = 0.0
    var completed = 0
    var lost: UInt64 = 0
    var captureToArrival = Average()
    var captureToDecoded = Average()
    var captureToPresented = Average()

    var averageDecodeMs: Double {
        decoded > 0 ? decodeMilliseconds / Double(decoded) : 0
    }

    var lossPercent: Double {
        let total = UInt64(completed) + lost
        return total > 0 ? Double(lost) / Double(total) * 100 : 0
    }

    /// The stats line written to os_log and /tmp/porthole-mac-stats.log.
    /// `rttMicros` and `agentStats` are the latest received rather than this
    /// window's: the agent's once-per-second timer is not phase-locked to
    /// ours, so a window can see zero or two of them. Both print n/a until
    /// the agent has supplied one.
    func line(rttMicros: UInt64?, agentStats: AgentStats?, queueDepth: Int) -> String {
        func ms(_ value: Double?, _ digits: Int) -> String {
            value.map { String(format: "%.\(digits)f", $0) } ?? "n/a"
        }
        let rttMs = rttMicros.map { Double($0) / 1000 }
        let encodeMs = agentStats.map { Double($0.encodeLatencyMicros) / 1000 }
        let agentFps = agentStats.map { "\($0.captureFps)/\($0.encodeFps)" } ?? "n/a"
        let txKbps = agentStats.map { String($0.txKbps) } ?? "n/a"
        return "stats fps=\(decoded)"
            + " decode_ms=\(ms(averageDecodeMs, 2))"
            + " rtt_ms=\(ms(rttMs, 2))"
            + " enc_ms=\(ms(encodeMs, 2))"
            + " cap_arrive_ms=\(ms(captureToArrival.milliseconds, 1))"
            + " cap_decoded_ms=\(ms(captureToDecoded.milliseconds, 1))"
            + " cap_present_ms=\(ms(captureToPresented.milliseconds, 1))"
            + " loss=\(ms(lossPercent, 2))%"
            + " queue=\(queueDepth)"
            + " agent_fps=\(agentFps)"
            + " tx_kbps=\(txKbps)"
    }

    mutating func reset() {
        self = StatsWindow()
    }
}

/// Append-only copy of the stats lines at /tmp/porthole-mac-stats.log,
/// truncated on each connect. `open` and `close` run on the main queue,
/// `append` on the decode queue, matching the session's stats timer.
final class StatsLog {
    private let url = URL(fileURLWithPath: "/tmp/porthole-mac-stats.log")
    private let formatter = ISO8601DateFormatter()
    private var handle: FileHandle?

    func open() {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func append(_ line: String) {
        try? handle?.write(contentsOf: Data("\(formatter.string(from: Date())) \(line)\n".utf8))
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}
