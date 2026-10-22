import TermoakKit
import Foundation

/// The REST calls of the networks screens (the server's docs/API.md,
/// "Private networks"), through an account's own handle (the engine's
/// generic API, like the web and the desktop): the server checks the
/// plan's `max_networks` and fills in the WireGuard public key at once, and
/// the changes reach the local stores by sync.
struct NetworksAPI {
    let handle: AccountHandle
    static let base = "/api/v1"

    private func call(_ method: HttpMethod, _ path: String, _ body: String? = nil) async throws -> String {
        try await handle.apiRequest(method: method, path: Self.base + path, bodyJson: body)
    }

    /// `features.networks` of the account's server, read again.
    func supported() async throws -> Bool {
        let json = try await call(.get, "/info")
        return Networks.supported(infoJson: json)
    }

    /// The kinds of network the account's server joins (`features.network_kinds`; empty without networks).
    func kinds() async throws -> [String] {
        let json = try await call(.get, "/info")
        return Networks.kinds(infoJson: json)
    }

    /// The networks of every vault you can see.
    func list() async throws -> [NetworkItem] {
        let json = try await call(.get, "/networks")
        return Networks.networks(json)
    }

    func create(_ body: String) async throws -> NetworkItem {
        let json = try await call(.post, "/networks", body)
        guard let n = Networks.network(json) else { throw ConfError.notAConf }
        return n
    }

    func update(_ id: String, _ body: String) async throws -> NetworkItem {
        let json = try await call(.put, "/networks/\(id)", body)
        guard let n = Networks.network(json) else { throw ConfError.notAConf }
        return n
    }

    func delete(_ id: String) async throws { _ = try await call(.delete, "/networks/\(id)") }

    /// Its state in the server, or `nil` when it can't be read (netd down...):
    /// "unknown", not an error.
    func status(_ id: String) async -> NetStatus? {
        guard let json = try? await call(.get, "/networks/\(id)/status") else { return nil }
        return Networks.status(json)
    }

    func up(_ id: String) async throws -> NetStatus {
        let json = try await call(.post, "/networks/\(id)/up", "{}")
        return Networks.status(json) ?? NetStatus(state: "unknown")
    }

    func down(_ id: String) async throws { _ = try await call(.post, "/networks/\(id)/down", "{}") }

    /// Test: brings it up, then asks its state about once a second for a few
    /// seconds until the WireGuard handshake appears. A Tailscale node: while
    /// it is starting, about 30 s (`up` already waited 10 s).
    func test(_ id: String, kind: String, onStatus: @MainActor (NetStatus) -> Void) async throws -> NetStatus {
        var st = try await up(id)
        await onStatus(st)
        var polls = 0
        let tailnet = kind == Networks.tailscale
        let pending: [NetState] = tailnet ? [.starting] : [.waiting, .starting]
        while polls < (tailnet ? Networks.tsTestPolls : Networks.testPolls), pending.contains(Networks.state(st, kind: kind)) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            st = await status(id) ?? st
            await onStatus(st)
            polls += 1
        }
        return st
    }

    /// A login or an approval of a Tailscale node: its state every 2 s until
    /// it is no longer waiting (up, an error, or `down` when the network went
    /// idle meanwhile: Test brings it back up already logged in), 5 minutes
    /// at most. Returns the last state (`nil`: never read). Cancelled with
    /// its task (the screen closes).
    func watchLogin(_ id: String, onStatus: @MainActor (NetStatus) -> Void) async -> NetStatus? {
        var last: NetStatus?
        var waited = 0
        while waited < Networks.loginWaitSeconds, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Networks.loginPollSeconds) * 1_000_000_000)
            waited += Networks.loginPollSeconds
            if Task.isCancelled { break }
            guard let st = await status(id) else { continue }
            last = st
            await onStatus(st)
            if st.state != "needs_auth" && st.state != "starting" { break }
        }
        return last
    }

    /// The hosts of a vault (to mark the devices already added); empty when they can't be read.
    func hosts(vaultId: String?) async -> [HostRef] {
        guard let json = try? await call(.get, "/hosts" + (vaultId.map { "?vault_id=\($0)" } ?? "")) else { return [] }
        return Networks.hostRefs(json)
    }

    /// Devices of the network (it brings it up; Editors).
    func peers(_ id: String) async throws -> [NetPeer] {
        let json = try await call(.get, "/networks/\(id)/peers")
        return Networks.peers(json)
    }

    /// The server generates the WireGuard private key (stored as the
    /// secret, never shown) and returns the public key; with a key already,
    /// `replace` (otherwise `409 key_exists`).
    func generateKey(_ id: String, replace: Bool) async throws -> String {
        let json = try await call(.post, "/networks/\(id)/wireguard/key", replace ? "{\"replace\":true}" : "{\"replace\":false}")
        return Networks.object(json)?["public_key"] as? String ?? ""
    }

    /// `(networks billed to you, max)` of your plan.
    func usage() async -> (used: Int, max: Int?)? {
        guard let json = try? await call(.get, "/me/plan") else { return nil }
        return Networks.usage(json)
    }

    /// The server tests the host (through its network): only when asked,
    /// never polled. `trust`: accept a new host key.
    func testHost(_ hostId: String, trust: Bool) async throws -> HostTest {
        let json = try await call(.post, "/hosts/\(hostId)/test" + (trust ? "?trust=true" : ""), "{}")
        return Networks.hostTest(json) ?? HostTest(ok: false)
    }

    /// Adds a host at an address of a network (in the network's vault).
    func addHost(_ body: String) async throws -> String {
        let json = try await call(.post, "/hosts", body)
        return Networks.object(json)?["label"] as? String ?? ""
    }
}

