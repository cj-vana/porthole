import Foundation

/// The per-second figures StreamSession publishes for the session chrome
/// and the US-013 stats HUD. Optionals are unknown values: no pong yet
/// (older agent, or the first second of a session) leaves every
/// offset-based field nil, and agent-side figures wait for agent_stats.
struct LatencyStats: Equatable {
    /// Capture on the agent to pixels presented on this display.
    var capturePresentMs: Double?
    var rttMs: Double?
    /// Frames decoded in the last second.
    var decodedFps: Int?
    /// Mean decode wall time over the last second.
    var decodeMs: Double?
    /// Agent-side mean from frame submit to access unit ready.
    var encodeMs: Double?
    /// Frames lost as a share of frames seen, over the last second.
    var lossPercent: Double?

    /// One-way network estimate: half the control round trip.
    var networkMs: Double? {
        rttMs.map { $0 / 2 }
    }

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

/// Metal callbacks arrive on driver-owned threads. Accumulate their timing
/// inline and drain one batch per stats window instead of enqueuing two jobs
/// per frame onto the serial decode queue that the telemetry is measuring.
final class RenderTelemetry {
    struct Batch {
        var rendered = 0
        var presented = 0
        var captureToPresented = StatsWindow.Average()
        var captureToRendered = StatsWindow.Average()
        var submitToRendered = StatsWindow.Average()
        var decodedToDraw = StatsWindow.Average()
        var drawToPresented = StatsWindow.Average()
        var submitToPresented = StatsWindow.Average()
        var renderCadence = StatsWindow.Cadence()
        var presentationCadence = StatsWindow.Cadence()
    }

    private let lock = NSLock()
    private var batch = Batch()

    func recordPresented(_ timing: MetalRenderer.PresentationTiming) {
        lock.lock()
        batch.presented += 1
        batch.presentationCadence.observe(timing.presentedMicros)
        if let captureClientMicros = timing.captureClientMicros {
            batch.captureToPresented.add(
                Int64(timing.presentedMicros) - Int64(captureClientMicros)
            )
        }
        batch.decodedToDraw.add(Int64(timing.drawStartedMicros) - Int64(timing.decodedMicros))
        batch.drawToPresented.add(
            Int64(timing.presentedMicros) - Int64(timing.drawStartedMicros)
        )
        batch.submitToPresented.add(
            Int64(timing.presentedMicros) - Int64(timing.submittedMicros)
        )
        lock.unlock()
    }

    func recordRendered(_ timing: MetalRenderer.RenderCompletionTiming) {
        lock.lock()
        batch.rendered += 1
        batch.renderCadence.observe(timing.completedMicros)
        if let captureClientMicros = timing.captureClientMicros {
            batch.captureToRendered.add(
                Int64(timing.completedMicros) - Int64(captureClientMicros)
            )
        }
        batch.submitToRendered.add(
            Int64(timing.completedMicros) - Int64(timing.submittedMicros)
        )
        lock.unlock()
    }

    func drain() -> Batch {
        lock.lock()
        let drained = batch
        batch = Batch()
        lock.unlock()
        return drained
    }

