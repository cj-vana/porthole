// swiftlint:disable file_length
import CoreVideo
import Darwin
import Foundation
import MetalKit
import QuartzCore

/// Draws decoded video while connected and the US-004 test pattern otherwise.
/// VideoToolbox's NV12 IOSurfaces map into zero-copy Metal textures; the shader
/// applies SPS color state and letterboxes into the native-Retina drawable.
/// Presentation timing: quality mode asks MTKView for a draw on arrival.
/// Gaming seeds a phase-locked mach-time cadence wheel from CVDisplayLink's
/// hardware period, then latches the newest mailbox frame immediately before
/// each scanout and renders directly into CAMetalLayer. Callback jitter cannot
/// perturb the established cadence.
final class MetalRenderer: NSObject, MTKViewDelegate {
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm
    /// Leave enough time for this single-triangle pass and Metal scheduling,
    /// while keeping the mailbox open for almost the entire refresh period.
    /// Four milliseconds is an intentionally conservative direct-scanout
    /// guard: the tested 144 Hz path stays on the current refresh instead of
    /// occasionally paying a full 6.94 ms miss. Hidden microsecond overrides
    /// keep future on-device A/B tests reproducible without turning them into
    /// UI claims.
    private static let gamingLatchLeadSeconds = tunedSeconds(
        key: "gamingLatchLeadMicros",
        defaultMicros: 4_000,
        allowedMicros: 1_000...5_000
    )
    /// A drawable that arrives inside this measured render margin is retained
    /// for the next tick instead of being submitted across a scanout boundary.
    private static let gamingMinimumTargetLeadSeconds = 0.0010
    /// Only a stale tick spends this extra 0.5 ms waiting for a frame that
    /// landed just across the independent source/display clock boundary.
    private static let gamingStaleRetryLeadSeconds = 0.0015
    /// `mach_wait_until` can be timer-coalesced past a vblank under sustained
    /// WindowServer load. Park most of the interval, then spin only the final
    /// half millisecond in gaming mode so the content latch cannot oversleep.
    private static let gamingLatchSpinSeconds = 0.0005
    /// Core Video's output phase precedes the compositor-reported presentation
    /// slot on the tested direct-display path. Advance the cadence toward the
    /// observed slot while retaining a complete render margin.
    private static let gamingOutputPhaseOffsetSeconds = tunedSeconds(
        key: "gamingOutputPhaseMicros",
        defaultMicros: 2_500,
        allowedMicros: 0...6_000
    )

    private static func tunedSeconds(key: String,
                                     defaultMicros: Int,
                                     allowedMicros: ClosedRange<Int>) -> Double {
        let stored = UserDefaults.standard.object(forKey: key) as? NSNumber
        let micros = stored.map { Int(truncating: $0) } ?? defaultMicros
        return Double(min(max(micros, allowedMicros.lowerBound), allowedMicros.upperBound))
            / 1_000_000
    }
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