/// What is known of the private networks, shared by every screen: which
/// accounts' servers have them (`features.networks`, read again when an
/// account starts and when the Networks screen opens), their state in the
/// server, the network of each host of the lists and the last host test
/// through them ("via Office · 23 ms"; only when asked, never polled).
/// This device never has networks.
@MainActor
final class NetworkBook: ObservableObject {
    static let shared = NetworkBook()

    @Published private(set) var supported: [String: Bool] = [:]
    /// Account → the kinds of network its server joins (`features.network_kinds`).
    @Published private(set) var kinds: [String: [String]] = [:]
    @Published private(set) var statuses: [String: NetStatus] = [:]
    @Published private(set) var unknown: Set<String> = []
    @Published private(set) var tests: [String: HostTest] = [:]
    @Published private(set) var testing: Set<String> = []
    /// Host (key) → its network (own or its groups').
    @Published private(set) var hostNetworks: [String: String] = [:]
    /// Network (`account/id`) → name.
    @Published private(set) var names: [String: String] = [:]
    private var statusAt: [String: Date] = [:]

    /// States younger than this are not asked again (unless forced).
    private static let fresh: TimeInterval = 15

    /// The account's server has private networks (as last read). Never This device.
    func isSupported(_ accountId: String?) -> Bool {
        guard let accountId else { return false }
        return supported[accountId] == true
    }

    var anySupported: Bool { supported.values.contains(true) }

    /// Whether the account's server joins networks of `kind` (Tailscale only when `/info` lists it).
    func kindSupported(_ accountId: String?, _ kind: String) -> Bool {
        guard let accountId else { return false }
        return kinds[accountId]?.contains(kind) == true
    }

    /// The kinds the account's server joins (empty: none, or not read yet).
    func kinds(of accountId: String?) -> [String] { accountId.flatMap { kinds[$0] } ?? [] }

    /// Reads `/api/v1/info` of the account's server again; keeps the last answer when it fails.
    func refreshFeatures(_ accountId: String, core: TermoakCore) async {
        guard let handle = try? core.account(accountId: accountId),
              let list = try? await NetworksAPI(handle: handle).kinds() else { return }
        setKinds(accountId, list)
    }

    /// What `/info` said: networks, and of which kinds (none: no networks).
    func setKinds(_ accountId: String, _ list: [String]) {
        supported[accountId] = !list.isEmpty
        kinds[accountId] = list
    }

    func forget(_ accountId: String) {
        supported[accountId] = nil
        kinds[accountId] = nil
    }

    func api(_ accountId: String?, core: TermoakCore) -> NetworksAPI? {
        guard let accountId, let handle = try? core.account(accountId: accountId) else { return nil }
        return NetworksAPI(handle: handle)
    }

