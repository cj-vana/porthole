import AppKit
import Foundation

/// Translates AppKit input into Porthole wire messages (US-006).
///
/// Stateful: tracks held modifiers (sent as key_modifiers 0x15 before
/// dependent keys, so shifted characters work on Linux), pointer lock, and
/// the remote output size used for absolute motion mapping. Everything
/// arrives on the main thread from SessionSurfaceView; the porthole-input-test
/// CLI drives the same entry points with factory-built NSEvents.
final class InputController {
    /// Full control frames ready for the wire; StreamSession routes them to
    /// the ControlChannel.
    var onSend: ((Data) -> Void)?
    /// Focus/lock state changes for the chrome indicator; called on main.
    var onCaptureChanged: ((Bool) -> Void)?
    var onPointerLockChanged: ((Bool) -> Void)?

    /// Remote output size from the hello handshake.
    var videoSize = CGSize(width: 2560, height: 1440)
    /// When false, Cmd chords (Cmd+Space, Cmd+Tab, ...) are not forwarded and
    /// macOS keeps them. When true they are forwarded best effort; note that
    /// Cmd+Tab and friends are intercepted by the Window Server before the
    /// app ever sees them, so "on" cannot forward those particular chords.
    var sendSystemShortcuts = false
    /// Chrome toggle intent. The lock engages only while the surface has
    /// focus; Esc releases it.
    var wantsPointerLock = false {
        didSet { updatePointerLock() }
    }

    private(set) var isCaptured = false
    private(set) var isPointerLocked = false

    /// macOS keyCodes of currently held modifiers (left/right tracked apart).
    private var heldModifierKeys: Set<UInt16> = []
    private var capsLockOn = false
    // Fresh agent state is all zeros, so the first key does not emit a
    // redundant key_modifiers frame; only real changes do.
    private var lastSentDepressed: UInt32 = 0
    private var lastSentLocked: UInt32 = 0

    /// Mouse buttons the protocol understands.
    enum MouseButton {
        case left, right, middle, back, forward

        var evdevCode: UInt16 {
            switch self {
            case .left: return InputMessages.buttonLeft
            case .right: return InputMessages.buttonRight
            case .middle: return InputMessages.buttonMiddle
            case .back: return InputMessages.buttonSide
            case .forward: return InputMessages.buttonExtra
            }
        }

        /// AppKit event type + buttonNumber to button. Nil for unknown.
        static func from(eventType: NSEvent.EventType, buttonNumber: Int) -> MouseButton? {
            switch eventType {
            case .leftMouseDown, .leftMouseUp: return .left
            case .rightMouseDown, .rightMouseUp: return .right
            case .otherMouseDown, .otherMouseUp:
                switch buttonNumber {
                case 2: return .middle
                case 3: return .back
                case 4: return .forward
                default: return nil
                }
            default: return nil
            }
        }
    }

    // MARK: Keyboard

