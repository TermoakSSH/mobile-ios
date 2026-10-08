import Foundation

// Rules of the status dots of the hosts lists (Settings → Host status), like
// the desktop's: the hosts on screen are checked from this device at most
// once a minute each, again at once when their address or port changed.
// Pure logic (unit-tested); HostStatusStore runs the engine's probeHosts.

/// What the dot of a host shows.
enum HostDot: Equatable {
    /// It accepted a connection, in `ms` milliseconds (green).
    case up(ms: Int)
    /// Refused, timed out or its name doesn't resolve (red).
    case down
    /// Not checked (behind jump hosts, Strict vault, turned off) or not yet:
    /// no dot.
    case unknown
}

/// The last check of a host.
struct HostCheck: Equatable {
    var dot: HostDot
    var checkedAt: Date
    /// `address:port` of the host when it was checked.
    var target: String
}

enum HostStatusPlan {
    /// A host is checked again after a minute (the desktop's rhythm).
    static let interval: TimeInterval = 60
    /// How often a list on screen looks for hosts due.
    static let tick: TimeInterval = 15

    /// `address:port` of a host (the port it connects to by default when it
    /// has none).
    static func target(address: String, port: UInt32?, telnet: Bool) -> String {
        "\(address.lowercased()):\(port ?? (telnet ? 23 : 22))"
    }

    /// The hosts (keys) to check now, in the order given: never checked,
    /// checked a minute ago or more, or whose address or port changed since;
    /// not those being checked, nor a key twice.
    static func due(_ hosts: [(key: String, target: String)], checks: [String: HostCheck],
                    inFlight: Set<String>, now: Date, interval: TimeInterval = interval) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for h in hosts where !inFlight.contains(h.key) && seen.insert(h.key).inserted {
            guard let c = checks[h.key] else { out.append(h.key); continue }
            if c.target != h.target || now.timeIntervalSince(c.checkedAt) >= interval { out.append(h.key) }
        }
        return out
    }

    /// "12 ms", "1.2 s".
    static func latency(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms) ms" }
        let tenths = Int((Double(ms) / 100).rounded())
        return "\(tenths / 10).\(tenths % 10) s"
    }

    /// The hosts turned off after turning one on or off (ids, as the engine
    /// takes them; the same host in two accounts has the same id).
    static func toggled(_ off: [String], _ id: String) -> [String] {
        off.contains(id) ? off.filter { $0 != id } : off + [id]
    }
}
