import AppKit
import ApplicationServices
import CoreGraphics
import os

/// Filters keyboard events before macOS global shortcuts and menu equivalents
/// can consume them. The tap stays installed while the Shortcuts toggle is on,
/// but filters only while Porthole is active and its stream surface is captured.
final class SystemShortcutCapture {
    private static let keyboardMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        | CGEventMask(1) << CGEventType.keyUp.rawValue
        | CGEventMask(1) << CGEventType.flagsChanged.rawValue

    private weak var input: InputController?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var injectedPresentationOptions: NSApplication.PresentationOptions = []
    private let logger = Logger(subsystem: "com.porthole.mac", category: "shortcuts")

    init(input: InputController) {
        self.input = input
    }

    deinit {
        stop()
    }

    var isRunning: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    /// Accessibility access is required for a non-root session tap to receive
    /// and discard keyboard events. The system prompt is requested only after
    /// the user explicitly enables Shortcuts.
    func start() -> Bool {
        precondition(Thread.isMainThread)
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return true
        }
        guard Self.requestAccessibilityAccess() else {
            logger.notice("Accessibility permission is required for shortcut capture")
            return false
        }
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.keyboardMask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            logger.error("Could not create the active keyboard event tap")
            return false
        }

        self.eventTap = eventTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        logger.info("System shortcut capture enabled")
        return true
    }

    func stop() {
        setCaptureActive(false)
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    /// The Dock owns process switching below ordinary application dispatch.
    /// Pair the event filter with AppKit's public kiosk-style guards while the
    /// remote surface is focused, then remove only the options added here.
    func setCaptureActive(_ active: Bool) {
        precondition(Thread.isMainThread)
        if active {
            guard injectedPresentationOptions.isEmpty else { return }
            let existing = NSApp.presentationOptions
            var requested: NSApplication.PresentationOptions = [
                .disableProcessSwitching,
                .disableForceQuit,
                .disableSessionTermination,
                .disableHideApplication
            ]
            if !existing.contains(.hideDock), !existing.contains(.autoHideDock) {
                requested.insert(.autoHideDock)
            }
            injectedPresentationOptions = requested.subtracting(existing)
            NSApp.presentationOptions = existing.union(injectedPresentationOptions)
        } else if !injectedPresentationOptions.isEmpty {
            var restored = NSApp.presentationOptions
            restored.subtract(injectedPresentationOptions)
            NSApp.presentationOptions = restored
            injectedPresentationOptions = []
        }
    }

    private static func requestAccessibilityAccess() -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let capture = Unmanaged<SystemShortcutCapture>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return capture.filter(type: type, event: event)
    }

    private func filter(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                logger.notice("Re-enabled a disabled system shortcut event tap")
            }
            return Unmanaged.passUnretained(event)
        }

        guard let input,
              let appEvent = NSEvent(cgEvent: event),
              Self.shouldFilter(event: appEvent,
                                enabled: input.sendSystemShortcuts,
                                captured: input.isCaptured,
                                applicationIsActive: NSApp.isActive) else {
            return Unmanaged.passUnretained(event)
        }
        guard input.handleCapturedKeyboardEvent(appEvent) else {
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    /// Escape is Porthole's invariant release path for pointer lock and native
    /// fullscreen. Modified Escape remains a remote shortcut.
    static func shouldFilter(event: NSEvent,
                             enabled: Bool,
                             captured: Bool,
                             applicationIsActive: Bool) -> Bool {
        enabled && captured && applicationIsActive && !isLocalEscape(event)
    }

    private static func isLocalEscape(_ event: NSEvent) -> Bool {
        guard event.keyCode == 0x35 else { return false }
        let shortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        return event.modifierFlags.isDisjoint(with: shortcutModifiers)
    }
}