    private struct GamingDrawableReservation {
        let drawable: CAMetalDrawable?
        let pending: Bool
        let ready: DispatchSemaphore
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
                                                  qos: .userInteractive,
                                                  autoreleaseFrequency: .workItem)
    private var gamingRenderQueueGeneration: UInt64 = 0
    private var gamingPrefetchQueue = DispatchQueue(label: "com.porthole.mac.drawable-prefetch.0",
                                                    qos: .userInteractive,
                                                    autoreleaseFrequency: .workItem)
    private var gamingPrefetchQueueGeneration: UInt64 = 0
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
    /// Tracks whether the late latch found a new decoded generation. When the
    /// source misses a tick, gaming redraws this generation to keep the
    /// two-buffer swapchain recycling instead of abandoning its drawable.
    private var lastGamingGeneration: UInt64?
    private var gamingPacerGeneration: UInt64 = 0
    private var gamingCadenceRunning = false
    private var gamingTickCallbacks = 0
    private var gamingTicksScheduled = 0
    private var gamingTicksCommitted = 0
    private var gamingTicksBusy = 0
    private var gamingFrameHolds = 0
    /// Reserve the next writable two-buffer swapchain surface after submitting
    /// N, then bind the newest decoded surface only at N+1's latch. Resource
    /// acquisition no longer consumes the content-latch budget.
    private var prefetchedGamingDrawable: CAMetalDrawable?
    private var prefetchedGamingGeneration: UInt64 = 0
    private var gamingDrawablePrefetchPending = false
    private var gamingDrawablePrefetchReady = DispatchSemaphore(value: 0)
    private var gamingDrawablePrefetchHits = 0
    private var gamingDrawablePrefetchMisses = 0
    private var gamingDrawablePrefetchRecoveries = 0
    private var gamingDrawablePrefetchTimeouts = 0
    private var gamingDrawablePrefetchLatchWaitTicks: UInt64 = 0
    private var gamingDrawablePrefetchTicks: UInt64 = 0
    private var gamingDrawablePrefetchSamples = 0
    private var gamingLookaheadTicks: UInt64 = 0
    private var gamingWaitTicks: UInt64 = 0
    private var gamingDrawableTicks: UInt64 = 0
    private var gamingDrawableSamples = 0
    private var gamingDeadlineResyncs = 0
    private var gamingDeadlineDeficitTicks: UInt64 = 0
    private var gamingDeadlineMaximumDeficitTicks: UInt64 = 0
    private var gamingCaptureTargetMicros: UInt64 = 0
    private var gamingCaptureTargetSamples = 0
    private var gamingPresentationPhaseMicros: Int64 = 0
    private var gamingPresentationPhaseSamples = 0
    private var gamingStaleRetries = 0
    private var gamingStaleRecoveries = 0
    private var lowLatencyPresentation = false
    /// AppKit replaces or re-homes the drawable swapchain during native
    /// fullscreen transitions. Do not acquire from the disappearing layer;
    /// the completed transition rebinds and submits the newest mailbox entry.
    private var presentationSuspended = false
    private var colorState = ColorState(matrix: .bt709, fullRange: false)
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
        gamingRenderQueue = DispatchQueue(label: label,
                                          qos: .userInteractive,
                                          autoreleaseFrequency: .workItem)
    }

    private func rotateGamingPrefetchQueueLocked() {
        gamingPrefetchQueueGeneration &+= 1
        let label = "com.porthole.mac.drawable-prefetch.\(gamingPrefetchQueueGeneration)"
        gamingPrefetchQueue = DispatchQueue(label: label,
                                            qos: .userInteractive,
                                            autoreleaseFrequency: .workItem)
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
}

// MARK: Phase-locked gaming late latch

