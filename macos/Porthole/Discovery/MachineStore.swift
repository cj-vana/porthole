import Combine
import CoreGraphics
import Foundation
import os

/// The picker's model: the union of machines discovered over mDNS and
/// pinned/manual machines persisted as JSON in Application Support.
///
/// Cards show for: discovered machines currently online, and persisted
/// machines regardless (with offline state). A discovered machine becomes
/// persisted the first time the user connects to it. All blocking work
/// (resolves, thumbnail polls) happens off the main thread; @Published
/// updates land on main.
final class MachineStore: ObservableObject {
    /// One picker card: the machine plus live runtime state.
    struct Card: Identifiable {
        let id: String
        var machine: Machine
        var online: Bool
        var thumbnail: CGImage?
        /// True when the machine is in the persisted (pinned) set.
        var isPinned: Bool
    }

    @Published private(set) var cards: [Card] = []
    /// The machine shown in the single session window; set by the picker on
    /// connect. One window by design: openWindow(id:) focuses the existing
    /// window instead of spawning duplicates, and the control channel is
    /// single-client per agent anyway.
    @Published var activeSessionMachine: Machine?

    /// Open a session to a machine: pins it, remembers it for
    /// auto-reconnect, and makes it the session window's content.
    func openSession(to machine: Machine) {
        recordConnect(machine)
        activeSessionMachine = machine
    }

    private let discovery = DiscoveryService()
    private let logger = Logger(subsystem: "com.porthole.mac", category: "picker")
    private var pollTimer: Timer?

    /// How often each card's thumbnail is refreshed (PRD FR-10: roughly
    /// every 10 s while idle).
    private let pollInterval: TimeInterval = 10

    init(directory: URL? = nil) {
        storeURL = (directory ?? Self.defaultDirectory).appendingPathComponent("machines.json")
        discovery.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.handleDiscovery(event) }
        }
        loadPersisted()
        discovery.start()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollThumbnails()
        }
    }

    deinit {
        pollTimer?.invalidate()
        discovery.stop()
    }

    // MARK: Discovery events

    private func handleDiscovery(_ event: DiscoveryService.Event) {
        switch event {
        case .online(let machine):
            if let index = cards.firstIndex(where: { $0.id == machine.id }) {
                // Keep a user rename and the learned dial preference; take
                // the fresh addresses/ports/caps.
                var updated = machine
                updated.name = cards[index].machine.name
                updated.preferredHost = cards[index].machine.preferredHost
                cards[index].machine = updated
                cards[index].online = true
                cards[index].isPinned = isPersisted(machine.id)
            } else {
                cards.append(Card(id: machine.id, machine: machine, online: true,
                                  thumbnail: nil, isPinned: isPersisted(machine.id)))
            }
            poll(machine: cards.first(where: { $0.id == machine.id })?.machine ?? machine)
        case .offline(let id):
            guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
            if isPersisted(id) {
                cards[index].online = false
            } else {
                // Unpinned and offline: the card goes away entirely.
                cards.remove(at: index)
            }
        }
    }

    // MARK: User actions

    /// Add a manual machine (Tailscale-only path). Persisted immediately and
    /// returned so the caller can open a session to it.
    @discardableResult
    func addManual(host: String) -> Machine {
        let machine = Machine(host: host)
        if let index = cards.firstIndex(where: { $0.id == machine.id }) {
            cards[index].online = true
        } else {
            cards.append(Card(id: machine.id, machine: machine, online: true,
                              thumbnail: nil, isPinned: true))
        }
        persist(machine)
        poll(machine: machine)
        return machine
    }

    /// Persist (pin) a machine; called automatically on first connect.
    func pin(_ machine: Machine) {
        persist(machine)
        if let index = cards.firstIndex(where: { $0.id == machine.id }) {
            cards[index].isPinned = true
        }
    }

    func unpin(id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        removePersisted(id: id)
        // A discovered machine that is still announced stays as an
        // unpinned online card; manual ones vanish.
        if cards[index].machine.isManual {
            cards.remove(at: index)
        } else {
            cards[index].isPinned = false
        }
    }

    func remove(id: String) {
        removePersisted(id: id)
        cards.removeAll { $0.id == id }
    }

    func rename(id: String, to name: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].machine.name = name
        if isPersisted(id) {
            persist(cards[index].machine)
        }
    }

    /// Called when the user opens a session: discovered machines pin on
    /// first connect (US-012), and the machine becomes the auto-reconnect
    /// target.
    func recordConnect(_ machine: Machine) {
        persist(machine)
        if let index = cards.firstIndex(where: { $0.id == machine.id }) {
            cards[index].isPinned = true
        }
        if let data = try? JSONEncoder().encode(machine) {
            UserDefaults.standard.set(data, forKey: "lastSessionMachine")
        }
    }

    /// The machine to auto-reconnect to on launch, if any.
    static func lastSessionMachine() -> Machine? {
        guard let data = UserDefaults.standard.data(forKey: "lastSessionMachine") else { return nil }
        return try? JSONDecoder().decode(Machine.self, from: data)
    }

    // MARK: Thumbnails

    private func pollThumbnails() {
        for card in cards {
            poll(machine: card.machine)
        }
    }

    private func poll(machine: Machine) {
        Task.detached { [weak self] in
            // Walk the same address order as the control dialer, and remember
            // which candidate answered so the dialer can start there.
            var fetched: (image: CGImage, host: String)?
            for host in machine.dialOrder {
                if let image = await ThumbnailFetcher.fetch(host: host, port: machine.thumbPort) {
                    fetched = (image, host)
                    break
                }
            }
            let result = fetched
            await MainActor.run { [weak self] in
                guard let self, let index = self.cards.firstIndex(where: { $0.id == machine.id }) else { return }
                if let result {
                    self.cards[index].thumbnail = result.image
                    self.cards[index].online = true
                    if self.cards[index].machine.preferredHost != result.host {
                        self.cards[index].machine.preferredHost = result.host
                        if self.cards[index].isPinned {
                            self.persist(self.cards[index].machine)
                        }
                    }
                } else if machine.isManual {
                    // Manual machines have no mDNS presence; a failed poll is
                    // the offline signal.
                    self.cards[index].online = false
                }
            }
        }
    }

    // MARK: Persistence

    private let storeURL: URL

    private static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Porthole", isDirectory: true)
    }

    private func loadPersisted() {
        for machine in loadMachines() where !cards.contains(where: { $0.id == machine.id }) {
            cards.append(Card(id: machine.id, machine: machine, online: false,
                              thumbnail: nil, isPinned: true))
        }
    }

    private func isPersisted(_ id: String) -> Bool {
        persistedIDs().contains(id)
    }

    private func persistedIDs() -> Set<String> {
        guard let data = try? Data(contentsOf: storeURL),
              let machines = try? JSONDecoder().decode([Machine].self, from: data) else { return [] }
        return Set(machines.map(\.id))
    }

    private func persist(_ machine: Machine) {
        var machines = loadMachines()
        if let index = machines.firstIndex(where: { $0.id == machine.id }) {
            machines[index] = machine
        } else {
            machines.append(machine)
        }
        saveMachines(machines)
    }

    private func removePersisted(id: String) {
        saveMachines(loadMachines().filter { $0.id != id })
    }

    private func loadMachines() -> [Machine] {
        guard let data = try? Data(contentsOf: storeURL),
              let machines = try? JSONDecoder().decode([Machine].self, from: data) else { return [] }
        return machines
    }

    private func saveMachines(_ machines: [Machine]) {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(machines)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            logger.error("failed to persist machines: \(error.localizedDescription, privacy: .public)")
        }
    }
}
