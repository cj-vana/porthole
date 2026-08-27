import AppKit
import MetalKit
import os

/// The Metal surface, with input capture (US-006). First responder while
/// clicked into; NSEvents forward to InputController. Input flows only while
/// the view holds focus; clicking the view captures, clicking elsewhere
/// releases (resignFirstResponder).
final class SessionSurfaceView: MTKView {
    var inputHandler: InputController?
    /// Fires only after MTKView exposes the CAMetalLayer that direct gaming
    /// presentation may retain off-main.
    var onPresentationLayerReady: (() -> Void)?

    /// Display link target; 0 means auto, the screen's maximum. Re-resolved
    /// when the view lands in a window and when that window changes screen,
    /// because a 60 Hz panel and a 144 Hz panel can be one drag apart.
    var targetFrameRate = 0 {
        didSet {
            if oldValue != targetFrameRate {
                applyFrameRate()
            }
        }
    }

    /// Gaming late-latches the newest decoded frame against the physical
    /// display clock. Quality presents on decoded-frame arrival.
    var lowLatencyPresentation = false {
        didSet {
            if oldValue != lowLatencyPresentation {
                applyPresentationMode()
            }
        }
    }

    /// Mirrors InputController's lock state so its transitions refresh the
    /// cursor rects; the rects themselves read the controller.
    var pointerLocked = false {
        didSet {
            if oldValue != pointerLocked {
                refreshCursor()
            }
        }
    }

    private var screenObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.porthole.mac", category: "surface")

    /// Top-left origin, matching remote output pixels and the letterbox math.
    override var isFlipped: Bool { true }
    /// The stream surface always clears and fills its drawable. Advertising
    /// that fact lets WindowServer skip blending it with content below.
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Let the window-activating click land on the view (and thus the remote
    /// desktop) instead of being eaten by activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    // MARK: Display link rate

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Removal is not a new presentation target. Rebinding here would let
        // an obsolete surface overwrite the renderer's newer weak layer just
        // before this surface deallocates, leaving reconnect with no target.
        guard window != nil else { return }
        // Configure the layer after it has moved into its window so AppKit's
        // backing layer is available and tied to the destination display.
        applyPresentationMode()
        window?.isOpaque = true
        window?.backgroundColor = .black
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification,
                                                                    object: nil,
                                                                    queue: .main) { [weak self] notification in
                guard let self, let window = self.window,
                      (notification.object as? NSWindow) === window else { return }
                self.applyPresentationMode()
                self.applyFrameRate()
            }
        }
        applyFrameRate()
    }

    private func applyPresentationMode() {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        // Timed synchronized presentation needs one drawable scanning, one
        // reserved for the imminent vblank, and one writable. Hardware-tick
        // admission prevents the three slots from becoming a frame backlog.
        metalLayer.maximumDrawableCount = lowLatencyPresentation ? 3 : 2
        // Fullscreen Space transitions can temporarily make every drawable
        // unavailable. A bounded nextDrawable() wait lets the mailbox recover
        // after occlusion instead of pinning its serial render worker forever.
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.presentsWithTransaction = false
        // The renderer supplies the exact forecasted presentation timestamp;
        // synchronization makes that reservation a tear-free scanout target.
        metalLayer.displaySyncEnabled = true
        onPresentationLayerReady?()
        logger.info("presentation sync on \(self.lowLatencyPresentation ? "(timed gaming)" : "(quality)")")
    }

    /// AppKit may rebuild the layer's swapchain while entering or leaving a
    /// native fullscreen Space. Reassert every queue and synchronization
    /// property after the transition before the renderer acquires a drawable.
    func reapplyPresentationMode() {
        applyPresentationMode()
        applyFrameRate()
    }

    private func applyFrameRate() {
        let screenMax = (window?.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 0
        let resolved: Int
        if targetFrameRate > 0 {
            resolved = targetFrameRate
        } else {
            resolved = screenMax > 0 ? screenMax : 60
        }
        if preferredFramesPerSecond != resolved {
            preferredFramesPerSecond = resolved
            logger.info("display link \(resolved) Hz (target \(self.targetFrameRate), screen max \(screenMax))")
        }
    }

    // MARK: Cursor

    override func resetCursorRects() {
        super.resetCursorRects()
        // wlr-screencopy is intentionally requested with overlay_cursor=0,
        // so the video contains no delayed server cursor. Draw the client's
        // arrow at the input position instead: absolute pointer motion feels
        // local (sub-millisecond) while the desktop response still follows
        // the measured video path. Pointer lock hides it through NSCursor.
        guard inputHandler?.isPointerLocked != true else { return }
        addCursorRect(bounds, cursor: .arrow)
    }

    private func refreshCursor() {
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        inputHandler?.setCaptured(true)
        refreshCursor()
        return true
    }

    override func resignFirstResponder() -> Bool {
        inputHandler?.setCaptured(false)
        refreshCursor()
        return true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // Native fullscreen has no visible chrome in gaming mode. Keep the
        // standard Escape route local so the user can always get the controls
        // back; pointer lock consumes its first Escape in InputController.
        if event.keyCode == 0x35,
           inputHandler?.isPointerLocked != true,
           window?.styleMask.contains(.fullScreen) == true {
            window?.toggleFullScreen(nil)
            return
        }
        if inputHandler?.handleKeyDown(event) != true {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        inputHandler?.handleKeyUp(event)
    }

    override func flagsChanged(with event: NSEvent) {
        inputHandler?.handleFlagsChanged(event)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        forwardButton(event, pressed: true)
    }

    override func mouseUp(with event: NSEvent) {
        forwardButton(event, pressed: false)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        forwardButton(event, pressed: true)
    }

    override func rightMouseUp(with event: NSEvent) {
        forwardButton(event, pressed: false)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        forwardButton(event, pressed: true)
    }

    override func otherMouseUp(with event: NSEvent) {
        forwardButton(event, pressed: false)
    }

    override func mouseMoved(with event: NSEvent) {
        forwardMotion(event)
    }

    override func mouseDragged(with event: NSEvent) {
        forwardMotion(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        forwardMotion(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        forwardMotion(event)
    }

    override func scrollWheel(with event: NSEvent) {
        // Captured scroll is remote input; uncaptured scroll stays local so
        // the one-to-one mode's scroll view can pan (US-010).
        if inputHandler?.isCaptured == true {
            inputHandler?.handleScroll(event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    // MARK: Forwarding

    private func forwardButton(_ event: NSEvent, pressed: Bool) {
        guard let button = InputController.MouseButton.from(eventType: event.type,
                                                            buttonNumber: event.buttonNumber) else { return }
        inputHandler?.handleMouseButton(button, pressed: pressed)
    }

    private func forwardMotion(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        inputHandler?.handleMouseMotion(point: point,
                                        deltaX: event.deltaX,
                                        deltaY: event.deltaY,
                                        viewSize: bounds.size)
    }
}