    /// Returns true when the event was consumed (forwarded or deliberately
    /// handled); false means the caller should pass it up the responder chain.
    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        // Pointer lock: Esc releases the lock and is not forwarded.
        if isPointerLocked, event.keyCode == 0x35 { // kVK_Escape
            wantsPointerLock = false
            return true
        }
        // System-shortcut chords stay local unless the toggle says otherwise.
        if event.modifierFlags.contains(.command), !sendSystemShortcuts {
            return false
        }
        guard let code = KeyMap.evdevCode(forKeyCode: event.keyCode) else {
            return true // unmapped key: consume quietly
        }
        syncModifiers()
        if event.isARepeat {
            // The virtual keyboard has no auto-repeat; fake it as pairs.
            sendKey(code, pressed: true)
            sendKey(code, pressed: false)
        } else {
            sendKey(code, pressed: true)
        }
        return true
    }

    func handleKeyUp(_ event: NSEvent) {
        if event.modifierFlags.contains(.command), !sendSystemShortcuts {
            return
        }
        guard let code = KeyMap.evdevCode(forKeyCode: event.keyCode) else { return }
        syncModifiers()
        sendKey(code, pressed: false)
    }

    func handleFlagsChanged(_ event: NSEvent) {
        switch event.keyCode {
        case 0x38, 0x3C: // Shift left/right
            updateModifier(keyCode: event.keyCode, down: event.modifierFlags.contains(.shift))
        case 0x3B, 0x3E: // Control
            updateModifier(keyCode: event.keyCode, down: event.modifierFlags.contains(.control))
        case 0x3A, 0x3D: // Option (Alt)
            updateModifier(keyCode: event.keyCode, down: event.modifierFlags.contains(.option))
        case 0x37, 0x36: // Command (Super)
            updateModifier(keyCode: event.keyCode, down: event.modifierFlags.contains(.command))
        case 0x39: // CapsLock
            let isOn = event.modifierFlags.contains(.capsLock)
            guard isOn != capsLockOn else { return }
            capsLockOn = isOn
            sendKey(KeyMap.keyCapsLock, pressed: isOn)
            syncModifiers()
        default:
            break
        }
    }

    private func updateModifier(keyCode: UInt16, down: Bool) {
        let wasDown = heldModifierKeys.contains(keyCode)
        guard down != wasDown else { return }
        if down {
            heldModifierKeys.insert(keyCode)
        } else {
            heldModifierKeys.remove(keyCode)
        }
        if let evdev = KeyMap.evdevCode(forKeyCode: keyCode) {
            sendKey(evdev, pressed: down)
        }
        syncModifiers()
    }

    // MARK: Mouse

    /// Buttons forward even without focus: the click that focuses the view
    /// also acts on the remote desktop, as remote desktop clients do.
    func handleMouseButton(_ button: MouseButton, pressed: Bool) {
        syncModifiers()
        sendButton(button.evdevCode, pressed: pressed)
    }

    /// Motion and scroll flow only while captured. When pointer-locked, the
    /// point is meaningless and device deltas become pointer_motion_rel.
    func handleMouseMotion(point: CGPoint, deltaX: Double, deltaY: Double, viewSize: CGSize) {
        guard isCaptured else { return }
        if isPointerLocked {
            sendMotionRel(dx256: Self.fixed256(deltaX), dy256: Self.fixed256(deltaY))
            return
        }
        guard let output = Letterbox.outputPoint(forViewPoint: point,
                                                 viewSize: viewSize,
                                                 videoSize: videoSize) else { return }
        sendMotionAbs(x: Int32(output.x), y: Int32(output.y))
    }

    /// Trackpad scroll is pixel-precise (hasPreciseScrollingDeltas, momentum
    /// arrives as continued deltas with momentumPhase set). Mouse wheels get
    /// one click = 10 px per protocol convention. macOS reports positive
    /// deltas for up/left; wl_pointer reports positive for down/right, so the
    /// sign flips.
    func handleScroll(_ event: NSEvent) {
        guard isCaptured else { return }
        let source: InputMessages.AxisSource
        if event.momentumPhase != [] {
            source = .continuous
        } else if event.phase != [] {
            source = .finger
        } else if event.hasPreciseScrollingDeltas {
            source = .continuous
        } else {
            source = .wheel
        }
        let unitScale = event.hasPreciseScrollingDeltas ? 256.0 : 2560.0
        let deltaY = -event.scrollingDeltaY
        let deltaX = -event.scrollingDeltaX
        if deltaY != 0 {
            sendAxis(vertical: true, source: source, value256: Self.fixed256(deltaY, unitScale: unitScale))
        }
        if deltaX != 0 {
            sendAxis(vertical: false, source: source, value256: Self.fixed256(deltaX, unitScale: unitScale))
        }
    }

    private static func fixed256(_ value: Double, unitScale: Double = 256) -> Int32 {
        Int32(min(Double(Int32.max), max(Double(Int32.min), (value * unitScale).rounded())))
    }

    // MARK: Focus and pointer lock

    func setCaptured(_ captured: Bool) {
        guard captured != isCaptured else { return }
        isCaptured = captured
        if !captured {
            releaseModifiers()
        }
        updatePointerLock()
        onCaptureChanged?(captured)
    }

    /// Release on disconnect/teardown: modifiers up, lock off, state clean.
    func reset() {
        releaseModifiers()
        wantsPointerLock = false
        isCaptured = false
    }

    /// Release held modifiers remotely so focus loss never strands Shift on
    /// the Linux side.
    private func releaseModifiers() {
        for keyCode in heldModifierKeys {
            if let evdev = KeyMap.evdevCode(forKeyCode: keyCode) {
                sendKey(evdev, pressed: false)
            }
        }
        heldModifierKeys.removeAll()
        if capsLockOn {
            sendKey(KeyMap.keyCapsLock, pressed: false)
            capsLockOn = false
        }
        syncModifiers(force: true)
    }

    private func updatePointerLock() {
        let shouldLock = wantsPointerLock && isCaptured
        guard shouldLock != isPointerLocked else { return }
        isPointerLocked = shouldLock
        if shouldLock {
            NSCursor.hide()
            _ = CGAssociateMouseAndMouseCursorPosition(0) // freeze the cursor
        } else {
            _ = CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
        onPointerLockChanged?(shouldLock)
    }

    // MARK: Scripted typing (porthole-input-test)

    /// Type a string as key events. Shifted characters are produced through
    /// key_modifiers (the virtual keyboard ignores shift key presses for
    /// character shifting, per the agent's US-006a notes).
    func typeText(_ text: String) {
        for character in text {
            guard let stroke = KeyMap.keystroke(for: character) else { continue }
            let base = depressedMask()
            if stroke.needsShift {
                sendModifiers(depressed: base | InputMessages.ModifierBit.shift)
            }
            sendKey(stroke.code, pressed: true)
            sendKey(stroke.code, pressed: false)
            if stroke.needsShift {
                sendModifiers(depressed: base)
            }
        }
    }

    // MARK: Wire primitives

    func sendMotionAbs(x: Int32, y: Int32) {
        emit(InputMessages.motionAbs(x: x, y: y))
    }

    func sendMotionRel(dx256: Int32, dy256: Int32) {
        emit(InputMessages.motionRel(dx256: dx256, dy256: dy256))
    }

    func sendButton(_ evdevCode: UInt16, pressed: Bool) {
        emit(InputMessages.button(evdevCode, pressed: pressed))
    }

    func sendAxis(vertical: Bool, source: InputMessages.AxisSource, value256: Int32) {
        emit(InputMessages.axis(vertical: vertical, source: source, value256: value256))
    }

    func sendKey(_ evdevCode: UInt16, pressed: Bool) {
        emit(InputMessages.key(evdevCode, pressed: pressed))
    }

    func sendModifiers(depressed: UInt32, locked: UInt32 = 0) {
        lastSentDepressed = depressed
        lastSentLocked = locked
        emit(InputMessages.keyModifiers(depressed: depressed, locked: locked))
    }

    /// Send key_modifiers when the mask changed; called before dependent
    /// keys and buttons so shifted characters and chords arrive in order.
    private func syncModifiers(force: Bool = false) {
        let depressed = depressedMask()
        let locked = capsLockOn ? InputMessages.ModifierBit.lock : 0
        if force || depressed != lastSentDepressed || locked != lastSentLocked {
            sendModifiers(depressed: depressed, locked: locked)
        }
    }

    /// xkb depressed mask from held keys; classic X11 bit order, see
    /// InputMessages.ModifierBit.
    private func depressedMask() -> UInt32 {
        var mask: UInt32 = 0
        if heldModifierKeys.contains(0x38) || heldModifierKeys.contains(0x3C) {
            mask |= InputMessages.ModifierBit.shift
        }
        if heldModifierKeys.contains(0x3B) || heldModifierKeys.contains(0x3E) {
            mask |= InputMessages.ModifierBit.control
        }
        if heldModifierKeys.contains(0x3A) || heldModifierKeys.contains(0x3D) {
            mask |= InputMessages.ModifierBit.alt
        }
        if heldModifierKeys.contains(0x37) || heldModifierKeys.contains(0x36) {
            mask |= InputMessages.ModifierBit.sup
        }
        return mask
    }

    private func emit(_ frame: Data) {
        onSend?(frame)
    }
}
