// swiftlint:disable file_length
import CoreVideo
import Darwin
import MetalKit
import QuartzCore

/// Draws decoded video while connected and the US-004 test pattern otherwise.
/// VideoToolbox's NV12 IOSurfaces map into zero-copy Metal textures; the shader
/// applies SPS color state and letterboxes into the native-Retina drawable.
/// Presentation timing: quality mode asks MTKView for a draw on arrival.
/// Gaming uses CVDisplayLink's vblank forecast to latch the newest frame just
/// before scanout, then renders directly into CAMetalLayer. When Core Video
/// forecasts more than one refresh ahead, the renderer targets the intervening
/// near-horizon vblank if its full GPU budget remains. Pixels stay in a single
/// newest-only mailbox until the selected latch deadline.
final class MetalRenderer: NSObject, MTKViewDelegate {
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm
    /// Leave enough time for this single-triangle pass and Metal scheduling,
    /// while keeping the mailbox open for almost the entire refresh period.
    private static let gamingLatchLeadSeconds = 0.0020
    /// Only a stale tick spends this extra 0.5 ms waiting for a frame that
    /// landed just across the independent source/display clock boundary.
    private static let gamingStaleRetryLeadSeconds = 0.0015
    private static let maximumPendingGamingTicks = 2

    struct PresentationTiming {
        let captureClientMicros: UInt64?
        let decodedMicros: UInt64
        let drawStartedMicros: UInt64
        let submittedMicros: UInt64
        let presentedMicros: UInt64
    }

    /// A frame whose Metal command buffer completed successfully. Unlike
    /// `addPresentedHandler`, this remains observable when WindowServer omits
    /// a scanout callback for an occluded or transitioning layer.
    struct RenderCompletionTiming {
        let captureClientMicros: UInt64?
        let decodedMicros: UInt64
        let submittedMicros: UInt64
        let completedMicros: UInt64
    }

    /// A decoded frame waiting for, or being redrawn by, the display link.
    private struct StreamFrame {
        let pixelBuffer: CVPixelBuffer
        let width: Int
        let height: Int
        /// Capture time on the client clock; nil while the clock offset to
        /// the agent is unknown.
        let captureClientMicros: UInt64?
        /// Decode completion on the same client clock.
        let decodedMicros: UInt64
        /// Distinguishes a new decoded frame from a redraw of the last one.
        let generation: UInt64
    }

    /// A plane texture plus the cache entry that keeps it valid.
    private struct PlaneTexture {
        let reference: CVMetalTexture
        let texture: MTLTexture
    }

    let device: MTLDevice

    private weak var view: MTKView?
    private weak var streamLayer: CAMetalLayer?
    private var gamingDisplayLink: CVDisplayLink?

    /// Called once per decoded frame when the drawable that carried it hit
    /// the screen, with the frame's capture time (client clock, nil if
    /// unknown) and the presentation time in microseconds on the same clock.
    /// Arrives on a Metal-owned thread.
    var onFramePresented: ((PresentationTiming) -> Void)?
    var onFrameRenderCompleted: ((RenderCompletionTiming) -> Void)?

    private let commandQueue: MTLCommandQueue
    private var gamingRenderQueue = DispatchQueue(label: "com.porthole.mac.late-latch.0",
                                                  qos: .userInteractive)
    private var gamingRenderQueueGeneration: UInt64 = 0
    private let presentationWatchdogQueue = DispatchQueue(
        label: "com.porthole.mac.presentation-watchdog",
        qos: .userInteractive
    )
    private let patternPipelineState: MTLRenderPipelineState
    private let videoPipelineState: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let startTime = CACurrentMediaTime()