    func reset() {
        lock.lock()
        batch = Batch()
        lock.unlock()
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

    /// Per-second timestamp cadence. Standard deviation identifies micro-
    /// stutter even when a source still averages exactly 144 frames/second;
    /// the maximum gap distinguishes one long stall from steady noise.
    struct Cadence {
        private var previousMicros: UInt64?
        private var sumMicros = 0.0
        private var squaredMicros = 0.0
        private var samples = 0
        private(set) var maxMilliseconds: Double?

        mutating func observe(_ timestampMicros: UInt64) {
            guard let previousMicros else {
                self.previousMicros = timestampMicros
                return
            }
            guard timestampMicros >= previousMicros else { return }
            self.previousMicros = timestampMicros
            let interval = Double(timestampMicros - previousMicros)
            sumMicros += interval
            squaredMicros += interval * interval
            samples += 1
            let milliseconds = interval / 1000
            maxMilliseconds = max(maxMilliseconds ?? milliseconds, milliseconds)
        }

        var jitterMilliseconds: Double? {
            guard samples > 0 else { return nil }
            let mean = sumMicros / Double(samples)
            let variance = max(0, squaredMicros / Double(samples) - mean * mean)
            return variance.squareRoot() / 1000
        }
    }

    var decoded = 0
    /// Distinct video frames whose Metal command buffers completed.
    var rendered = 0
    var presented = 0
    var decodeMilliseconds = 0.0
    var prepareMilliseconds = 0.0
    var completed = 0
    var lost: UInt64 = 0
    var captureToArrival = Average()
    var captureToDecoded = Average()
    var captureToPresented = Average()
    var captureToRendered = Average()
    var submitToRendered = Average()
    var decodedToDraw = Average()
    var drawToPresented = Average()
    var submitToPresented = Average()
    var captureCadence = Cadence()
    var arrivalCadence = Cadence()
    var decodeCadence = Cadence()
    var renderCadence = Cadence()
    var presentationCadence = Cadence()

    var averageDecodeMs: Double {
        decoded > 0 ? decodeMilliseconds / Double(decoded) : 0
    }

    var lossPercent: Double {
        let total = UInt64(completed) + lost
        return total > 0 ? Double(lost) / Double(total) * 100 : 0
    }

    mutating func apply(_ telemetry: RenderTelemetry.Batch) {
        rendered = telemetry.rendered
        presented = telemetry.presented
        captureToPresented = telemetry.captureToPresented
        captureToRendered = telemetry.captureToRendered
        submitToRendered = telemetry.submitToRendered
        decodedToDraw = telemetry.decodedToDraw
        drawToPresented = telemetry.drawToPresented
        submitToPresented = telemetry.submitToPresented
        renderCadence = telemetry.renderCadence
        presentationCadence = telemetry.presentationCadence
    }

    /// The stats line written to os_log and /tmp/porthole-mac-stats.log.
    /// `rttMicros` and `agentStats` are the latest received rather than this
    /// window's: the agent's once-per-second timer is not phase-locked to
    /// ours, so a window can see zero or two of them. Both print n/a until
    /// the agent has supplied one. `audio` is the player's own per-second
    /// window (US-009); all zeros until audio packets flow.
    func line(rttMicros: UInt64?, agentStats: AgentStats?, queueDepth: Int, audio: AudioPlayer.Stats) -> String {
        func ms(_ value: Double?, _ digits: Int) -> String {
            value.map { String(format: "%.\(digits)f", $0) } ?? "n/a"
        }
        let rttMs = rttMicros.map { Double($0) / 1000 }
        let encodeMs = agentStats.map { Double($0.encodeLatencyMicros) / 1000 }
        let agentFps = agentStats.map { "\($0.captureFps)/\($0.encodeFps)" } ?? "n/a"
        let txKbps = agentStats.map { String($0.txKbps) } ?? "n/a"
        return "stats fps=\(decoded)"
            + " gpu_fps=\(rendered)"
            + " present_fps=\(presented)"
            + " prep_ms=\(ms(decoded > 0 ? prepareMilliseconds / Double(decoded) : nil, 2))"
            + " decode_ms=\(ms(averageDecodeMs, 2))"
            + " rtt_ms=\(ms(rttMs, 2))"
            + " enc_ms=\(ms(encodeMs, 2))"
            + " cap_arrive_ms=\(ms(captureToArrival.milliseconds, 1))"
            + " cap_decoded_ms=\(ms(captureToDecoded.milliseconds, 1))"
            + " cap_present_ms=\(ms(captureToPresented.milliseconds, 1))"
            + " cap_gpu_ms=\(ms(captureToRendered.milliseconds, 1))"
            + " decoded_draw_ms=\(ms(decodedToDraw.milliseconds, 2))"
            + " draw_present_ms=\(ms(drawToPresented.milliseconds, 2))"
            + " submit_present_ms=\(ms(submitToPresented.milliseconds, 2))"
            + " submit_gpu_ms=\(ms(submitToRendered.milliseconds, 2))"
            + " jitter_ms=\(ms(captureCadence.jitterMilliseconds, 2))/"
            + "\(ms(arrivalCadence.jitterMilliseconds, 2))/"
            + "\(ms(decodeCadence.jitterMilliseconds, 2))/"
            + "\(ms(renderCadence.jitterMilliseconds, 2))/"
            + "\(ms(presentationCadence.jitterMilliseconds, 2))"
            + " max_gap_ms=\(ms(captureCadence.maxMilliseconds, 1))/"
            + "\(ms(arrivalCadence.maxMilliseconds, 1))/"
            + "\(ms(decodeCadence.maxMilliseconds, 1))/"
            + "\(ms(renderCadence.maxMilliseconds, 1))/"
            + "\(ms(presentationCadence.maxMilliseconds, 1))"
            + " loss=\(ms(lossPercent, 2))%"
            + " queue=\(queueDepth)"
            + " agent_fps=\(agentFps)"
            + " tx_kbps=\(txKbps)"
            + " audio_buf_ms=\(audio.bufferedMs)"
            + " audio_pkts=\(audio.packets)"
            + " audio_lost=\(audio.lost)"
            + " audio_drop_ms=\(audio.droppedMs)"
            + " audio_underrun=\(audio.underruns)"
    }

    /// The published per-second figures (header summary and stats HUD).
    /// Optionals follow the same rule as `line`: n/a until a source has
    /// reported.
    func snapshot(rttMicros: UInt64?, agentStats: AgentStats?) -> LatencyStats {
        LatencyStats(capturePresentMs: captureToPresented.milliseconds,
                     rttMs: rttMicros.map { Double($0) / 1000 },
                     decodedFps: decoded,
                     decodeMs: decoded > 0 ? averageDecodeMs : nil,
                     encodeMs: agentStats.map { Double($0.encodeLatencyMicros) / 1000 },
                     lossPercent: UInt64(completed) + lost > 0 ? lossPercent : nil)
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
        try? handle?.truncate(atOffset: 0)
        try? handle?.seek(toOffset: 0)
    }

    func append(_ line: String) {
        try? handle?.write(contentsOf: Data("\(formatter.string(from: Date())) \(line)\n".utf8))
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}
