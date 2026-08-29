// swiftlint:disable file_length
import AppKit
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
/// each scanout and renders directly into CAMetalLayer. A bounded phase servo
/// corrects drift without letting individual callback jitter become the clock.
final class MetalRenderer: NSObject, MTKViewDelegate {
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm
    /// Leave enough time for this single-triangle pass and Metal scheduling,
    /// while keeping the mailbox open for almost the entire refresh period.
    /// Four milliseconds keeps the mailbox open while leaving enough time for
    /// the measured Metal pass. A short feedback-controlled recovery window
    /// adds one millisecond only after a drawable or presentation outlier; the
    /// steady path does not permanently pay that latency tax. Hidden overrides
    /// keep future on-device A/B tests reproducible without becoming UI claims.
    private static let gamingLatchLeadSeconds = tunedSeconds(
        key: "gamingLatchLeadMicros",
        defaultMicros: 4_000,
        allowedMicros: 1_000...5_000
    )
    private static let gamingRecoveryLeadSeconds = 0.0010
    private static let gamingRecoveryFrameCount = 6
    private static let gamingDrawableRecoveryThresholdSeconds = 0.00075
    /// When a faster source is about to finish its next decode, Gaming may
    /// hold an already-acquired drawable for this bounded interval and submit
    /// the newer frame to the same output slot. The live A/B against a 214 fps
    /// source hit its prediction on 98-99% of attempted ticks and lowered mean
    /// capture-to-present by 0.7 ms at no presentation-rate cost; zero disables
    /// the wait and restores the plain late-acquire policy.
    private static let gamingPredictiveLatchMaximumWaitSeconds = tunedSeconds(
        key: "gamingPredictiveLatchMaxMicros",
        defaultMicros: 1_500,
        allowedMicros: 0...1_500
    )
    /// The drawable is already available before a predictive wait. Preserve
    /// two milliseconds for encode, GPU scheduling, and compositor admission.
    private static let gamingPredictiveMinimumSubmitLeadSeconds = 0.0020
    private static let gamingDecodeIntervalSmoothing = 0.25
    private static let gamingDecodeIntervalMicrosRange = 1_000.0...20_000.0
    /// Follow genuine display-phase movement without importing callback jitter
    /// into the independent wheel. At 144 Hz this converges a 3 ms step in
    /// about 12 frames while moving any one latch by at most a quarter ms.
    private static let gamingServoMaximumStepSeconds = 0.00025
    /// Flag submissions that leave less than the measured Metal scheduling
    /// margin, so cadence regressions remain visible in per-second telemetry.
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
        defaultMicros: 1_500,
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

    /// One render tick waiting for a newer decoded generation. Registering a
    /// per-attempt semaphore avoids accumulated signals from the much faster
    /// decode stream; the decode callback wakes only the active waiter.
    private struct GamingPredictiveWaiter {
        let generation: UInt64
        let signal: DispatchSemaphore
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
    private var gamingLatestDecodeMicros: UInt64?
    private var gamingDecodeIntervalMicros: Double?
    private var gamingPredictiveWaiter: GamingPredictiveWaiter?
    /// Quality mode allows one frame to be rendering or awaiting scanout.
    /// New frames replace `latestFrame` while that slot is busy. A unique
    /// token makes late Metal callbacks harmless when a layer is occluded.
    private var activeRenderToken: UInt64?
    private var nextRenderToken: UInt64 = 0
    /// Tracks whether the late latch found a new decoded generation. When the
    /// source misses a tick, gaming redraws this generation to keep the
    /// swapchain recycling instead of abandoning its drawable.
    private var lastGamingGeneration: UInt64?
    private var gamingPacerGeneration: UInt64 = 0
    private var gamingCadenceRunning = false
    private var gamingLatestForecastHostTime: UInt64 = 0
    private var gamingTickCallbacks = 0
    private var gamingTicksScheduled = 0
    private var gamingTicksCommitted = 0
    private var gamingTicksBusy = 0
    private var gamingFrameHolds = 0
    private var gamingLookaheadTicks: UInt64 = 0
    private var gamingWaitTicks: UInt64 = 0
    private var gamingDrawableTicks: UInt64 = 0
    private var gamingDrawableSamples = 0
    private var gamingPredictiveAttempts = 0
    private var gamingPredictiveHits = 0
    private var gamingPredictiveWaitTicks: UInt64 = 0
    private var gamingPredictiveAdvanceMicros: UInt64 = 0
    private var gamingRecoveryTicks = 0
    private var gamingRecoveryFrames = 0
    private var gamingRecoveryActivations = 0
    private var gamingDrawableRecoverySignals = 0
    private var gamingServoSignedTicks: Int64 = 0
    private var gamingServoAbsoluteTicks: UInt64 = 0
    private var gamingServoMaximumTicks: UInt64 = 0
    private var gamingServoSamples = 0
    private var gamingDeadlineResyncs = 0
    private var gamingDeadlineDeficitTicks: UInt64 = 0
    private var gamingDeadlineMaximumDeficitTicks: UInt64 = 0
    private var gamingCaptureTargetMicros: UInt64 = 0
    private var gamingCaptureTargetSamples = 0
    private var gamingPresentationPhaseMicros: Int64 = 0
    private var gamingPresentationPhaseSamples = 0
    private var gamingStaleRetries = 0
    private var gamingStaleRecoveries = 0
    /// AppKit and CAMetalLayer state sampled on the main thread. The stats
    /// worker only reads this cached string, avoiding cross-thread window API
    /// access while making silent 60 Hz/occlusion fallbacks diagnosable.
    private var presentationEnvironment = "surface=unbound"
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
        capturePresentationEnvironment(view: view)
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
        capturePresentationEnvironment(view: view)
        view.isPaused = hasFrame
        if gaming, hasFrame, layer != nil {
            startGamingPacer()
        } else {
            stopGamingPacer()
        }
        if let token { scheduleRender(token: token) }
    }