    // MARK: State in the server

    func status(_ id: String) -> NetStatus? { statuses[id] }

    func state(_ id: String, kind: String) -> NetState {
        unknown.contains(id) ? .unknown : Networks.state(statuses[id], kind: kind)
    }

    func setStatus(_ id: String, _ s: NetStatus?) {
        if let s {
            statuses[id] = s
            unknown.remove(id)
        } else {
            statuses[id] = nil
            unknown.insert(id)
        }
        statusAt[id] = Date()
    }

    /// Asks the state of a network when it is not fresh (or `force`).
    func refreshStatus(_ api: NetworksAPI, _ id: String, force: Bool = false) async {
        if !force, let at = statusAt[id], Date().timeIntervalSince(at) < Self.fresh { return }
        statusAt[id] = Date()
        setStatus(id, await api.status(id))
    }

    // MARK: Hosts

    static func links(_ groups: [HostGroup], account: String?, vault: String?) -> [GroupLink] {
        groups.filter { $0.accountId == account && $0.vaultId == vault }
            .map { GroupLink(id: $0.id, name: $0.name, parentId: $0.parentId, networkId: $0.settings.networkId) }
    }

    /// Learns the network of `hosts` (their own, or their groups' in the
    /// same vault) and the names of the networks in the local stores.
    func index(core: TermoakCore, hosts: [SshHost], groups: [HostGroup]) {
        let nets = (try? core.listNetworks(filter: ItemFilter(accountIds: nil, vaultIds: nil, includeDevice: false))) ?? []
        var n = names
        for net in nets { n["\(net.accountId ?? "")/\(net.id)"] = net.name }
        if n != names { names = n }
        var h = hostNetworks
        for host in hosts {
            guard host.accountId != nil,
                  let net = Networks.effective(own: host.settings.networkId, groupId: host.groupId,
                                               groups: Self.links(groups, account: host.accountId, vault: host.vaultId)) else {
                h[host.key] = nil
                continue
            }
            h[host.key] = net
        }
        if h != hostNetworks { hostNetworks = h }
    }

    func network(of host: SshHost) -> String? { hostNetworks[host.key] }

    /// Name of a network of an account (`nil`: not in the stores, missing).
    func name(_ accountId: String?, _ networkId: String) -> String? { names["\(accountId ?? "")/\(networkId)"] }

    /// The network a host connects through, from the stores (the terminal
    /// bar): its name, or the "missing" text; `nil` when direct.
    static func resolve(core: TermoakCore, hostId: String?, accountId: String?) -> String? {
        guard let hostId, let accountId, let host = try? core.getHost(id: hostId, accountId: accountId) else { return nil }
        let groups = (try? core.listGroups(filter: ItemFilter(accountIds: [accountId], vaultIds: nil, includeDevice: false))) ?? []
        guard let net = Networks.effective(own: host.settings.networkId, groupId: host.groupId,
                                           groups: links(groups, account: accountId, vault: host.vaultId)) else { return nil }
        return (try? core.getNetwork(id: net, accountId: accountId).name) ?? String(localized: "networks.missing")
    }

    // MARK: Host tests

    func test(of host: SshHost) -> HostTest? { tests[host.key] }
    func isTesting(_ host: SshHost) -> Bool { testing.contains(host.key) }

    /// Tests `host` from the server; the result stays for the lists.
    func testHost(_ api: NetworksAPI, _ host: SshHost, trust: Bool) async throws -> HostTest {
        testing.insert(host.key)
        defer { testing.remove(host.key) }
        let t = try await api.testHost(host.id, trust: trust)
        tests[host.key] = t
        return t
    }
}

// MARK: Texts

