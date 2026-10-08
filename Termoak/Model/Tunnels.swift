import TermoakKit
import Foundation

/// Running tunnels (port forwarding). They go over an SSH connection from the
/// phone: the one of a terminal open to that host if there is one, or an own
/// one that is closed when the last tunnel stops. iOS freezes the app shortly
/// after leaving it, so local tunnels work while the app is open (plus a few
/// minutes of grace).
/// A tunnel started without saving it (it only lives while it runs).
struct AdHocTunnel: Identifiable, Equatable {
    /// `adhoc:<uuid>`, its key in `Tunnels.running` and `stats`.
    let id: String
    let hostId: String
    let label: String
    let kind: ForwardKind
    let bindAddress: String
    let bindPort: UInt32
    let destHost: String?
    let destPort: UInt32?
}

@MainActor
final class Tunnels: ObservableObject {
    /// Running tunnels by saved tunnel id (and `adhoc:…` for unsaved ones).
    @Published private(set) var running: [String: ActiveForward] = [:]
    /// Unsaved tunnels that are running, in the order they started.
    @Published private(set) var adHoc: [AdHocTunnel] = []
    @Published private(set) var stats: [String: ForwardStats] = [:]
    @Published var prompt: AuthPrompt?
    @Published var error: String?

    private let core: TermoakCore
    /// Connection of a terminal open to that host (to avoid connecting again).
    var terminalConnection: ((String) -> SshSession?)?
    private var connections: [String: (session: SshSession, own: Bool)] = [:]
    private var hostOf: [String: String] = [:]
    private var timer: Timer?

    init(core: TermoakCore) {
        self.core = core
    }

    func activeForward(_ f: PortForward) -> ActiveForward? { running[f.id] }

    func start(_ f: PortForward) async {
        do {
            let s = try await connection(f.hostId, accountId: f.accountId)
            running[f.id] = try await s.startForward(forwardId: f.id)
            hostOf[f.id] = f.hostId
            measure()
        } catch {
            self.error = userMessage(error)
            releaseIfUnused(f.hostId)
        }
    }

    /// Starts a tunnel to a host without saving it (the engine's
    /// `startForwardSpec`); it goes away when stopped or when its
    /// connection closes.
    func startAdHoc(host: SshHost, label: String, kind: ForwardKind, bindAddress: String, bindPort: UInt32,
                    destHost: String?, destPort: UInt32?) async {
        do {
            let s = try await connection(host.id, accountId: host.accountId)
            let a = try await s.startForwardSpec(kind: kind, bindAddress: bindAddress, bindPort: bindPort,
                                                 destHost: destHost, destPort: destPort)
            let id = "adhoc:\(UUID().uuidString)"
            running[id] = a
            hostOf[id] = host.id
            adHoc.append(AdHocTunnel(id: id, hostId: host.id, label: label, kind: kind, bindAddress: bindAddress,
                                     bindPort: bindPort, destHost: destHost, destPort: destPort))
            measure()
        } catch {
            self.error = userMessage(error)
            releaseIfUnused(host.id)
        }
    }

    func stopAdHoc(_ t: AdHocTunnel) async {
        if let a = running.removeValue(forKey: t.id) { try? await a.stop() }
        stats[t.id] = nil
        hostOf[t.id] = nil
        adHoc.removeAll { $0.id == t.id }
        releaseIfUnused(t.hostId)
    }

    func stop(_ f: PortForward) async {
        if let a = running.removeValue(forKey: f.id) { try? await a.stop() }
        stats[f.id] = nil
        hostOf[f.id] = nil
        releaseIfUnused(f.hostId)
    }

    /// A terminal has just connected: start the host's automatic tunnels.
    func onTerminalConnected(hostId: String, session: SshSession) async {
        connections[hostId] = (session, false)
        let everywhere = ItemFilter(accountIds: nil, vaultIds: nil, includeDevice: true)
        let automatic = ((try? core.listForwards(hostId: hostId, filter: everywhere)) ?? []).filter { $0.autoStart && running[$0.id] == nil }
        for f in automatic {
            if let a = try? await session.startForward(forwardId: f.id) {
                running[f.id] = a
                hostOf[f.id] = hostId
            }
        }
        if !running.isEmpty { measure() }
    }

    private func connection(_ hostId: String, accountId: String?) async throws -> SshSession {
        if let c = connections[hostId], !c.session.isClosed() { return c.session }
        if let s = terminalConnection?(hostId), !s.isClosed() {
            connections[hostId] = (s, false)
            return s
        }
        let auth = AuthBridge { [weak self] p in
            Task { @MainActor in self?.prompt = p }
        }
        let s = try await core.connect(hostId: hostId, auth: auth, accountId: accountId)
        connections[hostId] = (s, true)
        return s
    }

    /// Closes the own connection of a host that has no tunnels left.
    private func releaseIfUnused(_ hostId: String) {
        guard !hostOf.values.contains(hostId), let c = connections[hostId] else { return }
        connections[hostId] = nil
        if c.own {
            let s = c.session
            Task.detached { try? await s.disconnect() }
        }
    }

    /// Stats every second while there are tunnels; the ones that went down
    /// (e.g. when closing the terminal whose connection they used) are removed.
    private func measure() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        update()
    }

    private func update() {
        for (id, a) in running {
            if a.isRunning() {
                stats[id] = a.stats()
            } else {
                running[id] = nil
                stats[id] = nil
                adHoc.removeAll { $0.id == id }
                if let h = hostOf.removeValue(forKey: id) { releaseIfUnused(h) }
            }
        }
        if running.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}
