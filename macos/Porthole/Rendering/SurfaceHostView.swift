import AppKit
import MetalKit
import SwiftUI

/// SwiftUI wrapper around the session surface (US-005/006), hosted in a
/// scroll view for the US-010 display modes.
///
/// US-005: while a stream is live the renderer draws decoded CVPixelBuffers
/// (see `MetalRenderer.display`); the test pattern remains as the
/// disconnected idle state. US-006: the surface is a SessionSurfaceView
/// that captures keyboard/mouse/trackpad input while it holds focus.
/// US-010: fit letterboxes into the window, one-to-one sizes the surface so
/// one video pixel lands on one backing-store pixel (scrolling when the
/// video is bigger than the window), fullscreen is the native kind.
struct MetalSurfaceView: NSViewRepresentable {
    /// Target rate for the view's display link: 60/120/144, or 0 for the
    /// screen's maximum. The system clamps it to what the display supports.
    let frameRate: Int
    /// Gaming mode may present between display-link ticks to minimize the
    /// decoded-frame-to-scanout delay. Quality mode remains synchronized.
    let lowLatency: Bool
    /// Pointer lock state, so the view can refresh its cursor rects on
    /// transitions (the cursor itself is decided in SessionSurfaceView).
    let pointerLocked: Bool
    let displayMode: DisplayMode
    /// Remote video size in pixels; .zero until the stream is live, which
    /// keeps one-to-one on the fit fallback until the size is known.
    let videoSize: CGSize
    /// Shared renderer owned by `StreamSession`; also the surface's delegate.
    let renderer: MetalRenderer
    /// Input translator owned by `StreamSession`.
    let input: InputController
    /// Native fullscreen transitions, including ones started by the window
    /// itself (green button, exit gesture), so the chrome stays in sync.
    let onFullscreenChanged: (Bool) -> Void

    func makeCoordinator() -> MetalRenderer {
        renderer
    }

    func makeNSView(context: Context) -> SurfaceHostView {
        let surface = SessionSurfaceView(frame: .zero, device: context.coordinator.device)
        surface.inputHandler = input
        surface.delegate = context.coordinator
        context.coordinator.view = surface
        surface.colorPixelFormat = MetalRenderer.pixelFormat
        surface.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Idle: the display link drives the test pattern. Live: the renderer
        // pauses the link and draws as frames arrive (see MetalRenderer.display).
        surface.targetFrameRate = frameRate
        surface.lowLatencyPresentation = lowLatency
        surface.isPaused = false
        surface.enableSetNeedsDisplay = false
        let host = SurfaceHostView(surface: surface)
        host.onFullscreenChanged = onFullscreenChanged
        return host
    }

    func updateNSView(_ nsView: SurfaceHostView, context: Context) {
        nsView.onFullscreenChanged = onFullscreenChanged
        nsView.surface.targetFrameRate = frameRate
        nsView.surface.lowLatencyPresentation = lowLatency
        nsView.surface.pointerLocked = pointerLocked
        let oneToOne = displayMode == .oneToOne && videoSize != .zero
        nsView.apply(mode: displayMode, videoSize: videoSize)
        renderer.setFillsDrawable(oneToOne)
        nsView.setWantsFullscreen(displayMode == .fullscreen)
    }
}

/// Hosts the session surface in a scroll view so one-to-one mode can pan a
/// video larger than the window; fit and fullscreen pin the surface to the
/// scroll view's own size (no scrolling, the renderer letterboxes). Also
/// owns the native-fullscreen bridge for the fullscreen mode.
final class SurfaceHostView: NSScrollView {
    let surface: SessionSurfaceView

    /// Reports enter/exit of native fullscreen; called on main.
    var onFullscreenChanged: ((Bool) -> Void)?

    private var mode: DisplayMode = .fit
    private var videoSize: CGSize = .zero
    private var wantsFullscreen = false
    /// toggleFullScreen during an animating transition is dropped by
    /// AppKit; requests wait for the did-enter/did-exit notification.
    private var fullscreenTransitionActive = false
    private var observers: [NSObjectProtocol] = []

