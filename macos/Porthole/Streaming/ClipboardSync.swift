import AppKit
import Foundation

/// Two-way clipboard text sync (US-008). NSPasteboard has no change
/// notification, so a timer polls `changeCount` a few times per second;
/// a local copy goes out through `onLocalCopy` and peer text is written
/// back to the pasteboard.
///
/// Loop prevention mirrors the agent's: the text last applied from the
/// peer is remembered and never echoed back, so one copy does not bounce
/// between the two machines forever. Main thread only (the timer rides
/// the main run loop).
final class ClipboardSync {
    /// The local pasteboard changed to this text; StreamSession sends it
    /// over the control channel.
    var onLocalCopy: ((String) -> Void)?

    /// Chrome toggle (US-008): while false nothing is sent or applied, but
    /// the watcher keeps consuming `changeCount` so re-enabling does not
    /// replay whatever was copied in between.
    var enabled = true

    private var timer: Timer?
    private var lastChangeCount = 0
    private var lastAppliedFromPeer: String?

    /// Poll interval. Pasteboard reads are cheap (changeCount is a local
    /// counter), so 300 ms keeps sync snappy without measurable cost.
    private static let interval: TimeInterval = 0.3

    func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common so sync keeps running during menu tracking and resizes.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastAppliedFromPeer = nil
    }

    /// Text the agent's clipboard picked up: apply it locally and remember
    /// it so the watcher does not send it straight back.
    func applyFromPeer(_ text: String) {
        guard enabled else { return }
        lastAppliedFromPeer = text
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        // Consume our own write so the next tick does not even read it.
        lastChangeCount = pasteboard.changeCount
    }

    private func tick() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard enabled,
              let text = pasteboard.string(forType: .string),
              text != lastAppliedFromPeer else { return }
        onLocalCopy?(text)
    }
}