extension MetalRenderer {
    /// Bind Core Video's forecast clock to the screen that owns the stream.
    /// Its nominal period and initial phase seed the independent cadence wheel
    /// below; callback delivery jitter cannot move an established latch.
    private func startGamingPacer() {
        stopGamingPacer()

        frameLock.lock()
        let valid = lowLatencyPresentation
            && !presentationSuspended
            && latestFrame != nil
            && streamLayer != nil
        frameLock.unlock()
        guard valid else { return }
        guard
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
                let forecast = outputTime.pointee
                let refreshTicks: UInt64
                if forecast.videoTimeScale > 0,
                   forecast.videoRefreshPeriod > 0 {
                    refreshTicks = UInt64(
                        Double(forecast.videoRefreshPeriod)
                            / Double(forecast.videoTimeScale)
                            * CVGetHostClockFrequency()
                    )
                } else {
                    refreshTicks = UInt64(CVGetHostClockFrequency() / 60)
                }
                renderer.scheduleGamingTick(outputHostTime: forecast.hostTime,
                                            refreshTicks: refreshTicks)
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

    private func stopGamingPacer() {
        if let gamingDisplayLink {
            CVDisplayLinkStop(gamingDisplayLink)
            self.gamingDisplayLink = nil
        }
        frameLock.lock()
        gamingPacerGeneration &+= 1
        gamingCadenceRunning = false
        let retiredPrefetch = prefetchedGamingDrawable
        prefetchedGamingDrawable = nil
        gamingDrawablePrefetchPending = false
        gamingDrawablePrefetchReady = DispatchSemaphore(value: 0)
        rotateGamingRenderQueueLocked()
        rotateGamingPrefetchQueueLocked()
        frameLock.unlock()
        withExtendedLifetime(retiredPrefetch) {}
    }

    /// Core Video supplies the display phase and nominal period, but its
    /// callback delivery can bunch under WindowServer load. Seed one
    /// mach-clocked cadence wheel from that phase and let it issue evenly
    /// spaced latches; later callbacks are diagnostics, not a second clock.
    private func scheduleGamingTick(outputHostTime: UInt64,
                                    refreshTicks: UInt64) {
        let now = CVGetCurrentHostTime()

        frameLock.lock()
        gamingTickCallbacks += 1
        gamingLookaheadTicks &+= outputHostTime > now ? outputHostTime - now : 0
        guard lowLatencyPresentation,
              !presentationSuspended,
              latestFrame != nil,
              streamLayer != nil,
              refreshTicks > 0 else {
            frameLock.unlock()
            return
        }
        guard !gamingCadenceRunning else {
            frameLock.unlock()
            return
        }
        gamingCadenceRunning = true
        let generation = gamingPacerGeneration
        let renderQueue = gamingRenderQueue
        frameLock.unlock()

        renderQueue.async { [weak self] in
            self?.runGamingCadence(pacerGeneration: generation,
                                   forecastHostTime: outputHostTime,
                                   refreshTicks: refreshTicks)
        }
    }

    private func runGamingCadence(pacerGeneration: UInt64,
                                  forecastHostTime: UInt64,
                                  refreshTicks: UInt64) {
        let latchLeadTicks = UInt64(
            CVGetHostClockFrequency() * Self.gamingLatchLeadSeconds
        )
        let outputPhaseTicks = UInt64(
            CVGetHostClockFrequency() * Self.gamingOutputPhaseOffsetSeconds
        )
        var outputHostTime = forecastHostTime &+ outputPhaseTicks
        var now = CVGetCurrentHostTime()
        while outputHostTime > refreshTicks,
              outputHostTime - refreshTicks > now + latchLeadTicks {
            outputHostTime -= refreshTicks
        }
        while outputHostTime <= now + latchLeadTicks {
            outputHostTime &+= refreshTicks
        }

        while true {
            let latchHostTime = outputHostTime > latchLeadTicks
                ? outputHostTime - latchLeadTicks
                : outputHostTime
            now = CVGetCurrentHostTime()
            if latchHostTime <= now {
                frameLock.lock()
                guard gamingPacerGeneration == pacerGeneration,
                      gamingCadenceRunning else {
                    frameLock.unlock()
                    return
                }
                gamingTicksBusy += 1
                frameLock.unlock()
                outputHostTime &+= refreshTicks
                continue
            }

            frameLock.lock()
            guard gamingPacerGeneration == pacerGeneration,
                  gamingCadenceRunning,
                  lowLatencyPresentation,
                  !presentationSuspended,
                  latestFrame != nil,
                  streamLayer != nil else {
                frameLock.unlock()
                return
            }
            gamingTicksScheduled += 1
            gamingWaitTicks &+= latchHostTime - now
            frameLock.unlock()

            drawLateLatchedFrame(pacerGeneration: pacerGeneration,
                                 outputHostTime: outputHostTime,
                                 latchHostTime: latchHostTime)
            outputHostTime &+= refreshTicks
        }
    }

    private static func waitPrecisely(until hostTime: UInt64) {
        let spinTicks = UInt64(CVGetHostClockFrequency() * gamingLatchSpinSeconds)
        let parkUntil = hostTime > spinTicks ? hostTime - spinTicks : hostTime
        if parkUntil > CVGetCurrentHostTime() {
            mach_wait_until(parkUntil)
        }
        while CVGetCurrentHostTime() < hostTime {}
    }

    // Acquire this refresh's writable surface as soon as Core Video forecasts
    // it, then keep the pixel mailbox open until the late-latch deadline. This
    // splits scarce swapchain admission from content admission without owning
    // a third surface or queueing an extra frame.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func drawLateLatchedFrame(pacerGeneration: UInt64,
                                      outputHostTime: UInt64,
                                      latchHostTime: UInt64) {
        guard let layer = gamingLayer(pacerGeneration: pacerGeneration) else { return }
        let drawableStarted = CVGetCurrentHostTime()
        var reservation = takePrefetchedGamingDrawable(
            layer: layer,
            pacerGeneration: pacerGeneration
        )
        if reservation.drawable == nil, reservation.pending {
            let deadlineLeadTicks = UInt64(
                CVGetHostClockFrequency() * Self.gamingMinimumTargetLeadSeconds
            )
            let deadline = outputHostTime > deadlineLeadTicks
                ? outputHostTime - deadlineLeadTicks
                : outputHostTime
            let waitStarted = CVGetCurrentHostTime()
            if deadline > waitStarted {
                let waitNanoseconds = Int(
                    Double(deadline - waitStarted)
                        / CVGetHostClockFrequency()
                        * 1_000_000_000
                )
                _ = reservation.ready.wait(timeout: .now() + .nanoseconds(waitNanoseconds))
            }
            let waitFinished = CVGetCurrentHostTime()
            if waitFinished <= deadline {
                reservation = takePrefetchedGamingDrawable(
                    layer: layer,
                    pacerGeneration: pacerGeneration
                )
            }
            frameLock.lock()
            gamingDrawablePrefetchLatchWaitTicks &+= waitFinished - waitStarted
            if reservation.drawable == nil {
                gamingDrawablePrefetchTimeouts += 1
            } else {
                gamingDrawablePrefetchRecoveries += 1
            }
            frameLock.unlock()
            guard waitFinished <= deadline else { return }
        }
        guard !reservation.pending || reservation.drawable != nil else { return }
        guard let drawable = reservation.drawable ?? layer.nextDrawable() else { return }
        let drawableFinished = CVGetCurrentHostTime()
        frameLock.lock()
        if reservation.drawable == nil {
            gamingDrawablePrefetchMisses += 1
        } else {
            gamingDrawablePrefetchHits += 1
        }
        gamingDrawableTicks &+= drawableFinished - drawableStarted
        gamingDrawableSamples += 1
        frameLock.unlock()
        scheduleNextGamingDrawablePrefetch(layer: layer,
                                           pacerGeneration: pacerGeneration)
        if latchHostTime > CVGetCurrentHostTime() {
            Self.waitPrecisely(until: latchHostTime)
        }
        guard let latchedLayer = gamingLayerAfterLateLatch(
            pacerGeneration: pacerGeneration,
            outputHostTime: outputHostTime
        ), latchedLayer === layer else { return }
        let contentLatched = CVGetCurrentHostTime()
        let minimumLeadTicks = UInt64(
            CVGetHostClockFrequency() * Self.gamingMinimumTargetLeadSeconds
        )
        let missedDeadline = outputHostTime <= contentLatched
            || outputHostTime - contentLatched < minimumLeadTicks
        if missedDeadline {
            // Keep the drawable lifecycle moving even when WindowServer hands
            // this slot back too late for its forecast vblank. Abandoning an
            // acquired drawable delays its recycle and turns one late tick into
            // a sustained starvation cascade; the pacer resynchronizes below.
            frameLock.lock()
            gamingDeadlineResyncs += 1
            let availableLead = outputHostTime > contentLatched
                ? outputHostTime - contentLatched
                : 0
            let deficit = minimumLeadTicks > availableLead
                ? minimumLeadTicks - availableLead
                : 0
            gamingDeadlineDeficitTicks &+= deficit
            gamingDeadlineMaximumDeficitTicks = max(gamingDeadlineMaximumDeficitTicks, deficit)
            frameLock.unlock()
        }
        let presentationTime = Double(outputHostTime) / CVGetHostClockFrequency()
        submitGamingDrawable(drawable,
                             layer: layer,
                             pacerGeneration: pacerGeneration,
                             targetPresentationMicros: UInt64(presentationTime * 1_000_000))
    }
}

