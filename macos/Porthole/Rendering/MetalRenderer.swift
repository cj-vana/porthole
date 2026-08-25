import MetalKit
import QuartzCore
import SwiftUI

/// SwiftUI wrapper around the `MTKView` that presents the session surface.
///
/// Seam (PRD US-005): this view/renderer pair is where the VideoToolbox
/// decode path will attach. Decoded `CVPixelBuffer`s will be converted to
/// `MTLTexture`s via `CVMetalTextureCache` and drawn in place of the
/// procedural test pattern; the SwiftUI chrome stays unchanged.
struct MetalSurfaceView: NSViewRepresentable {
    /// Target rate for the view's display link (60/120/144). Applied live on
    /// change; the system clamps it to what the attached display supports.
    let frameRate: Int

    func makeCoordinator() -> MetalRenderer {
        MetalRenderer()
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

/// Draws the US-004 render-path proof: an animated, time-derived test pattern.
///
/// The pattern is fully procedural and driven by monotonic time, so dropped
/// or irregular frames show up immediately as stutter in the moving marker
/// line and as skipped cells in the pacing ticker (one cell per frame at the
/// selected rate).
final class MetalRenderer: NSObject, MTKViewDelegate {
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    let device: MTLDevice

    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let startTime = CACurrentMediaTime()

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
              let vertexFunction = library.makeFunction(name: "testPatternVertex"),
              let fragmentFunction = library.makeFunction(name: "testPatternFragment") else {
            preconditionFailure("Failed to set up the Metal renderer")
        }
        self.commandQueue = commandQueue

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Test Pattern Pipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            preconditionFailure("Failed to create render pipeline: \(error)")
        }

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderPass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            return
        }

        var time = Float(CACurrentMediaTime() - startTime)
        var viewportSize = SIMD2<Float>(Float(view.drawableSize.width),
                                        Float(view.drawableSize.height))
        // Current display-link target; the shader sizes its pacing ticker to it.
        var frameRate = Float(view.preferredFramesPerSecond)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&time, length: MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&viewportSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.setFragmentBytes(&frameRate, length: MemoryLayout<Float>.size, index: 2)
        // Single fullscreen triangle; the pattern is computed per-fragment.
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
