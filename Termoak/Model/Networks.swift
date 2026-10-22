import Foundation

// Private networks (0.7): the logic of the screens, like the desktop's
// src/networks.rs, the web's networks.js and Android's data/Networks.kt
// (NETWORKS.md §8.1). The server joins the networks (termoak-netd); the app
// manages them through the REST API and reaches their hosts through the
// server relay (the engine does that when it connects). Pure Foundation,
// without the engine's types, so the unit tests compile this file on its
// own: the WireGuard .conf, the state in the server, the network of a host
// (its own or its groups'), the editors' picker and the network errors.

/// A WireGuard peer of a `.conf` or of a network (`wireguard.peers`).
struct WgPeer: Equatable {
    var publicKey: String
    var endpoint: String? = nil
    var allowedIps: [String] = []
    var keepalive: Int? = nil
}

/// What a WireGuard `.conf` holds, split as Termoak stores it: the
/// configuration and the keys (the secret).
struct WgConf: Equatable {
    var addresses: [String] = []
    var dns: [String] = []
    var mtu: Int? = nil
    var peers: [WgPeer] = []
    var privateKey: String? = nil
    var presharedKey: String? = nil
    /// Keys of the file Termoak doesn't use (`ListenPort`, `PostUp`...).
    var ignored: [String] = []
}

/// Why a `.conf` can't be used (or saved).
enum ConfError: Equatable, Error {
    /// Nothing in it, or text before any section.
    case notAConf
    /// A line that is not `Key = Value` (its number).
    case badLine(Int)
    case peerWithoutKey
    case noPeer
    /// A key that is not 32 bytes of base64 (which field; never the key).
    case badKey(String)
    /// `MTU` or `PersistentKeepalive` that is not a number.
    case badNumber(String)
    /// Peers with different preshared keys: Termoak keeps one per network.
    case mixedPresharedKeys
    case noAddress
    /// Peer n (from 1) has no `AllowedIPs`.
    case noAllowedIps(Int)
    /// Peer n's `Endpoint` is not `host:port`.
    case badEndpoint(Int)
    /// No peer has an endpoint: the server is the side that connects.
    case noEndpoint
}

/// State of a network as the screens show it.
enum NetState: Equatable {
    /// Not running: it starts when a host in it is used.
    case down
    case starting
    /// Running, but the WireGuard peer never answered (no handshake yet).
    case waiting
    /// Running, and the other side answered (Tailscale: the node is in the tailnet).
    case up
    /// Waiting for authorization (ZeroTier, or a Tailscale state this version doesn't know).
    case needsAuth
    /// Tailscale: the server's node must be logged in (an Editor opens the login URL).
    case needsLogin
    /// Tailscale: the node is logged in and waits for approval in the admin console.
    case needsApproval
    case error
    /// Not asked yet, or the server didn't answer: not an error page.
    case unknown
}

/// `GET /networks/{id}/status` (and the answer of `up`).
struct NetStatus: Equatable {
    var state: String
    var message: String? = nil
    /// ms since 1970.
    var lastHandshakeAt: Int64? = nil
    var rxBytes: Int64? = nil
    var txBytes: Int64? = nil
    var streams: Int64? = nil
    var nodeAddresses: [String] = []
    /// Tailscale, with `needs_auth`: `login` or `approval`.
    var auth: String? = nil
    /// Tailscale: the control server (`nil`: Tailscale's).
    var controlUrl: String? = nil
    var tailnet: String? = nil
    var magicDnsSuffix: String? = nil
    /// Tailscale: devices the server's node sees.
    var peerCount: Int? = nil
    var ephemeral: Bool? = nil
    /// Tailscale: the last error as the control server said it.
    var lastError: String? = nil
    /// The server's node: its name, MagicDNS name and id.
    var nodeName: String? = nil
    var nodeDnsName: String? = nil
    var nodeId: String? = nil
    /// Tailscale: the login page (only Editors get it).
    var authUrl: String? = nil
}

/// Tailscale/Headscale settings of a network (`tailscale`); `ephemeral`
/// `nil`: yes with an auth key, no without one.
struct TsConfig: Equatable {
    /// `nil`: Tailscale's control server; otherwise a Headscale URL.
    var controlUrl: String? = nil
    var hostname: String? = nil
    var tags: [String] = []
    var ephemeral: Bool? = nil
}

/// What an update does with the stored secret (Tailscale's auth key).
enum SecretChange: Equatable {
    /// No `secret` in the body: the stored one stays.
    case keep
    /// `secret: {auth_key}`.
    case set(String)
    /// `secret: null` removes it (`{}` would store an empty secret and
    /// `has_secret` would stay true).
    case clear
}

/// Why Tailscale settings can't be saved (the core's rules, checked again by the server).
enum TsProblem: Equatable {
    case controlUrlMissing, controlUrl, hostname, tags, tagsMax, authKey, keyMissing
}

/// A host of a vault as the devices list sees it (to mark devices already added).
struct HostRef: Equatable {
    var id: String
    var label: String
    var address: String
    var networkId: String?
}

/// What happened to a tailnet, as the screens say it (the texts are in NetworkBook.swift).
enum TailnetMessage: Equatable {
    /// The server must be logged in (`name`: the network, when known).
    case login(String?)
    /// The server's node waits for approval.
    case approval(String?)
    /// It could not join the tailnet: netd's reason without its prefix.
    case networkError(name: String, reason: String)
    case timeout
    case limit
    /// A dial that failed inside the tailnet: netd's words (capitalized,
    /// ending in a dot) and whether the ACL hint goes with them.
    case dial(String, aclHint: Bool)
    case unsupported
}

