import XCTest

/// Private networks (Termoak/Model/Networks.swift, NETWORKS.md §8.1): the
/// WireGuard .conf, the state in the server, peers → host addresses, the
/// network of a host and the editors' picker, and the network errors.
final class NetworksTests: XCTestCase {
    private let priv = "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="
    private let pub = "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg="
    private let psk = "FpCyhws9cxwWoV4xELtfJvjJN+zQVRPISllRWgeopVE="

    private func ok(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> WgConf {
        switch Networks.parse(text) {
        case .success(let c): return c
        case .failure(let e):
            XCTFail("\(e)", file: file, line: line)
            return WgConf()
        }
    }

    private func bad(_ text: String) -> ConfError? {
        if case .failure(let e) = Networks.parse(text) { return e }
        return nil
    }

    func testReadsAWgQuickConf() {
        let c = ok("""
        # made by the router
        [Interface]
        PrivateKey = \(priv)
        Address = 10.9.0.2/32, fd00::2/128
        address = 10.9.0.3/32
        DNS = 10.9.0.1, lan
        MTU = 1380
        ListenPort = 51820
        PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING

        [Peer]
        PublicKey = \(pub)
        PresharedKey = \(psk)
        Endpoint = vpn.example.com:51820
        AllowedIPs = 10.9.0.0/24
        AllowedIPs = 192.168.1.0/24 ; second line
        PersistentKeepalive = 25
        """)
        XCTAssertEqual(c.addresses, ["10.9.0.2/32", "fd00::2/128", "10.9.0.3/32"])
        XCTAssertEqual(c.dns, ["10.9.0.1", "lan"])
        XCTAssertEqual(c.mtu, 1380)
        XCTAssertEqual(c.privateKey, priv)
        XCTAssertEqual(c.presharedKey, psk)
        XCTAssertEqual(c.peers, [WgPeer(publicKey: pub, endpoint: "vpn.example.com:51820",
                                        allowedIps: ["10.9.0.0/24", "192.168.1.0/24"], keepalive: 25)])
        XCTAssertEqual(c.ignored, ["ListenPort", "PostUp"])
        XCTAssertNil(Networks.problem(c))
    }

    func testWithoutPrivateKeyTheServerGeneratesIt() {
        let c = ok("[Interface]\r\nAddress = 10.0.0.2/32\r\n\r\n[Peer]\r\nPublicKey = \(pub)\r\nEndpoint = [2001:db8::1]:51820\r\nAllowedIPs = 10.0.0.0/24\r\nPersistentKeepalive = off\r\n")
        XCTAssertNil(c.privateKey)
        XCTAssertNil(c.peers.first?.keepalive)
        XCTAssertNil(Networks.problem(c))
    }

    func testBadConfsSayWhy() {
        XCTAssertEqual(bad(""), .notAConf)
        XCTAssertEqual(bad("hello world"), .notAConf)
        XCTAssertEqual(bad("[Interface]\nnot a key value\n"), .badLine(2))
        XCTAssertEqual(bad("[Interface]\nAddress = 10.0.0.2/32\n"), .noPeer)
        XCTAssertEqual(bad("[Interface]\nAddress = 10.0.0.2/32\n[Peer]\nAllowedIPs = 10.0.0.0/24\n"), .peerWithoutKey)
        XCTAssertEqual(bad("[Interface]\nPrivateKey = secret-not-a-key\n[Peer]\nPublicKey = \(pub)\n"), .badKey("PrivateKey"))
        XCTAssertEqual(bad("[Interface]\n[Peer]\nPublicKey = abc=\n"), .badKey("PublicKey"))
        XCTAssertEqual(bad("[Interface]\nMTU = big\n[Peer]\nPublicKey = \(pub)\n"), .badNumber("MTU"))
        XCTAssertEqual(bad("[Interface]\n[Peer]\nPublicKey = \(pub)\nPersistentKeepalive = soon\n"), .badNumber("PersistentKeepalive"))
        let other = "aGVsbG9oZWxsb2hlbGxvaGVsbG9oZWxsb2hlbGxvaGk="
        XCTAssertTrue(Networks.validKey(other))
        XCTAssertEqual(bad("[Interface]\n[Peer]\nPublicKey = \(pub)\nPresharedKey = \(psk)\n[Peer]\nPublicKey = \(other)\nPresharedKey = \(other)\n"),
                       .mixedPresharedKeys)
        XCTAssertEqual(bad("[Interface]\n[Peer]\nPublicKey = \(pub)\nPresharedKey = \(psk)\n[Peer]\nPublicKey = \(other)\n"), .mixedPresharedKeys)
    }

    func testWhatStopsSaving() {
        let peer = WgPeer(publicKey: pub, endpoint: "vpn.example.com:51820", allowedIps: ["10.0.0.0/24"])
        XCTAssertEqual(Networks.problem(WgConf(addresses: [], peers: [peer])), .noAddress)
        XCTAssertEqual(Networks.problem(WgConf(addresses: ["10.0.0.2/32"], peers: [WgPeer(publicKey: pub, endpoint: "a:1")])), .noAllowedIps(1))
        var noPort = peer
        noPort.endpoint = "no-port"
        XCTAssertEqual(Networks.problem(WgConf(addresses: ["10.0.0.2/32"], peers: [peer, noPort])), .badEndpoint(2))
        var none = peer
        none.endpoint = nil
        XCTAssertEqual(Networks.problem(WgConf(addresses: ["10.0.0.2/32"], peers: [none])), .noEndpoint)
        XCTAssertTrue(Networks.validEndpoint("[fd00::1]:51820"))
        XCTAssertFalse(Networks.validEndpoint("host:70000"))
        XCTAssertFalse(Networks.validEndpoint("fd00::1:51820"))
    }

    func testNetworksOfTheApiAndTheirConfText() {
        let json = """
        [{"id":"n2","name":"lab","kind":"wireguard","vault_id":"v","has_secret":false,"wireguard":{"addresses":["10.1.0.2/32"],"peers":[]}},
         {"id":"n1","name":"Office","kind":"wireguard","vault_id":"v","has_secret":true,"future":1,
          "wireguard":{"addresses":["10.9.0.2/32"],"dns":["10.9.0.1"],"mtu":null,"public_key":"\(pub)",
          "peers":[{"public_key":"\(pub)","endpoint":"vpn:51820","allowed_ips":["10.9.0.0/24"],"persistent_keepalive":25}]}}]
        """
        let list = Networks.networks(json)
        XCTAssertEqual(list.map(\.name), ["lab", "Office"])
        let n = list[1]
        XCTAssertTrue(n.hasSecret)
        XCTAssertEqual(n.publicKey, pub)
        XCTAssertNil(n.mtu)
        XCTAssertEqual(n.peers, [WgPeer(publicKey: pub, endpoint: "vpn:51820", allowedIps: ["10.9.0.0/24"], keepalive: 25)])
        let text = Networks.confText(n, keyNote: "the key is kept")
        XCTAssertTrue(text.contains("# the key is kept"))
        XCTAssertFalse(text.contains("PrivateKey"))
        let again = ok(text)
        XCTAssertEqual(again.addresses, n.addresses)
        XCTAssertEqual(again.peers, n.peers)
        XCTAssertEqual(Networks.peerSnippet(name: "Office", publicKey: pub, addresses: ["10.9.0.2/32", "10.0.0.3"]),
                       "[Peer]\n# Termoak: Office\nPublicKey = \(pub)\nAllowedIPs = 10.9.0.2/32, 10.0.0.3/32")
    }

    func testBodiesKeepWhatTheServerSent() {
        let n = Networks.networks("[{\"id\":\"n1\",\"name\":\"Office\",\"kind\":\"wireguard\",\"future\":{\"x\":1},\"vault_id\":\"v\",\"wireguard\":{\"addresses\":[\"10.9.0.2/32\"],\"public_key\":\"\(pub)\",\"peers\":[]}}]")[0]
        let conf = WgConf(addresses: ["10.9.0.5/32"], peers: [WgPeer(publicKey: pub, endpoint: "vpn:1", allowedIps: ["10.9.0.0/24"], keepalive: 25)])
        let keep = Networks.object(Networks.body(base: n.json, vaultId: nil, name: "Office 2", description: "", conf: conf, secret: nil))!
        XCTAssertNil(keep["secret"])
        XCTAssertNil(keep["id"])
        XCTAssertEqual((keep["future"] as? [String: Any])?["x"] as? Int, 1)
        XCTAssertEqual(keep["name"] as? String, "Office 2")
        let wg = keep["wireguard"] as? [String: Any]
        XCTAssertNil(wg?["public_key"])
        XCTAssertEqual(wg?["addresses"] as? [String], ["10.9.0.5/32"])
        let created = Networks.object(Networks.body(base: nil, vaultId: "vault-1", name: "Lab", description: "x", conf: conf,
                                                    secret: (privateKey: priv, presharedKey: psk)))!
        XCTAssertEqual(created["vault_id"] as? String, "vault-1")
        XCTAssertEqual(created["kind"] as? String, "wireguard")
        XCTAssertEqual((created["secret"] as? [String: Any])?["private_key"] as? String, priv)
        let pskOnly = Networks.object(Networks.body(base: nil, vaultId: "v", name: "Lab", description: "", conf: conf,
                                                    secret: (privateKey: nil, presharedKey: psk)))!
        XCTAssertTrue((pskOnly["secret"] as? [String: Any])?["private_key"] is NSNull)
        let host = Networks.object(Networks.hostBody(label: "nas", address: "10.9.0.7", port: 2222, username: nil, network: n))!
        XCTAssertEqual(host["vault_id"] as? String, "v")
        XCTAssertEqual((host["settings"] as? [String: Any])?["network_id"] as? String, "n1")
        XCTAssertEqual((host["settings"] as? [String: Any])?["port"] as? Int, 2222)
    }

    func testStatesFromTheServer() {
        let up = Networks.status("{\"state\":\"up\",\"last_handshake_at\":1760000000000,\"rx_bytes\":1500,\"tx_bytes\":20,\"node\":{\"addresses\":[\"10.9.0.2\"]}}")
        XCTAssertEqual(Networks.state(up, kind: "wireguard"), .up)
        XCTAssertEqual(up?.nodeAddresses, ["10.9.0.2"])
        let waiting = Networks.status("{\"state\":\"up\"}")
        XCTAssertEqual(Networks.state(waiting, kind: "wireguard"), .waiting)
        XCTAssertEqual(Networks.state(waiting, kind: "tailscale"), .up)
        XCTAssertEqual(Networks.state(Networks.status("{\"state\":\"down\"}"), kind: "wireguard"), .down)
        XCTAssertEqual(Networks.state(Networks.status("{\"state\":\"error\",\"message\":\"bad key\"}"), kind: "wireguard"), .error)
        XCTAssertEqual(Networks.state(nil, kind: "wireguard"), .unknown)
        XCTAssertNil(Networks.status("not json"))
        XCTAssertEqual(Networks.bytes(1500), "1.5 kB")
        let usage = Networks.usage("{\"usage\":{\"networks\":3},\"plan\":{\"limits\":{\"max_networks\":10}}}")
        XCTAssertEqual(usage?.used, 3)
        XCTAssertEqual(usage?.max, 10)
        XCTAssertNil(Networks.usage("{\"usage\":{},\"plan\":{\"limits\":{\"max_networks\":null}}}")?.max)
        XCTAssertTrue(Networks.supported(infoJson: "{\"features\":{\"networks\":true}}"))
        XCTAssertFalse(Networks.supported(infoJson: "{\"features\":{}}"))
    }

    func testPeersGiveHostAddresses() {
        let peers = Networks.peers("""
        [{"name":"vpn.example.com:51820","addresses":["10.9.0.1/32","10.9.0.0/24","0.0.0.0/0","fd00::1/128","nonsense"],"online":true,"public_key":"\(pub)"},
         {"dns_name":"nas.tail1234.ts.net.","addresses":["100.64.0.7"]}]
        """)
        XCTAssertEqual(peers.count, 2)
        XCTAssertEqual(peers[0].title, "vpn.example.com:51820")
        XCTAssertEqual(Networks.hostAddresses(peers[0]), [
            HostAddress(address: "10.9.0.1", exact: true, source: "10.9.0.1/32"),
            HostAddress(address: "10.9.0.", exact: false, source: "10.9.0.0/24"),
            HostAddress(address: "fd00::1", exact: true, source: "fd00::1/128"),
        ])
        let b = Networks.hostAddresses(peers[1])
        XCTAssertEqual(b.first, HostAddress(address: "nas.tail1234.ts.net", exact: true, source: "nas.tail1234.ts.net."))
        XCTAssertEqual(b.last?.address, "100.64.0.7")
        XCTAssertEqual(NetPeer(publicKey: pub).title, "xTIBA5rboU…")
    }

    func testHostsInheritTheNetworkOfTheirGroups() {
        let groups = [
            GroupLink(id: "root", name: "Servers", parentId: nil, networkId: "net-office"),
            GroupLink(id: "web", name: "Web", parentId: "root", networkId: nil),
            GroupLink(id: "lab", name: "Lab", parentId: "root", networkId: "net-lab"),
            GroupLink(id: "loop1", name: "Loop 1", parentId: "loop2", networkId: nil),
            GroupLink(id: "loop2", name: "Loop 2", parentId: "loop1", networkId: nil),
        ]
        XCTAssertEqual(Networks.effective(own: nil, groupId: "web", groups: groups), "net-office")
        XCTAssertEqual(Networks.effective(own: nil, groupId: "lab", groups: groups), "net-lab")
        XCTAssertEqual(Networks.effective(own: "own", groupId: "web", groups: groups), "own")
        XCTAssertNil(Networks.effective(own: nil, groupId: nil, groups: groups))
        XCTAssertNil(Networks.effective(own: nil, groupId: "loop1", groups: groups))
        XCTAssertEqual(Networks.inherited("web", groups: groups)?.group.name, "Servers")
    }

    func testThePickerOffersTheSameVaultAndKeepsAMissingOne() {
        let groups = [GroupLink(id: "g", name: "Servers", parentId: nil, networkId: "n1")]
        let nets = [(id: "n2", name: "lab", kind: "wireguard"), (id: "n1", name: "Office", kind: "wireguard")]
        let c = Networks.choices(current: nil, groupId: "g", groups: groups, sameVault: nets)
        XCTAssertEqual(c.first, .inherit(groupName: "Servers", networkId: "n1", networkName: "Office"))
        XCTAssertNil(c.first?.id)
        XCTAssertEqual(c.dropFirst().map(\.id), ["n2", "n1"])
        XCTAssertEqual(Networks.choices(current: nil, groupId: nil, groups: groups, sameVault: nets).first,
                       .inherit(groupName: nil, networkId: nil, networkName: nil))
        let missing = Networks.choices(current: "gone", groupId: nil, groups: [], sameVault: nets)
        XCTAssertEqual(missing.last, .missing(id: "gone"))
        XCTAssertEqual(missing.count, 4)
        XCTAssertEqual(Networks.choices(current: nil, groupId: "g", groups: groups, sameVault: []).first,
                       .inherit(groupName: "Servers", networkId: "n1", networkName: nil))
    }

    func testNetworkErrors() {
        XCTAssertEqual(Networks.message(code: "plan_limit", detailsJson: "{\"limit\":\"max_networks\",\"max\":10}"), .planLimit(max: 10))
        XCTAssertEqual(Networks.message(code: "plan_limit", detailsJson: "{\"limit\":\"max_networks\"}"), .planLimit(max: nil))
        XCTAssertNil(Networks.message(code: "plan_limit", detailsJson: "{\"limit\":\"max_teams\",\"max\":3}"))
        XCTAssertEqual(Networks.message(code: "network_dial_failed", detailsJson: "{\"netd_code\":\"timeout\"}"), .netd("timeout"))
        XCTAssertEqual(Networks.message(code: "network_dial_failed", detailsJson: "{}"), .dialFailed)
        XCTAssertEqual(Networks.message(code: "network_unavailable", detailsJson: "{\"netd_code\":\"unsupported_kind\"}"), .unsupportedKind)
        XCTAssertEqual(Networks.message(code: "network_unavailable", detailsJson: "{}"), .unavailable)
        XCTAssertEqual(Networks.message(code: "network_not_found", detailsJson: nil), .notFound)
        XCTAssertEqual(Networks.message(code: "key_exists", detailsJson: nil), .keyExists)
        XCTAssertEqual(Networks.message(code: "not_wireguard", detailsJson: nil), .notWireguard)
        XCTAssertEqual(Networks.message(code: "relay_limit", detailsJson: "{\"max\":16}"), .relayLimit(max: 16))
        XCTAssertNil(Networks.message(code: "invalid_password", detailsJson: "{}"))
        // The engine's errors through the relay keep the server's message only.
        XCTAssertEqual(Networks.message(code: "network_dial_failed", detailsJson: "{}",
                                        message: "server relay to nas:22: the server responded 429 (relay_limit): too many", device: true),
                       .relayLimit(max: nil))
        XCTAssertEqual(Networks.message(code: "network_dial_failed", detailsJson: "{}", message: "connection refused", device: true),
                       .dialFailedDetail("connection refused"))
        XCTAssertEqual(Networks.message(code: "network_unavailable", detailsJson: "{}", message: "nas: sign in", device: true), .unavailableHere)
    }

    func testHostTests() {
        let ok = Networks.hostTest("{\"ok\":true,\"latency_ms\":23,\"network\":{\"id\":\"n1\",\"name\":\"Office\",\"kind\":\"wireguard\"}}")
        XCTAssertEqual(ok?.networkName, "Office")
        XCTAssertEqual(Networks.viaLatency(test: ok, networkId: "n1"), 23)
        XCTAssertNil(Networks.viaLatency(test: ok, networkId: "n2"))
        let unknown = Networks.hostTest("{\"ok\":false,\"error\":\"unknown key\",\"error_code\":\"host_key_unknown\",\"fingerprint\":\"SHA256:abc\"}")
        XCTAssertEqual(unknown?.fingerprint, "SHA256:abc")
        XCTAssertNil(Networks.viaLatency(test: unknown, networkId: "n1"))
    }
}
