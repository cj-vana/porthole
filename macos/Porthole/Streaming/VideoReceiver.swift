import Foundation
import Network

/// UDP listener for the agent's fragmented video stream (docs/protocol.md).
/// The agent sends datagrams to the control peer's IP at the port negotiated
/// in `hello`; we bind that port here before asking for a keyframe.
final class VideoReceiver {
    enum Event {
        case datagram(WireProtocol.DatagramHeader, Data)
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "porthole.video")
    private var listener: NWListener?
    private var peer: NWConnection?

    /// Returns the port actually bound, or nil on failure. `onEvent` reports
    /// listener failure asynchronously as well.
    @discardableResult
    func start(port: UInt16) -> UInt16? {
        stop()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        do {
            listener = try NWListener(using: .udp, on: endpointPort)
        } catch {
            onEvent?(.failed("UDP listener on :\(port) failed: \(error.localizedDescription)"))
            return nil
        }

        listener?.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.onEvent?(.failed("UDP listener failed: \(error.localizedDescription)"))
            }
        }
        listener?.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            // Only one agent talks to us; a new peer replaces the old one.
            self.peer?.cancel()
            self.peer = connection
            connection.start(queue: self.queue)
            self.receiveLoop(connection)
        }
        listener?.start(queue: queue)
        return port
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        peer?.cancel()
        peer = nil
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty,
               let datagram = WireProtocol.parseDatagram(data) {
                self.onEvent?(.datagram(datagram.header, datagram.payload))
            }
            if error == nil {
                self.receiveLoop(connection)
            }
        }
    }
}