extension NetState {
    /// `short`: for lists ("Waiting"); a tailnet ([kind]) says "Connecting to the tailnet…" while it starts.
    func label(short: Bool = false, kind: String? = nil) -> String {
        switch self {
        case .down: return String(localized: "networks.state.down")
        case .starting where kind == Networks.tailscale: return String(localized: "networks.ts.state.starting")
        case .starting: return String(localized: "networks.state.starting")
        case .waiting: return short ? String(localized: "networks.state.waiting_short") : String(localized: "networks.state.waiting")
        case .up: return String(localized: "networks.state.up")
        case .needsAuth: return short ? String(localized: "networks.state.needs_auth_short") : String(localized: "networks.state.needs_auth")
        case .needsLogin: return short ? String(localized: "networks.ts.state.login_short") : String(localized: "networks.ts.state.login")
        case .needsApproval: return short ? String(localized: "networks.ts.state.approval_short") : String(localized: "networks.ts.state.approval")
        case .error: return String(localized: "networks.state.error")
        case .unknown: return String(localized: "networks.state.unknown")
        }
    }

    /// The explanation for a network of `kind` (a tailnet has no "other side" that answers).
    func hint(kind: String) -> String {
        guard kind == Networks.tailscale else { return hint }
        switch self {
        case .down: return String(localized: "networks.ts.state.down_hint")
        case .starting: return String(localized: "networks.ts.state.starting_hint")
        case .up: return String(localized: "networks.ts.state.up_hint")
        default: return hint
        }
    }

    var hint: String {
        switch self {
        case .down: return String(localized: "networks.state.down_hint")
        case .starting: return String(localized: "networks.state.starting_hint")
        case .waiting: return String(localized: "networks.state.waiting_hint")
        case .up: return String(localized: "networks.state.up_hint")
        case .needsAuth: return String(localized: "networks.state.needs_auth_hint")
        case .needsLogin: return String(localized: "networks.ts.state.login_hint")
        case .needsApproval: return String(localized: "networks.ts.state.approval_hint")
        case .error: return String(localized: "networks.state.error_hint")
        case .unknown: return String(localized: "networks.state.unknown_hint")
        }
    }
}

extension NetworkMessage {
    var text: String {
        switch self {
        case .planLimit(let max?): return String(localized: "error.plan_limit.max_networks \(max)")
        case .planLimit(nil): return String(localized: "error.plan_limit.max_networks_unknown")
        case .relayLimit(let max?): return String(localized: "error.relay_limit \(max)")
        case .relayLimit(nil): return String(localized: "error.relay_limit_unknown")
        case .netd("dial_failed"): return String(localized: "networks.netd.dial_failed")
        case .netd("timeout"): return String(localized: "networks.netd.timeout")
        case .netd("needs_auth"): return String(localized: "networks.netd.needs_auth")
        case .netd("network_error"): return String(localized: "networks.netd.network_error")
        case .netd("limit"): return String(localized: "networks.netd.limit")
        case .netd: return String(localized: "networks.netd.invalid")
        case .dialFailed: return String(localized: "error.network_dial_failed")
        case .dialFailedDetail(let detail): return String(localized: "error.network_dial_failed.detail \(detail)")
        case .unavailable: return String(localized: "error.network_unavailable")
        case .unavailableHere: return String(localized: "error.network_unavailable.device")
        case .unsupportedKind: return String(localized: "error.unsupported_kind")
        case .notFound: return String(localized: "error.network_not_found")
        case .keyExists: return String(localized: "error.key_exists")
        case .notWireguard: return String(localized: "error.not_wireguard")
        case .notInNetwork: return String(localized: "error.not_in_network")
        case .tailnet(let t): return t.text
        }
    }
}

extension TailnetMessage {
    var text: String {
        switch self {
        case .login(let name?): return String(localized: "networks.ts.error.login \(name)")
        case .login(nil): return String(localized: "networks.ts.netd.needs_login")
        case .approval(let name?): return String(localized: "networks.ts.error.approval \(name)")
        case .approval(nil): return String(localized: "networks.ts.netd.needs_approval")
        case .networkError(let name, let reason): return String(localized: "networks.ts.error.network_error \(name) \(reason)")
        case .timeout: return String(localized: "networks.ts.error.timeout")
        case .limit: return String(localized: "networks.ts.error.limit")
        case .dial(let text, let acl): return acl ? text + " " + String(localized: "networks.ts.error.acl_hint") : text
        case .unsupported: return String(localized: "networks.ts.unsupported")
        }
    }
}

