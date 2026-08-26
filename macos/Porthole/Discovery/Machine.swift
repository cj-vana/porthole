import Foundation

/// A machine that can be connected to. Discovered machines come from mDNS
/// TXT records (docs/protocol.md "Discovery and thumbnails"); manual entries
/// carry default ports. Persisted (pinned) machines are stored as JSON in
/// Application Support by MachineStore.
struct Machine: Codable, Hashable, Identifiable {
    /// Stable identity: the mDNS instance name for discovered machines,
    /// "manual:<host>" for manual entries.
    let id: String
    /// Display name (TXT `name`, or the host for manual entries).
    var name: String
    /// Address to dial: resolved mDNS host name, or a literal IP.
    var host: String
    var controlPort: UInt16
    var videoPort: UInt16
    var thumbPort: UInt16
    /// TXT `caps`, e.g. ["nvenc", "h264", "hevc", "144"].
    var caps: [String]
    var isManual: Bool
    /// Dial order for control/thumbnail connections: mDNS-resolved LAN
    /// addresses first, then the machine name as a bare host name. The name
    /// fallback is what makes a card work when the LAN address is filtered
    /// but the machine is on Tailscale with MagicDNS (the mDNS name and the
    /// Tailscale host name are the same), without typing an IP.
    var addressCandidates: [String]
    /// The candidate that last answered a thumbnail poll, dialed first so a
    /// session does not spend a timeout on a filtered LAN address. Optional
    /// so machines.json written before it existed still decodes.
    var preferredHost: String?

    /// Dial order for the session and thumbnail poll. A directly reachable
    /// RFC1918/link-local address always outranks an overlay address. The
    /// learned preference only reorders candidates inside the same path
    /// class, so a fast thumbnail response over Tailscale cannot silently
    /// move a 100.64/10 endpoint ahead of the physical LAN forever.
    var dialOrder: [String] {
        let candidates = addressCandidates.isEmpty ? [host] : addressCandidates
        var unique: [String] = []
        for candidate in ([preferredHost].compactMap { $0 } + candidates)
            where !unique.contains(candidate) {
            unique.append(candidate)
        }
        return unique.enumerated().sorted { lhs, rhs in
            let lhsTier = Self.pathTier(lhs.element)
            let rhsTier = Self.pathTier(rhs.element)
            if lhsTier != rhsTier { return lhsTier < rhsTier }
            let lhsPreferred = lhs.element == preferredHost
            let rhsPreferred = rhs.element == preferredHost
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Lower values are attempted first. Discovery currently emits IPv4
    /// literals plus hostname fallbacks. RFC1918 and IPv4 link-local are
    /// physical-LAN candidates; 100.64/10 is explicitly an overlay/CGNAT
    /// candidate; hostnames stay last because they may resolve to either.
    private static func pathTier(_ host: String) -> Int {
        guard let octets = ipv4Octets(host) else { return 3 }
        if octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254) {
            return 0
        }
        if octets[0] == 100 && (64...127).contains(octets[1]) {
            return 2
        }
        return 1
    }

    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = UInt8(part) else {
                return nil
            }
            octets.append(value)
        }
        return octets
    }

    /// Build from a resolved `_porthole._tcp` service. Returns nil when the
    /// TXT record is missing or has an unsupported protocol version.
    init?(serviceName: String, hostName: String, addresses: [String], txt: [String: Data]) {
        func string(_ key: String) -> String? {
            txt[key].flatMap { String(data: $0, encoding: .utf8) }
        }
        guard string("v") == "1" else { return nil }
        self.id = serviceName
        name = string("name") ?? serviceName
        host = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        controlPort = UInt16(string("control_port") ?? "") ?? WireProtocol.controlPort
        videoPort = UInt16(string("video_port") ?? "") ?? WireProtocol.defaultVideoPort
        thumbPort = UInt16(string("thumb_port") ?? "") ?? 52803
        caps = string("caps")?.split(separator: ",").map(String.init) ?? []
        isManual = false
        // The agent announces on every interface; dedupe identical addresses
        // so the dialer does not waste a timeout on repeats.
        var candidates: [String] = []
        for address in addresses where !candidates.contains(address) {
            candidates.append(address)
        }
        let shortHost = host.hasSuffix(".local") ? String(host.dropLast(".local".count)) : host
        for fallback in [name, shortHost] where !candidates.contains(fallback) {
            candidates.append(fallback)
        }
        addressCandidates = candidates
        preferredHost = nil
    }

    /// Manual entry (Tailscale-only path, or when mDNS is unavailable).
    init(host: String) {
        id = "manual:\(host)"
        name = host
        self.host = host
        controlPort = WireProtocol.controlPort
        videoPort = WireProtocol.defaultVideoPort
        thumbPort = 52803
        caps = []
        isManual = true
        addressCandidates = [host]
        preferredHost = nil
    }

    /// Short badge labels for the picker card, in wire order.
    var capBadges: [String] {
        caps.map { cap in
            switch cap.lowercased() {
            case "nvenc": return "NVENC"
            case "vaapi": return "VAAPI"
            case "h264": return "H.264"
            case "hevc": return "HEVC"
            case "144": return "144 Hz"
            case "120": return "120 Hz"
            default: return cap.uppercased()
            }
        }
    }
}
