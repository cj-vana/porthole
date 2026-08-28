import Combine
import CoreGraphics
import CoreVideo
import Foundation
import os

/// Encoder-safe virtual-display geometry normalized from an AppKit backing
/// rectangle. The agent independently enforces the same trust boundary.
private struct RemoteDisplaySize: Equatable {
    static let minWidth = 320
    static let minHeight = 180
    static let maxDimension = 8_192

    let width: UInt32
    let height: UInt32

    init?(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        let boundedWidth = min(max(Int(size.width.rounded(.down)), Self.minWidth),
                               Self.maxDimension)
        let boundedHeight = min(max(Int(size.height.rounded(.down)), Self.minHeight),
                                Self.maxDimension)
        width = UInt32(boundedWidth - boundedWidth % 2)
        height = UInt32(boundedHeight - boundedHeight % 2)
    }
}

/// Owns one streaming session: TCP control channel, UDP video receiver,
/// fragment reassembly, hardware decode, and handoff of decoded frames to
/// the Metal renderer. One instance lives for the app's lifetime; connect
/// and disconnect drive its lifecycle.
///
/// Threading: control callbacks arrive on the control queue and datagrams
/// on the receive thread; everything session-stateful (reassembly, decode,
/// stats counters, the clock offset) runs on the serial decode queue.
/// Published properties are set on the main queue. One instance belongs to
/// one session screen and is disconnected when that screen disappears.
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
    /// A connection attempt gets a fresh Metal surface identity. Core
    /// Animation can retain the cadence of a previously drained swapchain;
    /// rebuilding the surface isolates reconnects from that old layer.
    @Published private(set) var surfaceGeneration: UInt64 = 0
    /// A supported remote panel is reported after the initial control query.
    /// `unavailable` also covers older agents that do not implement it.
    @Published private(set) var desktopBarState: DesktopBarState = .unavailable

    /// The surface's renderer; decoded frames replace the test pattern.
    let renderer = MetalRenderer()
    /// Keyboard/mouse/scroll translation and wire encoding (US-006).
    let input = InputController()
    /// Opus audio playback (US-009); SessionView drives volume and mute.
    let audio = AudioPlayer()

    /// Host the control channel last dialed; live file transfers (US-011)
    /// open their own connections to it. Cleared on disconnect.
    private(set) var connectedHost: String?

    private let control = ControlChannel()
    private let audioReceiver = AudioReceiver()
    /// Clipboard sync (US-008) and gamepad passthrough (US-014); started
    /// on the live transition, stopped on disconnect.
    private let peripherals: SessionPeripherals
    private let video: VideoIngest
    private let decoder = CodecSwitchingDecoder()
    private let decodeQueue: DispatchQueue
    private let logger = Logger(subsystem: "com.porthole.mac", category: "session")
    /// Candidate walk for connect(machine:): the host that last answered a
    /// thumbnail poll, then the mDNS LAN addresses, then the bare host name
    /// (MagicDNS/Tailscale), with one second per attempt. Walks on main
    /// because each try drives the published state through connect(host:).
    private let dialer: DialWalker
    private let statsLog = StatsLog()
    private let renderTelemetry = RenderTelemetry()

    private var hello: Hello?
    private var needsKeyframe = true
    /// The stored gaming toggle has been applied to this session (US-013).
    private var appliedStoredSettings = false
    /// The latest AppKit viewport and the most recent resize sent. Decode
    /// queue only; desired size survives reconnects within this session view.
    private var desiredDisplaySize: RemoteDisplaySize?
    private var sentDisplaySize: RemoteDisplaySize?
    private var displayResizeWorkItem: DispatchWorkItem?
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
        peripherals = SessionPeripherals(control: control)
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
        surfaceGeneration &+= 1
        lastError = nil
        desktopBarState = .unavailable
        state = .connecting
        needsKeyframe = true
        appliedStoredSettings = false
        highestSubmittedSequence = nil
        consecutiveEmptySeconds = 0
        decodeQueue.sync {
            displayResizeWorkItem?.cancel()
            displayResizeWorkItem = nil
            sentDisplaySize = nil
        }
        if connectStartedAt == nil {
            connectStartedAt = Date()
        }
        connectedHost = host
        renderTelemetry.reset()
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
        audioReceiver.stop()
        audio.stop()
        decodeQueue.sync {
            displayResizeWorkItem?.cancel()
            displayResizeWorkItem = nil
            sentDisplaySize = nil
            decoder.invalidate()
            clockOffset.reset()
            latestAgentStats = nil
            stats.reset()
        }
        statsTimer?.cancel()
        statsTimer = nil
        statsLog.close()
        peripherals.stop()
        renderer.clearStream()
        input.reset()
        hello = nil
        connectedHost = nil
        latency = .empty
        desktopBarState = .unavailable
        state = .disconnected
    }

    /// Chrome toggle (US-008): pause or resume clipboard sync without
    /// touching the connection.
    func setClipboardSync(_ enabled: Bool) {
        peripherals.clipboardEnabled = enabled
    }

    /// Reversible remote panel control. The published state changes only
    /// after the agent acknowledges what the desktop actually applied.
    func setDesktopBarVisible(_ visible: Bool) {
        control.sendDesktopBar(visible ? .show : .hide)
    }

    /// AppKit reports every layout change; exact deduplication plus a short
    /// settle delay turns an interactive drag into one remote mode change.
    func setRemoteDisplaySize(_ size: CGSize) {
        guard let normalized = RemoteDisplaySize(size) else { return }
        decodeQueue.async { [weak self] in
            guard let self, self.desiredDisplaySize != normalized else { return }
            self.desiredDisplaySize = normalized
            guard self.appliedStoredSettings else { return }
            self.scheduleDisplayResize()
        }
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
        audio.attach(to: audioReceiver)
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
        wireRendererTelemetry()
    }

    private func wireRendererTelemetry() {
        renderer.onFramePresented = { [weak self] timing in
            self?.renderTelemetry.recordPresented(timing)
        }
        renderer.onFrameRenderCompleted = { [weak self] timing in
            self?.renderTelemetry.recordRendered(timing)
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
            control.sendDesktopBar(.query)
        case .hello(let hello):
            handleHello(hello)
        case .pong(let pong):
            clockOffset.addPong(pong, receivedMicros: receivedMicros)
        case .agentStats(let agentStats):
            latestAgentStats = agentStats
        case .desktopBar(let barState):
            DispatchQueue.main.async { [weak self] in
                self?.desktopBarState = barState
            }
        case .clipboard(let text):
            peripherals.applyClipboard(fromPeer: text)
        case .disconnected(let reason):
            fail(reason)
        }
    }

    // MARK: Video channel

    /// Decode queue: a complete access unit that arrived at `arrivedMicros`
    /// (stamped on the receive thread, before any queueing).
    private func handleArrival(_ accessUnit: Reassembler.AccessUnit, arrivedMicros: UInt64) {
        stats.completed += 1
        stats.captureCadence.observe(accessUnit.timestampMicros)
        stats.arrivalCadence.observe(arrivedMicros)
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
                                       sampleFormat: accessUnit.sampleFormat,
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
        stats.prepareMilliseconds += decoder.lastPrepareMilliseconds
        let decodedMicros = ClientClock.nowMicros()
        stats.decodeCadence.observe(decodedMicros)
        let captureClient = clockOffset.clientMicros(forAgentMicros: timestampMicros)
        if let captureClient {
            stats.captureToDecoded.add(Int64(decodedMicros) - captureClient)
        }
        renderer.display(pixelBuffer, captureClientMicros: captureClient.map { UInt64(max(0, $0)) })
        if case .waitingForKeyframe = state, let hello {
            if let started = connectStartedAt {
                let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
                logger.info("connect to first decoded frame: \(milliseconds) ms")
                connectStartedAt = nil
            }
            setState(.live(width: Int(hello.width), height: Int(hello.height), fps: Int(hello.fps)))
            applyStoredSettingsOnce()
            peripherals.start { [weak self] in
                guard let self else { return false }
                return self.state != .disconnected
            }
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
        renderer.refreshPresentationEnvironment()
        stats.apply(renderTelemetry.drain())
        let rttMicros = clockOffset.latestRttMicros
        let line = stats.line(rttMicros: rttMicros, agentStats: latestAgentStats,
                              queueDepth: video.backlogDepth, audio: audio.perSecond())
            + " " + renderer.drainGamingPacerMetrics()
        logger.info("\(line, privacy: .public)")
        statsLog.append(line)

        let latency = stats.snapshot(rttMicros: rttMicros, agentStats: latestAgentStats)
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

// MARK: Hello and stream settings (US-013)

extension StreamSession {
    /// Decode queue. A first hello starts the video path; a reconfigured
    /// hello (a settings request answered, or an agent-side encoder
    /// restart) keeps the session up and rebinds only what changed.
    private func handleHello(_ hello: Hello) {
        let previous = self.hello
        self.hello = hello
        // InputController is main-thread; hop for the size update.
        DispatchQueue.main.async { [weak self] in
            self?.input.videoSize = CGSize(width: Int(hello.width), height: Int(hello.height))
        }
        logger.info("""
            hello: codec \(hello.codec.rawValue), \(hello.width)x\(hello.height), cap \(hello.fps) fps, \
            keyframe every \(hello.keyframeIntervalSecs)s, video port \(hello.videoPort)
            """)
        if decoder.select(hello.codec) {
            needsKeyframe = true
        }
        let helloSize = RemoteDisplaySize(
            CGSize(width: Int(hello.width), height: Int(hello.height))
        )
        if helloSize == desiredDisplaySize {
            displayResizeWorkItem?.cancel()
            displayResizeWorkItem = nil
            sentDisplaySize = helloSize
        } else if previous != nil, appliedStoredSettings {
            scheduleDisplayResize()
        }
        guard let previous else {
            setState(.waitingForKeyframe)
            guard bindVideo(port: hello.videoPort) else { return }
            // Audio rides its default port (hello does not negotiate one);
            // a failed bind costs sound only, logged by the player.
            audio.start()
            audioReceiver.start(port: WireProtocol.audioPort)
            // Joining mid-GOP: ask for an IDR to start decoding, and probe
            // the clock offset early; the stats timer pings once per second
            // after this burst.
            control.requestKeyframe(force: true)
            control.sendPingBurst(count: 5, interval: 0.1)
            return
        }
        // Reconfigured: the encoder restart makes the next access unit an
        // IDR, so decode continues without a teardown.
        if previous.videoPort != hello.videoPort {
            video.stop()
            guard bindVideo(port: hello.videoPort) else { return }
        }
        if previous.width != hello.width || previous.height != hello.height {
            needsKeyframe = true
        }
        if case .live = state {
            setState(.live(width: Int(hello.width), height: Int(hello.height), fps: Int(hello.fps)))
        }
    }

    /// Bind (or rebind) the UDP video port from a hello. Fails the session
    /// when the bind does not stick.
    private func bindVideo(port: UInt16) -> Bool {
        guard video.start(port: port) != nil else {
            fail("could not bind UDP video port \(port)")
            return false
        }
        return true
    }

    /// Gaming mode: up to 288 fps HEVC at 60 Mbps with the encoder
    /// biased toward latency; off restores 60 fps H.264 at 40 Mbps. The
    /// decoder switches codec immediately rather than waiting for the
    /// reconfigured hello, which is advisory (docs/protocol.md "settings").
    func setGamingMode(_ enabled: Bool, fps: Int = 144) {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.apply(enabled ? .gaming(fps: fps) : .quality)
            self.sendDisplayResizeIfNeeded()
        }
    }

    /// Decode queue. Before hello there is no live encoder to reconfigure,
    /// so the request is dropped; the stored toggle covers the next connect.
    private func apply(_ settings: StreamSettings) {
        guard hello != nil else { return }
        control.sendSettings(fps: settings.fps,
                             codec: settings.codec,
                             bitrateMbps: settings.bitrateMbps,
                             lowLatency: settings.lowLatency)
        if decoder.select(settings.codec) {
            needsKeyframe = true
        }
    }

    /// Once per session, on the first decoded frame: a stored gaming toggle
    /// reconfigures the stream only after connect has delivered a frame,
    /// keeping click-to-first-frame fast.
    private func applyStoredSettingsOnce() {
        guard !appliedStoredSettings else { return }
        appliedStoredSettings = true
        let stored = StreamSettings.stored()
        let shouldApplySettings = stored != .quality && hello.map { !stored.matches($0) } == true
        // This runs inside the frame-decoded callback, nested in synchronous
        // VideoToolbox decode. Switching the decoder here would invalidate its
        // own callback. The next queue turn also lets settings and resize ride
        // the TCP stream back-to-back for one agent-side rebuild.
        decodeQueue.async { [weak self] in
            guard let self else { return }
            if shouldApplySettings {
                self.apply(stored)
            }
            self.sendDisplayResizeIfNeeded()
        }
    }

    private func scheduleDisplayResize() {
        displayResizeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.sendDisplayResizeIfNeeded()
        }
        displayResizeWorkItem = work
        decodeQueue.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
    }

    private func sendDisplayResizeIfNeeded() {
        displayResizeWorkItem?.cancel()
        displayResizeWorkItem = nil
        let remoteSizeChanged = desiredDisplaySize.map {
            $0.width != hello?.width || $0.height != hello?.height
        } == true
        guard let desiredDisplaySize,
              desiredDisplaySize != sentDisplaySize,
              remoteSizeChanged else { return }
        sentDisplaySize = desiredDisplaySize
        needsKeyframe = true
        control.sendDisplayResize(width: desiredDisplaySize.width,
                                  height: desiredDisplaySize.height)
        logger.info("requested display size \(desiredDisplaySize.width)x\(desiredDisplaySize.height)")
    }
}
