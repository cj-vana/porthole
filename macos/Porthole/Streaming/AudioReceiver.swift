import Darwin
import Foundation
import os

/// UDP receiver for the agent's Opus audio stream (docs/protocol.md,
/// US-009). Same BSD-socket shape as VideoReceiver, with the same teardown
/// rule: the receive thread owns the descriptor and is the only place it is
/// closed, because a close from stop() would race a reader between two
/// recvfrom calls onto a descriptor number the kernel may have reissued
/// (see VideoReceiver for the full rationale). SO_RCVTIMEO bounds how long
/// an idle reader takes to notice the stop flag. Audio is about fifty
/// datagrams of a few hundred bytes per second, so the default socket
/// buffer is plenty and there is no SO_RCVBUF tuning here.
final class AudioReceiver {
    enum Event {
        case packet(WireProtocol.AudioDatagram)
        case failed(String)
    }

    /// Fires on the receive thread; callers treat it as a background queue.
    var onEvent: ((Event) -> Void)?

    private static let datagramBufferBytes = 4 * 1024
    private static let receiveTimeout = timeval(tv_sec: 0, tv_usec: 100_000)

    private let logger = Logger(subsystem: "com.porthole.mac", category: "audio")
    private let stateLock = NSLock()
    private var stopping = false
    private var thread: Thread?
    private var exited = DispatchSemaphore(value: 0)

    /// Returns the port actually bound, or nil on failure. Failures on the
    /// running socket are reported through `onEvent` as well.
    @discardableResult
    func start(port: UInt16) -> UInt16? {
        stop()
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            onEvent?(.failed("audio UDP socket failed: \(Self.errnoDescription())"))
            return nil
        }
        var timeout = Self.receiveTimeout
        let timeoutSet = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                                    socklen_t(MemoryLayout<timeval>.size))
        guard timeoutSet == 0 else {
            // Without the timeout nothing can stop the reader once it blocks.
            let reason = Self.errnoDescription()
            close(descriptor)
            onEvent?(.failed("audio SO_RCVTIMEO failed: \(reason)"))
            return nil
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let reason = Self.errnoDescription()
            close(descriptor)
            onEvent?(.failed("audio UDP bind on :\(port) failed: \(reason)"))
            return nil
        }

        let exited = DispatchSemaphore(value: 0)
        stateLock.lock()
        stopping = false
        self.exited = exited
        stateLock.unlock()

        let thread = Thread { [weak self] in
            self?.receiveLoop(descriptor: descriptor)
            // Closed before `exited` fires so that stop() returning means
            // the port is free for the next start().
            close(descriptor)
            exited.signal()
        }
        thread.name = "porthole.audio"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        return port
    }

    func stop() {
        stateLock.lock()
        stopping = true
        stateLock.unlock()
        if let thread, thread !== Thread.current,
           exited.wait(timeout: .now() + 2) == .timedOut {
            logger.warning("audio receive thread did not exit after stop")
        }
        thread = nil
    }

    /// Runs until stop() raises the flag, with `receiveTimeout` bounding
    /// the wait when nothing arrives. One Data copy per datagram, out of a
    /// buffer reused for the life of the thread.
    private func receiveLoop(descriptor: Int32) {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.datagramBufferBytes, alignment: 16)
        defer { buffer.deallocate() }
        while !isStopping {
            let received = recvfrom(descriptor, buffer, Self.datagramBufferBytes, 0, nil, nil)
            if received < 0 {
                let code = errno
                if code == EINTR || code == EAGAIN || code == EWOULDBLOCK { continue }
                if isStopping { return }
                onEvent?(.failed("audio UDP receive failed: \(String(cString: strerror(code)))"))
                return
            }
            guard received > 0 else { continue }
            let data = Data(bytes: buffer, count: received)
            if let packet = WireProtocol.parseAudioDatagram(data) {
                onEvent?(.packet(packet))
            }
        }
    }

    private var isStopping: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopping
    }

    private static func errnoDescription() -> String {
        String(cString: strerror(errno))
    }
}
