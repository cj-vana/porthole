import Foundation

/// Walks a machine's address candidates for one connect attempt (US-007).
/// The first candidate is tried at once; each later one only after the
/// previous has had `timeoutSeconds` without reaching the session's ready
/// state. Reaching it, or ending the session, cancels the walk.
final class DialWalker {
    /// Dial this candidate now. The first call is synchronous inside
    /// `start`; later ones arrive on the walker's queue.
    var onTry: ((_ host: String, _ port: UInt16) -> Void)?
    /// Every candidate timed out.
    var onExhausted: (() -> Void)?

    private let queue: DispatchQueue
    private let timeoutSeconds: Double
    private let lock = NSLock()
    private var remaining: [(host: String, port: UInt16)] = []
    private var timeout: DispatchWorkItem?

    init(queue: DispatchQueue, timeoutSeconds: Double = 0.25) {
        self.queue = queue
        self.timeoutSeconds = timeoutSeconds
    }

    func start(hosts: [String], port: UInt16) {
        cancel()
        lock.lock()
        remaining = hosts.map { ($0, port) }
        lock.unlock()
        advance()
    }

    func cancel() {
        lock.lock()
        timeout?.cancel()
        timeout = nil
        remaining = []
        lock.unlock()
    }

    private func advance() {
        lock.lock()
        guard !remaining.isEmpty else {
            lock.unlock()
            onExhausted?()
            return
        }
        let next = remaining.removeFirst()
        let work = DispatchWorkItem { [weak self] in self?.advance() }
        timeout = work
        lock.unlock()
        onTry?(next.host, next.port)
        queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)
    }
}
