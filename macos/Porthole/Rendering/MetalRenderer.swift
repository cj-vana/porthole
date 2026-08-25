import CoreVideo
import MetalKit
import QuartzCore
import SwiftUI

/// SwiftUI wrapper around the `MTKView` that presents the session surface.
///
/// US-005: while a stream is live the renderer draws decoded CVPixelBuffers
/// (see `MetalRenderer.display`); the test pattern remains as the
/// disconnected idle state.
struct MetalSurfaceView: NSViewRepresentable {
    /// Target rate for the view's display link (60/120/144). Applied live on
    /// change; the system clamps it to what the attached display supports.
    let frameRate: Int
    /// Shared renderer owned by `StreamSession`; also the view's delegate.
    let renderer: MetalRenderer

    func makeCoordinator() -> MetalRenderer {
        renderer
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        view.colorPixelFormat = MetalRenderer.pixelFormat
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Vsync-driven: MTKView's display link calls draw(in:) every frame.
        view.preferredFramesPerSecond = frameRate
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        if nsView.preferredFramesPerSecond != frameRate {
            nsView.preferredFramesPerSecond = frameRate
        }
    }
}

/// Draws the session surface: the decoded video stream when connected, the
/// US-004 procedural test pattern otherwise.
///
/// Stream frames arrive as NV12 CVPixelBuffers from VideoToolbox on the
/// decode queue and are converted to Metal textures per draw via
/// CVMetalTextureCache (zero-copy off the IOSurface). The video quad is
/// aspect-fit (letterboxed) into the drawable, which is at native Retina
/// resolution. YCbCr conversion happens in the fragment shader with the
/// matrix reported by the SPS VUI (BT.709 default for HD).
final class MetalRenderer: NSObject, MTKViewDelegate {
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    let device: MTLDevice

    private let commandQueue: MTLCommandQueue
    private let patternPipelineState: MTLRenderPipelineState
    private let videoPipelineState: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let startTime = CACurrentMediaTime()

    // Latest stream frame + its geometry/color, written from the decode
    // queue, read on the display link. All guarded by frameLock.
    private let frameLock = NSLock()
    private var latestFrame: CVPixelBuffer?
    private var videoWidth = 0
    private var videoHeight = 0
    private var colorState = H264Decoder.ColorState(matrix: .bt709, fullRange: false)

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

    /// Present a decoded frame at the next draw.
    func display(_ pixelBuffer: CVPixelBuffer) {
        frameLock.lock()
        latestFrame = pixelBuffer
        videoWidth = CVPixelBufferGetWidth(pixelBuffer)
        videoHeight = CVPixelBufferGetHeight(pixelBuffer)
        frameLock.unlock()
    }

    /// Back to the test pattern (disconnect, stream teardown).
    func clearStream() {
        frameLock.lock()
        latestFrame = nil
        frameLock.unlock()
    }

    /// Color conversion parameters from the decoder's SPS parsing.
    func setColorState(matrix: H264SPS.ColorMatrix, fullRange: Bool) {
        frameLock.lock()
        colorState = H264Decoder.ColorState(matrix: matrix, fullRange: fullRange)
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
        let width = videoWidth
        let height = videoHeight
        let colors = colorState
        frameLock.unlock()

        if let frame,
           drawVideo(frame: frame,
                     videoWidth: width,
                     videoHeight: height,
                     colors: colors,
                     view: view,
                     encoder: encoder) {
            // Stream frame submitted.
        } else {
            drawTestPattern(view: view, encoder: encoder)
        }

        encoder.endEncoding()
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
    private func drawVideo(frame: CVPixelBuffer,
                           videoWidth: Int,
                           videoHeight: Int,
                           colors: H264Decoder.ColorState,
                           view: MTKView,
                           encoder: MTLRenderCommandEncoder) -> Bool {
        guard let textureCache else { return false }

        // NV12: plane 0 is luma (r8), plane 1 is interleaved CbCr (rg8).
        var lumaTexture: CVMetalTexture?
        var chromaTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                        textureCache,
                                                        frame,
                                                        nil,
                                                        .r8Unorm,
                                                        CVPixelBufferGetWidthOfPlane(frame, 0),
                                                        CVPixelBufferGetHeightOfPlane(frame, 0),
                                                        0,
                                                        &lumaTexture) == kCVReturnSuccess,
              CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                        textureCache,
                                                        frame,
                                                        nil,
                                                        .rg8Unorm,
                                                        CVPixelBufferGetWidthOfPlane(frame, 1),
                                                        CVPixelBufferGetHeightOfPlane(frame, 1),
                                                        1,
                                                        &chromaTexture) == kCVReturnSuccess,
              let lumaRef = lumaTexture,
              let chromaRef = chromaTexture,
              let luma = CVMetalTextureGetTexture(lumaRef),
              let chroma = CVMetalTextureGetTexture(chromaRef) else {
            return false
        }

        // Aspect-fit the video into the drawable (letterbox or pillarbox).
        let drawableAspect = Float(view.drawableSize.width / view.drawableSize.height)
        let videoAspect = Float(videoWidth) / Float(videoHeight)
        var scale = SIMD2<Float>(1, 1)
        if videoAspect > drawableAspect {
            scale.y = drawableAspect / videoAspect
        } else {
            scale.x = videoAspect / drawableAspect
        }

        // YCbCr to RGB. Kr/Kb per matrix; limited-range content expands from
        // 16..235 (Y) and 16..240 (C), full-range content passes through.
        let kr: Float
        let kb: Float
        switch colors.matrix {
        case .bt601: kr = 0.299; kb = 0.114
        case .bt709: kr = 0.2126; kb = 0.0722
        case .bt2020: kr = 0.2627; kb = 0.0593
        }
        let kg = 1 - kr - kb
        var colorCoeffs = SIMD4<Float>(2 * (1 - kr),
                                       2 * kb * (1 - kb) / kg,
                                       2 * kr * (1 - kr) / kg,
                                       2 * (1 - kb))
        var rangeCoeffs = colors.fullRange
            ? SIMD4<Float>(0, 1, 0.5, 1)
            : SIMD4<Float>(16 / 255, 255 / 219, 0.5, 255 / 224)

        encoder.setRenderPipelineState(videoPipelineState)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentTexture(luma, index: 0)
        encoder.setFragmentTexture(chroma, index: 1)
        encoder.setFragmentBytes(&colorCoeffs, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentBytes(&rangeCoeffs, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        return true
    }
}
