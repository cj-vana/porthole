import Foundation

/// The main-thread peripherals of a live session: clipboard sync (US-008)
/// and gamepad passthrough (US-014). Owns their wiring to the control
/// channel so StreamSession only drives lifecycle: start on the live
/// transition, stop on disconnect.
final class SessionPeripherals {
    private let clipboard = ClipboardSync()
    private let gamepad = GamepadForwarder()

    init(control: ControlChannel) {
        clipboard.onLocalCopy = { [weak control] text in
            control?.sendClipboard(text)
        }
        gamepad.onState = { [weak control] state in
            control?.sendGamepad(buttons: state.buttons, axes: state.axes, hat: state.hat)
        }
    }

    /// Chrome toggle (US-008): pause or resume clipboard sync without
    /// touching the connection.
    var clipboardEnabled: Bool {
        get { clipboard.enabled }
        set { clipboard.enabled = newValue }
    }

    /// Peer clipboard text from the control channel; any thread. The
    /// pasteboard write happens on main, where the sync timer runs.
    func applyClipboard(fromPeer text: String) {
        DispatchQueue.main.async { [clipboard] in
            clipboard.applyFromPeer(text)
        }
    }

    /// Live transition, called from the decode queue. Both peripherals are
    /// main-thread (the pasteboard timer, the GameController notifications),
    /// so hop; `stillLive` runs on main and covers a disconnect racing the
    /// hop. The starts are idempotent, which covers the re-entry after a
    /// mid-session encoder reconfigure.
    func start(stillLive: @escaping () -> Bool) {
        DispatchQueue.main.async { [self] in
            guard stillLive() else { return }
            clipboard.start()
            gamepad.start()
        }
    }

    /// Disconnect; main thread, like the session teardown that calls it.
    func stop() {
        clipboard.stop()
        gamepad.stop()
    }
}
