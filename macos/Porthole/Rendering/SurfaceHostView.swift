import AppKit
import MetalKit
import os
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
    /// Gaming mode late-latches against the physical display clock. Quality
    /// mode remains decoded-frame driven and synchronized.
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
        surface.colorPixelFormat = MetalRenderer.pixelFormat
        surface.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Idle uses MTKView's display link. A live stream pauses it: quality
        // presents on arrival, while gaming uses the renderer's late latch.
        surface.targetFrameRate = frameRate
        surface.lowLatencyPresentation = lowLatency
        surface.isPaused = false
        surface.enableSetNeedsDisplay = false
        context.coordinator.attach(view: surface)
        context.coordinator.setLowLatencyPresentation(lowLatency)
        let host = SurfaceHostView(surface: surface, renderer: context.coordinator)
        host.onFullscreenChanged = onFullscreenChanged
        return host
    }

    func updateNSView(_ nsView: SurfaceHostView, context: Context) {
        nsView.onFullscreenChanged = onFullscreenChanged
        nsView.surface.targetFrameRate = frameRate
        nsView.surface.lowLatencyPresentation = lowLatency
        renderer.setLowLatencyPresentation(lowLatency)
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
    private let renderer: MetalRenderer

    /// Reports enter/exit of native fullscreen; called on main.
    var onFullscreenChanged: ((Bool) -> Void)?

    private var mode: DisplayMode = .fit
    private var videoSize: CGSize = .zero
    private var wantsFullscreen = false
    /// SwiftUI can attach the represented view to a restored window before
    /// its first update supplies the persisted display mode. Do not interpret
    /// the default `false` as an instruction to leave an already-fullscreen
    /// window during that interval.
    private var hasFullscreenIntent = false
    private var reportedFullscreen: Bool?
    /// toggleFullScreen during an animating transition is dropped by
    /// AppKit; requests wait for the did-enter/did-exit notification.
    private var fullscreenTransitionActive = false
    /// SwiftUI may update this representable several times before AppKit
    /// posts `willEnterFullScreen`. Reserve the transition synchronously so
    /// those updates cannot call `toggleFullScreen` twice and cancel the
    /// first request before its animation begins.
    private var fullscreenTogglePending = false
    private var fullscreenRetryCount = 0
    /// AppKit can finish moving a window between Spaces without delivering
    /// the matching did-enter/did-exit notification. In that case the
    /// renderer must not remain suspended forever. Each transition gets a
    /// generation so a late watchdog cannot disturb a newer transition.
    private var fullscreenTransitionGeneration: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    private let logger = Logger(subsystem: "com.porthole.mac", category: "fullscreen")

    init(surface: SessionSurfaceView, renderer: MetalRenderer) {
        self.surface = surface
        self.renderer = renderer
        super.init(frame: .zero)
        drawsBackground = false
        scrollerStyle = .overlay
        automaticallyAdjustsContentInsets = false
        surface.onPresentationLayerReady = { [weak renderer, weak surface] in
            guard let renderer, let surface else { return }
            renderer.attach(view: surface)
        }
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
        if wantsFullscreen != wants {
            fullscreenRetryCount = 0
        }
        wantsFullscreen = wants
        hasFullscreenIntent = true
        // Window state must not change during a SwiftUI update pass.
        DispatchQueue.main.async { [weak self] in self?.applyFullscreen() }
    }

    private func applyFullscreen() {
        guard hasFullscreenIntent, let window,
              !fullscreenTransitionActive, !fullscreenTogglePending else { return }
        prepareForFullscreen(window)
        let isFullscreen = window.styleMask.contains(.fullScreen)
        if isFullscreen == wantsFullscreen {
            fullscreenRetryCount = 0
            // Window restoration can attach us to an already-fullscreen
            // Space without posting didEnterFullScreen. In that path AppKit
            // has still replaced the layer's drawable pool, so repair the
            // renderer binding once before reporting the restored state.
            if reportedFullscreen != isFullscreen {
                surface.setFullscreenPresentationSettled(isFullscreen)
                surface.reapplyPresentationMode()
                renderer.resumePresentation(view: surface)
            }
            reportFullscreen(isFullscreen)
        } else {
            fullscreenTogglePending = true
            logger.info("fullscreen toggle scheduled target=\(self.wantsFullscreen)")
            // AppKit snapshots the live window when toggleFullScreen starts.
            // Suspending Metal before this call can leave that snapshot
            // transaction waiting forever after `willEnter`; the notification
            // handler below suspends presentation at the safe boundary.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(35)) { [weak self, weak window] in
                guard let self, let window,
                      self.fullscreenTogglePending,
                      !self.fullscreenTransitionActive else { return }
                self.logger.info("fullscreen toggle dispatched target=\(self.wantsFullscreen)")
                window.toggleFullScreen(nil)
            }
            // AppKit can ignore a request while SwiftUI is finishing scene
            // attachment without posting any notification. Retry a bounded
            // number of times; the pending bit also prevents duplicate
            // toggles during the normal animation path.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(750)) { [weak self] in
                guard let self, self.fullscreenTogglePending else { return }
                self.fullscreenTogglePending = false
                if self.fullscreenRetryCount < 3 {
                    self.fullscreenRetryCount += 1
                    self.logger.info("fullscreen toggle retry=\(self.fullscreenRetryCount)")
                    self.applyFullscreen()
                } else {
                    self.reportFullscreen(window.styleMask.contains(.fullScreen))
                }
            }
        }
    }

    /// SwiftUI can rewrite a scene window's collection behavior after the
    /// represented view first attaches. Reassert the mutually exclusive
    /// primary roles immediately before every native fullscreen request.
    private func prepareForFullscreen(_ window: NSWindow) {
        window.styleMask.insert(.resizable)
        window.collectionBehavior.remove(.auxiliary)
        window.collectionBehavior.remove(.canJoinAllApplications)
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.insert(.primary)
        window.collectionBehavior.insert(.fullScreenPrimary)
    }

    private func reportFullscreen(_ entered: Bool) {
        guard reportedFullscreen != entered else { return }
        let hadReportedWindowState = reportedFullscreen != nil
        reportedFullscreen = entered
        // A newly attached window is normally not fullscreen. SwiftUI already
        // owns that initial state, and echoing it can race an on-appear gaming
        // request back to Fit before AppKit starts the transition. Real exits
        // still follow a previously reported fullscreen state.
        guard entered || hadReportedWindowState else { return }
        onFullscreenChanged?(entered)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if observers.isEmpty {
            observeWindow()
        }
        // SwiftUI's singleton Window scene did not advertise itself as a
        // fullscreen-primary window, leaving AppKit's Enter Full Screen menu
        // command disabled and causing toggleFullScreen to be ignored. Make
        // the session a real native-fullscreen participant before applying
        // the persisted intent.
        if let window {
            // A secondary SwiftUI `Window` is assigned the newer auxiliary
            // window-manager role as well as the legacy fullscreen role.
            // Both groups are mutually exclusive: merely adding
            // fullScreenPrimary leaves `Enter Full Screen` disabled while
            // auxiliary/fullScreenNone remain set.
            prepareForFullscreen(window)
            logger.info("""
                fullscreen window ready style=\(window.styleMask.rawValue) \
                behavior=\(window.collectionBehavior.rawValue)
                """)
        }
        // A persisted fullscreen mode arrives before the window exists;
        // apply it once there is a window to toggle, and re-derive the
        // one-to-one size for this window's backing scale.
        applyFullscreen()
        layoutSurface()
    }

    private func observeWindow() {
        observe(NSWindow.willEnterFullScreenNotification) {
            $0.logger.info("fullscreen will enter")
            $0.fullscreenTogglePending = false
            $0.fullscreenTransitionActive = true
            $0.beginPresentationTransition(targetFullscreen: true)
        }
        observe(NSWindow.willExitFullScreenNotification) {
            $0.logger.info("fullscreen will exit")
            $0.fullscreenTogglePending = false
            $0.fullscreenTransitionActive = true
            $0.beginPresentationTransition(targetFullscreen: false)
        }
        observe(NSWindow.didEnterFullScreenNotification) {
            $0.logger.info("fullscreen did enter")
            $0.completePresentationTransition(enteredFullscreen: true)
        }
        observe(NSWindow.didExitFullScreenNotification) {
            $0.logger.info("fullscreen did exit")
            $0.completePresentationTransition(enteredFullscreen: false)
        }
        // Dragging the window between a 1x and a 2x display changes what
        // "one video pixel on one device pixel" means in points.
        observe(NSWindow.didChangeBackingPropertiesNotification) { $0.layoutSurface() }
    }

    /// Drain the old display binding for the entire Space transition. AppKit
    /// snapshots the existing layer contents before posting `willEnter` or
    /// `willExit`; reacquiring CAMetalLayer drawables during that animation can
    /// prevent WindowServer from completing the swapchain handoff.
    private func beginPresentationTransition(targetFullscreen: Bool) {
        fullscreenTransitionGeneration &+= 1
        let generation = fullscreenTransitionGeneration
        renderer.suspendPresentation()

        // `didEnterFullScreen`/`didExitFullScreen` are normally authoritative,
        // but AppKit occasionally omits one after the Space has already
        // settled. Bound that suspension without resuming during the normal
        // animation. The current style mask is the source of truth at expiry.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1_250)) { [weak self] in
            guard let self, let window = self.window,
                  self.fullscreenTransitionActive,
                  self.fullscreenTransitionGeneration == generation else { return }
            let enteredFullscreen = window.styleMask.contains(.fullScreen)
            self.logger.error("""
                fullscreen completion missing target=\(targetFullscreen) \
                actual=\(enteredFullscreen); recovering presentation
                """)
            self.completePresentationTransition(
                enteredFullscreen: enteredFullscreen,
                adoptWindowState: enteredFullscreen == targetFullscreen
            )
        }
    }

    /// Finish from either AppKit's completion notification or the bounded
    /// state-based fallback. Rebinding the settled layer also rotates the
    /// direct-render lane so no drawable wait from the old Space can block it.
    private func completePresentationTransition(enteredFullscreen: Bool,
                                                adoptWindowState: Bool = true) {
        fullscreenTransitionGeneration &+= 1
        fullscreenTogglePending = false
        fullscreenTransitionActive = false
        surface.setFullscreenPresentationSettled(enteredFullscreen)
        surface.reapplyPresentationMode()
        renderer.resumePresentation(view: surface)
        // Track the completed window state locally before SwiftUI propagates
        // the callback. Otherwise applyFullscreen can see the stale
        // pre-transition intent and immediately undo a user action.
        // If a timed-out transition never reached its target, keep the
        // existing SwiftUI intent: app-initiated requests retry, while a
        // cancelled native green-button action stays cancelled.
        if adoptWindowState {
            wantsFullscreen = enteredFullscreen
            hasFullscreenIntent = true
            reportFullscreen(enteredFullscreen)
        }
        applyFullscreen()
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