    init(surface: SessionSurfaceView) {
        self.surface = surface
        super.init(frame: .zero)
        drawsBackground = false
        scrollerStyle = .overlay
        automaticallyAdjustsContentInsets = false
        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        contentView = clipView
        documentView = surface
        hasHorizontalScroller = false
        hasVerticalScroller = false
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("SurfaceHostView is built in code")
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func apply(mode: DisplayMode, videoSize: CGSize) {
        guard mode != self.mode || videoSize != self.videoSize else { return }
        self.mode = mode
        self.videoSize = videoSize
        layoutSurface()
    }

    override func layout() {
        super.layout()
        layoutSurface()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // SwiftUI resizes the represented view directly; fit mode must track
        // the new size even when no layout pass follows.
        layoutSurface()
    }

    /// One-to-one means one video pixel per backing-store pixel. The
    /// surface's drawable is its point size times the backing scale, so the
    /// frame that yields a video-sized drawable is the pixel dimensions
    /// divided by that scale: a 2560x1440 stream occupies 1280x720 points
    /// on a Retina (2x) display and 2560x1440 points on a 1x display, and a
    /// glyph the remote rendered into n pixels lands on exactly n device
    /// pixels here, with no resampling to blur it.
    private func layoutSurface() {
        let oneToOne = mode == .oneToOne && videoSize.width > 0 && videoSize.height > 0
        let size: NSSize
        if oneToOne {
            let scale = window?.backingScaleFactor ?? 2
            size = NSSize(width: videoSize.width / scale, height: videoSize.height / scale)
        } else {
            size = contentView.bounds.size
        }
        if surface.frame.size != size {
            surface.setFrameSize(size)
        }
        if hasVerticalScroller != oneToOne {
            hasHorizontalScroller = oneToOne
            hasVerticalScroller = oneToOne
            horizontalScrollElasticity = oneToOne ? .automatic : .none
            verticalScrollElasticity = oneToOne ? .automatic : .none
        }
    }

    // MARK: Native fullscreen (US-010)

    func setWantsFullscreen(_ wants: Bool) {
        wantsFullscreen = wants
        // Window state must not change during a SwiftUI update pass.
        DispatchQueue.main.async { [weak self] in self?.applyFullscreen() }
    }

    private func applyFullscreen() {
        guard let window, !fullscreenTransitionActive else { return }
        if window.styleMask.contains(.fullScreen) != wantsFullscreen {
            window.toggleFullScreen(nil)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if observers.isEmpty {
            observeWindow()
        }
        // A persisted fullscreen mode arrives before the window exists;
        // apply it once there is a window to toggle, and re-derive the
        // one-to-one size for this window's backing scale.
        applyFullscreen()
        layoutSurface()
    }

    private func observeWindow() {
        observe(NSWindow.willEnterFullScreenNotification) { $0.fullscreenTransitionActive = true }
        observe(NSWindow.willExitFullScreenNotification) { $0.fullscreenTransitionActive = true }
        observe(NSWindow.didEnterFullScreenNotification) {
            $0.fullscreenTransitionActive = false
            $0.onFullscreenChanged?(true)
            $0.applyFullscreen()
        }
        observe(NSWindow.didExitFullScreenNotification) {
            $0.fullscreenTransitionActive = false
            $0.onFullscreenChanged?(false)
            $0.applyFullscreen()
        }
        // Dragging the window between a 1x and a 2x display changes what
        // "one video pixel on one device pixel" means in points.
        observe(NSWindow.didChangeBackingPropertiesNotification) { $0.layoutSurface() }
    }

    private func observe(_ name: Notification.Name, _ handler: @escaping (SurfaceHostView) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name,
                                                                object: nil,
                                                                queue: .main) { [weak self] notification in
            guard let self, let window = self.window,
                  (notification.object as? NSWindow) === window else { return }
            handler(self)
        })
    }
}

/// Centers a document smaller than the clip area (AppKit pins it to the
/// origin edge otherwise), so a one-to-one video smaller than the window
/// floats centered like the letterboxed fit mode.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return bounds }
        if documentView.frame.width < bounds.width {
            bounds.origin.x = (documentView.frame.width - bounds.width) / 2
        }
        if documentView.frame.height < bounds.height {
            bounds.origin.y = (documentView.frame.height - bounds.height) / 2
        }
        return bounds
    }
}
