import Foundation
import Network
import os

/// TCP control channel to the agent (docs/protocol.md). The agent is the
/// server; we connect, receive `hello`, and send `keyframe_request`, input,
/// and latency `ping`s. The agent answers pings with `pong` and reports
/// `agent_stats` once per second.
final class ControlChannel {
    enum Event {
        /// TCP connection is up; hello follows immediately after.
        case ready
        case hello(Hello)
        case pong(Pong)
        case agentStats(AgentStats)
        case disconnected(reason: String)
    }

    var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "porthole.control")
    private let logger = Logger(subsystem: "com.porthole.mac", category: "control")
    private var connection: NWConnection?
    private var parser = ControlFrameParser()
    /// keyframe_requests are throttled to one per second (per protocol.md),
    /// except an explicit forced request on join.
    private var lastKeyframeRequest = Date.distantPast
    private var pingBurst: DispatchWorkItem?

    func connect(host: String, port: UInt16 = WireProtocol.controlPort) {
        disconnect()
        let endpoint = NWEndpoint.Host(host)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        // Input and probe messages are a few bytes each. With Nagle on, the
        // kernel holds each one for the peer's delayed ACK, so mouse motion
        // reaches the agent in 40 ms clumps.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let connection = NWConnection(host: endpoint,
                                      port: endpointPort,
                                      using: NWParameters(tls: nil, tcp: tcpOptions))
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            // Stale connections (a cancelled dial during candidate fallback)
            // must not report into the live session.
            guard let self, self.connection === connection else { return }
            switch state {
            case .ready:
                self.onEvent?(.ready)
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
        pingBurst?.cancel()
        pingBurst = nil
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

    /// Latency probe; the agent echoes the timestamp in a pong.
    func sendPing() {
        let frame = WireProtocol.encodePing(clientTimestampMicros: ClientClock.nowMicros())
        connection?.send(content: frame, completion: .contentProcessed { _ in })
    }

    /// `count` pings `interval` apart, starting now, so the session's clock
    /// offset has a low-RTT sample right after hello instead of waiting for
    /// the once-per-second probe. disconnect() cancels the remainder.
    func sendPingBurst(count: Int, interval: TimeInterval) {
        pingBurst?.cancel()
        pingBurst = nil
        guard count > 0 else { return }
        sendPing()
        let work = DispatchWorkItem { [weak self] in
            self?.sendPingBurst(count: count - 1, interval: interval)
        }
        pingBurst = work
        queue.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            // Same stale-connection guard: a cancelled dial's in-flight
            // receive fires its completion with an error; ignore it.
            guard let self, self.connection === connection else { return }
            if let data, !data.isEmpty {
                for frame in self.parser.append(data) {
                    self.handleFrame(type: frame.type, payload: frame.payload)
                }
            }
            if isComplete || error != nil {
                self.onEvent?(.disconnected(reason: error?.localizedDescription ?? "connection closed by peer"))
                return
            }
            self.receiveLoop(connection)
        }
    }

    private func handleFrame(type: ControlMessageType, payload: Data) {
        switch type {
        case .hello:
            if let hello = Hello(payload: payload) {
                onEvent?(.hello(hello))
            } else {
                onEvent?(.disconnected(reason: "malformed hello"))
            }
        case .pong:
            if let pong = Pong(payload: payload) {
                onEvent?(.pong(pong))
            } else {
                logger.warning("ignoring malformed pong (\(payload.count) bytes)")
            }
        case .agentStats:
            if let stats = AgentStats(payload: payload) {
                onEvent?(.agentStats(stats))
            } else {
                logger.warning("ignoring malformed agent_stats (\(payload.count) bytes)")
            }
        default:
            break // the remaining types are client -> agent
        }
    }
}
