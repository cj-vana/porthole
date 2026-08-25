import Foundation
import Network

/// TCP control channel to the agent (docs/protocol.md). The agent is the
/// server; we connect, receive `hello`, and send `keyframe_request`.
final class ControlChannel {
    enum Event {
        case hello(Hello)
        case disconnected(reason: String)
    }

    var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "porthole.control")
    private var connection: NWConnection?
    private var parser = ControlFrameParser()
    /// keyframe_requests are throttled to one per second (per protocol.md),
    /// except an explicit forced request on join.
    private var lastKeyframeRequest = Date.distantPast

    func connect(host: String, port: UInt16 = WireProtocol.controlPort) {
        disconnect()
        let endpoint = NWEndpoint.Host(host)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: endpoint, port: endpointPort, using: .tcp)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                self.onEvent?(.disconnected(reason: "control channel failed: \(error.localizedDescription)"))
            case .cancelled:
                self.onEvent?(.disconnected(reason: "control channel closed"))
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveLoop(connection)
    }

    func disconnect() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        parser = ControlFrameParser()
    }

    /// Ask the agent for a fresh IDR. Throttled to 1/second unless forced
    /// (protocol.md reference receiver behavior; forced is used on join).
    func requestKeyframe(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastKeyframeRequest) >= 1 else { return }
        lastKeyframeRequest = now
        let message = WireProtocol.encodeControlMessage(.keyframeRequest)
        connection?.send(content: message, completion: .contentProcessed { _ in })
    }

    /// Send one framed input message (0x10-0x15). Input rides the same
    /// control connection as keyframe_request (docs/protocol.md).
    func sendInput(_ frame: Data) {
        connection?.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for frame in self.parser.append(data) {
                    switch frame.type {
                    case .hello:
                        if let hello = Hello(payload: frame.payload) {
                            self.onEvent?(.hello(hello))
                        } else {
                            self.onEvent?(.disconnected(reason: "malformed hello"))
                        }
                    default:
                        break // agent sends only hello; input types are client -> agent
                    }
                }
            }
            if isComplete || error != nil {
                self.onEvent?(.disconnected(reason: error?.localizedDescription ?? "connection closed by peer"))
                return
            }
            self.receiveLoop(connection)
        }
    }
}