// MARK: Shared gaming drawable submission

extension MetalRenderer {
    // swiftlint:disable function_body_length
    /// Encode one newest-mailbox frame into a drawable already admitted by the
    /// active presentation driver. No caller may queue more than its one
    /// driver-owned drawable.
    private func submitGamingDrawable(_ drawable: CAMetalDrawable,
                                      layer: CAMetalLayer,
                                      pacerGeneration: UInt64,
                                      targetPresentationMicros: UInt64) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        frameLock.lock()
        guard gamingPacerGeneration == pacerGeneration,
              lowLatencyPresentation,
              !presentationSuspended,
              streamLayer === layer,
              let frame = latestFrame else {
            frameLock.unlock()
            return
        }
        let holdsPreviousFrame = frame.generation == lastGamingGeneration
        let colors = colorState
        frameLock.unlock()

        let drawableSize = CGSize(width: drawable.texture.width,
                                  height: drawable.texture.height)
        let coversDrawable = Self.videoCoversDrawable(frame: frame,
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
        guard drawVideo(frame: frame,
                        colors: colors,
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
        if shouldSubmit {
            if holdsPreviousFrame { gamingFrameHolds += 1 }
            lastGamingGeneration = frame.generation
        }
        frameLock.unlock()
        guard shouldSubmit else { return }

        armGamingCompletion(commandBuffer: commandBuffer,
                            drawable: drawable,
                            frame: frame,
                            targetPresentationMicros: targetPresentationMicros)
        commandBuffer.present(drawable)
        commandBuffer.commit()
        // Committed command buffers are retained by Metal through completion.
        // Waiting for `scheduled` here serializes the cadence wheel behind
        // WindowServer's present handshake; at native 1440p that handshake can
        // span a refresh and collapse an otherwise 144 Hz path to 60 Hz.
        frameLock.lock()
        gamingTicksCommitted += 1
        if let captureMicros = frame.captureClientMicros,
           targetPresentationMicros >= captureMicros {
            gamingCaptureTargetMicros &+= targetPresentationMicros - captureMicros
            gamingCaptureTargetSamples += 1
        }
        frameLock.unlock()
    }
    // swiftlint:enable function_body_length
}

// MARK: Gaming tick lifetime

extension MetalRenderer {
    private func takePrefetchedGamingDrawable(
        layer: CAMetalLayer,
        pacerGeneration: UInt64
    ) -> GamingDrawableReservation {
        frameLock.lock()
        let valid = gamingPacerGeneration == pacerGeneration
            && streamLayer === layer
            && prefetchedGamingGeneration == pacerGeneration
        let drawable = valid ? prefetchedGamingDrawable : nil
        if valid { prefetchedGamingDrawable = nil }
        let pending = gamingPacerGeneration == pacerGeneration
            && gamingDrawablePrefetchPending
        let ready = gamingDrawablePrefetchReady
        frameLock.unlock()
        return GamingDrawableReservation(drawable: drawable,
                                         pending: pending,
                                         ready: ready)
    }

