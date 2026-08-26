import Foundation

/// Bounded count of access units in flight from the receive thread to the
/// decode queue. A full backlog means decode is falling behind, which is
/// decode-fatal for predictive video anyway: the caller drops the unit and
/// resyncs on a keyframe instead of queueing further behind.
final class DecodeBacklog {
    private let lock = NSLock()
    private let limit: Int
    private var count = 0

    init(limit: Int) {
        self.limit = limit
    }

    /// Take a slot; false when the backlog is full.
    func reserve() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count < limit else { return false }
        count += 1
        return true
    }

    func release() {
        lock.lock()
        count -= 1
        lock.unlock()
    }

    var depth: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
