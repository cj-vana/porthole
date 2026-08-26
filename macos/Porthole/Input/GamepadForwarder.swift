import Foundation
import GameController

/// Forwards a connected controller's state to the agent (US-014). Each
/// GCExtendedGamepad change is converted whole to the wire layout and sent
/// from the valueChangedHandler itself, so passthrough adds no polling
/// latency. Identical consecutive states are dropped: an idle analog stick
/// still fires the handler, and resending the same 17 bytes would flood
/// the control channel for nothing.
final class GamepadForwarder {
    /// One wire-ready snapshot per change; StreamSession frames and sends it.
    var onState: ((State) -> Void)?

    /// gamepad_state fields, already in wire convention (evdev signs and
    /// ranges) rather than GameController's.
    struct State: Equatable {
        var buttons: UInt32 = 0
        /// Left stick x/y, right stick x/y, left trigger, right trigger.
        var axes: [Int16] = [0, 0, 0, 0, 0, 0]
        var hat: UInt8 = 0
    }

    private var observers: [NSObjectProtocol] = []
    private var lastSent: State?

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else { return }
            self?.attach(controller)
        })
        // A stick left deflected when the controller unplugs would stay
        // deflected on the virtual pad forever; a neutral state releases it
        // (the same reason InputController releases modifiers on focus loss).
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            self?.sendNeutral()
        })
        for controller in GCController.controllers() {
            attach(controller)
        }
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
        }
        lastSent = nil
    }

    /// Only the extended profile carries the dual-stick layout the wire
    /// wants; micro gamepads (Siri Remote) are ignored.
    private func attach(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        gamepad.valueChangedHandler = { [weak self] gamepad, _ in
            self?.forward(gamepad)
        }
    }

    private func forward(_ gamepad: GCExtendedGamepad) {
        let state = Self.wireState(for: gamepad)
        guard state != lastSent else { return }
        lastSent = state
        onState?(state)
    }

    private func sendNeutral() {
        let state = State()
        lastSent = state
        onState?(state)
    }

    /// GameController to wire: buttons into the SDL bit order, sticks and
    /// triggers scaled to i16, the dpad as the hat bitmask. GameController
    /// reports stick +y as up while the wire (evdev ABS_Y) is +down, so
    /// the y axes flip sign. buttonOptions, buttonHome, and the thumbstick
    /// buttons are optional in the profile; a pad without them reads as
    /// never pressed.
    private static func wireState(for gamepad: GCExtendedGamepad) -> State {
        var state = State()
        func button(_ bit: Int, _ pressed: Bool) {
            if pressed {
                state.buttons |= 1 << bit
            }
        }
        button(0, gamepad.buttonA.isPressed)
        button(1, gamepad.buttonB.isPressed)
        button(2, gamepad.buttonX.isPressed)
        button(3, gamepad.buttonY.isPressed)
        button(4, gamepad.buttonOptions?.isPressed ?? false) // back
        button(5, gamepad.buttonHome?.isPressed ?? false) // guide
        button(6, gamepad.buttonMenu.isPressed) // start
        button(7, gamepad.leftThumbstickButton?.isPressed ?? false)
        button(8, gamepad.rightThumbstickButton?.isPressed ?? false)
        button(9, gamepad.leftShoulder.isPressed)
        button(10, gamepad.rightShoulder.isPressed)

        state.axes = [
            stick(gamepad.leftThumbstick.xAxis.value),
            stick(-gamepad.leftThumbstick.yAxis.value),
            stick(gamepad.rightThumbstick.xAxis.value),
            stick(-gamepad.rightThumbstick.yAxis.value),
            trigger(gamepad.leftTrigger.value),
            trigger(gamepad.rightTrigger.value)
        ]

        if gamepad.dpad.up.isPressed { state.hat |= 1 }
        if gamepad.dpad.right.isPressed { state.hat |= 2 }
        if gamepad.dpad.down.isPressed { state.hat |= 4 }
        if gamepad.dpad.left.isPressed { state.hat |= 8 }
        return state
    }

    private static func stick(_ value: Float) -> Int16 {
        Int16(clamping: Int((Double(value) * 32767).rounded()))
    }

    private static func trigger(_ value: Float) -> Int16 {
        Int16(clamping: Int((Double(max(0, min(1, value))) * 32767).rounded()))
    }
}
