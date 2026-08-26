import Combine
import CoreGraphics
import CoreVideo
import Foundation
import os

/// Owns one streaming session: TCP control channel, UDP video receiver,
/// fragment reassembly, hardware decode, and handoff of decoded frames to
/// the Metal renderer. One instance lives for the app's lifetime; connect
/// and disconnect drive its lifecycle.
///
/// Threading: NW callbacks arrive on the control/video queues; everything
/// session-stateful (reassembly, decode, stats counters) runs on the serial
/// decode queue. Published properties are set on the main queue.
final class StreamSession: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case waitingForKeyframe
        case live(width: Int, height: Int, fps: Int)
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var lastError: String?
    /// True while the surface holds focus and input flows (US-006).
    @Published private(set) var inputCaptured = false
    /// True while pointer lock (relative mouse mode) is engaged.
    @Published private(set) var pointerLockActive = false

    /// The surface's renderer; decoded frames replace the test pattern.
    let renderer = MetalRenderer()
    /// Keyboard/mouse/scroll translation and wire encoding (US-006).
    let input = InputController()

    private let control = ControlChannel()
    private let video = VideoReceiver()
    private let decoder = H264Decoder()
    private var reassembler = Reassembler()
    private let decodeQueue = DispatchQueue(label: "porthole.decode")
    private let logger = Logger(subsystem: "com.porthole.mac", category: "session")

    private var hello: Hello?
    private var needsKeyframe = true
    /// Sequence of the access unit currently inside decode(); valid because
    /// the decode queue is serial and decoding is synchronous.
    private var decodingSequence: UInt64?
    private var highestSubmittedSequence: UInt64?
    private var consecutiveEmptySeconds = 0

    /// Access units received but not yet decoded; bounded to apply
    /// backpressure (a full queue means we are falling behind, which is
    /// decode-fatal for predictive video: drop and resync on a keyframe).
    private var pendingDecodes = 0
    private let pendingLock = NSLock()
    private let maxPendingDecodes = 8

    // Per-second stats counters, mutated only on the decode queue.
    private var decodedThisSecond = 0
    private var decodeMillisecondsThisSecond = 0.0
    private var completedThisSecond = 0
    private var lostThisSecond: UInt64 = 0

    private var statsTimer: DispatchSourceTimer?
    private var statsLogHandle: FileHandle?
    private let statsLogURL = URL(fileURLWithPath: "/tmp/porthole-mac-stats.log")

    var isConnected: Bool {
        state != .disconnected
    }

    // MARK: Lifecycle

    /// Set at connect() so the first decoded frame can report the
    /// click-to-first-frame latency (US-007 target: under 3 s on LAN).
    private var connectStartedAt: Date?

    /// Remaining address candidates for the in-flight dial (US-007): mDNS
    /// LAN addresses are tried first, then the bare host name fallback
    /// (MagicDNS/Tailscale). Each candidate gets dialTimeoutSeconds before
    /// the next is tried.
    private var dialCandidates: [(host: String, port: UInt16)] = []
    private var dialTimeout: DispatchWorkItem?
    private let dialTimeoutSeconds: Double = 1.0

    /// Connect to a picker machine, walking its address candidates.
    func connect(machine: Machine) {
        connectStartedAt = Date() // the fallback re-dial must not reset this
        let candidates = machine.addressCandidates.isEmpty ? [machine.host] : machine.addressCandidates
        dialCandidates = candidates.map { ($0, machine.controlPort) }
        guard let first = dialCandidates.first else { return }
        dialCandidates.removeFirst()
        connect(host: first.host, controlPort: first.port)
        armDialTimeout()
    }

    /// Give up on the in-flight dial after dialTimeoutSeconds and try the
    /// next candidate; only fails the connect when none remain.
    private func armDialTimeout() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .connecting else { return }
            guard let next = self.dialCandidates.first else {
                self.fail("no address for this machine is reachable")
                return
            }
            self.dialCandidates.removeFirst()
            self.logger.info("dial timed out; trying \(next.host, privacy: .public)")
            self.control.disconnect()
            self.state = .disconnected // connect(host:) requires the idle state
            self.connect(host: next.host, controlPort: next.port)
            self.armDialTimeout()
        }
        dialTimeout = work
        decodeQueue.asyncAfter(deadline: .now() + dialTimeoutSeconds, execute: work)
    }

    func connect(host: String, controlPort: UInt16 = WireProtocol.controlPort) {
        guard state == .disconnected else { return }
        lastError = nil
        state = .connecting
        needsKeyframe = true
        highestSubmittedSequence = nil
        consecutiveEmptySeconds = 0
        if connectStartedAt == nil {
            connectStartedAt = Date()
        }
        openStatsLog()

        control.onEvent = { [weak self] event in
            self?.decodeQueue.async { self?.handleControlEvent(event) }
        }
        video.onEvent = { [weak self] event in
            self?.handleVideoEvent(event)
        }
        decoder.onFrameDecoded = { [weak self] pixelBuffer, _ in
            self?.handleDecodedFrame(pixelBuffer)
        }
        decoder.onFailure = { [weak self] message in
            self?.handleDecodeFailure(message)
        }
        decoder.onSessionRebuilt = { [weak self] colorState, width, height in
            self?.logger.info("decode session rebuilt: \(width)x\(height), matrix \(String(describing: colorState.matrix)), fullRange \(colorState.fullRange)")
            self?.renderer.setColorState(matrix: colorState.matrix, fullRange: colorState.fullRange)
        }

        // Input flows to the control channel on the same connection (US-006).
        input.onSend = { [weak self] frame in
            self?.control.sendInput(frame)
        }
        input.onCaptureChanged = { [weak self] captured in
            DispatchQueue.main.async { self?.inputCaptured = captured }
        }
        input.onPointerLockChanged = { [weak self] locked in
            DispatchQueue.main.async {
                self?.pointerLockActive = locked
                if !locked {
                    // Esc released the lock; turn the chrome toggle off too.
                    UserDefaults.standard.set(false, forKey: "pointerLock")
                }
            }
        }

        logger.info("connecting to \(host, privacy: .public):\(controlPort)")
        control.connect(host: host, port: controlPort)
        startStatsTimer()
    }

    func disconnect() {
        guard state != .disconnected else { return }
        dialTimeout?.cancel()
        dialTimeout = nil
        dialCandidates = []
        control.disconnect()
        video.stop()
        decodeQueue.sync {
            decoder.invalidate()
            reassembler.reset()
        }
        statsTimer?.cancel()
        statsTimer = nil
        try? statsLogHandle?.close()
        statsLogHandle = nil
        renderer.clearStream()
        input.reset()
        hello = nil
        state = .disconnected
    }

    // MARK: Control channel

    private func handleControlEvent(_ event: ControlChannel.Event) {
        switch event {
        case .ready:
            // Connected to a candidate; stop the fallback walk.
            dialTimeout?.cancel()
            dialTimeout = nil
            dialCandidates = []
        case .hello(let hello):
            guard hello.codec == .h264 else {
                fail("agent streams codec \(hello.codec.rawValue); US-005 supports h264 only")
                return
            }
            self.hello = hello
            // InputController is main-thread; hop for the size update.
            DispatchQueue.main.async { [weak self] in
                self?.input.videoSize = CGSize(width: Int(hello.width), height: Int(hello.height))
            }
            logger.info("hello: \(hello.width)x\(hello.height)@\(hello.fps), keyframe every \(hello.keyframeIntervalSecs)s, video port \(hello.videoPort)")
            setState(.waitingForKeyframe)
            guard video.start(port: hello.videoPort) != nil else {
                fail("could not bind UDP video port \(hello.videoPort)")
                return
            }
            // Joining mid-GOP: ask for an IDR to start decoding.
            control.requestKeyframe(force: true)
        case .disconnected(let reason):
            fail(reason)
        }
    }

    // MARK: Video channel

    /// Called on the video queue; hops to the decode queue with bounded
    /// backlog.
    private func handleVideoEvent(_ event: VideoReceiver.Event) {
        switch event {
        case .failed(let message):
            decodeQueue.async { [weak self] in self?.fail(message) }
        case .datagram(let header, let payload):
            pendingLock.lock()
            let depth = pendingDecodes
            if depth < maxPendingDecodes {
                pendingDecodes += 1
            }
            pendingLock.unlock()
            guard depth < maxPendingDecodes else {
                decodeQueue.async { [weak self] in self?.handleLoss(frameCount: 1, reason: "decode queue full") }
                return
            }
            decodeQueue.async { [weak self] in
                guard let self else { return }
                self.pendingLock.lock()
                self.pendingDecodes -= 1
                self.pendingLock.unlock()
                self.ingest(header: header, payload: payload)
            }
        }
    }

    private func ingest(header: WireProtocol.DatagramHeader, payload: Data) {
        for event in reassembler.ingest(header: header, payload: payload) {
            switch event {
            case .completed(let accessUnit):
                completedThisSecond += 1
                handleAccessUnit(accessUnit)
            case .loss(let frameCount):
                handleLoss(frameCount: frameCount, reason: "reassembly")
            }
        }
    }

    private func handleAccessUnit(_ accessUnit: Reassembler.AccessUnit) {
        // Late completion behind a newer frame is decode-fatal too: its
        // references have moved on.
        if let highest = highestSubmittedSequence, accessUnit.sequence <= highest {
            handleLoss(frameCount: 1, reason: "late frame \(accessUnit.sequence)")
            return
        }
        if needsKeyframe && !accessUnit.isKeyframe {
            return
        }

        highestSubmittedSequence = accessUnit.sequence
        decodingSequence = accessUnit.sequence
        let submitted = decoder.decode(accessUnit: accessUnit.data,
                                       timestampMicros: accessUnit.timestampMicros)
        decodingSequence = nil

        if !decoder.isReady {
            // IDR arrived without parameter sets; wait for a restart that
            // carries SPS/PPS.
            needsKeyframe = true
            control.requestKeyframe()
            return
        }
        guard submitted else { return }
        needsKeyframe = false
    }

    private func handleDecodedFrame(_ pixelBuffer: CVPixelBuffer) {
        decodedThisSecond += 1
        decodeMillisecondsThisSecond += decoder.lastDecodeMilliseconds
        renderer.display(pixelBuffer)
        if case .waitingForKeyframe = state, let hello {
            if let started = connectStartedAt {
                let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
                logger.info("connect to first decoded frame: \(milliseconds) ms")
                connectStartedAt = nil
            }
            setState(.live(width: Int(hello.width), height: Int(hello.height), fps: Int(hello.fps)))
        }
    }

    /// Any loss is decode-fatal until the next IDR (protocol.md).
    private func handleLoss(frameCount: UInt64, reason: String) {
        lostThisSecond += frameCount
        if !needsKeyframe {
            logger.info("loss (\(frameCount) frame(s), \(reason, privacy: .public)); requesting keyframe")
        }
        needsKeyframe = true
        control.requestKeyframe()
    }

    private func handleDecodeFailure(_ message: String) {
        logger.warning("decoder: \(message, privacy: .public)")
        lostThisSecond += 1
        needsKeyframe = true
        control.requestKeyframe()
    }

    // MARK: Stats

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: decodeQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.emitStats() }
        timer.resume()
        statsTimer = timer
    }

    private func emitStats() {
        let fps = decodedThisSecond
        let averageDecodeMs = fps > 0 ? decodeMillisecondsThisSecond / Double(fps) : 0
        let totalFrames = UInt64(completedThisSecond) + lostThisSecond
        let lossPercent = totalFrames > 0 ? Double(lostThisSecond) / Double(totalFrames) * 100 : 0
        pendingLock.lock()
        let depth = pendingDecodes
        pendingLock.unlock()

        let line = String(format: "stats fps=%d decode_ms=%.2f loss=%.2f%% queue=%d",
                          fps, averageDecodeMs, lossPercent, depth)
        logger.info("\(line, privacy: .public)")
        appendStatsLog(line)

        // Stall recovery: nothing decoded for a while means the stream died
        // silently (agent restart, black hole); keep asking for keyframes.
        if fps == 0, state != .disconnected {
            consecutiveEmptySeconds += 1
            if consecutiveEmptySeconds >= 3 {
                control.requestKeyframe()
            }
        } else {
            consecutiveEmptySeconds = 0
        }

        decodedThisSecond = 0
        decodeMillisecondsThisSecond = 0
        completedThisSecond = 0
        lostThisSecond = 0
    }

    private func openStatsLog() {
        FileManager.default.createFile(atPath: statsLogURL.path, contents: nil)
        statsLogHandle = try? FileHandle(forWritingTo: statsLogURL)
    }

    private func appendStatsLog(_ line: String) {
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let data = stamped.data(using: .utf8) {
            try? statsLogHandle?.write(contentsOf: data)
        }
    }

    // MARK: Helpers

    private func setState(_ newState: State) {
        if Thread.isMainThread {
            state = newState
        } else {
            DispatchQueue.main.async { [weak self] in self?.state = newState }
        }
    }

    private func fail(_ message: String) {
        logger.error("\(message, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state != .disconnected else { return }
            self.lastError = message
            self.disconnect()
        }
    }
}
