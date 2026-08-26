import Foundation
import Network

/// Sends one dropped file to the agent's file port (US-011) over its own
/// TCP connection, so a large transfer never competes with the video path.
/// Wire format (docs/protocol.md "File transfer"): 2-byte BE name length,
/// the UTF-8 name, 8-byte BE size, then the bytes. The agent answers with
/// one ack byte once the file is renamed into place, which is what turns
/// "all bytes handed to the kernel" into "the file is safe on the far end".
///
/// The file is streamed in bounded chunks with backpressure (the next read
/// happens in the previous send's completion), so a multi-gigabyte drop
/// never sits in memory. All IO runs on the sender's own queue; callbacks
/// land on main.
final class FileSender {
    /// Fraction of the file handed to the connection, 0 to 1.
    var onProgress: ((Double) -> Void)?
    /// Terminal state, called exactly once; nil means the agent acked.
    var onFinished: ((String?) -> Void)?

    /// Read/send unit. Large enough to keep the pipe full on a LAN, small
    /// enough that one in-flight chunk is the whole memory footprint.
    private static let chunkSize = 256 * 1024

    private let url: URL
    private let queue = DispatchQueue(label: "porthole.filesend")
    private var connection: NWConnection?
    private var file: FileHandle?
    private var totalBytes: UInt64 = 0
    private var sentBytes: UInt64 = 0
    private var finished = false

    init(url: URL) {
        self.url = url
    }

    func start(host: String, port: UInt16 = WireProtocol.filePort) {
        queue.async { [weak self] in
            self?.open(host: host, port: port)
        }
    }

    private func open(host: String, port: UInt16) {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values.isDirectory == true {
                finish("folders cannot be sent")
                return
            }
            totalBytes = UInt64(values.fileSize ?? 0)
            file = try FileHandle(forReadingFrom: url)
        } catch {
            finish(error.localizedDescription)
            return
        }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            finish("invalid file port \(port)")
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: endpointPort,
                                      using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.sendHeader()
            case .waiting(let error):
                // .waiting retries forever; a filtered or closed file port
                // would leave the transfer row stuck, so treat it as fatal
                // (the session being live proves the host itself answers).
                self?.finish(error.localizedDescription)
            case .failed(let error):
                self?.finish(error.localizedDescription)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendHeader() {
        let name = Data(url.lastPathComponent.utf8)
        guard name.count <= Int(UInt16.max) else {
            finish("file name is too long")
            return
        }
        var header = Data(capacity: 2 + name.count + 8)
        header.appendUInt16BE(UInt16(name.count))
        header.append(name)
        header.appendUInt64BE(totalBytes)
        connection?.send(content: header, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finish(error.localizedDescription)
            } else {
                self?.sendNextChunk()
            }
        })
    }

    private func sendNextChunk() {
        guard !finished else { return }
        let chunk: Data?
        do {
            chunk = try file?.read(upToCount: Self.chunkSize)
        } catch {
            finish(error.localizedDescription)
            return
        }
        guard let chunk, !chunk.isEmpty else {
            awaitAck()
            return
        }
        sentBytes += UInt64(chunk.count)
        report(progress: totalBytes > 0 ? Double(sentBytes) / Double(totalBytes) : 1)
        connection?.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finish(error.localizedDescription)
            } else {
                self?.sendNextChunk()
            }
        })
    }

    private func awaitAck() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, _, error in
            if let data, !data.isEmpty {
                self?.finish(nil)
            } else {
                self?.finish(error?.localizedDescription ?? "agent closed before acknowledging")
            }
        }
    }

    private func report(progress: Double) {
        let callback = onProgress
        DispatchQueue.main.async { callback?(progress) }
    }

    private func finish(_ error: String?) {
        guard !finished else { return }
        finished = true
        try? file?.close()
        file = nil
        connection?.cancel()
        connection = nil
        let callback = onFinished
        DispatchQueue.main.async { callback?(error) }
    }
}
