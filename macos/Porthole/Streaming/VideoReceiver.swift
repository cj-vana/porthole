import Darwin
import Foundation
import os

/// UDP receiver for the agent's fragmented video stream (docs/protocol.md).
/// The agent sends datagrams to the control peer's IP at the port negotiated
/// in `hello`; we bind that port here before asking for a keyframe.
///
/// A BSD socket on its own thread rather than NWListener: Network.framework
/// has no way to grow the socket receive buffer, and the macOS default
/// (786 KB, charged at roughly 2 KB of mbuf per datagram) overflows on a
/// 400-datagram keyframe burst, which is the loss that then forces the next
/// keyframe. `onEvent` fires on the receive thread; callers treat it as a
/// background queue and hop to their own.
final class VideoReceiver {
    enum Event {
        case datagram(WireProtocol.DatagramHeader, Data)
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?

    /// Requested SO_RCVBUF. kern.ipc.maxsockbuf defaults to exactly this on
    /// macOS; the granted size is read back and logged either way.
    static let receiveBufferBytes: Int32 = 8 * 1024 * 1024
    private static let datagramBufferBytes = 64 * 1024
    /// SO_RCVTIMEO, and so the longest an idle reader takes to notice stop().
    /// The receive thread owns the socket and is the only thread that closes
    /// it. Closing from stop() instead would race a reader that is between
    /// two recvfrom calls: its next call would use a descriptor number the
    /// kernel may already have reissued to another socket, and block on
    /// that one. Darwin has no other wake for a blocked recvfrom on an
    /// unconnected UDP socket (shutdown returns ENOTCONN), so the reader
    /// polls the stop flag at this interval.
    private static let receiveTimeout = timeval(tv_sec: 0, tv_usec: 100_000)

    private let logger = Logger(subsystem: "com.porthole.mac", category: "video")
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
            onEvent?(.failed("UDP socket failed: \(Self.errnoDescription())"))
            return nil
        }
        configureReceiveBuffer(descriptor)
        var timeout = Self.receiveTimeout
        let timeoutSet = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                                    socklen_t(MemoryLayout<timeval>.size))
        guard timeoutSet == 0 else {
            // Without the timeout nothing can stop the reader once it blocks.
            let reason = Self.errnoDescription()
            close(descriptor)
            onEvent?(.failed("SO_RCVTIMEO failed: \(reason)"))
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
            onEvent?(.failed("UDP bind on :\(port) failed: \(reason)"))
            return nil
        }

        let exited = DispatchSemaphore(value: 0)
        stateLock.lock()
        stopping = false
        self.exited = exited
        stateLock.unlock()

        let thread = Thread { [weak self] in
            self?.receiveLoop(descriptor: descriptor)
            // Closed before `exited` fires so that stop() returning means the
            // port is free for the next start().
            close(descriptor)
            exited.signal()
        }
        thread.name = "porthole.video"
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
            logger.warning("video receive thread did not exit after stop")
        }
        thread = nil
    }

    private func configureReceiveBuffer(_ descriptor: Int32) {
        var requested = Self.receiveBufferBytes
        let optionLength = socklen_t(MemoryLayout<Int32>.size)
        if setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &requested, optionLength) != 0 {
            logger.warning("SO_RCVBUF \(requested) refused: \(Self.errnoDescription(), privacy: .public)")
        }
        var granted: Int32 = 0
        var grantedLength = optionLength
        getsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &granted, &grantedLength)
        logger.info("UDP receive buffer: requested \(requested) bytes, granted \(granted)")
    }

    /// Runs until stop() raises the flag, checked before every recvfrom so a
    /// steady stream cannot keep the loop alive, with `receiveTimeout`
    /// bounding the wait when nothing arrives. One Data copy per datagram,
    /// out of a buffer reused for the life of the thread.
    private func receiveLoop(descriptor: Int32) {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.datagramBufferBytes, alignment: 16)
        defer { buffer.deallocate() }
        while !isStopping {
            let received = recvfrom(descriptor, buffer, Self.datagramBufferBytes, 0, nil, nil)
            if received < 0 {
                let code = errno
                if code == EINTR || code == EAGAIN || code == EWOULDBLOCK { continue }
                if isStopping { return }
                onEvent?(.failed("UDP receive failed: \(String(cString: strerror(code)))"))
                return
            }
            guard received > 0 else { continue }
            let data = Data(bytes: buffer, count: received)
            if let datagram = WireProtocol.parseDatagram(data) {
                onEvent?(.datagram(datagram.header, datagram.payload))
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
