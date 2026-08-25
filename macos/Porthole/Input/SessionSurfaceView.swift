import AppKit
import MetalKit

/// The Metal surface, with input capture (US-006). First responder while
/// clicked into; NSEvents forward to InputController. Input flows only while
/// the view holds focus; clicking the view captures, clicking elsewhere
/// releases (resignFirstResponder).
final class SessionSurfaceView: MTKView {
    var inputHandler: InputController?

    /// Top-left origin, matching remote output pixels and the letterbox math.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Let the window-activating click land on the view (and thus the remote
    /// desktop) instead of being eaten by activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        inputHandler?.setCaptured(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        inputHandler?.setCaptured(false)
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
        inputHandler?.handleScroll(event)
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
