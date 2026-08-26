import CoreVideo
import MetalKit
import QuartzCore

/// Draws the session surface: the decoded video stream when connected, the
/// US-004 procedural test pattern otherwise.
///
/// Stream frames arrive as NV12 CVPixelBuffers from VideoToolbox on the
/// decode queue and are converted to Metal textures per draw via
/// CVMetalTextureCache (zero-copy off the IOSurface). The video quad is
/// aspect-fit (letterboxed) into the drawable, which is at native Retina
/// resolution. YCbCr conversion happens in the fragment shader with the
/// matrix reported by the SPS VUI (BT.709 default for HD).
///
/// Presentation timing: while a stream is live the view's display link is
/// paused. Quality mode asks MTKView for a draw on arrival. Gaming mode skips
/// MTKView and the main thread entirely: the decode queue writes a newest-only
/// mailbox and a user-interactive render queue submits that frame directly to
/// CAMetalLayer. This removes a main-run-loop hop and prevents stale decoded
/// frames from filling the drawable FIFO.
final class MetalRenderer: NSObject, MTKViewDelegate {
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    struct PresentationTiming {
        let captureClientMicros: UInt64?
        let decodedMicros: UInt64
        let drawStartedMicros: UInt64
        let submittedMicros: UInt64
        let presentedMicros: UInt64
    }

    /// A frame whose Metal command buffer completed successfully. Unlike
    /// `addPresentedHandler`, this remains observable on unsynchronized
    /// direct-to-display fullscreen paths in current macOS releases.
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

    /// The surface this renderer draws into; attached by MetalSurfaceView on
    /// the main thread. Gaming draws retain only its CAMetalLayer while the
    /// normal MTKView path continues to use this weak reference.
    private weak var view: MTKView?
    private weak var streamLayer: CAMetalLayer?

    /// Called once per decoded frame when the drawable that carried it hit
    /// the screen, with the frame's capture time (client clock, nil if
    /// unknown) and the presentation time in microseconds on the same clock.
    /// Arrives on a Metal-owned thread.
    var onFramePresented: ((PresentationTiming) -> Void)?
    var onFrameRenderCompleted: ((RenderCompletionTiming) -> Void)?

    private let commandQueue: MTLCommandQueue
    /// Serial within one swapchain generation. A fullscreen transition may
    /// strand `nextDrawable()` in the old generation indefinitely, so resume
    /// replaces this lane instead of putting the new layer behind that wait.
    private var directRenderQueue = DispatchQueue(label: "com.porthole.mac.direct-scanout.0",
                                                  qos: .userInteractive)
    private var directRenderQueueGeneration: UInt64 = 0
    private let patternPipelineState: MTLRenderPipelineState
    private let videoPipelineState: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let startTime = CACurrentMediaTime()

    // Latest stream frame + its color state, written from the decode
    // queue, read on the display link. All guarded by frameLock.
    private let frameLock = NSLock()
    private var latestFrame: StreamFrame?
    private var nextGeneration: UInt64 = 0
    /// One decoded frame may be queued, rendering, or awaiting scanout. New
    /// frames replace `latestFrame` while that slot is busy. A unique token
    /// makes late Metal callbacks harmless, including the documented case in
    /// which an occluded CAMetalLayer never calls its presented handler.
    private var activeRenderToken: UInt64?
    private var nextRenderToken: UInt64 = 0
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

    /// Main-thread attachment performed once when SwiftUI creates the native
    /// surface. `nextDrawable()` is explicitly designed to be called from a
    /// rendering thread, so gaming mode keeps the layer and never touches the
    /// AppKit view off-main.
    func attach(view: MTKView) {
        self.view = view
        frameLock.lock()
        streamLayer = view.layer as? CAMetalLayer
        activeRenderToken = nil
        let token = !presentationSuspended && latestFrame != nil
            ? reserveRenderTokenLocked()
            : nil
        frameLock.unlock()
        if let token { scheduleRender(token: token) }
    }

    /// Stop drawable acquisition while AppKit moves the window between
    /// Spaces. Any late callback carries an invalidated token and is ignored.
    func suspendPresentation() {
        frameLock.lock()
        presentationSuspended = true
        activeRenderToken = nil
        frameLock.unlock()
    }

    /// Bind the layer AppKit settled on and restart from the freshest decoded
    /// frame. Keeping this separate from `attach` prevents ordinary SwiftUI
    /// updates from resuming a transition early.
    func resumePresentation(view: MTKView) {
        self.view = view
        frameLock.lock()
        streamLayer = view.layer as? CAMetalLayer
        directRenderQueueGeneration &+= 1
        directRenderQueue = DispatchQueue(
            label: "com.porthole.mac.direct-scanout.\(directRenderQueueGeneration)",
            qos: .userInteractive
        )
        presentationSuspended = false
        activeRenderToken = nil
        let token = latestFrame != nil ? reserveRenderTokenLocked() : nil
        frameLock.unlock()
        if let token { scheduleRender(token: token) }
    }