/// A network as the REST API gives it: the whole object is kept to send it
/// back on PUT.
struct NetworkItem: Identifiable, Equatable {
    var id: String
    var name: String
    var kind: String
    var description: String
    var vaultId: String?
    var hasSecret: Bool
    var secretHidden: Bool
    var publicKey: String?
    var addresses: [String]
    var dns: [String]
    var mtu: Int?
    var peers: [WgPeer]
    /// The JSON as read.
    var json: String
    /// Tailscale settings (kind `tailscale`).
    var tailscale: TsConfig? = nil

    var isWireguard: Bool { kind == Networks.wireguard }
    var isTailscale: Bool { kind == Networks.tailscale }
}

/// A device of a network (`GET /networks/{id}/peers`); WireGuard: its
/// configured peers (`addresses` are their allowed IPs).
struct NetPeer: Equatable, Identifiable {
    var name: String? = nil
    var dnsName: String? = nil
    var addresses: [String] = []
    var online: Bool? = nil
    var lastSeen: Int64? = nil
    var publicKey: String? = nil
    var endpoint: String? = nil
    var os: String? = nil
    /// Tailscale: ACL tags.
    var tags: [String] = []
    /// Tailscale: subnets the device routes (exit nodes: `/0`).
    var routes: [String] = []

    var id: String { (publicKey ?? "") + (name ?? "") + (dnsName ?? "") + addresses.joined(separator: ",") }

    /// Its MagicDNS name without the trailing dot (`nas.tail1234.ts.net`).
    var bareDnsName: String? {
        guard var d = dnsName?.trimmingCharacters(in: .whitespaces) else { return nil }
        while d.hasSuffix(".") { d.removeLast() }
        return d.isEmpty ? nil : d
    }

    /// Tailscale: where a host on this device connects: its MagicDNS name, or its first IP.
    var deviceAddress: String? {
        if let d = bareDnsName { return d }
        guard let a = addresses.first?.split(separator: "/").first.map(String.init)?.trimmingCharacters(in: .whitespaces),
              !a.isEmpty else { return nil }
        return a
    }

    /// Tailscale: the subnets of `routes` a host can be in (never an exit node's `/0`).
    var hostRoutes: [String] {
        routes.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasSuffix("/0") }
    }

    /// Its name, DNS name, endpoint or the start of its key.
    var title: String {
        if let n = name, !n.isEmpty { return n }
        if let d = dnsName, !d.isEmpty { return d }
        if let e = endpoint, !e.isEmpty { return e }
        if let k = publicKey { return String(k.prefix(10)) + "…" }
        return "—"
    }
}

/// An address a host can be added at: a single one (`exact`), or a
/// subnet's start to complete.
struct HostAddress: Equatable, Identifiable {
    var address: String
    var exact: Bool
    var source: String
    var id: String { source }
}

/// `POST /hosts/{id}/test`: "via Office · 23 ms", or why it failed.
struct HostTest: Equatable {
    var ok: Bool
    var latencyMs: Int64? = nil
    var fingerprint: String? = nil
    var error: String? = nil
    var errorCode: String? = nil
    var networkId: String? = nil
    var networkName: String? = nil
    var networkKind: String? = nil
}

/// A group as the network inheritance sees it.
struct GroupLink: Equatable {
    var id: String
    var name: String
    var parentId: String?
    var networkId: String?
}

/// The group that gives the hosts inside a network, and that network.
struct InheritedNetwork: Equatable {
    var group: GroupLink
    var networkId: String
}

/// A choice of the "Network" picker of the host and group editors.
enum NetworkChoice: Equatable, Hashable {
    /// `nil`: the group's network (`inherited`), or direct when no group gives one.
    case inherit(groupName: String?, networkId: String?, networkName: String?)
    /// A network of the item's vault.
    case network(id: String, name: String, kind: String)
    /// The item's network is not in its vault (deleted, not synced): kept, flagged.
    case missing(id: String)

    var id: String? {
        switch self {
        case .inherit: return nil
        case .network(let id, _, _), .missing(let id): return id
        }
    }
}

/// A network error of the API as the screens say it.
enum NetworkMessage: Equatable {
    case planLimit(max: Int?)
    case relayLimit(max: Int?)
    case netd(String)
    case dialFailed
    case dialFailedDetail(String)
    case unavailable
    case unavailableHere
    case unsupportedKind
    case notFound
    case keyExists
    case notWireguard
    case notInNetwork
    /// A tailnet's login, approval or dial, in words.
    case tailnet(TailnetMessage)
}

enum Networks {
    /// Feature of `/api/v1/info` that says the server can reach private networks.
    static let feature = "networks"
    static let wireguard = "wireguard"
    static let tailscale = "tailscale"
    static let zerotier = "zerotier"
    /// A `.conf` bigger than this is not a WireGuard configuration.
    static let maxConfBytes = 64 * 1024
    /// Polls of the state after Test, about once a second.
    static let testPolls = 6
    /// Polls of a Tailscale network's state after Test while it starts (`up` already waits 10 s): about 30 s.
    static let tsTestPolls = 30
    /// A login or an approval is followed every 2 s for 5 minutes at most.
    static let loginPollSeconds = 2
    static let loginWaitSeconds = 300
    /// Most tags a node may ask for (the core's `TailscaleConfig::MAX_TAGS`).
    static let maxTags = 20
    private static let maxDepth = 16