    private func scheduleNextGamingDrawablePrefetch(
        layer: CAMetalLayer,
        pacerGeneration: UInt64
    ) {
        frameLock.lock()
        let valid = gamingPacerGeneration == pacerGeneration
            && lowLatencyPresentation
            && !presentationSuspended
            && streamLayer === layer
        guard valid, !gamingDrawablePrefetchPending,
              prefetchedGamingDrawable == nil else {
            frameLock.unlock()
            return
        }
        gamingDrawablePrefetchPending = true
        let prefetchQueue = gamingPrefetchQueue
        let ready = DispatchSemaphore(value: 0)
        gamingDrawablePrefetchReady = ready
        frameLock.unlock()

        prefetchQueue.async { [weak self] in
            let started = CVGetCurrentHostTime()
            let drawable = layer.nextDrawable()
            let finished = CVGetCurrentHostTime()
            guard let self else { return }
            self.frameLock.lock()
            let valid = self.gamingPacerGeneration == pacerGeneration
                && self.lowLatencyPresentation
                && !self.presentationSuspended
                && self.streamLayer === layer
            var retiredDrawable: CAMetalDrawable?
            if self.gamingPacerGeneration == pacerGeneration {
                self.gamingDrawablePrefetchPending = false
                self.gamingDrawablePrefetchTicks &+= finished - started
                self.gamingDrawablePrefetchSamples += 1
            }
            if valid, let drawable {
                retiredDrawable = self.prefetchedGamingDrawable
                self.prefetchedGamingDrawable = drawable
                self.prefetchedGamingGeneration = pacerGeneration
            } else {
                retiredDrawable = drawable
            }
            self.frameLock.unlock()
            withExtendedLifetime(retiredDrawable) {}
            ready.signal()
        }
    }
}

// MARK: Gaming frame admission

extension MetalRenderer {
    private func gamingLayer(pacerGeneration: UInt64) -> CAMetalLayer? {
        frameLock.lock()
        let layer = gamingPacerGeneration == pacerGeneration
            && lowLatencyPresentation
            && !presentationSuspended
            && latestFrame != nil
            ? streamLayer
            : nil
        frameLock.unlock()
        return layer
    }

