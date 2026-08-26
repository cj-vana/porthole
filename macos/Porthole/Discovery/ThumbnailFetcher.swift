import CoreGraphics
import Foundation
import Network

/// One-shot thumbnail fetch (FR-10, docs/protocol.md): connect to the
/// machine's thumb_port over TCP, read one length-prefixed message of
/// {width u16, height u16, RGBA8 pixels}, connection closes. The endpoint
/// exists so picker polls never touch the single-client control channel.
enum ThumbnailFetcher {
    /// Fetch and decode one thumbnail. Returns nil when the machine is
    /// unreachable, the payload is malformed, or the agent has captured no
    /// frame yet (length 0). Runs off the main thread; safe to call often.
    static func fetch(host: String, port: UInt16) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let box = ResumeBox(continuation: continuation)
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                box.resumeIfPending(nil)
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(host),
                                          port: endpointPort,
                                          using: .tcp)
            var buffer = Data()

            // Unreachable hosts (Tailscale down, wrong IP) should fail fast.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                box.resumeIfPending(nil)
                connection.cancel()
            }

            func receive() {
                connection.receive(minimumIncompleteLength: 1,
                                   maximumLength: 1 << 21) { data, _, isComplete, error in
                    if let data {
                        buffer.append(data)
                    }
                    // Parse eagerly: the agent closes after one message.
                    if let image = parse(buffer) {
                        box.resumeIfPending(image)
                        connection.cancel()
                        return
                    }
                    if isComplete || error != nil {
                        connection.cancel()
                        box.resumeIfPending(nil)
                        return
                    }
                    receive()
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    receive()
                case .failed, .cancelled:
                    box.resumeIfPending(nil)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "porthole.thumb"))
        }
    }

    /// Parse a complete thumbnail message into a CGImage. Returns nil when
    /// the buffer is incomplete, empty (no frame yet), or malformed.
    static func parse(_ data: Data) -> CGImage? {
        guard data.count >= 4 else { return nil }
        let length = Int(data.readUInt32BE(at: 0))
        guard length > 0 else { return nil } // no frame captured yet
        guard data.count >= 4 + length, length >= 4 else { return nil }
        let payload = data.subdata(in: 4..<(4 + length))
        let width = Int(payload.readUInt16BE(at: 0))
        let height = Int(payload.readUInt16BE(at: 2))
        guard width > 0, height > 0, payload.count == 4 + width * height * 4 else {
            return nil
        }
        let pixels = payload.subdata(in: 4..<payload.count) as CFData
        guard let provider = CGDataProvider(data: pixels) else { return nil }
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                           | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    /// Resume exactly once, balancing NWConnection's many terminal paths.
    /// Lock-guarded, hence safe to send across the connection's @Sendable
    /// handlers.
    private final class ResumeBox: @unchecked Sendable {
        private var continuation: CheckedContinuation<CGImage?, Never>?
        private let lock = NSLock()

        init(continuation: CheckedContinuation<CGImage?, Never>) {
            self.continuation = continuation
        }

        func resumeIfPending(_ image: CGImage?) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: image)
        }
    }
}