    // Latest stream frame + its color state, written from the decode
    // queue, read on the display link. All guarded by frameLock.
    private let frameLock = NSLock()
    private var latestFrame: StreamFrame?
    private var nextGeneration: UInt64 = 0
    /// Quality mode allows one frame to be rendering or awaiting scanout.
    /// New frames replace `latestFrame` while that slot is busy. A unique
    /// token makes late Metal callbacks harmless when a layer is occluded.
    private var activeRenderToken: UInt64?
    private var nextRenderToken: UInt64 = 0
    /// Gaming presents each decoded generation at most once even if the
    /// display callback outruns the stream for a tick.
    private var lastGamingGeneration: UInt64?
    private var gamingTicksPending = 0
    private var gamingPacerGeneration: UInt64 = 0
    private var gamingTickCallbacks = 0
    private var gamingTicksScheduled = 0
    private var gamingTicksCommitted = 0
    private var gamingTicksBusy = 0
    private var gamingLookaheadTicks: UInt64 = 0
    private var gamingWaitTicks: UInt64 = 0
    private var gamingDrawableTicks: UInt64 = 0
    private var gamingDrawableSamples = 0
    private var gamingCaptureTargetMicros: UInt64 = 0
    private var gamingCaptureTargetSamples = 0
    private var gamingStaleRetries = 0
    private var gamingStaleRecoveries = 0
    private var lowLatencyPresentation = false
    /// AppKit replaces or re-homes the drawable swapchain during native
    /// fullscreen transitions. Do not acquire from the disappearing layer;
    /// the completed transition rebinds and submits the newest mailbox entry.
    private var presentationSuspended = false
    private var colorState = ColorState(matrix: .bt709, fullRange: false)
    /// US-010 one-to-one mode draws the quad unscaled; see setFillsDrawable.
    private var fillsDrawable = false
    override convenience init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            preconditionFailure("Porthole requires a Metal-capable GPU")
        }
        self.init(device: device)
    }

    init(device: MTLDevice) {
        self.device = device
        guard let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let patternPipeline = MetalRenderer.makePipeline(device: device,
                                                               library: library,
                                                               label: "Test Pattern Pipeline",
                                                               vertex: "testPatternVertex",
                                                               fragment: "testPatternFragment"),
              let videoPipeline = MetalRenderer.makePipeline(device: device,
                                                             library: library,
                                                             label: "Video Pipeline",
                                                             vertex: "videoVertex",
                                                             fragment: "videoFragment") else {
            preconditionFailure("Failed to set up the Metal renderer")
        }
        self.commandQueue = commandQueue
        patternPipelineState = patternPipeline
        videoPipelineState = videoPipeline
        super.init()

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    deinit {
        if let gamingDisplayLink {
            CVDisplayLinkStop(gamingDisplayLink)
        }
    }

    private static func makePipeline(device: MTLDevice,
                                     library: MTLLibrary,
                                     label: String,
                                     vertex: String,
                                     fragment: String) -> MTLRenderPipelineState? {
        guard let vertexFunction = library.makeFunction(name: vertex),
              let fragmentFunction = library.makeFunction(name: fragment) else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: Stream frame handoff (called from the decode queue)

    /// Main-thread attachment when MTKView's CAMetalLayer is ready.
    func attach(view: MTKView) {
        self.view = view
        let layer = view.layer as? CAMetalLayer
        frameLock.lock()
        streamLayer = layer
        activeRenderToken = nil
        lastGamingGeneration = nil
        let hasFrame = latestFrame != nil
        let gaming = lowLatencyPresentation
        let suspended = presentationSuspended
        let token = !suspended && !gaming && hasFrame
            ? reserveRenderTokenLocked()
            : nil
        frameLock.unlock()
        view.isPaused = hasFrame
        if gaming, hasFrame, !suspended, layer != nil {
            startGamingPacer()
        } else {
            stopGamingPacer()
        }
        if let token { scheduleRender(token: token) }
    }

    /// Stop display updates while AppKit moves the window between Spaces.
    func suspendPresentation() {
        frameLock.lock()
        presentationSuspended = true
        activeRenderToken = nil
        frameLock.unlock()
        stopGamingPacer()
        view?.isPaused = true
    }

    /// Bind the layer AppKit settled on and restart from the freshest decoded
    /// frame. Keeping this separate from `attach` prevents ordinary SwiftUI
    /// updates from resuming a transition early.
    func resumePresentation(view: MTKView) {
        self.view = view
        let layer = view.layer as? CAMetalLayer
        frameLock.lock()
        streamLayer = layer
        presentationSuspended = false
        activeRenderToken = nil
        lastGamingGeneration = nil
        let hasFrame = latestFrame != nil
        let gaming = lowLatencyPresentation
        let token = !gaming && hasFrame
            ? reserveRenderTokenLocked()
            : nil
        frameLock.unlock()
        view.isPaused = hasFrame
        if gaming, hasFrame, layer != nil {
            startGamingPacer()
        } else {
            stopGamingPacer()
        }
        if let token { scheduleRender(token: token) }
    }

    /// A blocked drawable belongs to an obsolete presentation generation.
    /// Replacing the serial queue lets a fresh layer start immediately while
    /// the old bounded wait unwinds independently.
    private func rotateGamingRenderQueueLocked() {
        gamingRenderQueueGeneration &+= 1
        let label = "com.porthole.mac.late-latch.\(gamingRenderQueueGeneration)"
        gamingRenderQueue = DispatchQueue(label: label, qos: .userInteractive)
    }

    /// Switch between MTKView's quality path and hardware-paced gaming mode.
    func setLowLatencyPresentation(_ enabled: Bool) {
        frameLock.lock()
        guard lowLatencyPresentation != enabled else {
            frameLock.unlock()
            return
        }
        lowLatencyPresentation = enabled
        activeRenderToken = nil
        lastGamingGeneration = nil
        let hasFrame = latestFrame != nil
        let token = !enabled && !presentationSuspended && latestFrame != nil
            ? reserveRenderTokenLocked()
            : nil
        frameLock.unlock()
        view?.isPaused = hasFrame
        if enabled, hasFrame, !presentationSuspended {
            startGamingPacer()
        } else {
            stopGamingPacer()
        }
        if let token { scheduleRender(token: token) }
    }

    /// Present a decoded frame at the next draw. `captureClientMicros` is
    /// the frame's capture time mapped onto the client clock, or nil when
    /// no pong has established the offset yet.
    func display(_ pixelBuffer: CVPixelBuffer, captureClientMicros: UInt64?) {
        frameLock.lock()
        let firstFrame = latestFrame == nil
        latestFrame = StreamFrame(pixelBuffer: pixelBuffer,
                                  width: CVPixelBufferGetWidth(pixelBuffer),
                                  height: CVPixelBufferGetHeight(pixelBuffer),
                                  captureClientMicros: captureClientMicros,
                                  decodedMicros: ClientClock.nowMicros(),
                                  generation: nextGeneration)
        nextGeneration += 1
        let gaming = lowLatencyPresentation
        let token = !lowLatencyPresentation && !presentationSuspended && activeRenderToken == nil
            ? reserveRenderTokenLocked()
            : nil
        frameLock.unlock()
        if firstFrame {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.view?.isPaused = true
                if gaming { self.startGamingPacer() }
            }
        }
        guard let token else { return }
        scheduleRender(token: token)
    }

    /// `frameLock` must be held.
    private func reserveRenderTokenLocked() -> UInt64 {
        let token = nextRenderToken
        nextRenderToken &+= 1
        activeRenderToken = token
        return token
    }

    private func scheduleRender(token: UInt64) {
        DispatchQueue.main.async { [weak self] in self?.drawArrivedFrame(token: token) }
    }

    /// Main thread: present the newest decoded frame through MTKView. Gaming
    /// mode never calls this function.
    private func drawArrivedFrame(token: UInt64) {
        frameLock.lock()
        let valid = activeRenderToken == token
            && !presentationSuspended
            && latestFrame != nil
            && !lowLatencyPresentation
        frameLock.unlock()
        guard valid, let view else {
            releaseRenderSlot(token: token, after: nil)
            return
        }
        if !view.isPaused { view.isPaused = true }
        view.draw()
    }

    /// A drawable reached the display, timed out, or could not be submitted.
    /// Only the callback for the currently reserved token can open the slot.
    /// If a newer decoded generation arrived meanwhile, it is scheduled
    /// immediately and all intermediate frames remain coalesced.
    private func releaseRenderSlot(token: UInt64, after generation: UInt64?) {
        frameLock.lock()
        guard activeRenderToken == token else {
            frameLock.unlock()
            return
        }
        activeRenderToken = nil
        let needsDraw = !presentationSuspended && (latestFrame.map { frame in
            generation == nil || frame.generation != generation
        } ?? false)
        let nextToken = needsDraw ? reserveRenderTokenLocked() : nil
        frameLock.unlock()
        if let nextToken { scheduleRender(token: nextToken) }
    }

    /// Back to the test pattern (disconnect, stream teardown).
    func clearStream() {
        frameLock.lock()
        latestFrame = nil
        activeRenderToken = nil
        lastGamingGeneration = nil
        frameLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.stopGamingPacer()
            self?.view?.isPaused = false
        }
    }

    // MARK: Display-timed gaming late latch

    /// Bind a Core Video clock to the screen that owns the stream surface.
    /// MTKView remains paused: it still owns the layer, while this clock only
    /// forecasts when the layer's next drawable will scan out.
    private func startGamingPacer() {
        stopGamingPacer()

        frameLock.lock()
        let valid = lowLatencyPresentation
            && !presentationSuspended
            && latestFrame != nil
            && streamLayer != nil
        frameLock.unlock()
        guard valid,
              let screen = view?.window?.screen,
              let screenNumber = screen.deviceDescription[
                  NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber else { return }

        var displayLink: CVDisplayLink?
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &displayLink) == kCVReturnSuccess,
              let displayLink else { return }
        let callbackStatus = CVDisplayLinkSetOutputCallback(
            displayLink,
            { _, _, outputTime, _, _, context in
                guard let context else { return kCVReturnError }
                let renderer = Unmanaged<MetalRenderer>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                renderer.scheduleGamingTick(
                    outputHostTime: MetalRenderer.nearHorizonHostTime(
                        for: outputTime.pointee
                    )
                )
                return kCVReturnSuccess
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard callbackStatus == kCVReturnSuccess else { return }
        gamingDisplayLink = displayLink
        guard CVDisplayLinkStart(displayLink) == kCVReturnSuccess else {
            gamingDisplayLink = nil
            return
        }
    }

    /// Core Video can forecast the second upcoming vblank. The preceding
    /// refresh is a valid lower-latency target when the callback still leaves
    /// the complete render budget; otherwise retain the conservative forecast.
    private static func nearHorizonHostTime(for forecast: CVTimeStamp) -> UInt64 {
        let hostFrequency = CVGetHostClockFrequency()
        let refreshTicks: UInt64
        if forecast.videoTimeScale > 0,
           forecast.videoRefreshPeriod > 0 {
            refreshTicks = UInt64(
                Double(forecast.videoRefreshPeriod)
                    / Double(forecast.videoTimeScale)
                    * hostFrequency
            )
        } else {
            refreshTicks = 0
        }
        let nearHostTime = forecast.hostTime > refreshTicks
            ? forecast.hostTime - refreshTicks
            : forecast.hostTime
        let now = CVGetCurrentHostTime()
        let minimumLeadTicks = UInt64(hostFrequency * gamingLatchLeadSeconds)
        let nearLeadTicks = nearHostTime > now ? nearHostTime - now : 0
        return nearLeadTicks >= minimumLeadTicks
            ? nearHostTime
            : forecast.hostTime
    }

    private func stopGamingPacer() {
        if let gamingDisplayLink {
            CVDisplayLinkStop(gamingDisplayLink)
            self.gamingDisplayLink = nil
        }
        frameLock.lock()
        gamingPacerGeneration &+= 1
        gamingTicksPending = 0
        rotateGamingRenderQueueLocked()
        frameLock.unlock()
    }

    /// Called on Core Video's real-time thread. It reserves at most two future
    /// display ticks and hands their timed waits to a serial render worker.
    private func scheduleGamingTick(outputHostTime: UInt64) {
        let leadTicks = UInt64(CVGetHostClockFrequency() * Self.gamingLatchLeadSeconds)
        let now = CVGetCurrentHostTime()
        let latchHostTime = outputHostTime > leadTicks
            ? max(outputHostTime - leadTicks, now)
            : now

        frameLock.lock()
        gamingTickCallbacks += 1
        gamingLookaheadTicks &+= outputHostTime > now ? outputHostTime - now : 0
        guard lowLatencyPresentation,
              !presentationSuspended,
              latestFrame != nil,
              streamLayer != nil else {
            frameLock.unlock()
            return
        }
        if gamingTicksPending >= Self.maximumPendingGamingTicks {
            gamingTicksBusy += 1
            frameLock.unlock()
            return
        }
        gamingTicksPending += 1
        gamingTicksScheduled += 1
        gamingWaitTicks &+= latchHostTime > now ? latchHostTime - now : 0
        let generation = gamingPacerGeneration
        let renderQueue = gamingRenderQueue
        frameLock.unlock()

        renderQueue.async { [weak self] in
            if latchHostTime > CVGetCurrentHostTime() {
                mach_wait_until(latchHostTime)
            }
            self?.drawLateLatchedFrame(pacerGeneration: generation,
                                       outputHostTime: outputHostTime)
        }
    }

    private func finishGamingTick(pacerGeneration: UInt64) {
        frameLock.lock()
        if gamingPacerGeneration == pacerGeneration {
            gamingTicksPending = max(0, gamingTicksPending - 1)
        }
        frameLock.unlock()
    }

    // Drawable acquisition precedes mailbox selection so a decode that lands
    // during a temporarily blocked acquisition can still win this refresh.
    // swiftlint:disable:next function_body_length
    private func drawLateLatchedFrame(pacerGeneration: UInt64,
                                      outputHostTime: UInt64) {
        defer { finishGamingTick(pacerGeneration: pacerGeneration) }

        guard let layer = gamingLayerWithFreshFrame(
            pacerGeneration: pacerGeneration,
            outputHostTime: outputHostTime
        ) else { return }
        let drawableStarted = CVGetCurrentHostTime()
        guard let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let drawableFinished = CVGetCurrentHostTime()
        frameLock.lock()
        gamingDrawableTicks &+= drawableFinished - drawableStarted
        gamingDrawableSamples += 1
        frameLock.unlock()

        frameLock.lock()
        guard gamingPacerGeneration == pacerGeneration,
              lowLatencyPresentation,
              !presentationSuspended,
              streamLayer === layer,
              let frame = latestFrame,
              frame.generation != lastGamingGeneration else {
            frameLock.unlock()
            return
        }
        let colors = colorState
        let fills = fillsDrawable
        frameLock.unlock()

        let drawableSize = CGSize(width: drawable.texture.width,
                                  height: drawable.texture.height)
        let coversDrawable = Self.videoCoversDrawable(frame: frame,
                                                      fills: fills,
                                                      drawableSize: drawableSize)
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = drawable.texture
        renderPass.colorAttachments[0].loadAction = coversDrawable ? .dontCare : .clear
        renderPass.colorAttachments[0].storeAction = .store
        if !coversDrawable {
            renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0,
                                                                      green: 0,
                                                                      blue: 0,
                                                                      alpha: 1)
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            return
        }

        let drawStartedMicros = ClientClock.nowMicros()
        guard drawVideo(frame: frame,
                        colors: colors,
                        fills: fills,
                        drawableSize: drawableSize,
                        encoder: encoder) else {
            encoder.endEncoding()
            return
        }
        encoder.endEncoding()

        frameLock.lock()
        let shouldSubmit = gamingPacerGeneration == pacerGeneration
            && lowLatencyPresentation
            && !presentationSuspended
            && streamLayer === layer
        if shouldSubmit { lastGamingGeneration = frame.generation }
        frameLock.unlock()
        guard shouldSubmit else { return }

        armGamingCallbacks(commandBuffer: commandBuffer,
                           drawable: drawable,
                           frame: frame,
                           drawStartedMicros: drawStartedMicros)
        // `atTime` is on the Core Animation host-time base. Commit before the
        // forecasted refresh and let Metal hold the completed drawable for
        // that exact phase instead of depending on submission timing alone.
        let presentationTime = Double(outputHostTime) / CVGetHostClockFrequency()
        if presentationTime > CACurrentMediaTime() {
            commandBuffer.present(drawable, atTime: presentationTime)
        } else {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
        let targetMicros = UInt64(presentationTime * 1_000_000)
        frameLock.lock()
        gamingTicksCommitted += 1
        if let captureMicros = frame.captureClientMicros,
           targetMicros >= captureMicros {
            gamingCaptureTargetMicros &+= targetMicros - captureMicros
            gamingCaptureTargetSamples += 1
        }
        frameLock.unlock()
    }
}

// MARK: Gaming frame admission

extension MetalRenderer {
    /// A frame just behind the ordinary latch gets one bounded retry rather
    /// than turning independent 180 Hz capture and 144 Hz scanout jitter into
    /// a visible doubled refresh.
    private func gamingLayerWithFreshFrame(pacerGeneration: UInt64,
                                           outputHostTime: UInt64) -> CAMetalLayer? {
        frameLock.lock()
        let presentationValid = gamingPacerGeneration == pacerGeneration
            && lowLatencyPresentation
            && !presentationSuspended
        let hasFreshFrame = latestFrame.map {
            $0.generation != lastGamingGeneration
        } == true
        let layer = streamLayer
        if presentationValid, !hasFreshFrame { gamingStaleRetries += 1 }
        frameLock.unlock()
        guard presentationValid, let layer else { return nil }
        guard !hasFreshFrame else { return layer }

        let retryLeadTicks = UInt64(
            CVGetHostClockFrequency() * Self.gamingStaleRetryLeadSeconds
        )
        let retryHostTime = outputHostTime > retryLeadTicks
            ? outputHostTime - retryLeadTicks
            : outputHostTime
        if retryHostTime > CVGetCurrentHostTime() {
            mach_wait_until(retryHostTime)
        }
        frameLock.lock()
        let recovered = gamingPacerGeneration == pacerGeneration
            && lowLatencyPresentation
            && !presentationSuspended
            && streamLayer === layer
            && latestFrame.map { $0.generation != lastGamingGeneration } == true
        if recovered { gamingStaleRecoveries += 1 }
        frameLock.unlock()
        return recovered ? layer : nil
    }
}

// MARK: Shared presentation and drawing

extension MetalRenderer {
    /// Per-second visibility into the real-time pacer. The four counters are
    /// hardware callbacks / admitted ticks / committed frames / busy skips.
    func drainGamingPacerMetrics() -> String {
        frameLock.lock()
        let callbacks = gamingTickCallbacks
        let scheduled = gamingTicksScheduled
        let committed = gamingTicksCommitted
        let busy = gamingTicksBusy
        let lookahead = gamingLookaheadTicks
        let wait = gamingWaitTicks
        let drawable = gamingDrawableTicks
        let drawableSamples = gamingDrawableSamples
        let captureTarget = gamingCaptureTargetMicros
        let captureTargetSamples = gamingCaptureTargetSamples
        let staleRetries = gamingStaleRetries
        let staleRecoveries = gamingStaleRecoveries
        gamingTickCallbacks = 0
        gamingTicksScheduled = 0
        gamingTicksCommitted = 0
        gamingTicksBusy = 0
        gamingLookaheadTicks = 0
        gamingWaitTicks = 0
        gamingDrawableTicks = 0
        gamingDrawableSamples = 0
        gamingCaptureTargetMicros = 0
        gamingCaptureTargetSamples = 0
        gamingStaleRetries = 0
        gamingStaleRecoveries = 0
        frameLock.unlock()

        let ticksPerMillisecond = CVGetHostClockFrequency() / 1_000
        func averageMilliseconds(_ ticks: UInt64, _ samples: Int) -> String {
            guard samples > 0 else { return "0.00" }
            return String(format: "%.2f", Double(ticks) / Double(samples) / ticksPerMillisecond)
        }
        func averageMicroseconds(_ micros: UInt64, _ samples: Int) -> String {
            guard samples > 0 else { return "n/a" }
            return String(format: "%.2f", Double(micros) / Double(samples) / 1_000)
        }
        return "pacer=\(callbacks)/\(scheduled)/\(committed)/\(busy)"
            + " lookahead_ms=\(averageMilliseconds(lookahead, callbacks))"
            + " latch_wait_ms=\(averageMilliseconds(wait, scheduled))"
            + " drawable_wait_ms=\(averageMilliseconds(drawable, drawableSamples))"
            + " cap_target_ms=\(averageMicroseconds(captureTarget, captureTargetSamples))"
            + " stale_retry=\(staleRecoveries)/\(staleRetries)"
    }

    /// Color conversion parameters from the decoder's SPS parsing.
    func setColorState(matrix: H264SPS.ColorMatrix, fullRange: Bool) {
        frameLock.lock()
        colorState = ColorState(matrix: matrix, fullRange: fullRange)
        frameLock.unlock()
    }

    /// US-010 one-to-one mode: the hosting view sizes the drawable to match
    /// the video pixel for pixel, so the quad must fill it exactly rather
    /// than trusting the letterbox math to land on a scale of 1.
    func setFillsDrawable(_ fills: Bool) {
        frameLock.lock()
        fillsDrawable = fills
        frameLock.unlock()
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        frameLock.lock()
        let suspended = presentationSuspended
        let gamingOwnsStream = lowLatencyPresentation && latestFrame != nil
        let failedToken = activeRenderToken
        frameLock.unlock()
        // The CVDisplayLink late latch owns gaming frames. MTKView continues
        // to drive the animated test pattern while there is no live stream.
        guard !suspended, !gamingOwnsStream else { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderPass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            if let failedToken { releaseRenderSlot(token: failedToken, after: nil) }
            return
        }

        frameLock.lock()
        let token = activeRenderToken
        let frame = token == nil ? nil : latestFrame
        let colors = colorState
        let fills = fillsDrawable
        frameLock.unlock()
        // Select the latest frame after acquiring a drawable: nextDrawable
        // can wait, and a frame decoded during that wait should not be charged
        // a negative main-queue delay or replaced by older pixels.
        let drawStartedMicros = ClientClock.nowMicros()

        var drewVideo = false
        if let frame {
            drewVideo = drawVideo(frame: frame,
                                  colors: colors,
                                  fills: fills,
                                  drawableSize: view.drawableSize,
                                  encoder: encoder)
        }
        if !drewVideo {
            drawTestPattern(view: view, encoder: encoder)
        }
        encoder.endEncoding()

        if drewVideo, let frame, let token {
            armPresentationCallbacks(commandBuffer: commandBuffer,
                                     drawable: drawable,
                                     frame: frame,
                                     token: token,
                                     drawStartedMicros: drawStartedMicros)
        } else if let token {
            commandBuffer.addCompletedHandler { [weak self] _ in
                self?.releaseRenderSlot(token: token, after: nil)
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Quality mode releases its one-frame producer slot on actual scanout,
    /// with a bounded fallback when an occluded layer omits that callback.
    private func armPresentationCallbacks(commandBuffer: MTLCommandBuffer,
                                          drawable: CAMetalDrawable,
                                          frame: StreamFrame,
                                          token: UInt64,
                                          drawStartedMicros: UInt64) {
        let submittedMicros = ClientClock.nowMicros()
        drawable.addPresentedHandler { [weak self] presented in
            guard let self else { return }
            self.releaseRenderSlot(token: token, after: frame.generation)
            if presented.presentedTime > 0 {
                self.onFramePresented?(
                    PresentationTiming(captureClientMicros: frame.captureClientMicros,
                                       decodedMicros: frame.decodedMicros,
                                       drawStartedMicros: drawStartedMicros,
                                       submittedMicros: submittedMicros,
                                       presentedMicros: UInt64(presented.presentedTime * 1_000_000))
                )
            }
        }
        commandBuffer.addCompletedHandler { [weak self] completed in
            guard let self else { return }
            if completed.status != .error {
                self.onFrameRenderCompleted?(
                    RenderCompletionTiming(captureClientMicros: frame.captureClientMicros,
                                           decodedMicros: frame.decodedMicros,
                                           submittedMicros: submittedMicros,
                                           completedMicros: ClientClock.nowMicros())
                )
            }
            if completed.status == .error {
                self.releaseRenderSlot(token: token, after: nil)
                return
            }
            self.presentationWatchdogQueue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.releaseRenderSlot(token: token, after: frame.generation)
            }
        }
    }

    // MARK: Test pattern (US-004, disconnected idle state)

    private func drawTestPattern(view: MTKView, encoder: MTLRenderCommandEncoder) {
        var time = Float(CACurrentMediaTime() - startTime)
        var viewportSize = SIMD2<Float>(Float(view.drawableSize.width),
                                        Float(view.drawableSize.height))
        // Current display-link target; the shader sizes its pacing ticker to it.
        var frameRate = Float(view.preferredFramesPerSecond)

        encoder.setRenderPipelineState(patternPipelineState)
        encoder.setFragmentBytes(&time, length: MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&viewportSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.setFragmentBytes(&frameRate, length: MemoryLayout<Float>.size, index: 2)
        // Single fullscreen triangle; the pattern is computed per-fragment.
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    // MARK: Stream video (US-005)

    /// Avoid loading/clearing a drawable that the video fully overwrites.
    private static func videoCoversDrawable(frame: StreamFrame, fills: Bool,
                                            drawableSize: CGSize) -> Bool {
        if fills { return true }
        guard frame.width > 0, frame.height > 0, drawableSize.width > 0,
              drawableSize.height > 0 else { return false }
        let widthAtDrawableHeight = CGFloat(frame.width) * drawableSize.height
            / CGFloat(frame.height)
        let heightAtDrawableWidth = CGFloat(frame.height) * drawableSize.width
            / CGFloat(frame.width)
        return abs(widthAtDrawableHeight - drawableSize.width) < 0.5
            && abs(heightAtDrawableWidth - drawableSize.height) < 0.5
    }

    /// Returns false when textures could not be produced; the caller falls
    /// back to the test pattern for this draw.
    private func drawVideo(frame: StreamFrame,
                           colors: ColorState,
                           fills: Bool,
                           drawableSize: CGSize,
                           encoder: MTLRenderCommandEncoder) -> Bool {
        // NV12: plane 0 is luma (r8), plane 1 is interleaved CbCr (rg8).
        guard let luma = makePlaneTexture(from: frame.pixelBuffer, plane: 0, format: .r8Unorm),
              let chroma = makePlaneTexture(from: frame.pixelBuffer, plane: 1, format: .rg8Unorm) else {
            return false
        }

        // Aspect-fit the video into the drawable (letterbox or pillarbox),
        // unless one-to-one mode already sized the drawable to the video.
        var scale = SIMD2<Float>(1, 1)
        if !fills {
            guard drawableSize.height > 0 else { return false }
            let drawableAspect = Float(drawableSize.width / drawableSize.height)
            let videoAspect = Float(frame.width) / Float(frame.height)
            if videoAspect > drawableAspect {
                scale.y = drawableAspect / videoAspect
            } else {
                scale.x = videoAspect / drawableAspect
            }
        }

        var colorCoeffs = Self.colorCoefficients(for: colors.matrix)
        // Limited-range content expands from 16..235 (Y) and 16..240 (C),
        // full-range content passes through.
        var rangeCoeffs = colors.fullRange
            ? SIMD4<Float>(0, 1, 0.5, 1)
            : SIMD4<Float>(16 / 255, 255 / 219, 0.5, 255 / 224)

        encoder.setRenderPipelineState(videoPipelineState)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentTexture(luma.texture, index: 0)
        encoder.setFragmentTexture(chroma.texture, index: 1)
        encoder.setFragmentBytes(&colorCoeffs, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentBytes(&rangeCoeffs, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        return true
    }

    private func makePlaneTexture(from pixelBuffer: CVPixelBuffer,
                                  plane: Int,
                                  format: MTLPixelFormat) -> PlaneTexture? {
        guard let textureCache else { return nil }
        var reference: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                               textureCache,
                                                               pixelBuffer,
                                                               nil,
                                                               format,
                                                               CVPixelBufferGetWidthOfPlane(pixelBuffer, plane),
                                                               CVPixelBufferGetHeightOfPlane(pixelBuffer, plane),
                                                               plane,
                                                               &reference)
        guard status == kCVReturnSuccess,
              let reference,
              let texture = CVMetalTextureGetTexture(reference) else {
            return nil
        }
        return PlaneTexture(reference: reference, texture: texture)
    }

    /// YCbCr to RGB coefficients for the fragment shader, from Kr/Kb per
    /// matrix.
    private static func colorCoefficients(for matrix: H264SPS.ColorMatrix) -> SIMD4<Float> {
        let kr: Float
        let kb: Float
        switch matrix {
        case .bt601: kr = 0.299; kb = 0.114
        case .bt709: kr = 0.2126; kb = 0.0722
        case .bt2020: kr = 0.2627; kb = 0.0593
        }
        let kg = 1 - kr - kb
        return SIMD4<Float>(2 * (1 - kr),
                            2 * kb * (1 - kb) / kg,
                            2 * kr * (1 - kr) / kg,
                            2 * (1 - kb))
    }
}

// MARK: Hardware-paced gaming telemetry

extension MetalRenderer {
    /// The hardware display callback schedules the next frame, so these
    /// handlers record completion and scanout without driving a submission.
    private func armGamingCallbacks(commandBuffer: MTLCommandBuffer,
                                    drawable: CAMetalDrawable,
                                    frame: StreamFrame,
                                    drawStartedMicros: UInt64) {
        let submittedMicros = ClientClock.nowMicros()
        drawable.addPresentedHandler { [weak self] presented in
            guard let self, presented.presentedTime > 0 else { return }
            self.onFramePresented?(
                PresentationTiming(captureClientMicros: frame.captureClientMicros,
                                   decodedMicros: frame.decodedMicros,
                                   drawStartedMicros: drawStartedMicros,
                                   submittedMicros: submittedMicros,
                                   presentedMicros: UInt64(presented.presentedTime * 1_000_000))
            )
        }
        commandBuffer.addCompletedHandler { [weak self] completed in
            guard let self, completed.status != .error else { return }
            self.onFrameRenderCompleted?(
                RenderCompletionTiming(captureClientMicros: frame.captureClientMicros,
                                       decodedMicros: frame.decodedMicros,
                                       submittedMicros: submittedMicros,
                                       completedMicros: ClientClock.nowMicros())
            )
        }
    }
}