    /// A frame just behind the ordinary latch gets one bounded retry. If the
    /// source still has not advanced, redraw the previous generation so the
    /// acquired drawable is presented and recycled; the held pixels are no
    /// older than leaving the same drawable on screen for another refresh.
    private func gamingLayerAfterLateLatch(pacerGeneration: UInt64,
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
            Self.waitPrecisely(until: retryHostTime)
        }
        frameLock.lock()
        let recovered = gamingPacerGeneration == pacerGeneration
            && lowLatencyPresentation
            && !presentationSuspended
            && streamLayer === layer
            && latestFrame.map { $0.generation != lastGamingGeneration } == true
        let canHold = gamingPacerGeneration == pacerGeneration
            && lowLatencyPresentation
            && !presentationSuspended
            && streamLayer === layer
            && latestFrame != nil
        if recovered { gamingStaleRecoveries += 1 }
        frameLock.unlock()
        return recovered || canHold ? layer : nil
    }
}

// MARK: Shared presentation and drawing

extension MetalRenderer {
    // swiftlint:disable function_body_length
    /// Per-second visibility into the real-time pacer. The four counters are
    /// hardware callbacks / cadence ticks / committed frames / late skips.
    func drainGamingPacerMetrics() -> String {
        frameLock.lock()
        let callbacks = gamingTickCallbacks
        let scheduled = gamingTicksScheduled
        let committed = gamingTicksCommitted
        let busy = gamingTicksBusy
        let held = gamingFrameHolds
        let prefetchHits = gamingDrawablePrefetchHits
        let prefetchMisses = gamingDrawablePrefetchMisses
        let prefetchRecoveries = gamingDrawablePrefetchRecoveries
        let prefetchTimeouts = gamingDrawablePrefetchTimeouts
        let prefetchLatchWait = gamingDrawablePrefetchLatchWaitTicks
        let prefetch = gamingDrawablePrefetchTicks
        let prefetchSamples = gamingDrawablePrefetchSamples
        let lookahead = gamingLookaheadTicks
        let wait = gamingWaitTicks
        let drawable = gamingDrawableTicks
        let drawableSamples = gamingDrawableSamples
        let deadlineResyncs = gamingDeadlineResyncs
        let deadlineDeficit = gamingDeadlineDeficitTicks
        let deadlineMaximumDeficit = gamingDeadlineMaximumDeficitTicks
        let captureTarget = gamingCaptureTargetMicros
        let captureTargetSamples = gamingCaptureTargetSamples
        let presentationPhase = gamingPresentationPhaseMicros
        let presentationPhaseSamples = gamingPresentationPhaseSamples
        let staleRetries = gamingStaleRetries
        let staleRecoveries = gamingStaleRecoveries
        gamingTickCallbacks = 0
        gamingTicksScheduled = 0
        gamingTicksCommitted = 0
        gamingTicksBusy = 0
        gamingFrameHolds = 0
        gamingDrawablePrefetchHits = 0
        gamingDrawablePrefetchMisses = 0
        gamingDrawablePrefetchRecoveries = 0
        gamingDrawablePrefetchTimeouts = 0
        gamingDrawablePrefetchLatchWaitTicks = 0
        gamingDrawablePrefetchTicks = 0
        gamingDrawablePrefetchSamples = 0
        gamingLookaheadTicks = 0
        gamingWaitTicks = 0
        gamingDrawableTicks = 0
        gamingDrawableSamples = 0
        gamingDeadlineResyncs = 0
        gamingDeadlineDeficitTicks = 0
        gamingDeadlineMaximumDeficitTicks = 0
        gamingCaptureTargetMicros = 0
        gamingCaptureTargetSamples = 0
        gamingPresentationPhaseMicros = 0
        gamingPresentationPhaseSamples = 0
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
        func averageSignedMicroseconds(_ micros: Int64, _ samples: Int) -> String {
            guard samples > 0 else { return "n/a" }
            return String(format: "%.2f", Double(micros) / Double(samples) / 1_000)
        }
        return "present_driver=core_video_latch"
            + " pacer=\(callbacks)/\(scheduled)/\(committed)/\(busy)"
            + " hold=\(held)"
            + " lookahead_ms=\(averageMilliseconds(lookahead, callbacks))"
            + " latch_wait_ms=\(averageMilliseconds(wait, scheduled))"
            + " drawable_wait_ms=\(averageMilliseconds(drawable, drawableSamples))"
            + " prefetch=\(prefetchHits)/\(prefetchMisses)"
            + " prefetch_wait_ms=\(averageMilliseconds(prefetch, prefetchSamples))"
            + " prefetch_latch=\(prefetchRecoveries)/\(prefetchTimeouts)"
            + "/\(averageMilliseconds(prefetchLatchWait, prefetchRecoveries + prefetchTimeouts))"
            + " cap_target_ms=\(averageMicroseconds(captureTarget, captureTargetSamples))"
            + " present_phase_ms=\(averageSignedMicroseconds(presentationPhase, presentationPhaseSamples))"
            + " latch_lead_ms=\(String(format: "%.2f", Self.gamingLatchLeadSeconds * 1_000))"
            + " phase_offset_ms=\(String(format: "%.2f", Self.gamingOutputPhaseOffsetSeconds * 1_000))"
            + " deadline_resync=\(deadlineResyncs)"
            + " deadline_deficit_ms=\(averageMilliseconds(deadlineDeficit, deadlineResyncs))"
            + "/\(averageMilliseconds(deadlineMaximumDeficit, 1))"
            + " stale_retry=\(staleRecoveries)/\(staleRetries)"
    }
    // swiftlint:enable function_body_length

