import Foundation
import SwiftUI

/// Active drag-and-drop transfers for the session window (US-011). Each
/// dropped file gets its own FileSender (one TCP connection per file, per
/// protocol.md); rows linger briefly after a terminal state so success and
/// failure are readable before they clear. Main thread only, like the rest
/// of the view models.
final class FileTransferList: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let name: String
        var progress: Double = 0
        var error: String?
        var done = false
    }

    @Published private(set) var items: [Item] = []
    /// Senders stay owned here until their terminal callback; nothing else
    /// retains them once start() returns.
    private var senders: [UUID: FileSender] = [:]

    func send(url: URL, host: String) {
        let item = Item(name: url.lastPathComponent)
        items.append(item)
        let sender = FileSender(url: url)
        senders[item.id] = sender
        sender.onProgress = { [weak self] progress in
            self?.update(item.id) { $0.progress = progress }
        }
        sender.onFinished = { [weak self] error in
            guard let self else { return }
            self.senders[item.id] = nil
            self.update(item.id) {
                $0.done = true
                $0.error = error
                if error == nil {
                    $0.progress = 1
                }
            }
            // Failures linger longer: a progress bar reaching the end tells
            // its own story, an error line needs time to be read.
            let linger: TimeInterval = error == nil ? 2 : 5
            DispatchQueue.main.asyncAfter(deadline: .now() + linger) { [weak self] in
                self?.items.removeAll { $0.id == item.id }
            }
        }
        sender.start(host: host)
    }

    private func update(_ id: UUID, _ mutate: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
    }
}

/// One row per active transfer, styled like the rest of the session chrome.
/// Renders nothing while no transfer is running.
struct FileTransferOverlay: View {
    @ObservedObject var transfers: FileTransferList

    var body: some View {
        if !transfers.items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(transfers.items) { item in
                    row(item)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 260)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func row(_ item: FileTransferList.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: item.error == nil ? "doc" : "exclamationmark.triangle")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(item.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if item.done, item.error == nil {
                    Image(systemName: "checkmark")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = item.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                ProgressView(value: item.progress)
                    .controlSize(.small)
            }
        }
    }
}