    /// Switch between MTKView's synchronized quality path and direct gaming
    /// scanout. Invalidate any scheduled token so a mode change cannot strand
    /// the mailbox on the queue it just left.
    func setLowLatencyPresentation(_ enabled: Bool) {
        frameLock.lock()
        guard lowLatencyPresentation != enabled else {
            frameLock.unlock()
            return
        }
        lowLatencyPresentation = enabled
        activeRenderToken = nil
        let token = !presentationSuspended && latestFrame != nil
            ? reserveRenderTokenLocked()
            : nil
        frameLock.unlock()
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
        let token = !presentationSuspended && activeRenderToken == nil
            ? reserveRenderTokenLocked()
            : nil
        frameLock.unlock()
        if firstFrame {
            DispatchQueue.main.async { [weak self] in self?.view?.isPaused = true }
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
        frameLock.lock()
        let direct = lowLatencyPresentation
        let renderQueue = directRenderQueue
        frameLock.unlock()
        if direct {
            renderQueue.async { [weak self] in
                self?.drawDirect(token: token)
            }
        } else {
            DispatchQueue.main.async { [weak self] in self?.drawArrivedFrame(token: token) }
        }
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
        frameLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.view?.isPaused = false }
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
        let directOwnsStream = lowLatencyPresentation && latestFrame != nil
        let failedToken = activeRenderToken
        frameLock.unlock()
        // A display-link tick can race the first decoded frame before the
        // main-thread pause lands. Do not let MTKView compete with direct
        // scanout for one of the layer's two drawables.
        guard !directOwnsStream else { return }

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
                                     drawStartedMicros: drawStartedMicros,
                                     direct: false)
        } else if let token {
            commandBuffer.addCompletedHandler { [weak self] _ in
                self?.releaseRenderSlot(token: token, after: nil)
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: Direct gaming scanout

    // Acquisition must precede mailbox selection, and every failure must
    // release the unique token; keeping that ordering visible is intentional.
    // swiftlint:disable function_body_length
    /// Render the newest decoded frame directly into CAMetalLayer. This queue
    /// never touches NSView/NSWindow and therefore does not wait behind input,
    /// SwiftUI reconciliation, fullscreen animation, or menu event handling.
    private func drawDirect(token: UInt64) {
        frameLock.lock()
        let valid = activeRenderToken == token
            && !presentationSuspended
            && lowLatencyPresentation
            && latestFrame != nil
        let layer = streamLayer
        frameLock.unlock()
        guard valid, let layer else {
            releaseRenderSlot(token: token, after: nil)
            return
        }

        // Acquire a drawable before selecting the mailbox entry. If the
        // drawable pool briefly fills, a frame decoded during that wait wins
        // over the older frame that originally scheduled this render.
        guard let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            releaseRenderSlot(token: token, after: nil)
            return
        }

        frameLock.lock()
        guard activeRenderToken == token,
              !presentationSuspended,
              lowLatencyPresentation,
              let frame = latestFrame else {
            frameLock.unlock()
            releaseRenderSlot(token: token, after: nil)
            return
        }
        let colors = colorState
        let fills = fillsDrawable
        frameLock.unlock()

        let drawableSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
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
            releaseRenderSlot(token: token, after: nil)
            return
        }

        let drawStartedMicros = ClientClock.nowMicros()
        guard drawVideo(frame: frame,
                        colors: colors,
                        fills: fills,
                        drawableSize: drawableSize,
                        encoder: encoder) else {
            encoder.endEncoding()
            releaseRenderSlot(token: token, after: nil)
            return
        }
        encoder.endEncoding()

        armPresentationCallbacks(commandBuffer: commandBuffer,
                                 drawable: drawable,
                                 frame: frame,
                                 token: token,
                                 drawStartedMicros: drawStartedMicros,
                                 direct: true)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    // swiftlint:enable function_body_length

    // swiftlint:disable function_parameter_count
    /// Register before `present()`. Quality releases on actual scanout (with
    /// a bounded watchdog for occlusion). Gaming releases on GPU completion;
    /// CAMetalLayer's drawable pool then provides the hard queue bound.
    private func armPresentationCallbacks(commandBuffer: MTLCommandBuffer,
                                          drawable: CAMetalDrawable,
                                          frame: StreamFrame,
                                          token: UInt64,
                                          drawStartedMicros: UInt64,
                                          direct: Bool) {
        let submittedMicros = ClientClock.nowMicros()
        drawable.addPresentedHandler { [weak self] presented in
            guard let self else { return }
            if !direct {
                self.releaseRenderSlot(token: token, after: frame.generation)
            }
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
            if direct {
                // Do not wait for addPresentedHandler here. On macOS its
                // callback can arrive a refresh after the pixels were shown,
                // which turns a one-in-flight mailbox into a 72 fps pipeline
                // on a 144 Hz panel. GPU completion opens the producer slot;
                // CAMetalLayer's drawable pool remains the hard queue bound.
                self.releaseRenderSlot(token: token,
                                       after: completed.status == .error ? nil : frame.generation)
                return
            }
            if completed.status == .error {
                self.releaseRenderSlot(token: token, after: nil)
                return
            }
            self.frameLock.lock()
            let renderQueue = self.directRenderQueue
            self.frameLock.unlock()
            renderQueue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.releaseRenderSlot(token: token, after: frame.generation)
            }
        }
    }
    // swiftlint:enable function_parameter_count

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
