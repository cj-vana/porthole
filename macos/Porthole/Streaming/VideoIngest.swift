import Foundation

/// The receive side of the video channel: UDP datagrams in, whole access
/// units out on the decode queue.
///
/// Reassembly runs on the receive thread at datagram rate. A keyframe is
/// several hundred datagrams delivered within a few milliseconds, and an
/// earlier design that queued each datagram behind decode (with a small
/// per-datagram cap) lost most of every IDR, which the stream can never
/// recover from. Only complete access units cross to the decode queue, with
/// a bounded backlog; a full backlog means decode is falling behind, which
/// is decode-fatal for predictive video anyway, so the unit is dropped and
/// the session resyncs on a keyframe.
final class VideoIngest {
    /// A complete access unit and its arrival time (ClientClock, stamped on
    /// the receive thread before any queueing). Called on the decode queue.
    var onAccessUnit: ((Reassembler.AccessUnit, _ arrivedMicros: UInt64) -> Void)?
    /// Frames lost (reassembly gap, stale partial, or backlog full), with the
    /// reason for the log. Called on the decode queue.
    var onLoss: ((_ frameCount: UInt64, _ reason: String) -> Void)?
    /// Receiver failure (bind or read error). Called on the decode queue.
    var onFailure: ((String) -> Void)?

    private let receiver = VideoReceiver()
    private let reassembler = Reassembler()
    // Hardware decode takes ~1.5 ms per frame, far below the 6.9 ms frame
    // period, but a CBR encoder can release several completed frames together
    // after a large IDR. Six slots falsely classified that short, recoverable
    // burst as sustained overload and triggered a 270 ms encoder restart every
    // GOP. This still bounds the worst case while letting VideoToolbox drain a
    // transient burst faster than new frames arrive.
    private let backlog = DecodeBacklog(limit: 24)
    private let decodeQueue: DispatchQueue

    init(decodeQueue: DispatchQueue) {
        self.decodeQueue = decodeQueue
        receiver.onEvent = { [weak self] event in self?.handle(event) }
    }

    /// Bind the negotiated UDP port. Returns the bound port, or nil when the
    /// bind failed (the failure is also reported through `onFailure`).
    @discardableResult
    func start(port: UInt16) -> UInt16? {
        receiver.start(port: port)
    }

    /// Stop the receiver (joining its thread) and drop reassembly state.
    func stop() {
        receiver.stop()
        reassembler.reset()
    }

    /// Access units queued for decode right now.
    var backlogDepth: Int {
        backlog.depth
    }

    private func handle(_ event: VideoReceiver.Event) {
        switch event {
        case .failed(let message):
            decodeQueue.async { [weak self] in self?.onFailure?(message) }
        case .datagram(let header, let payload):
            for event in reassembler.ingest(header: header, payload: payload) {
                switch event {
                case .completed(let accessUnit):
                    let arrivedMicros = ClientClock.nowMicros()
                    guard backlog.reserve() else {
                        decodeQueue.async { [weak self] in self?.onLoss?(1, "decode backlog full") }
                        continue
                    }
                    decodeQueue.async { [weak self] in
                        guard let self else { return }
                        self.backlog.release()
                        self.onAccessUnit?(accessUnit, arrivedMicros)
                    }
                case .loss(let frameCount):
                    decodeQueue.async { [weak self] in self?.onLoss?(frameCount, "reassembly") }
                }
            }
        }
    }
}
