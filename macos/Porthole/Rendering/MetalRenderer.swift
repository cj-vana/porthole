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
/// paused and each decoded frame triggers one draw on the main thread, so a
/// frame waits only for the next vsync rather than for the next link tick
/// on top of it (the cap_present stat is the measurement). The link runs
/// again for the test pattern when no stream is up.
final class MetalRenderer: NSObject, MTKViewDelegate {
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    /// A decoded frame waiting for, or being redrawn by, the display link.
    private struct StreamFrame {
        let pixelBuffer: CVPixelBuffer
        let width: Int
        let height: Int
        /// Capture time on the client clock; nil while the clock offset to
        /// the agent is unknown.
        let captureClientMicros: UInt64?
        /// Distinguishes a new decoded frame from a redraw of the last one.
        let generation: UInt64
    }

    /// A plane texture plus the cache entry that keeps it valid.
    private struct PlaneTexture {
        let reference: CVMetalTexture
        let texture: MTLTexture
    }

    let device: MTLDevice

    /// The surface this renderer draws into; set by MetalSurfaceView. Main
    /// thread only.
    weak var view: MTKView?

    /// Called once per decoded frame when the drawable that carried it hit
    /// the screen, with the frame's capture time (client clock, nil if
    /// unknown) and the presentation time in microseconds on the same clock.
    /// Arrives on a Metal-owned thread.
    var onFramePresented: ((_ captureClientMicros: UInt64?, _ presentedMicros: UInt64) -> Void)?

    private let commandQueue: MTLCommandQueue
    private let patternPipelineState: MTLRenderPipelineState
    private let videoPipelineState: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let startTime = CACurrentMediaTime()

    // Latest stream frame + its color state, written from the decode
    // queue, read on the display link. All guarded by frameLock.
    private let frameLock = NSLock()
    private var latestFrame: StreamFrame?
    private var nextGeneration: UInt64 = 0
    /// A main-thread draw has been queued and not yet run; frames that land
    /// meanwhile are drawn by that one draw (the newest wins).
    private var drawQueued = false
    private var colorState = ColorState(matrix: .bt709, fullRange: false)
    /// US-010 one-to-one mode draws the quad unscaled; see setFillsDrawable.
    private var fillsDrawable = false
    /// Generation whose presentation has been registered; display-link
    /// thread only.
    private var lastPresentedGeneration: UInt64?

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

    /// Present a decoded frame at the next draw. `captureClientMicros` is
    /// the frame's capture time mapped onto the client clock, or nil when
    /// no pong has established the offset yet.
    func display(_ pixelBuffer: CVPixelBuffer, captureClientMicros: UInt64?) {
        frameLock.lock()
        latestFrame = StreamFrame(pixelBuffer: pixelBuffer,
                                  width: CVPixelBufferGetWidth(pixelBuffer),
                                  height: CVPixelBufferGetHeight(pixelBuffer),
                                  captureClientMicros: captureClientMicros,
                                  generation: nextGeneration)
        nextGeneration += 1
        let alreadyQueued = drawQueued
        drawQueued = true
        frameLock.unlock()
        guard !alreadyQueued else { return }
        DispatchQueue.main.async { [weak self] in self?.drawArrivedFrame() }
    }

    /// Main thread: present the newest decoded frame now.
    private func drawArrivedFrame() {
        frameLock.lock()
        drawQueued = false
        let hasFrame = latestFrame != nil
        frameLock.unlock()
        guard hasFrame, let view else { return }
        if !view.isPaused {
            view.isPaused = true
        }
        view.draw()
    }

    /// Back to the test pattern (disconnect, stream teardown).
    func clearStream() {
        frameLock.lock()
        latestFrame = nil
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
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderPass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            return
        }

        frameLock.lock()
        let frame = latestFrame
        let colors = colorState
        let fills = fillsDrawable
        frameLock.unlock()

        var drewVideo = false
        if let frame {
            drewVideo = drawVideo(frame: frame, colors: colors, fills: fills, view: view, encoder: encoder)
        }
        if !drewVideo {
            drawTestPattern(view: view, encoder: encoder)
        }
        encoder.endEncoding()

        // The presented handler has to be registered before present(); a
        // redraw of the same frame reports nothing, so cap_present measures
        // the first time each decoded frame reaches the screen.
        if drewVideo, let frame, frame.generation != lastPresentedGeneration {
            lastPresentedGeneration = frame.generation
            let captureClientMicros = frame.captureClientMicros
            drawable.addPresentedHandler { [weak self] presented in
                guard presented.presentedTime > 0 else { return }
                self?.onFramePresented?(captureClientMicros, UInt64(presented.presentedTime * 1_000_000))
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
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

    /// Returns false when textures could not be produced; the caller falls
    /// back to the test pattern for this draw.
    private func drawVideo(frame: StreamFrame,
                           colors: ColorState,
                           fills: Bool,
                           view: MTKView,
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
            let drawableAspect = Float(view.drawableSize.width / view.drawableSize.height)
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