    /// Template of a new network's `.conf`.
    static let confTemplate = "[Interface]\nAddress = 10.0.0.2/32\n# DNS = 10.0.0.1\n\n[Peer]\nPublicKey = \n"
        + "Endpoint = vpn.example.com:51820\nAllowedIPs = 10.0.0.0/24\nPersistentKeepalive = 25\n"

    // MARK: JSON helpers

    static func object(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func array(_ json: String) -> [Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [Any]
    }

    static func text(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private static func str(_ o: [String: Any], _ key: String) -> String? {
        guard let s = o[key] as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func int(_ o: [String: Any], _ key: String) -> Int64? {
        (o[key] as? NSNumber)?.int64Value
    }

    private static func strings(_ v: Any?) -> [String] {
        (v as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    /// Kinds of network the server can join (`features.network_kinds`): a
    /// server without the field (0.7.0-next.2) joins WireGuard only; none
    /// without `features.networks`.
    static func kinds(infoJson: String) -> [String] {
        guard let o = object(infoJson), let f = o["features"] as? [String: Any], f[feature] as? Bool == true else { return [] }
        guard let list = f["network_kinds"] as? [Any] else { return [wireguard] }
        return list.compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    /// Whether a server's `/api/v1/info` says it has private networks.
    static func supported(infoJson: String) -> Bool {
        guard let o = object(infoJson), let f = o["features"] as? [String: Any] else { return false }
        return f[feature] as? Bool ?? false
    }

    // MARK: WireGuard .conf

    /// A WireGuard key: 32 bytes in standard base64.
    static func validKey(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count == 44, t.hasSuffix("="), let data = Data(base64Encoded: t) else { return false }
        return data.count == 32 && t.range(of: "^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw480]=$", options: .regularExpression) != nil
    }

    private static func list(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static let knownKeys = ["ListenPort", "Table", "PreUp", "PostUp", "PreDown", "PostDown", "SaveConfig", "FwMark", "Jc"]

    private static func keyName(_ lower: String, _ original: String) -> String {
        knownKeys.first { $0.lowercased() == lower } ?? original
    }

    /// Reads a WireGuard `.conf` (wg-quick): `[Interface]` `Address`
    /// (repeatable, comma lists), `DNS`, `MTU`, `PrivateKey`; each `[Peer]`
    /// `PublicKey`, `Endpoint`, `AllowedIPs`, `PersistentKeepalive` (`off` =
    /// none), `PresharedKey`. Keys are case-insensitive, `#` and `;` start
    /// comments, the value is everything after the first `=`. Other keys are
    /// listed in `ignored`; bad keys are never echoed.
    static func parse(_ text: String) -> Result<WgConf, ConfError> {
        var section: String?
        var seenSection = false
        var conf = WgConf()
        var peers: [WgPeer] = []
        var psks: [String?] = []
        var peer: WgPeer?
        var psk: String?
        var ignored: [String] = []
        func finishPeer() -> ConfError? {
            guard let p = peer else { return nil }
            if p.publicKey.isEmpty { return .peerWithoutKey }
            peers.append(p)
            psks.append(psk)
            peer = nil
            psk = nil
            return nil
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            let cut = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let cut2 = cut.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            var line = String(cut2).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                if let e = finishPeer() { return .failure(e) }
                seenSection = true
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                section = name
                if name == "peer" { peer = WgPeer(publicKey: "") }
                continue
            }
            guard let section else { return .failure(.notAConf) }
            guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { return .failure(.badLine(i + 1)) }
            let keyText = line[..<eq].trimmingCharacters(in: .whitespaces)
            let key = keyText.lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch (section, key) {
            case ("interface", "address"): conf.addresses += list(value)
            case ("interface", "dns"): conf.dns += list(value)
            case ("interface", "mtu"):
                guard let m = Int(value), (576...65535).contains(m) else { return .failure(.badNumber("MTU")) }
                conf.mtu = m
            case ("interface", "privatekey"):
                guard validKey(value) else { return .failure(.badKey("PrivateKey")) }
                conf.privateKey = value
            case ("peer", _):
                var p = peer ?? WgPeer(publicKey: "")
                switch key {
                case "publickey":
                    guard validKey(value) else { return .failure(.badKey("PublicKey")) }
                    p.publicKey = value
                case "endpoint": p.endpoint = value.isEmpty ? nil : value
                case "allowedips": p.allowedIps += list(value)
                case "presharedkey":
                    guard validKey(value) else { return .failure(.badKey("PresharedKey")) }
                    psk = value
                case "persistentkeepalive":
                    if value.lowercased() == "off" {
                        p.keepalive = nil
                    } else {
                        guard let k = Int(value), (0...65535).contains(k) else { return .failure(.badNumber("PersistentKeepalive")) }
                        p.keepalive = k > 0 ? k : nil
                    }
                default:
                    let n = keyName(key, keyText)
                    if !ignored.contains(n) { ignored.append(n) }
                }
                peer = p
            default:
                let n = keyName(key, keyText)
                if !ignored.contains(n) { ignored.append(n) }
            }
        }
        if let e = finishPeer() { return .failure(e) }
        if !seenSection { return .failure(.notAConf) }
        if peers.isEmpty { return .failure(.noPeer) }
        // One preshared key per network (netd applies it to every peer).
        let withPsk = psks.compactMap { $0 }
        if !withPsk.isEmpty && Set(psks.map { $0 ?? "" }).count > 1 { return .failure(.mixedPresharedKeys) }
        conf.peers = peers
        conf.presharedKey = withPsk.first
        conf.ignored = ignored
        return .success(conf)
    }

    /// What stops saving a configuration: addresses, each peer's allowed IPs
    /// and `host:port` endpoint, and at least one endpoint. `nil`: it can be saved.
    static func problem(_ c: WgConf) -> ConfError? {
        if c.addresses.isEmpty { return .noAddress }
        if c.peers.isEmpty { return .noPeer }
        for (i, p) in c.peers.enumerated() {
            if p.allowedIps.isEmpty { return .noAllowedIps(i + 1) }
            if let e = p.endpoint, !validEndpoint(e) { return .badEndpoint(i + 1) }
        }
        if !c.peers.contains(where: { $0.endpoint != nil }) { return .noEndpoint }
        return nil
    }

    /// `host:port` or `[v6]:port`.
    static func validEndpoint(_ e: String) -> Bool {
        let t = e.trimmingCharacters(in: .whitespaces)
        guard let colon = t.lastIndex(of: ":") else { return false }
        let host = t[..<colon]
        guard let port = Int(t[t.index(after: colon)...]), (1...65535).contains(port), !host.isEmpty else { return false }
        if host.hasPrefix("[") { return host.hasSuffix("]") && host.count > 2 }
        return !host.contains(":") && !host.contains(" ") && !host.contains("[") && !host.contains("]")
    }

    /// Reads and checks: what the form shows under the text.
    static func check(_ text: String) -> Result<WgConf, ConfError> {
        switch parse(text) {
        case .success(let c): return problem(c).map { .failure($0) } ?? .success(c)
        case .failure(let e): return .failure(e)
        }
    }

    /// A network's configuration as a `.conf` without keys but the peers'
    /// public ones; `keyNote` is a comment saying the private key is kept.
    static func confText(_ n: NetworkItem, keyNote: String) -> String {
        var out = "[Interface]\n# \(keyNote)\n"
        if !n.addresses.isEmpty { out += "Address = \(n.addresses.joined(separator: ", "))\n" }
        if !n.dns.isEmpty { out += "DNS = \(n.dns.joined(separator: ", "))\n" }
        if let mtu = n.mtu { out += "MTU = \(mtu)\n" }
        for p in n.peers {
            out += "\n[Peer]\nPublicKey = \(p.publicKey)\n"
            if let e = p.endpoint { out += "Endpoint = \(e)\n" }
            if !p.allowedIps.isEmpty { out += "AllowedIPs = \(p.allowedIps.joined(separator: ", "))\n" }
            if let k = p.keepalive { out += "PersistentKeepalive = \(k)\n" }
        }
        return out
    }

    /// The `[Peer]` block to add on the other side of the tunnel.
    static func peerSnippet(name: String, publicKey: String, addresses: [String]) -> String {
        let allowed = addresses.map { $0.contains("/") ? $0 : ($0.contains(":") ? "\($0)/128" : "\($0)/32") }.joined(separator: ", ")
        return ["[Peer]", "# Termoak: \(name)", "PublicKey = \(publicKey)", "AllowedIPs = " + (allowed.isEmpty ? "10.0.0.2/32" : allowed)]
            .joined(separator: "\n")
    }

    // MARK: The server's JSON

    static func status(_ json: String) -> NetStatus? { object(json).map(status(object:)) }

    static func status(object o: [String: Any]) -> NetStatus {
        NetStatus(
            state: o["state"] as? String ?? "",
            message: str(o, "message"),
            lastHandshakeAt: int(o, "last_handshake_at").flatMap { $0 > 0 ? $0 : nil },
            rxBytes: int(o, "rx_bytes"),
            txBytes: int(o, "tx_bytes"),
            streams: int(o, "streams"),
            nodeAddresses: strings((o["node"] as? [String: Any])?["addresses"]),
            auth: str(o, "auth"),
            controlUrl: str(o, "control_url"),
            tailnet: str(o, "tailnet"),
            magicDnsSuffix: str(o, "magic_dns_suffix"),
            peerCount: int(o, "peer_count").map(Int.init),
            ephemeral: o["ephemeral"] as? Bool,
            lastError: str(o, "last_error"),
            nodeName: (o["node"] as? [String: Any]).flatMap { str($0, "name") },
            nodeDnsName: (o["node"] as? [String: Any]).flatMap { str($0, "dns_name") },
            nodeId: (o["node"] as? [String: Any]).flatMap { str($0, "node_id") },
            authUrl: (o["node"] as? [String: Any]).flatMap { str($0, "auth_url") }
        )
    }

    /// The state shown: `up` without a WireGuard handshake is "waiting"; a
    /// Tailscale node that needs authorization needs a login or an approval.
    static func state(_ s: NetStatus?, kind: String) -> NetState {
        guard let s else { return .unknown }
        switch s.state {
        case "down": return .down
        case "starting": return .starting
        case "needs_auth":
            guard kind == tailscale else { return .needsAuth }
            return s.auth == "approval" ? .needsApproval : .needsLogin
        case "error": return .error
        case "up": return kind == wireguard && s.lastHandshakeAt == nil ? .waiting : .up
        default: return .unknown
        }
    }

    private static func peers(of v: Any?) -> [WgPeer] {
        (v as? [Any] ?? []).compactMap { $0 as? [String: Any] }.map { p in
            WgPeer(publicKey: p["public_key"] as? String ?? "", endpoint: str(p, "endpoint"),
                   allowedIps: strings(p["allowed_ips"]),
                   keepalive: int(p, "persistent_keepalive").flatMap { $0 > 0 ? Int($0) : nil })
        }
    }

    static func network(object o: [String: Any]) -> NetworkItem {
        let wg = o["wireguard"] as? [String: Any]
        return NetworkItem(
            id: o["id"] as? String ?? "",
            name: o["name"] as? String ?? "",
            kind: o["kind"] as? String ?? wireguard,
            description: o["description"] as? String ?? "",
            vaultId: str(o, "vault_id"),
            hasSecret: o["has_secret"] as? Bool ?? false,
            secretHidden: o["secret_hidden"] as? Bool ?? false,
            publicKey: wg.flatMap { str($0, "public_key") },
            addresses: strings(wg?["addresses"]),
            dns: strings(wg?["dns"]),
            mtu: wg.flatMap { int($0, "mtu") }.map(Int.init),
            peers: peers(of: wg?["peers"]),
            json: text(o),
            tailscale: (o["tailscale"] as? [String: Any]).map { t in
                TsConfig(controlUrl: str(t, "control_url"), hostname: str(t, "hostname"), tags: strings(t["tags"]),
                         ephemeral: t["ephemeral"] as? Bool)
            }
        )
    }

    static func network(_ json: String) -> NetworkItem? { object(json).map(network(object:)) }

    static func networks(_ json: String) -> [NetworkItem] {
        (array(json) ?? []).compactMap { $0 as? [String: Any] }.map(network(object:))
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func peers(_ json: String) -> [NetPeer] {
        (array(json) ?? []).compactMap { $0 as? [String: Any] }.map { p in
            NetPeer(name: str(p, "name"), dnsName: str(p, "dns_name"), addresses: strings(p["addresses"]),
                    online: p["online"] as? Bool, lastSeen: int(p, "last_seen").flatMap { $0 > 0 ? $0 : nil },
                    publicKey: str(p, "public_key"), endpoint: str(p, "endpoint"),
                    os: str(p, "os"), tags: strings(p["tags"]), routes: strings(p["routes"]))
        }
    }

    static func hostTest(_ json: String) -> HostTest? {
        guard let o = object(json) else { return nil }
        let net = o["network"] as? [String: Any]
        return HostTest(ok: o["ok"] as? Bool ?? false, latencyMs: int(o, "latency_ms"), fingerprint: str(o, "fingerprint"),
                        error: str(o, "error"), errorCode: str(o, "error_code"),
                        networkId: net.flatMap { str($0, "id") }, networkName: net.flatMap { str($0, "name") },
                        networkKind: net.flatMap { str($0, "kind") })
    }

    /// `(networks billed to you, max)` of `GET /me/plan` (`max` nil: no limit).
    static func usage(_ json: String) -> (used: Int, max: Int?)? {
        guard let o = object(json) else { return nil }
        let used = int((o["usage"] as? [String: Any]) ?? [:], "networks").map(Int.init) ?? 0
        let limits = (o["plan"] as? [String: Any])?["limits"] as? [String: Any]
        return (used, limits.flatMap { int($0, "max_networks") }.map(Int.init))
    }

    // MARK: Bodies of the REST calls

    /// Body of a create (`vaultId` set) or an update (`base`: the network as
    /// read): name, description, kind and its configuration (the server
    /// derives `public_key`); `secret` only when given (missing: the stored
    /// keys stay; an object replaces both).
    static func body(base: String?, vaultId: String?, name: String, description: String, conf: WgConf,
                     secret: (privateKey: String?, presharedKey: String?)?) -> String {
        var o = base.flatMap(object) ?? [:]
        o["id"] = nil
        o["name"] = name
        o["description"] = description
        o["kind"] = wireguard
        var wg = o["wireguard"] as? [String: Any] ?? [:]
        wg["addresses"] = conf.addresses
        wg["dns"] = conf.dns
        wg["mtu"] = conf.mtu.map { $0 as Any } ?? NSNull()
        wg["peers"] = conf.peers.map { p -> [String: Any] in
            ["public_key": p.publicKey, "endpoint": p.endpoint.map { $0 as Any } ?? NSNull(), "allowed_ips": p.allowedIps,
             "persistent_keepalive": p.keepalive.map { $0 as Any } ?? NSNull()]
        }
        wg["public_key"] = nil
        o["wireguard"] = wg
        if let vaultId { o["vault_id"] = vaultId }
        if let secret {
            o["secret"] = ["private_key": secret.privateKey.map { $0 as Any } ?? NSNull(),
                           "preshared_key": secret.presharedKey.map { $0 as Any } ?? NSNull()]
        }
        return text(o)
    }

    /// `POST /hosts` body for a host at `address` of a network (its vault, the network chosen).
    static func hostBody(label: String, address: String, port: Int, username: String?, network: NetworkItem) -> String {
        var o: [String: Any] = [
            "label": label, "address": address,
            "settings": ["port": port, "username": username.map { $0 as Any } ?? NSNull(), "network_id": network.id] as [String: Any],
        ]
        if let v = network.vaultId { o["vault_id"] = v }
        return text(o)
    }

    // MARK: Tailscale / Headscale

    /// The node's name when none is set: `termoak-` and the last 8 hex
    /// digits of the id (as netd does).
    static func defaultHostname(_ id: String?) -> String {
        let hex = (id ?? "").replacingOccurrences(of: "-", with: "").lowercased()
        return "termoak-" + (hex.count >= 8 ? String(hex.suffix(8)) : "xxxxxxxx")
    }

    /// `tag:a, tag:b` → `[tag:a, tag:b]`.
    static func parseTags(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `https://hs.example.com/` → `https://hs.example.com`.
    static func cleanControlUrl(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    /// What stops saving Tailscale settings and a new auth key (the core's
    /// rules, NETWORKS.md §8.1; the server checks them again): `controlUrl`
    /// `nil` is Tailscale's control server, `""` a Headscale without its
    /// URL. `nil`: it can be saved. The key is never part of the text.
    static func tailscaleProblem(controlUrl: String?, hostname: String?, tags: [String], authKey: String?) -> TsProblem? {
        if let controlUrl {
            let url = controlUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if url.isEmpty { return .controlUrlMissing }
            let rest: Substring
            if url.hasPrefix("https://") { rest = url.dropFirst(8) } else if url.hasPrefix("http://") { rest = url.dropFirst(7) } else { return .controlUrl }
            let authority = rest.split(separator: "/", omittingEmptySubsequences: false).first ?? ""
            if authority.isEmpty || authority.contains("@") || url.contains("?") || url.contains("#")
                || url.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
                return .controlUrl
            }
        }
        let h = (hostname ?? "").trimmingCharacters(in: .whitespaces)
        if !h.isEmpty && !matches(h, "^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$") { return .hostname }
        if tags.count > maxTags { return .tagsMax }
        if tags.contains(where: { !matches($0.trimmingCharacters(in: .whitespaces), "^tag:[A-Za-z0-9][A-Za-z0-9_-]{0,62}$") }) { return .tags }
        if let k = authKey?.trimmingCharacters(in: .whitespaces), !k.isEmpty,
           k.count > 1024 || k.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value > 0x7e }) {
            return .authKey
        }
        return nil
    }

    /// Body of a Tailscale network's create (`vaultId` set) or update (the
    /// network as read, in `base`, sent back whole with `ephemeral`): name,
    /// description, kind and settings; the secret as `secret` says (`keep`:
    /// no `secret`, `set`: `{auth_key}`, `clear`: `null`).
    static func tailscaleBody(base: String?, vaultId: String?, name: String, description: String,
                              ts: TsConfig, secret: SecretChange) -> String {
        var o = base.flatMap(object) ?? [:]
        o["id"] = nil
        o["name"] = name
        o["description"] = description
        o["kind"] = tailscale
        var t = o["tailscale"] as? [String: Any] ?? [:]
        let url = ts.controlUrl.map(cleanControlUrl).flatMap { $0.isEmpty ? nil : $0 }
        t["control_url"] = url.map { $0 as Any } ?? NSNull()
        let host = (ts.hostname ?? "").trimmingCharacters(in: .whitespaces)
        t["hostname"] = host.isEmpty ? NSNull() : host as Any
        t["tags"] = ts.tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        t["ephemeral"] = ts.ephemeral.map { $0 as Any } ?? NSNull()
        o["tailscale"] = t
        if let vaultId { o["vault_id"] = vaultId }
        switch secret {
        case .keep: o["secret"] = nil
        case .set(let key): o["secret"] = ["auth_key": key.trimmingCharacters(in: .whitespaces)]
        case .clear: o["secret"] = NSNull()
        }
        return text(o)
    }

    /// "Tailscale", or the Headscale server's host (`https://hs.example.com:8080/x` → `hs.example.com:8080`).
    static func controlServerLabel(_ url: String?) -> String {
        guard let u = url?.trimmingCharacters(in: .whitespaces), !u.isEmpty else { return "Tailscale" }
        let rest = u.range(of: "://").map { String(u[$0.upperBound...]) } ?? u
        let host = rest.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return host.isEmpty ? u : host
    }

    /// The node's address and the devices it sees ("100.64.0.3 · 4 devices"); `devices` makes the count's text.
    static func tailnetSummary(_ s: NetStatus, devices: (Int) -> String) -> String {
        ([s.nodeAddresses.first, devices(s.peerCount ?? 0)].compactMap { $0 }).joined(separator: " · ")
    }

    private static func bare(_ s: String?) -> String {
        var t = (s ?? "").trimmingCharacters(in: .whitespaces)
        while t.hasSuffix(".") { t.removeLast() }
        return t.lowercased()
    }

    /// The host of `hosts` that already reaches `peer` through the network
    /// `networkId`: same network, and its address is the device's name,
    /// MagicDNS name (or its first label) or one of its IPs, or its label is
    /// the device's name.
    static func importedHost(_ peer: NetPeer, networkId: String, hosts: [HostRef]) -> HostRef? {
        var names = Set<String>()
        let dns = bare(peer.dnsName)
        if !dns.isEmpty {
            names.insert(dns)
            if let short = dns.split(separator: ".").first { names.insert(String(short)) }
        }
        let name = bare(peer.name)
        if !name.isEmpty { names.insert(name) }
        for a in peer.addresses {
            let ip = bare(a.split(separator: "/").first.map(String.init))
            if !ip.isEmpty { names.insert(ip) }
        }
        return hosts.first { h in
            h.networkId == networkId && (names.contains(bare(h.address)) || (!name.isEmpty && bare(h.label) == name))
        }
    }

    /// Devices of a tailnet that can be added at once: not added yet and with an address.
    static func newDevices(_ peers: [NetPeer], networkId: String, hosts: [HostRef]) -> [NetPeer] {
        peers.filter { $0.deviceAddress != nil && importedHost($0, networkId: networkId, hosts: hosts) == nil }
    }

    /// Online devices first, then by name.
    static func sortDevices(_ peers: [NetPeer]) -> [NetPeer] {
        peers.sorted { a, b in
            let ao = a.online == true, bo = b.online == true
            if ao != bo { return ao }
            return a.title.lowercased() < b.title.lowercased()
        }
    }

    /// `GET /hosts?vault_id=…` as `HostRef`s.
    static func hostRefs(_ json: String) -> [HostRef] {
        (array(json) ?? []).compactMap { $0 as? [String: Any] }.map { h in
            HostRef(id: h["id"] as? String ?? "", label: h["label"] as? String ?? "", address: h["address"] as? String ?? "",
                    networkId: (h["settings"] as? [String: Any]).flatMap { str($0, "network_id") })
        }
    }

    /// `POST /hosts` body for a device of a tailnet: its name, its MagicDNS name (or first IP), port 22.
    static func deviceHostBody(_ peer: NetPeer, network: NetworkItem) -> String? {
        guard let address = peer.deviceAddress else { return nil }
        let label = (peer.name ?? "").trimmingCharacters(in: .whitespaces)
        return hostBody(label: label.isEmpty ? address : label, address: address, port: 22, username: nil, network: network)
    }

    /// netd's English reason without its `the network "X" could not start: ` prefix.
    static func tailscaleReason(_ message: String) -> String {
        for marker in ["\" could not start: ", "\" waits for authorization: ", "\" is still starting: "] {
            if let r = message.range(of: marker) { return String(message[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
        }
        return message.trimmingCharacters(in: .whitespaces)
    }

    /// The network's name in netd's `the network "X" …` message.
    private static func quotedName(_ message: String) -> String? {
        guard let r = message.range(of: #"the network "(.*?)" (could not start|waits for authorization|is still starting)"#,
                                    options: .regularExpression) else { return nil }
        let m = String(message[r]).dropFirst("the network \"".count)
        return m.range(of: "\" ").map { String(m[..<$0.lowerBound]) }
    }

    /// A dial that failed inside a tailnet: netd's words and, for an address or name it can't see, the ACL hint.
    static func tailnetDial(_ message: String) -> TailnetMessage {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        text = text.prefix(1).uppercased() + text.dropFirst()
        return .dial(text + ".", aclHint: message.contains("outside the tailnet") || message.contains("no device named"))
    }

    /// What netd's English message says about a tailnet (host tests and
    /// connections only carry it): a login or an approval, still starting
    /// and could not join (`kindKnown`: the network is a tailnet), or a dial
    /// outside the tailnet. `nil`: none of those.
    static func tailscaleMessage(_ message: String, name: String?, kindKnown: Bool = false) -> TailnetMessage? {
        let n = name ?? quotedName(message)
        if let r = message.range(of: "waits for authorization") {
            // "the node is logged in but must be approved": approval; "must be logged in": login.
            return message[r.lowerBound...].contains("approv") ? .approval(n) : .login(n)
        }
        // Any kind can be "still starting": "the tailnet" only when it is one.
        if kindKnown && message.contains("is still starting") { return .timeout }
        if kindKnown, message.contains("could not start"), let n { return .networkError(name: n, reason: tailscaleReason(message)) }
        if message.contains("outside the tailnet") || message.contains("no device named") { return tailnetDial(message) }
        return nil
    }

    /// An error of a Tailscale network `name` on its screens (Test,
    /// devices): what netd found (`netd_code` and `auth` of the error's
    /// details), with the network's name. `nil`: other errors, as usual.
    static func tailscaleError(code: String, detailsJson: String?, message: String?, name: String) -> TailnetMessage? {
        let d = detailsJson.flatMap(object) ?? [:]
        let netd = d["netd_code"] as? String ?? ""
        let msg = message ?? ""
        switch (code, netd) {
        case ("network_dial_failed", "needs_auth"): return d["auth"] as? String == "approval" ? .approval(name) : .login(name)
        case ("network_dial_failed", "network_error"): return .networkError(name: name, reason: tailscaleReason(msg))
        case ("network_dial_failed", "dial_failed") where !msg.trimmingCharacters(in: .whitespaces).isEmpty: return tailnetDial(msg)
        case ("network_dial_failed", "timeout"): return .timeout
        case ("network_dial_failed", "limit"): return .limit
        case ("network_unavailable", "unsupported_kind"): return .unsupported
        default: return nil
        }
    }

    /// Whether an error of the devices list means "log the server in first".
    static func needsLogin(code: String?, detailsJson: String?) -> Bool {
        code == "network_dial_failed" && (detailsJson.flatMap(object)?["netd_code"] as? String) == "needs_auth"
    }

    /// A failed host test through a tailnet (it carries no netd_code, only
    /// netd's English message), in words; `nil`: not a tailnet's.
    static func hostTestTailnet(_ t: HostTest) -> TailnetMessage? {
        guard t.errorCode == "network_dial_failed", t.networkKind == tailscale,
              let e = t.error, !e.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return tailscaleMessage(e, name: t.networkName, kindKnown: true) ?? tailnetDial(e)
    }

    // MARK: Peers → host addresses

    /// Addresses a host can be added at, from a peer's addresses (WireGuard:
    /// its allowed IPs): `10.9.0.5/32` is `10.9.0.5`; a subnet gives its
    /// start to complete; everything (`/0`) is none. Its DNS name first.
    static func hostAddresses(_ peer: NetPeer) -> [HostAddress] {
        var out: [HostAddress] = []
        var seen = Set<String>()
        for raw in peer.addresses {
            let a = raw.trimmingCharacters(in: .whitespaces)
            let parts = a.split(separator: "/", maxSplits: 1).map(String.init)
            let ip = parts.first ?? ""
            let bits = parts.count > 1 ? Int(parts[1]) : nil
            if bits == 0 { continue }
            let address: String
            let exact: Bool
            if let octets = ipv4(ip) {
                exact = bits == nil || bits! >= 32
                if exact {
                    address = octets.map(String.init).joined(separator: ".")
                } else {
                    let keep = min(max((bits! + 7) / 8, 1), 3)
                    address = octets.prefix(keep).map(String.init).joined(separator: ".") + "."
                }
            } else if isIpv6(ip) {
                exact = bits == nil || bits! >= 128
                address = ip.lowercased()
            } else {
                continue
            }
            if seen.insert(address).inserted { out.append(HostAddress(address: address, exact: exact, source: a)) }
        }
        if let dns = peer.dnsName?.trimmingCharacters(in: .whitespaces), !dns.isEmpty {
            let name = dns.hasSuffix(".") ? String(dns.dropLast()) : dns
            if seen.insert(name).inserted { out.insert(HostAddress(address: name, exact: true, source: dns), at: 0) }
        }
        return out
    }

    private static func ipv4(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let nums = parts.compactMap { p -> Int? in
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isNumber), let n = Int(p), n <= 255 else { return nil }
            return n
        }
        return nums.count == 4 ? nums : nil
    }

    private static func isIpv6(_ s: String) -> Bool {
        s.contains(":") && s.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
    }

    // MARK: The network of a host or group

    /// The group `groupId` (or its parents) that gives the hosts inside a
    /// network, and that network.
    static func inherited(_ groupId: String?, groups: [GroupLink]) -> InheritedNetwork? {
        var byId: [String: GroupLink] = [:]
        for g in groups { byId[g.id] = g }
        var seen = Set<String>()
        var g = groupId.flatMap { byId[$0] }
        while let cur = g, seen.insert(cur.id).inserted, seen.count <= maxDepth {
            if let n = cur.networkId { return InheritedNetwork(group: cur, networkId: n) }
            g = cur.parentId.flatMap { byId[$0] }
        }
        return nil
    }

    /// The network a host's (or group's) first connection goes through:
    /// its own, or the nearest group's.
    static func effective(own: String?, groupId: String?, groups: [GroupLink]) -> String? {
        own ?? inherited(groupId, groups: groups)?.networkId
    }

    /// The choices of the "Network" picker: first `nil` (the group's
    /// network, or direct), then the networks of the item's own vault
    /// (`(id, name, kind)`), then its network when it is not among them.
    static func choices(current: String?, groupId: String?, groups: [GroupLink],
                        sameVault: [(id: String, name: String, kind: String)]) -> [NetworkChoice] {
        let inh = inherited(groupId, groups: groups)
        let inhName = inh.flatMap { i in sameVault.first { $0.id == i.networkId }?.name }
        var out: [NetworkChoice] = [.inherit(groupName: inh?.group.name, networkId: inh?.networkId, networkName: inhName)]
        for n in sameVault.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
            out.append(.network(id: n.id, name: n.name, kind: n.kind))
        }
        if let current, !sameVault.contains(where: { $0.id == current }) { out.append(.missing(id: current)) }
        return out
    }

    // MARK: Errors

    /// The network error of an API error (its code, details JSON and
    /// message; `device`: a rule of the engine, status 0), or `nil`: not a
    /// network error (show it as usual).
    static func message(code: String, detailsJson: String?, message: String? = nil, device: Bool = false) -> NetworkMessage? {
        let d = detailsJson.flatMap(object) ?? [:]
        let netd = d["netd_code"] as? String ?? ""
        let max = int(d, "max").map(Int.init)
        let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch code {
        case "plan_limit":
            return d["limit"] as? String == "max_networks" ? .planLimit(max: max) : nil
        case "relay_limit": return .relayLimit(max: max)
        case "network_dial_failed":
            if netd == "needs_auth", let auth = d["auth"] as? String {
                return .tailnet(auth == "approval" ? .approval(nil) : .login(nil))
            }
            if ["dial_failed", "timeout", "needs_auth", "network_error", "limit", "invalid"].contains(netd) { return .netd(netd) }
            if netd == "unsupported_kind" { return .unsupportedKind }
            // Through the relay the engine keeps the server's message only.
            if let detail, detail.contains("relay_limit") { return .relayLimit(max: nil) }
            // Through the relay the engine keeps netd's English message only: a tailnet's says what happened.
            if let detail, let t = tailscaleMessage(detail, name: nil) { return .tailnet(t) }
            if let detail, !detail.isEmpty, device { return .dialFailedDetail(detail) }
            return .dialFailed
        case "network_unavailable":
            if netd == "unsupported_kind" { return .unsupportedKind }
            return device ? .unavailableHere : .unavailable
        case "unsupported_kind": return .unsupportedKind
        case "network_not_found": return .notFound
        case "key_exists": return .keyExists
        case "not_wireguard": return .notWireguard
        case "not_in_network": return .notInNetwork
        default: return nil
        }
    }

    /// Label of a network kind.
    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case wireguard: return "WireGuard"
        case tailscale: return "Tailscale"
        case zerotier: return "ZeroTier"
        default: return kind
        }
    }

    /// "1.2 MB" (decimal units, like the web).
    static func bytes(_ n: Int64) -> String {
        let p = Locale(identifier: "en_US_POSIX")
        if n < 1000 { return "\(n) B" }
        if n < 1_000_000 { return String(format: "%.1f kB", locale: p, Double(n) / 1000) }
        if n < 1_000_000_000 { return String(format: "%.1f MB", locale: p, Double(n) / 1_000_000) }
        return String(format: "%.2f GB", locale: p, Double(n) / 1_000_000_000)
    }

    /// "via Office" with the last test's latency when it went through that network.
    static func viaLatency(test: HostTest?, networkId: String) -> Int64? {
        guard let t = test, t.ok, let ms = t.latencyMs, t.networkId == nil || t.networkId == networkId else { return nil }
        return ms
    }
}
