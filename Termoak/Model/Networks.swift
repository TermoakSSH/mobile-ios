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
    /// Running, and the other side answered.
    case up
    case needsAuth
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

    var isWireguard: Bool { kind == Networks.wireguard }
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

    var id: String { (publicKey ?? "") + (name ?? "") + (dnsName ?? "") + addresses.joined(separator: ",") }

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
            nodeAddresses: strings((o["node"] as? [String: Any])?["addresses"])
        )
    }

    /// The state shown: `up` without a WireGuard handshake is "waiting".
    static func state(_ s: NetStatus?, kind: String) -> NetState {
        guard let s else { return .unknown }
        switch s.state {
        case "down": return .down
        case "starting": return .starting
        case "needs_auth": return .needsAuth
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
            json: text(o)
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
                    publicKey: str(p, "public_key"), endpoint: str(p, "endpoint"))
        }
    }

    static func hostTest(_ json: String) -> HostTest? {
        guard let o = object(json) else { return nil }
        let net = o["network"] as? [String: Any]
        return HostTest(ok: o["ok"] as? Bool ?? false, latencyMs: int(o, "latency_ms"), fingerprint: str(o, "fingerprint"),
                        error: str(o, "error"), errorCode: str(o, "error_code"),
                        networkId: net.flatMap { str($0, "id") }, networkName: net.flatMap { str($0, "name") })
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
            if ["dial_failed", "timeout", "needs_auth", "network_error", "limit", "invalid"].contains(netd) { return .netd(netd) }
            if netd == "unsupported_kind" { return .unsupportedKind }
            // Through the relay the engine keeps the server's message only.
            if let detail, detail.contains("relay_limit") { return .relayLimit(max: nil) }
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
