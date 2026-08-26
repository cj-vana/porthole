import Foundation
import os

/// Browses the local link for `_porthole._tcp` agents (FR-8, US-007).
///
/// NetServiceBrowser/NetService are run-loop APIs, so browsing and resolving
/// happen on a dedicated background thread; parsed machines are reported
/// through `onEvent` and the store hops to the main queue. mDNS is
/// link-local only: agents reachable solely over Tailscale do not appear
/// here and stay a manual-entry path.
final class DiscoveryService: NSObject {
    enum Event {
        case online(Machine)
        /// mDNS instance name of a service that withdrew its announcement.
        case offline(id: String)
    }

    var onEvent: ((Event) -> Void)?

    private let logger = Logger(subsystem: "com.porthole.mac", category: "discovery")
    private var thread: DiscoveryThread?
    /// Services found but not yet resolved; mutated on the discovery thread.
    private var pendingServices: [String: NetService] = [:]

    func start() {
        guard thread == nil else { return }
        let thread = DiscoveryThread()
        thread.owner = self
        self.thread = thread
        thread.start()
    }

    func stop() {
        thread?.cancel()
        thread = nil
    }

    /// Thread whose run loop hosts the browser and all resolves.
    private final class DiscoveryThread: Thread {
        weak var owner: DiscoveryService?

        override func main() {
            let browser = NetServiceBrowser()
            browser.delegate = owner
            // searchForServices schedules the browser in the current run loop.
            browser.searchForServices(ofType: "_porthole._tcp", inDomain: "")
            while !isCancelled {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1))
            }
        }
    }

    fileprivate func emit(_ event: Event) {
        onEvent?(event)
    }
}

extension DiscoveryService: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing _: Bool) {
        logger.info("found \(service.name, privacy: .public); resolving")
        service.delegate = self
        service.resolve(withTimeout: 5)
        pendingServices[service.name] = service
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemove service: NetService,
                           moreComing _: Bool) {
        logger.info("withdrew \(service.name, privacy: .public)")
        pendingServices.removeValue(forKey: service.name)
        emit(.offline(id: service.name))
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        logger.error("browse failed: \(errorDict, privacy: .public)")
    }
}

extension DiscoveryService: NetServiceDelegate {
    func netServiceDidResolveAddress(_ service: NetService) {
        guard let txtData = service.txtRecordData(), let hostName = service.hostName else {
            logger.warning("\(service.name, privacy: .public) resolved without TXT/host")
            return
        }
        let addresses = Self.ipv4Addresses(of: service)
        let txt = NetService.dictionary(fromTXTRecord: txtData)
        guard let machine = Machine(serviceName: service.name, hostName: hostName,
                                    addresses: addresses, txt: txt) else {
            logger.warning("\(service.name, privacy: .public) has an unsupported TXT record")
            return
        }
        logger.info("resolved \(machine.name, privacy: .public) at \(machine.host, privacy: .public):\(machine.controlPort) candidates \(machine.addressCandidates, privacy: .public)")
        emit(.online(machine))
    }

    func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
        logger.error("resolve failed for \(service.name, privacy: .public): \(errorDict, privacy: .public)")
    }

    /// IPv4 addresses from a resolved service's sockaddr list.
    private static func ipv4Addresses(of service: NetService) -> [String] {
        (service.addresses ?? []).compactMap { data in
            data.withUnsafeBytes { raw -> String? in
                guard raw.count >= 8, raw[1] == AF_INET else { return nil }
                return "\(raw[4]).\(raw[5]).\(raw[6]).\(raw[7])"
            }
        }
    }
}