    /// Queue a main-thread snapshot for the next per-second stats line.
    /// Environment state changes far less often than the rendering counters,
    /// so a one-line, one-tick-delayed sample is sufficient and nonblocking.
    func refreshPresentationEnvironment() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.view else { return }
            self.capturePresentationEnvironment(view: view)
        }
    }

    private func capturePresentationEnvironment(view: MTKView) {
        precondition(Thread.isMainThread)
        let window = view.window
        let layer = view.layer as? CAMetalLayer
        let flag: (Bool) -> String = { $0 ? "1" : "0" }
        let nativeFullscreen = window?.styleMask.contains(.fullScreen) == true
        let environment = "surface="
            + "active\(flag(NSApp.isActive))"
            + ",visible\(flag(window?.occlusionState.contains(.visible) == true))"
            + ",window\(flag(window?.isVisible == true))"
            + ",key\(flag(window?.isKeyWindow == true))"
            + ",space\(flag(window?.isOnActiveSpace == true))"
            + ",full\(flag(nativeFullscreen))"
            + ",screen\(window?.screen?.maximumFramesPerSecond ?? 0)"
            + ",view\(view.preferredFramesPerSecond)"
            + ",sync\(flag(layer?.displaySyncEnabled == true))"
            + ",buf\(layer?.maximumDrawableCount ?? 0)"
            + ",hidden\(flag(view.isHidden || layer?.isHidden == true))"
        frameLock.lock()
        presentationEnvironment = environment
        frameLock.unlock()
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
        let decodedMicros = ClientClock.nowMicros()
        frameLock.lock()
        let firstFrame = latestFrame == nil
        if let previousMicros = gamingLatestDecodeMicros,
           decodedMicros > previousMicros {
            let intervalMicros = Double(decodedMicros - previousMicros)
            if Self.gamingDecodeIntervalMicrosRange.contains(intervalMicros) {
                if let previousEstimate = gamingDecodeIntervalMicros {
                    let gain = Self.gamingDecodeIntervalSmoothing
                    gamingDecodeIntervalMicros = previousEstimate
                        + (intervalMicros - previousEstimate) * gain
                } else {
                    gamingDecodeIntervalMicros = intervalMicros
                }
            } else {
                gamingDecodeIntervalMicros = nil
            }
        }
        gamingLatestDecodeMicros = decodedMicros
        let generation = nextGeneration
        latestFrame = StreamFrame(pixelBuffer: pixelBuffer,
                                  width: CVPixelBufferGetWidth(pixelBuffer),
                                  height: CVPixelBufferGetHeight(pixelBuffer),
                                  captureClientMicros: captureClientMicros,
                                  decodedMicros: decodedMicros,
                                  generation: generation)
        nextGeneration += 1
        let predictiveSignal: DispatchSemaphore?
        if let waiter = gamingPredictiveWaiter,
           waiter.generation != generation {
            gamingPredictiveWaiter = nil
            predictiveSignal = waiter.signal
        } else {
            predictiveSignal = nil
        }
        let gaming = lowLatencyPresentation
        let token = !lowLatencyPresentation && !presentationSuspended && activeRenderToken == nil
            ? reserveRenderTokenLocked()
            : nil
        frameLock.unlock()
        predictiveSignal?.signal()
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
        gamingLatestDecodeMicros = nil
        gamingDecodeIntervalMicros = nil
        let predictiveSignal = gamingPredictiveWaiter?.signal
        gamingPredictiveWaiter = nil
        frameLock.unlock()
        predictiveSignal?.signal()
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
    /// below; later forecasts may only apply the servo's bounded correction.
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
        gamingLatestForecastHostTime = 0
        gamingRecoveryTicks = 0
        let predictiveSignal = gamingPredictiveWaiter?.signal
        gamingPredictiveWaiter = nil
        rotateGamingRenderQueueLocked()
        frameLock.unlock()
        predictiveSignal?.signal()
    }

    /// Core Video supplies the display phase and nominal period, but its
    /// callback delivery can bunch under WindowServer load. Seed one
    /// mach-clocked cadence wheel from that phase and let it issue evenly
    /// spaced latches; later callbacks supply bounded phase-error samples,
    /// not per-frame deadlines.
    private func scheduleGamingTick(outputHostTime: UInt64,
                                    refreshTicks: UInt64) {
        let now = CVGetCurrentHostTime()

        frameLock.lock()
        gamingTickCallbacks += 1
        gamingLookaheadTicks &+= outputHostTime > now ? outputHostTime - now : 0
        gamingLatestForecastHostTime = outputHostTime
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

    // swiftlint:disable:next function_body_length
    private func runGamingCadence(pacerGeneration: UInt64,
                                  forecastHostTime: UInt64,
                                  refreshTicks: UInt64) {
        let baseLatchLeadTicks = UInt64(
            CVGetHostClockFrequency() * Self.gamingLatchLeadSeconds
        )
        let recoveryLeadTicks = UInt64(
            CVGetHostClockFrequency() * Self.gamingRecoveryLeadSeconds
        )
        let outputPhaseTicks = UInt64(
            CVGetHostClockFrequency() * Self.gamingOutputPhaseOffsetSeconds
        )
        var outputHostTime = Self.firstGamingOutputHostTime(
            forecastHostTime: forecastHostTime,
            outputPhaseTicks: outputPhaseTicks,
            refreshTicks: refreshTicks,
            maximumLeadTicks: baseLatchLeadTicks + recoveryLeadTicks
        )

        while true {
            outputHostTime = servoedGamingOutputHostTime(
                outputHostTime,
                outputPhaseTicks: outputPhaseTicks,
                refreshTicks: refreshTicks
            )
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
            let recovering = gamingRecoveryTicks > 0
            frameLock.unlock()

            let latchLeadTicks = baseLatchLeadTicks + (recovering ? recoveryLeadTicks : 0)
            let latchHostTime = outputHostTime > latchLeadTicks
                ? outputHostTime - latchLeadTicks
                : outputHostTime
            let now = CVGetCurrentHostTime()
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
            if recovering, gamingRecoveryTicks > 0 {
                gamingRecoveryTicks -= 1
                gamingRecoveryFrames += 1
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

    private static func firstGamingOutputHostTime(
        forecastHostTime: UInt64,
        outputPhaseTicks: UInt64,
        refreshTicks: UInt64,
        maximumLeadTicks: UInt64
    ) -> UInt64 {
        var outputHostTime = forecastHostTime &+ outputPhaseTicks
        let now = CVGetCurrentHostTime()
        while outputHostTime > refreshTicks,
              outputHostTime - refreshTicks > now + maximumLeadTicks {
            outputHostTime -= refreshTicks
        }
        while outputHostTime <= now + maximumLeadTicks {
            outputHostTime &+= refreshTicks
        }
        return outputHostTime
    }

    private func servoedGamingOutputHostTime(
        _ outputHostTime: UInt64,
        outputPhaseTicks: UInt64,
        refreshTicks: UInt64
    ) -> UInt64 {
        frameLock.lock()
        let forecastHostTime = gamingLatestForecastHostTime
        frameLock.unlock()
        guard forecastHostTime > 0, refreshTicks > 0 else { return outputHostTime }
        // A stopped or occluded display link must not make this mapping walk a
        // progressively older forecast forward one refresh at a time. The
        // independent wheel remains authoritative until fresh forecasts resume.
        let now = CVGetCurrentHostTime()
        guard forecastHostTime &+ (refreshTicks &* 4) >= now else {
            return outputHostTime
        }

        var desiredHostTime = forecastHostTime &+ outputPhaseTicks
        let halfRefresh = refreshTicks / 2
        while desiredHostTime + halfRefresh < outputHostTime {
            desiredHostTime &+= refreshTicks
        }
        while desiredHostTime > outputHostTime + halfRefresh,
              desiredHostTime >= refreshTicks {
            desiredHostTime -= refreshTicks
        }

        let error = Int64(desiredHostTime) - Int64(outputHostTime)
        let maximumStep = Int64(
            CVGetHostClockFrequency() * Self.gamingServoMaximumStepSeconds
        )
        let correction = min(max(error, -maximumStep), maximumStep)
        let correctedHostTime: UInt64
        if correction >= 0 {
            correctedHostTime = outputHostTime &+ UInt64(correction)
        } else {
            correctedHostTime = outputHostTime - UInt64(-correction)
        }

        let absoluteCorrection = UInt64(abs(correction))
        frameLock.lock()
        gamingServoSignedTicks += correction
        gamingServoAbsoluteTicks &+= absoluteCorrection
        gamingServoMaximumTicks = max(gamingServoMaximumTicks, absoluteCorrection)
        gamingServoSamples += 1
        frameLock.unlock()
        return correctedHostTime
    }

    private static func waitPrecisely(until hostTime: UInt64) {
        let spinTicks = UInt64(CVGetHostClockFrequency() * gamingLatchSpinSeconds)
        let parkUntil = hostTime > spinTicks ? hostTime - spinTicks : hostTime
        if parkUntil > CVGetCurrentHostTime() {
            mach_wait_until(parkUntil)
        }
        while CVGetCurrentHostTime() < hostTime {}
    }

    // A source faster than the local display periodically finishes a decode
    // just after the ordinary latch. Wait only when the learned decode period
    // predicts that boundary inside a small configured window. The drawable
    // is already acquired, and the output deadline keeps a fixed render
    // reserve, so a prediction miss cannot grow into swapchain starvation.
    // swiftlint:disable:next function_body_length
    private func waitForPredictedFrame(pacerGeneration: UInt64,
                                       layer: CAMetalLayer,
                                       outputHostTime: UInt64) {
        let maximumWaitSeconds = Self.gamingPredictiveLatchMaximumWaitSeconds
        guard maximumWaitSeconds > 0 else { return }

        let nowMicros = ClientClock.nowMicros()
        let nowHostTime = CVGetCurrentHostTime()
        let hostClockFrequency = CVGetHostClockFrequency()
        let maximumWaitTicks = UInt64(hostClockFrequency * maximumWaitSeconds)
        let minimumSubmitLeadTicks = UInt64(
            hostClockFrequency * Self.gamingPredictiveMinimumSubmitLeadSeconds
        )

        frameLock.lock()
        guard gamingPacerGeneration == pacerGeneration,
              lowLatencyPresentation,
              !presentationSuspended,
              streamLayer === layer,
              let frame = latestFrame,
              let decodeIntervalMicros = gamingDecodeIntervalMicros else {
            frameLock.unlock()
            return
        }
        let predictedMicros = Double(frame.decodedMicros) + decodeIntervalMicros
        let predictionLeadMicros = predictedMicros - Double(nowMicros)
        let predictionLeadTicks = UInt64(
            max(0, predictionLeadMicros) / 1_000_000 * hostClockFrequency
        )
        guard predictionLeadMicros > 0,
              predictionLeadTicks <= maximumWaitTicks,
              outputHostTime > nowHostTime + minimumSubmitLeadTicks else {
            frameLock.unlock()
            return
        }
        let deadlineWaitTicks = outputHostTime - nowHostTime - minimumSubmitLeadTicks
        let waitTicks = min(maximumWaitTicks, deadlineWaitTicks)
        guard predictionLeadTicks <= waitTicks else {
            frameLock.unlock()
            return
        }

        let signal = DispatchSemaphore(value: 0)
        gamingPredictiveWaiter = GamingPredictiveWaiter(
            generation: frame.generation,
            signal: signal
        )
        gamingPredictiveAttempts += 1
        let startingGeneration = frame.generation
        let startingDecodedMicros = frame.decodedMicros
        frameLock.unlock()

        let waitStarted = CVGetCurrentHostTime()
        let waitNanoseconds = Int(
            Double(waitTicks) / hostClockFrequency * 1_000_000_000
        )
        _ = signal.wait(timeout: .now() + .nanoseconds(max(1, waitNanoseconds)))
        let waitFinished = CVGetCurrentHostTime()

        frameLock.lock()
        if gamingPredictiveWaiter?.signal === signal {
            gamingPredictiveWaiter = nil
        }
        let newerFrame = gamingPacerGeneration == pacerGeneration
            && lowLatencyPresentation
            && !presentationSuspended
            && streamLayer === layer
            ? latestFrame
            : nil
        if let newerFrame, newerFrame.generation != startingGeneration {
            gamingPredictiveHits += 1
            if newerFrame.decodedMicros >= startingDecodedMicros {
                gamingPredictiveAdvanceMicros &+= newerFrame.decodedMicros
                    - startingDecodedMicros
            }
        }
        gamingPredictiveWaitTicks &+= waitFinished - waitStarted
        frameLock.unlock()
    }

    // The three-surface pool absorbs ordinary compositor jitter. A configured
    // predictive micro-latch may hold this already-admitted surface briefly
    // for an imminent newer decode, without moving the output target.
    // swiftlint:disable:next function_body_length
    private func drawLateLatchedFrame(pacerGeneration: UInt64,
                                      outputHostTime: UInt64,
                                      latchHostTime: UInt64) {
        guard let layer = gamingLayer(pacerGeneration: pacerGeneration) else { return }
        if latchHostTime > CVGetCurrentHostTime() {
            Self.waitPrecisely(until: latchHostTime)
        }
        guard let latchedLayer = gamingLayerAfterLateLatch(
            pacerGeneration: pacerGeneration,
            outputHostTime: outputHostTime
        ), latchedLayer === layer else { return }

        let drawableStarted = CVGetCurrentHostTime()
        guard let drawable = layer.nextDrawable() else { return }
        let drawableFinished = CVGetCurrentHostTime()
        let drawableTicks = drawableFinished - drawableStarted
        let recoveryThresholdTicks = UInt64(
            CVGetHostClockFrequency() * Self.gamingDrawableRecoveryThresholdSeconds
        )

        frameLock.lock()
        gamingDrawableTicks &+= drawableTicks
        gamingDrawableSamples += 1
        if drawableTicks >= recoveryThresholdTicks {
            gamingDrawableRecoverySignals += 1
            if gamingRecoveryTicks == 0 { gamingRecoveryActivations += 1 }
            gamingRecoveryTicks = max(gamingRecoveryTicks, Self.gamingRecoveryFrameCount)
        }
        frameLock.unlock()

        waitForPredictedFrame(pacerGeneration: pacerGeneration,
                              layer: layer,
                              outputHostTime: outputHostTime)
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
            // a sustained starvation cascade; recovery widens following latches.
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
            if gamingRecoveryTicks == 0 { gamingRecoveryActivations += 1 }
            gamingRecoveryTicks = max(gamingRecoveryTicks, Self.gamingRecoveryFrameCount)
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
        let lookahead = gamingLookaheadTicks
        let wait = gamingWaitTicks
        let drawable = gamingDrawableTicks
        let drawableSamples = gamingDrawableSamples
        let predictiveAttempts = gamingPredictiveAttempts
        let predictiveHits = gamingPredictiveHits
        let predictiveWait = gamingPredictiveWaitTicks
        let predictiveAdvance = gamingPredictiveAdvanceMicros
        let decodeInterval = gamingDecodeIntervalMicros
        let recoveryFrames = gamingRecoveryFrames
        let recoveryActivations = gamingRecoveryActivations
        let drawableRecoverySignals = gamingDrawableRecoverySignals
        let servoSigned = gamingServoSignedTicks
        let servoAbsolute = gamingServoAbsoluteTicks
        let servoMaximum = gamingServoMaximumTicks
        let servoSamples = gamingServoSamples
        let deadlineResyncs = gamingDeadlineResyncs
        let deadlineDeficit = gamingDeadlineDeficitTicks
        let deadlineMaximumDeficit = gamingDeadlineMaximumDeficitTicks
        let captureTarget = gamingCaptureTargetMicros
        let captureTargetSamples = gamingCaptureTargetSamples
        let presentationPhase = gamingPresentationPhaseMicros
        let presentationPhaseSamples = gamingPresentationPhaseSamples
        let staleRetries = gamingStaleRetries
        let staleRecoveries = gamingStaleRecoveries
        let environment = presentationEnvironment
        gamingTickCallbacks = 0
        gamingTicksScheduled = 0
        gamingTicksCommitted = 0
        gamingTicksBusy = 0
        gamingFrameHolds = 0
        gamingLookaheadTicks = 0
        gamingWaitTicks = 0
        gamingDrawableTicks = 0
        gamingDrawableSamples = 0
        gamingPredictiveAttempts = 0
        gamingPredictiveHits = 0
        gamingPredictiveWaitTicks = 0
        gamingPredictiveAdvanceMicros = 0
        gamingRecoveryFrames = 0
        gamingRecoveryActivations = 0
        gamingDrawableRecoverySignals = 0
        gamingServoSignedTicks = 0
        gamingServoAbsoluteTicks = 0
        gamingServoMaximumTicks = 0
        gamingServoSamples = 0
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
        func averageSignedMilliseconds(_ ticks: Int64, _ samples: Int) -> String {
            guard samples > 0 else { return "0.000" }
            return String(format: "%.3f", Double(ticks) / Double(samples) / ticksPerMillisecond)
        }
        let drawablePolicy = Self.gamingPredictiveLatchMaximumWaitSeconds > 0
            ? "predictive_micro_latch_3"
            : "adaptive_late_acquire_3"
        let decodePeriod = decodeInterval.map {
            String(format: "%.2f", $0 / 1_000)
        } ?? "n/a"
        let predictiveMaximum = String(
            format: "%.2f",
            Self.gamingPredictiveLatchMaximumWaitSeconds * 1_000
        )
        return "present_driver=core_video_latch"
            + " pacer=\(callbacks)/\(scheduled)/\(committed)/\(busy)"
            + " hold=\(held)"
            + " lookahead_ms=\(averageMilliseconds(lookahead, callbacks))"
            + " latch_wait_ms=\(averageMilliseconds(wait, scheduled))"
            + " drawable_wait_ms=\(averageMilliseconds(drawable, drawableSamples))"
            + " drawable_policy=\(drawablePolicy)"
            + " predictive=\(predictiveHits)/\(predictiveAttempts)"
            + " predictive_wait_ms=\(averageMilliseconds(predictiveWait, predictiveAttempts))"
            + " predictive_advance_ms=\(averageMicroseconds(predictiveAdvance, predictiveHits))"
            + " decode_period_ms=\(decodePeriod)"
            + " predictive_max_ms=\(predictiveMaximum)"
            + " recovery=\(recoveryFrames)/\(recoveryActivations)"
            + " recovery_signal=\(drawableRecoverySignals)"
            + " servo_ms=\(averageSignedMilliseconds(servoSigned, servoSamples))"
            + "/\(averageMilliseconds(servoAbsolute, servoSamples))"
            + "/\(averageMilliseconds(servoMaximum, 1))"
            + " cap_target_ms=\(averageMicroseconds(captureTarget, captureTargetSamples))"
            + " present_phase_ms=\(averageSignedMicroseconds(presentationPhase, presentationPhaseSamples))"
            + " latch_lead_ms=\(String(format: "%.2f", Self.gamingLatchLeadSeconds * 1_000))"
            + "/\(String(format: "%.2f", (Self.gamingLatchLeadSeconds + Self.gamingRecoveryLeadSeconds) * 1_000))"
            + " phase_offset_ms=\(String(format: "%.2f", Self.gamingOutputPhaseOffsetSeconds * 1_000))"
            + " deadline_resync=\(deadlineResyncs)"
            + " deadline_deficit_ms=\(averageMilliseconds(deadlineDeficit, deadlineResyncs))"
            + "/\(averageMilliseconds(deadlineMaximumDeficit, 1))"
            + " stale_retry=\(staleRecoveries)/\(staleRetries)"
            + " \(environment)"
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