    /// Color conversion parameters from the decoder's SPS parsing.
    func setColorState(matrix: H264SPS.ColorMatrix, fullRange: Bool) {
        frameLock.lock()
        colorState = ColorState(matrix: matrix, fullRange: fullRange)
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
        frameLock.unlock()
        // Select the latest frame after acquiring a drawable: nextDrawable
        // can wait, and a frame decoded during that wait should not be charged
        // a negative main-queue delay or replaced by older pixels.
        let drawStartedMicros = ClientClock.nowMicros()

        var drewVideo = false
        if let frame {
            drewVideo = drawVideo(frame: frame,
                                  colors: colors,
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
    private static func videoCoversDrawable(frame: StreamFrame,
                                            drawableSize: CGSize) -> Bool {
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
                           drawableSize: CGSize,
                           encoder: MTLRenderCommandEncoder) -> Bool {
        // NV12: plane 0 is luma (r8), plane 1 is interleaved CbCr (rg8).
        guard let luma = makePlaneTexture(from: frame.pixelBuffer, plane: 0, format: .r8Unorm),
              let chroma = makePlaneTexture(from: frame.pixelBuffer, plane: 1, format: .rg8Unorm) else {
            return false
        }

        // Aspect-fit during the brief interval before a remote source resize
        // settles, then the source and drawable naturally share an aspect.
        var scale = SIMD2<Float>(1, 1)
        guard drawableSize.height > 0 else { return false }
        let drawableAspect = Float(drawableSize.width / drawableSize.height)
        let videoAspect = Float(frame.width) / Float(frame.height)
        if videoAspect > drawableAspect {
            scale.y = drawableAspect / videoAspect
        } else {
            scale.x = videoAspect / drawableAspect
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
    /// The capture-free feedback block activates full-rate drawable recycling
    /// without retaining decoded frames. Completion records GPU timing and
    /// keeps the source IOSurface alive until Metal has finished sampling it.
    private func armGamingCompletion(commandBuffer: MTLCommandBuffer,
                                     drawable: CAMetalDrawable,
                                     frame: StreamFrame,
                                     targetPresentationMicros: UInt64) {
        let submittedMicros = ClientClock.nowMicros()
        let captureClientMicros = frame.captureClientMicros
        let decodedMicros = frame.decodedMicros
        drawable.addPresentedHandler { [weak self] presented in
            guard let self, presented.presentedTime > 0 else { return }
            let presentedMicros = UInt64(presented.presentedTime * 1_000_000)
            let phaseMicros = Int64(presentedMicros) - Int64(targetPresentationMicros)
            if abs(phaseMicros) < 100_000 {
                self.frameLock.lock()
                self.gamingPresentationPhaseMicros += phaseMicros
                self.gamingPresentationPhaseSamples += 1
                self.frameLock.unlock()
            }
            self.onFramePresented?(
                PresentationTiming(captureClientMicros: captureClientMicros,
                                   decodedMicros: decodedMicros,
                                   drawStartedMicros: submittedMicros,
                                   submittedMicros: submittedMicros,
                                   presentedMicros: presentedMicros)
            )
        }
        commandBuffer.addCompletedHandler { [weak self] completed in
            guard let self, completed.status != .error else { return }
            self.onFrameRenderCompleted?(
                RenderCompletionTiming(captureClientMicros: captureClientMicros,
                                       decodedMicros: decodedMicros,
                                       submittedMicros: submittedMicros,
                                       completedMicros: ClientClock.nowMicros())
            )
        }
    }
}
