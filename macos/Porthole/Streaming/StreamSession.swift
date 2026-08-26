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
/// Threading: control callbacks arrive on the control queue and datagrams
/// on the receive thread; everything session-stateful (reassembly, decode,
/// stats counters, the clock offset) runs on the serial decode queue.
/// Published properties are set on the main queue.
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
    /// Latest per-second latency figures for the session chrome.
    @Published private(set) var latency = LatencyStats.empty

    /// The surface's renderer; decoded frames replace the test pattern.
    let renderer = MetalRenderer()
    /// Keyboard/mouse/scroll translation and wire encoding (US-006).
    let input = InputController()

    private let control = ControlChannel()
    private let video: VideoIngest
    private let decoder = H264Decoder()
    private let decodeQueue: DispatchQueue
    private let logger = Logger(subsystem: "com.porthole.mac", category: "session")
    /// Candidate walk for connect(machine:): the host that last answered a
    /// thumbnail poll, then the mDNS LAN addresses, then the bare host name
    /// (MagicDNS/Tailscale), with one second per attempt. Walks on main
    /// because each try drives the published state through connect(host:).
    private let dialer: DialWalker
    private let statsLog = StatsLog()

    private var hello: Hello?
    private var needsKeyframe = true
    /// Sequence of the access unit currently inside decode(); valid because
    /// the decode queue is serial and decoding is synchronous.
    private var decodingSequence: UInt64?
    private var highestSubmittedSequence: UInt64?
    private var consecutiveEmptySeconds = 0

    // Per-second counters and the agent clock estimate, decode queue only.
    private var stats = StatsWindow()
    private var clockOffset = ClockOffset()
    private var latestAgentStats: AgentStats?
    private var statsTimer: DispatchSourceTimer?

    /// Set at connect() so the first decoded frame can report the
    /// click-to-first-frame latency (US-007 target: under 3 s on LAN).
    private var connectStartedAt: Date?

    var isConnected: Bool {
        state != .disconnected
    }

    init() {
        let queue = DispatchQueue(label: "porthole.decode")
        decodeQueue = queue
        video = VideoIngest(decodeQueue: queue)
        dialer = DialWalker(queue: .main)
        wireDialer()
        wireStream()
        wireInput()
    }

    // MARK: Lifecycle

    /// Connect to a picker machine, walking its address candidates.
    func connect(machine: Machine) {
        connectStartedAt = Date() // the fallback re-dial must not reset this
        dialer.start(hosts: machine.dialOrder, port: machine.controlPort)
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
        statsLog.open()
        logger.info("connecting to \(host, privacy: .public):\(controlPort)")
        control.connect(host: host, port: controlPort)
        startStatsTimer()
    }

    func disconnect() {
        guard state != .disconnected else { return }
        dialer.cancel()
        control.disconnect()
        video.stop()
        decodeQueue.sync {
            decoder.invalidate()
            clockOffset.reset()
            latestAgentStats = nil
            stats.reset()
        }
        statsTimer?.cancel()
        statsTimer = nil
        statsLog.close()
        renderer.clearStream()
        input.reset()
        hello = nil
        latency = .empty
        state = .disconnected
    }

    private func wireDialer() {
        dialer.onTry = { [weak self] host, port in
            guard let self else { return }
            if self.state == .connecting {
                // The previous candidate timed out; drop that dial first.
                self.logger.info("dial timed out; trying \(host, privacy: .public)")
                self.control.disconnect()
                self.state = .disconnected // connect(host:) requires the idle state
            }
            self.connect(host: host, controlPort: port)
        }
        dialer.onExhausted = { [weak self] in
            guard let self, self.state == .connecting else { return }
            self.fail("no address for this machine is reachable")
        }
    }

    private func wireStream() {
        control.onEvent = { [weak self] event in
            // Stamp the arrival before the hop: decode is synchronous on the
            // decode queue and would add its own milliseconds to every RTT.
            let receivedMicros = ClientClock.nowMicros()
            self?.decodeQueue.async { self?.handleControlEvent(event, receivedMicros: receivedMicros) }
        }
        video.onAccessUnit = { [weak self] accessUnit, arrivedMicros in
            self?.handleArrival(accessUnit, arrivedMicros: arrivedMicros)
        }
        video.onLoss = { [weak self] frameCount, reason in
            self?.handleLoss(frameCount: frameCount, reason: reason)
        }
        video.onFailure = { [weak self] message in
            self?.fail(message)
        }
        decoder.onFrameDecoded = { [weak self] pixelBuffer, timestampMicros in
            self?.handleDecodedFrame(pixelBuffer, timestampMicros: timestampMicros)
        }
        decoder.onFailure = { [weak self] message in
            self?.handleDecodeFailure(message)
        }
        decoder.onSessionRebuilt = { [weak self] colorState, width, height in
            self?.logger.info("""
                decode session rebuilt: \(width)x\(height), \
                matrix \(String(describing: colorState.matrix)), fullRange \(colorState.fullRange)
                """)
            self?.renderer.setColorState(matrix: colorState.matrix, fullRange: colorState.fullRange)
        }
        renderer.onFramePresented = { [weak self] captureClientMicros, presentedMicros in
            guard let captureClientMicros else { return }
            self?.decodeQueue.async {
                self?.stats.captureToPresented.add(Int64(presentedMicros) - Int64(captureClientMicros))
            }
        }
    }

    /// Input flows to the control channel on the same connection (US-006).
    private func wireInput() {
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
    }

    // MARK: Control channel

    private func handleControlEvent(_ event: ControlChannel.Event, receivedMicros: UInt64) {
        switch event {
        case .ready:
            // Connected to a candidate; stop the fallback walk.
            dialer.cancel()
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
            logger.info("""
                hello: \(hello.width)x\(hello.height)@\(hello.fps), \
                keyframe every \(hello.keyframeIntervalSecs)s, video port \(hello.videoPort)
                """)
            setState(.waitingForKeyframe)
            guard video.start(port: hello.videoPort) != nil else {
                fail("could not bind UDP video port \(hello.videoPort)")
                return
            }
            // Joining mid-GOP: ask for an IDR to start decoding, and probe
            // the clock offset early; the stats timer pings once per second
            // after this burst.
            control.requestKeyframe(force: true)
            control.sendPingBurst(count: 5, interval: 0.1)
        case .pong(let pong):
            clockOffset.addPong(pong, receivedMicros: receivedMicros)
        case .agentStats(let agentStats):
            latestAgentStats = agentStats
        case .disconnected(let reason):
            fail(reason)
        }
    }

    // MARK: Video channel

    /// Decode queue: a complete access unit that arrived at `arrivedMicros`
    /// (stamped on the receive thread, before any queueing).
    private func handleArrival(_ accessUnit: Reassembler.AccessUnit, arrivedMicros: UInt64) {
        stats.completed += 1
        if let captureClient = clockOffset.clientMicros(forAgentMicros: accessUnit.timestampMicros) {
            stats.captureToArrival.add(Int64(arrivedMicros) - captureClient)
        }
        handleAccessUnit(accessUnit)
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

    private func handleDecodedFrame(_ pixelBuffer: CVPixelBuffer, timestampMicros: UInt64) {
        stats.decoded += 1
        stats.decodeMilliseconds += decoder.lastDecodeMilliseconds
        let captureClient = clockOffset.clientMicros(forAgentMicros: timestampMicros)
        if let captureClient {
            stats.captureToDecoded.add(Int64(ClientClock.nowMicros()) - captureClient)
        }
        renderer.display(pixelBuffer, captureClientMicros: captureClient.map { UInt64(max(0, $0)) })
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
        stats.lost += frameCount
        if !needsKeyframe {
            logger.info("loss (\(frameCount) frame(s), \(reason, privacy: .public)); requesting keyframe")
        }
        needsKeyframe = true
        control.requestKeyframe()
    }

    private func handleDecodeFailure(_ message: String) {
        logger.warning("decoder: \(message, privacy: .public)")
        stats.lost += 1
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
        let rttMicros = clockOffset.latestRttMicros
        let line = stats.line(rttMicros: rttMicros, agentStats: latestAgentStats, queueDepth: video.backlogDepth)
        logger.info("\(line, privacy: .public)")
        statsLog.append(line)

        let latency = LatencyStats(capturePresentMs: stats.captureToPresented.milliseconds,
                                   rttMs: rttMicros.map { Double($0) / 1000 })
        DispatchQueue.main.async { [weak self] in self?.latency = latency }

        // Stall recovery: nothing decoded for a while means the stream died
        // silently (agent restart, black hole); keep asking for keyframes.
        if stats.decoded == 0, state != .disconnected {
            consecutiveEmptySeconds += 1
            if consecutiveEmptySeconds >= 3 {
                control.requestKeyframe()
            }
        } else {
            consecutiveEmptySeconds = 0
        }
        stats.reset()

        // Steady-state probe; before hello there is no peer to answer.
        if hello != nil {
            control.sendPing()
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
