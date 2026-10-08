import TermoakKit
import Foundation

/// The status dots of the hosts lists: the last check of each host (by
/// `SshHost.key`), shared by the list, the grid and every group screen.
/// The checks are the engine's `probeHosts` (a TCP connection to the host's
/// port, through its proxy; no SSH, no sign-in).
@MainActor
final class HostStatusStore: ObservableObject {
    static let shared = HostStatusStore()

    @Published private(set) var checks: [String: HostCheck] = [:]
    private var inFlight: Set<String> = []

    func dot(for host: SshHost) -> HostDot { checks[host.key]?.dot ?? .unknown }
    func check(for host: SshHost) -> HostCheck? { checks[host.key] }

    static func target(_ host: SshHost) -> String {
        HostStatusPlan.target(address: host.address, port: host.settings.port, telnet: host.isTelnet)
    }

    /// Checks the hosts given that are due (see `HostStatusPlan.due`).
    /// `off`: ids of the hosts whose check is turned off.
    func refresh(_ hosts: [SshHost], core: TermoakCore, off: [String]) async {
        let list = hosts.map { (key: $0.key, target: Self.target($0)) }
        let due = Set(HostStatusPlan.due(list, checks: checks, inFlight: inFlight, now: Date()))
        guard !due.isEmpty else { return }
        var todo: [SshHost] = []
        var seen = Set<String>()
        for h in hosts where due.contains(h.key) && seen.insert(h.key).inserted { todo.append(h) }
        inFlight.formUnion(due)
        defer { inFlight.subtract(due) }
        let refs = todo.map { ItemRef(accountId: $0.accountId, id: $0.id) }
        guard let probes = try? await core.probeHosts(hosts: refs, off: off, concurrency: 0) else { return }
        let now = Date()
        for p in probes {
            let key = itemKey(p.accountId, p.hostId)
            guard let h = todo.first(where: { $0.key == key }) else { continue }
            checks[key] = HostCheck(dot: Self.dot(p), checkedAt: now, target: Self.target(h))
        }
    }

    /// Forgets a host's check (turned off or on: checked again next time).
    func forget(_ host: SshHost) {
        checks[host.key] = nil
    }

    static func dot(_ p: HostProbe) -> HostDot {
        switch p.status {
        case .up: return .up(ms: Int(p.ms ?? 0))
        case .down: return .down
        case .skipped: return .unknown
        }
    }
}
