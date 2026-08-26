import AppKit
import MetalKit
import os

/// The Metal surface, with input capture (US-006). First responder while
/// clicked into; NSEvents forward to InputController. Input flows only while
/// the view holds focus; clicking the view captures, clicking elsewhere
/// releases (resignFirstResponder).
final class SessionSurfaceView: MTKView {
    var inputHandler: InputController?

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

    /// Shown over the surface while input is captured and pointer lock is
    /// off. The remote cursor is composited into the stream (headless
    /// outputs have no hardware cursor plane), so with the local arrow also
    /// visible there are two cursors on screen and any latency looks worse
    /// than it is. Cursor rects are window-scoped and stateless, unlike
    /// NSCursor.hide/unhide, so leaving the surface brings the arrow back
    /// with no bookkeeping.
    private static let transparentCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true }
        return NSCursor(image: image, hotSpot: .zero)
    }()

    /// Top-left origin, matching remote output pixels and the letterbox math.
    override var isFlipped: Bool { true }
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
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification,
                                                                    object: nil,
                                                                    queue: .main) { [weak self] notification in
                guard let self, let window = self.window,
                      (notification.object as? NSWindow) === window else { return }
                self.applyFrameRate()
            }
        }
        applyFrameRate()
    }

    private func applyFrameRate() {
        let resolved: Int
        if targetFrameRate > 0 {
            resolved = targetFrameRate
        } else {
            let maximum = (window?.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 0
            resolved = maximum > 0 ? maximum : 60
        }
        if preferredFramesPerSecond != resolved {
            preferredFramesPerSecond = resolved
            let screenMax = (window?.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 0
            logger.info("display link \(resolved) Hz (target \(self.targetFrameRate), screen max \(screenMax))")
        }
    }

    // MARK: Cursor

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let inputHandler, inputHandler.isCaptured, !inputHandler.isPointerLocked else { return }
        addCursorRect(bounds, cursor: Self.transparentCursor)
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
