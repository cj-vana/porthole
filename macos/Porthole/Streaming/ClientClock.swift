import Foundation
import QuartzCore

/// The one client-side clock for latency math: ping timestamps, datagram
/// arrival, decode completion, and presentation all read it. It is
/// CACurrentMediaTime because CAMetalDrawable.presentedTime is on that base,
/// and mixing clocks would put presentation on a different timeline from
/// everything else.
enum ClientClock {
    static func nowMicros() -> UInt64 {
        UInt64(CACurrentMediaTime() * 1_000_000)
    }
}