extension TsProblem {
    var text: String {
        switch self {
        case .controlUrlMissing: return String(localized: "networks.ts.error.control_url_missing")
        case .controlUrl: return String(localized: "networks.ts.error.control_url")
        case .hostname: return String(localized: "networks.ts.error.hostname")
        case .tags: return String(localized: "networks.ts.error.tags")
        case .tagsMax: return String(localized: "networks.ts.error.tags_max \(Networks.maxTags)")
        case .authKey: return String(localized: "networks.ts.error.auth_key")
        case .keyMissing: return String(localized: "networks.ts.error.key_missing")
        }
    }
}

/// "100.64.0.3 · 4 devices" (`connected`: "Connected · …").
func tailnetSummaryText(_ s: NetStatus, connected: Bool = true) -> String {
    let summary = Networks.tailnetSummary(s) { String(localized: "networks.ts.devices \($0)") }
    return connected ? String(localized: "networks.ts.connected \(summary)") : summary
}

/// Text of an error on a network's screens (Test, devices): a tailnet's in words, otherwise as everywhere.
func networkErrorText(_ error: Error, network: NetworkItem) -> String {
    if network.isTailscale, let info = (error as? TermoakError)?.apiError,
       let t = Networks.tailscaleError(code: info.code, detailsJson: info.detailsJson, message: info.message, name: network.name) {
        return t.text
    }
    return userMessage(error)
}

/// Text of an error saving a network: the server's own reason for a `400` (bad settings).
func networkSaveErrorText(_ error: Error) -> String {
    if let info = (error as? TermoakError)?.apiError, info.status == 400 {
        let reason = info.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty { return String(localized: "networks.form.error_server \(reason)") }
    }
    return userMessage(error)
}

extension ConfError {
    var text: String {
        switch self {
        case .notAConf: return String(localized: "networks.conf.error.not_a_conf")
        case .badLine(let n): return String(localized: "networks.conf.error.bad_line \(n)")
        case .peerWithoutKey: return String(localized: "networks.conf.error.peer_without_key")
        case .noPeer: return String(localized: "networks.conf.error.no_peer")
        case .badKey(let f): return String(localized: "networks.conf.error.bad_key \(f)")
        case .badNumber(let f): return String(localized: "networks.conf.error.bad_number \(f)")
        case .mixedPresharedKeys: return String(localized: "networks.conf.error.mixed_psk")
        case .noAddress: return String(localized: "networks.conf.error.no_address")
        case .noAllowedIps(let n): return String(localized: "networks.conf.error.no_allowed_ips \(n)")
        case .badEndpoint(let n): return String(localized: "networks.conf.error.bad_endpoint \(n)")
        case .noEndpoint: return String(localized: "networks.conf.error.no_endpoint")
        }
    }
}

/// Text of a failed host test: its `error_code`, else the server's text.
func hostTestErrorText(_ t: HostTest) -> String {
    // A tailnet says more: netd's English reason (the test carries no netd_code), in words.
    if let m = Networks.hostTestTailnet(t) { return m.text }
    switch t.errorCode ?? "" {
    case "host_key_unknown": return String(localized: "networks.test.host_key_unknown")
    case "host_key_changed": return String(localized: "networks.test.host_key_changed")
    case "auth_failed": return String(localized: "networks.test.auth_failed")
    case "timeout": return String(localized: "networks.test.timeout")
    case "connect_failed": return String(localized: "networks.test.connect_failed")
    case "telnet_not_supported": return String(localized: "networks.test.telnet")
    case let code:
        if let m = Networks.message(code: code, detailsJson: nil) { return m.text }
        if let e = t.error, !e.isEmpty { return e.prefix(1).uppercased() + e.dropFirst() }
        return String(localized: "networks.test.failed")
    }
}

/// The friendly text of a private network error (0.7), from its code and
/// details (`apiError`): the server's (`network_dial_failed` with its
/// `netd_code`, `plan_limit` of `max_networks`, `key_exists`...) and the
/// engine's own (a network host on This device or signed out); `nil`: not
/// one of them.
func networkErrorText(_ error: Error) -> String? {
    guard let e = error as? TermoakError else { return nil }
    guard let info = e.apiError else {
        if case .NetworkUnavailable = e { return String(localized: "error.network_unavailable") }
        return nil
    }
    return Networks.message(code: info.code, detailsJson: info.detailsJson, message: info.message, device: info.status == 0)?.text
}
