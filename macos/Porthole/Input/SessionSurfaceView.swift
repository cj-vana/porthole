import AppKit
import CoreGraphics
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
    private var terminationObserver: NSObjectProtocol?
    private var savedDisplayMode: (displayID: CGDirectDisplayID, mode: CGDisplayMode)?
    private var displayModeChangeInFlight = false
    private var fullscreenPresentationSettled = false
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
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        restoreGamingDisplayMode()
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
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.restoreGamingDisplayMode()
            }
        }
        applyFrameRate()
    }

    private func applyPresentationMode() {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        // Keep the swapchain at the minimum depth. A third writable surface
        // lets Core Animation retain another complete frame even though the
        // cadence wheel submits only once per tick.
        let drawableCount = 2
        if metalLayer.maximumDrawableCount != drawableCount {
            metalLayer.maximumDrawableCount = drawableCount
        }
        // Fullscreen Space transitions can temporarily make every drawable
        // unavailable. A bounded nextDrawable() wait lets the mailbox recover
        // after occlusion instead of pinning its serial render worker forever.
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.presentsWithTransaction = false
        // Gaming commits exactly once from the physical display link. Let that
        // be the only pacing clock: synchronized Core Animation presentation
        // otherwise retains two extra frames behind the manual late latch.
        // Quality mode keeps the ordinary tear-free synchronized path.
        metalLayer.displaySyncEnabled = !lowLatencyPresentation
        onPresentationLayerReady?()
        logger.info("presentation sync \(self.lowLatencyPresentation ? "off (gaming wheel)" : "on (quality)")")
    }

    /// AppKit may rebuild the layer's swapchain while entering or leaving a
    /// native fullscreen Space. Reassert every queue and synchronization
    /// property after the transition before the renderer acquires a drawable.
    func reapplyPresentationMode() {
        applyPresentationMode()
        applyFrameRate()
    }

    /// Native fullscreen replaces the drawable pool while its Space is still
    /// animating. Delay the gaming-only panel cadence change until AppKit has
    /// completed that replacement so the new swapchain inherits the final
    /// display clock instead of the transient one.
    func setFullscreenPresentationSettled(_ settled: Bool) {
        fullscreenPresentationSettled = settled
    }

    private func applyFrameRate() {
        let screen = window?.screen ?? NSScreen.main
        let screenMax = screen?.maximumFramesPerSecond ?? 0
        let resolved: Int
        if targetFrameRate > 0 {
            resolved = targetFrameRate
        } else {
            resolved = screenMax > 0 ? screenMax : 60
        }
        let presentationRate = resolved
        // MTKView is paused in gaming mode, but its rate hint still controls
        // CAMetalLayer recycling. Keep it on the cadence wheel's clock.
        let layerRateHint = presentationRate
        applyGamingDisplayMode(screen: screen, refreshRate: presentationRate)
        if preferredFramesPerSecond != layerRateHint {
            preferredFramesPerSecond = layerRateHint
            logger.info(
                "layer \(layerRateHint) Hz; gaming \(presentationRate) Hz; screen \(screenMax) Hz"
            )
        }
    }

    private func applyGamingDisplayMode(screen: NSScreen?, refreshRate: Int) {
        guard !displayModeChangeInFlight else { return }
        guard lowLatencyPresentation, fullscreenPresentationSettled, let screen,
              let displayID = screen.deviceDescription[
                  NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber else {
            restoreGamingDisplayMode()
            return
        }
        let targetID = CGDirectDisplayID(displayID.uint32Value)
        if let savedDisplayMode, savedDisplayMode.displayID != targetID {
            restoreGamingDisplayMode()
        }
        guard let currentMode = CGDisplayCopyDisplayMode(targetID),
              abs(currentMode.refreshRate - Double(refreshRate)) >= 0.5,
              let targetMode = displayMode(screen: screen, refreshRate: refreshRate) else { return }

        if savedDisplayMode == nil {
            savedDisplayMode = (targetID, currentMode)
        }
        displayModeChangeInFlight = true
        let changed = Self.configureDisplay(targetID, mode: targetMode)
        displayModeChangeInFlight = false
        if changed {
            logger.info(
                "gaming display cadence \(Int(currentMode.refreshRate)) -> \(refreshRate) Hz"
            )
            // CoreGraphics completes the mode transaction synchronously, but
            // AppKit publishes the replacement drawable pool shortly after.
            // Rebind once that pool exists; the second pass sees the desired
            // mode and therefore cannot trigger another display transaction.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
                self?.reapplyPresentationMode()
            }
        } else {
            savedDisplayMode = nil
            logger.error("could not apply gaming display cadence \(refreshRate) Hz")
        }
    }

    private func displayMode(screen: NSScreen, refreshRate: Int) -> CGDisplayMode? {
        guard let displayNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(displayNumber.uint32Value)
        guard let current = CGDisplayCopyDisplayMode(displayID),
              let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            return nil
        }
        return modes.first {
            $0.width == current.width
                && $0.height == current.height
                && $0.pixelWidth == current.pixelWidth
                && $0.pixelHeight == current.pixelHeight
                && abs($0.refreshRate - Double(refreshRate)) < 0.5
        }
    }

    private func restoreGamingDisplayMode() {
        guard !displayModeChangeInFlight, let savedDisplayMode else { return }
        displayModeChangeInFlight = true
        let restored = Self.configureDisplay(savedDisplayMode.displayID,
                                             mode: savedDisplayMode.mode)
        displayModeChangeInFlight = false
        if restored {
            logger.info("restored display cadence \(Int(savedDisplayMode.mode.refreshRate)) Hz")
            self.savedDisplayMode = nil
        } else {
            logger.error("could not restore original display cadence")
        }
    }

    private static func configureDisplay(_ displayID: CGDirectDisplayID,
                                         mode: CGDisplayMode) -> Bool {
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success,
              let configuration else { return false }
        guard CGConfigureDisplayWithDisplayMode(configuration, displayID, mode, nil) == .success else {
            CGCancelDisplayConfiguration(configuration)
            return false
        }
        return CGCompleteDisplayConfiguration(configuration, .forSession) == .success
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
        // Captured scroll is remote input; uncaptured scroll stays local.
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
