import XCTest

/// Tailscale/Headscale networks (Termoak/Model/Networks.swift, NETWORKS.md
/// §8.1, phase 2b): the kinds the server joins, the form's body (ephemeral,
/// the key kept, replaced or removed, the default hostname), the core's
/// rules, the states, the devices → hosts (imported ones marked) and the
/// errors, also the ones host tests and connections only carry as netd's
/// English message.
final class TailscaleNetworksTests: XCTestCase {
    private let tailnetJson = """
    {"id":"0b9f3c2e-1111-4a5b-8c7d-12345678abcd","name":"Tailnet","kind":"tailscale","vault_id":"v1","description":"",
     "has_secret":true,"secret_hidden":false,"created_at":5,
     "tailscale":{"control_url":"https://hs.example.com","hostname":null,"tags":["tag:termoak"],"ephemeral":null,"future":"kept"}}
    """

    private func obj(_ json: String) -> [String: Any] { Networks.object(json) ?? [:] }

    func testTailscaleOnlyWhenTheServerListsIt() {
        XCTAssertEqual(Networks.kinds(infoJson: #"{"features":{"networks":true,"network_kinds":["tailscale","wireguard"]}}"#), ["tailscale", "wireguard"])
        // A server without the field (0.7.0-next.2): WireGuard only.
        XCTAssertEqual(Networks.kinds(infoJson: #"{"features":{"networks":true}}"#), ["wireguard"])
        XCTAssertEqual(Networks.kinds(infoJson: #"{"features":{"networks":false,"network_kinds":["tailscale"]}}"#), [])
        XCTAssertEqual(Networks.kinds(infoJson: "not json"), [])
    }

    func testReadsATailnet() {
        let n = Networks.network(tailnetJson)!
        XCTAssertTrue(n.isTailscale)
        XCTAssertEqual(n.tailscale, TsConfig(controlUrl: "https://hs.example.com", hostname: nil, tags: ["tag:termoak"], ephemeral: nil))
        XCTAssertEqual(Networks.controlServerLabel(n.tailscale?.controlUrl), "hs.example.com")
        XCTAssertEqual(Networks.controlServerLabel("http://hs.example.com:8080/x"), "hs.example.com:8080")
        XCTAssertEqual(Networks.controlServerLabel(nil), "Tailscale")
    }

    func testTheFormsBodySendsTheWholeNetworkBack() {
        let n = Networks.network(tailnetJson)!
        // Untouched ephemeral stays null; the key kept: no secret at all.
        let keep = obj(Networks.tailscaleBody(base: n.json, vaultId: nil, name: "Tailnet", description: "",
                                              ts: TsConfig(controlUrl: "https://hs.example.com/", tags: ["tag:termoak"]), secret: .keep))
        XCTAssertNil(keep["id"])
        XCTAssertNil(keep["secret"])
        let ts = keep["tailscale"] as? [String: Any] ?? [:]
        XCTAssertTrue(ts["ephemeral"] is NSNull)
        XCTAssertEqual(ts["control_url"] as? String, "https://hs.example.com")
        XCTAssertTrue(ts["hostname"] is NSNull)
        // What the server sent and this version doesn't know goes back too.
        XCTAssertEqual(ts["future"] as? String, "kept")
        XCTAssertEqual((keep["created_at"] as? NSNumber)?.intValue, 5)
        XCTAssertEqual(keep["kind"] as? String, "tailscale")
        // Remove the key: secret null (`{}` would store an empty secret and has_secret would stay true).
        let clear = obj(Networks.tailscaleBody(base: n.json, vaultId: nil, name: "Tailnet", description: "", ts: TsConfig(), secret: .clear))
        XCTAssertTrue(clear["secret"] is NSNull)
        XCTAssertTrue((clear["tailscale"] as? [String: Any])?["control_url"] is NSNull)
        // A new key, ephemeral changed by the user.
        let set = obj(Networks.tailscaleBody(base: nil, vaultId: "v1", name: "New", description: "d",
                                             ts: TsConfig(controlUrl: nil, hostname: " office-1 ", tags: ["tag:a"], ephemeral: false),
                                             secret: .set(" tskey-auth-k ")))
        XCTAssertEqual((set["secret"] as? [String: Any])?["auth_key"] as? String, "tskey-auth-k")
        XCTAssertEqual(set["vault_id"] as? String, "v1")
        XCTAssertEqual((set["tailscale"] as? [String: Any])?["hostname"] as? String, "office-1")
        XCTAssertEqual((set["tailscale"] as? [String: Any])?["ephemeral"] as? Bool, false)
        // A new network without a key: no secret.
        XCTAssertNil(obj(Networks.tailscaleBody(base: nil, vaultId: "v1", name: "New", description: "", ts: TsConfig(), secret: .keep))["secret"])
    }

    func testTheDefaultHostnameAndTags() {
        XCTAssertEqual(Networks.defaultHostname("0b9f3c2e-1111-4a5b-8c7d-12345678ABCD"), "termoak-5678abcd")
        XCTAssertEqual(Networks.defaultHostname(nil), "termoak-xxxxxxxx")
        XCTAssertEqual(Networks.parseTags("tag:a, tag:b\ntag:c ,"), ["tag:a", "tag:b", "tag:c"])
        XCTAssertEqual(Networks.cleanControlUrl(" https://hs.example.com// "), "https://hs.example.com")
    }

    func testTheCoresRulesBeforeSaving() {
        XCTAssertNil(Networks.tailscaleProblem(controlUrl: nil, hostname: "", tags: [], authKey: nil))
        XCTAssertNil(Networks.tailscaleProblem(controlUrl: "https://hs.example.com:8443/path", hostname: "termoak-office",
                                               tags: ["tag:termoak", "tag:a_b-1"], authKey: "hskey-auth-abc"))
        XCTAssertEqual(Networks.tailscaleProblem(controlUrl: "  ", hostname: nil, tags: [], authKey: nil), .controlUrlMissing)
        XCTAssertEqual(Networks.tailscaleProblem(controlUrl: "hs.example.com", hostname: nil, tags: [], authKey: nil), .controlUrl)
        XCTAssertEqual(Networks.tailscaleProblem(controlUrl: "https://user@hs.example.com", hostname: nil, tags: [], authKey: nil), .controlUrl)
        XCTAssertEqual(Networks.tailscaleProblem(controlUrl: "https://hs.example.com/?x=1", hostname: nil, tags: [], authKey: nil), .controlUrl)
        XCTAssertEqual(Networks.tailscaleProblem(controlUrl: "https:///x", hostname: nil, tags: [], authKey: nil), .controlUrl)
        XCTAssertEqual(Networks.tailscaleProblem(controlUrl: nil, hostname: "-office", tags: [], authKey: nil), .hostname)
        XCTAssertEqual(Networks.tailscaleProblem(controlUrl: nil, hostname: String(repeating: "a", count: 64), tags: [], authKey: nil), .hostname)
        XCTAssertEqual(Networks.tailscaleProblem(controlUrl: nil, hostname: nil, tags: ["termoak"], authKey: nil), .tags)
        XCTAssertEqual(Networks.tailscaleProblem(controlUrl: nil, hostname: nil, tags: ["tag:-x"], authKey: nil), .tags)
        XCTAssertEqual(Networks.tailscaleProblem(controlUrl: nil, hostname: nil, tags: (1...21).map { "tag:t\($0)" }, authKey: nil), .tagsMax)
        XCTAssertEqual(Networks.tailscaleProblem(controlUrl: nil, hostname: nil, tags: [], authKey: "has space"), .authKey)
        XCTAssertEqual(Networks.tailscaleProblem(controlUrl: nil, hostname: nil, tags: [], authKey: "ñ"), .authKey)
    }

    func testStatesOfATailnet() {
        let ts = Networks.tailscale
        // No handshake in a tailnet: up is connected.
        XCTAssertEqual(Networks.state(NetStatus(state: "up"), kind: ts), .up)
        XCTAssertEqual(Networks.state(NetStatus(state: "up"), kind: Networks.wireguard), .waiting)
        XCTAssertEqual(Networks.state(NetStatus(state: "needs_auth", auth: "login"), kind: ts), .needsLogin)
        XCTAssertEqual(Networks.state(NetStatus(state: "needs_auth"), kind: ts), .needsLogin)
        XCTAssertEqual(Networks.state(NetStatus(state: "needs_auth", auth: "approval"), kind: ts), .needsApproval)
        XCTAssertEqual(Networks.state(NetStatus(state: "needs_auth", auth: "approval"), kind: Networks.zerotier), .needsAuth)
        XCTAssertEqual(Networks.state(NetStatus(state: "starting"), kind: ts), .starting)
        let st = Networks.status("""
        {"state":"up","control_url":"https://hs.example.com","tailnet":"qa","magic_dns_suffix":"ts.qa.test","peer_count":4,
         "ephemeral":true,"last_error":null,"node":{"name":"termoak-5678abcd","dns_name":"termoak-5678abcd.ts.qa.test.",
         "addresses":["100.64.0.3","fd7a:115c:a1e0::3"],"node_id":"nX","auth_url":"https://hs.example.com/register/abc"},"rx_bytes":10}
        """)!
        XCTAssertEqual(st.peerCount, 4)
        XCTAssertEqual(st.ephemeral, true)
        XCTAssertEqual(st.nodeName, "termoak-5678abcd")
        XCTAssertEqual(st.nodeId, "nX")
        XCTAssertEqual(st.authUrl, "https://hs.example.com/register/abc")
        XCTAssertNil(st.lastError)
        XCTAssertEqual(Networks.tailnetSummary(st) { "\($0) devices" }, "100.64.0.3 · 4 devices")
        XCTAssertEqual(Networks.tailnetSummary(NetStatus(state: "up")) { "\($0) devices" }, "0 devices")
    }

    func testDevicesBecomeHostsAndAddedOnesAreMarked() {
        let peers = Networks.peers("""
        [{"name":"nas","dns_name":"nas.ts.qa.test.","addresses":["100.64.0.5","fd7a::5"],"os":"linux","online":true,"tags":["tag:srv"],"routes":["192.168.10.0/24","0.0.0.0/0","::/0"]},
         {"name":"laptop","dns_name":"laptop.ts.qa.test.","addresses":["100.64.0.6"],"online":false,"last_seen":1000},
         {"name":"phone","addresses":["100.64.0.7/32"]},
         {"name":"ghost"}]
        """)
        let nas = peers[0]
        XCTAssertEqual(nas.deviceAddress, "nas.ts.qa.test")
        XCTAssertEqual(nas.hostRoutes, ["192.168.10.0/24"])
        XCTAssertEqual(nas.tags, ["tag:srv"])
        XCTAssertEqual(nas.os, "linux")
        XCTAssertEqual(peers[2].deviceAddress, "100.64.0.7")
        XCTAssertNil(peers[3].deviceAddress)
        // A host of the same network by MagicDNS name, short label, an IP or the device's name.
        let n = "n1"
        XCTAssertEqual(Networks.importedHost(nas, networkId: n, hosts: [HostRef(id: "h1", label: "x", address: "NAS.ts.qa.test.", networkId: n)])?.id, "h1")
        XCTAssertEqual(Networks.importedHost(nas, networkId: n, hosts: [HostRef(id: "h1", label: "x", address: "nas", networkId: n)])?.id, "h1")
        XCTAssertEqual(Networks.importedHost(nas, networkId: n, hosts: [HostRef(id: "h1", label: "x", address: "fd7a::5", networkId: n)])?.id, "h1")
        XCTAssertEqual(Networks.importedHost(peers[1], networkId: n, hosts: [HostRef(id: "h1", label: "laptop", address: "10.0.0.9", networkId: n)])?.id, "h1")
        // Another network, or direct: not this device's host.
        XCTAssertNil(Networks.importedHost(nas, networkId: n, hosts: [HostRef(id: "h1", label: "nas", address: "nas.ts.qa.test", networkId: "n2")]))
        XCTAssertNil(Networks.importedHost(nas, networkId: n, hosts: [HostRef(id: "h1", label: "nas", address: "nas.ts.qa.test", networkId: nil)]))
        // "Add N hosts": the ones not added yet and with an address.
        let hosts = [HostRef(id: "h1", label: "nas", address: "nas.ts.qa.test", networkId: n)]
        XCTAssertEqual(Networks.newDevices(peers, networkId: n, hosts: hosts).map(\.name), ["laptop", "phone"])
        XCTAssertEqual(Networks.sortDevices(peers).map(\.name), ["nas", "ghost", "laptop", "phone"])
        // The host it makes: its name, its MagicDNS name, port 22, in the network's vault.
        let net = Networks.network(tailnetJson)!
        let body = obj(Networks.deviceHostBody(peers[1], network: net)!)
        XCTAssertEqual(body["label"] as? String, "laptop")
        XCTAssertEqual(body["address"] as? String, "laptop.ts.qa.test")
        XCTAssertEqual(((body["settings"] as? [String: Any])?["port"] as? NSNumber)?.intValue, 22)
        XCTAssertEqual((body["settings"] as? [String: Any])?["network_id"] as? String, net.id)
        XCTAssertEqual(body["vault_id"] as? String, "v1")
        XCTAssertEqual(Networks.hostRefs("""
        [{"id":"h1","label":"nas","address":"nas.ts.qa.test","settings":{"network_id":"n1"}},{"id":"h2","label":"web","address":"10.0.0.1","settings":{}}]
        """), [HostRef(id: "h1", label: "nas", address: "nas.ts.qa.test", networkId: "n1"),
               HostRef(id: "h2", label: "web", address: "10.0.0.1", networkId: nil)])
    }

    func testErrorsOfATailnetByNetdCodeAndAuth() {
        func t(_ code: String, _ d: String, _ m: String?) -> TailnetMessage? {
            Networks.tailscaleError(code: code, detailsJson: d, message: m, name: "Tailnet")
        }
        XCTAssertEqual(t("network_dial_failed", #"{"netd_code":"needs_auth","auth":"login"}"#, nil), .login("Tailnet"))
        XCTAssertEqual(t("network_dial_failed", #"{"netd_code":"needs_auth","auth":"approval"}"#, nil), .approval("Tailnet"))
        XCTAssertEqual(t("network_dial_failed", #"{"netd_code":"network_error"}"#,
                         #"the network "Tailnet" could not start: the control server refused the auth key: invalid key"#),
                       .networkError(name: "Tailnet", reason: "the control server refused the auth key: invalid key"))
        XCTAssertEqual(t("network_dial_failed", #"{"netd_code":"dial_failed"}"#, "8.8.8.8 is outside the tailnet (no device has that address or routes its subnet)"),
                       .dial("8.8.8.8 is outside the tailnet (no device has that address or routes its subnet).", aclHint: true))
        XCTAssertEqual(t("network_dial_failed", #"{"netd_code":"dial_failed"}"#, "connection refused"), .dial("Connection refused.", aclHint: false))
        XCTAssertEqual(t("network_dial_failed", #"{"netd_code":"timeout"}"#, "x"), .timeout)
        XCTAssertEqual(t("network_dial_failed", #"{"netd_code":"limit"}"#, "x"), .limit)
        XCTAssertEqual(t("network_unavailable", #"{"netd_code":"unsupported_kind"}"#, "x"), .unsupported)
        XCTAssertNil(t("plan_limit", #"{"limit":"max_networks"}"#, nil))
        // The generic texts (any screen) with the details' auth.
        XCTAssertEqual(Networks.message(code: "network_dial_failed", detailsJson: #"{"netd_code":"needs_auth","auth":"login"}"#), .tailnet(.login(nil)))
        XCTAssertEqual(Networks.message(code: "network_dial_failed", detailsJson: #"{"netd_code":"needs_auth","auth":"approval"}"#), .tailnet(.approval(nil)))
        // Without auth (other kinds): as before.
        XCTAssertEqual(Networks.message(code: "network_dial_failed", detailsJson: #"{"netd_code":"needs_auth"}"#), .netd("needs_auth"))
        // The devices list: "log the server in first".
        XCTAssertTrue(Networks.needsLogin(code: "network_dial_failed", detailsJson: #"{"netd_code":"needs_auth","auth":"login"}"#))
        XCTAssertFalse(Networks.needsLogin(code: "network_dial_failed", detailsJson: #"{"netd_code":"timeout"}"#))
    }

    func testHostTestsAndConnectionsOnlyCarryNetdsMessage() {
        func test(_ error: String) -> HostTest {
            HostTest(ok: false, error: error, errorCode: "network_dial_failed", networkName: "Tailnet", networkKind: "tailscale")
        }
        XCTAssertEqual(Networks.hostTestTailnet(test(#"the network "Tailnet" waits for authorization: the node must be logged in: open the login URL"#)),
                       .login("Tailnet"))
        // The approval message says "logged in" too: it is still an approval.
        XCTAssertEqual(Networks.hostTestTailnet(test(#"the network "Tailnet" waits for authorization: the node is logged in but must be approved: approve it in the tailnet's admin console (Machines) or with headscale"#)),
                       .approval("Tailnet"))
        XCTAssertEqual(Networks.hostTestTailnet(test(#"the network "Tailnet" is still starting: joining"#)), .timeout)
        XCTAssertEqual(Networks.hostTestTailnet(test(#"the network "Tailnet" could not start: the control server refused the auth key: bad"#)),
                       .networkError(name: "Tailnet", reason: "the control server refused the auth key: bad"))
        XCTAssertEqual(Networks.hostTestTailnet(test("there is no device named nas in the tailnet (or it is not shared with the server's node)")),
                       .dial("There is no device named nas in the tailnet (or it is not shared with the server's node).", aclHint: true))
        XCTAssertEqual(Networks.hostTestTailnet(test("dial tcp: refused")), .dial("Dial tcp: refused.", aclHint: false))
        // A WireGuard network keeps the old texts.
        XCTAssertNil(Networks.hostTestTailnet(HostTest(ok: false, error: "x", errorCode: "network_dial_failed", networkKind: "wireguard")))
        XCTAssertEqual(Networks.hostTest(#"{"ok":false,"error_code":"network_dial_failed","network":{"id":"n1","name":"T","kind":"tailscale"}}"#)?.networkKind,
                       "tailscale")
        // Connections through the relay: the engine's error keeps the server's message only (status 0).
        XCTAssertEqual(Networks.message(code: "network_dial_failed", detailsJson: "{}",
                                        message: #"the network "Tailnet" waits for authorization: the node must be logged in: open the login URL"#, device: true),
                       .tailnet(.login("Tailnet")))
        XCTAssertEqual(Networks.message(code: "network_dial_failed", detailsJson: "{}", message: "127.0.0.1 is outside the tailnet", device: true),
                       .tailnet(.dial("127.0.0.1 is outside the tailnet.", aclHint: true)))
        // "Still starting" without the kind is any network's: the old text with netd's words.
        XCTAssertEqual(Networks.message(code: "network_dial_failed", detailsJson: "{}", message: #"the network "Office" is still starting: x"#, device: true),
                       .dialFailedDetail(#"the network "Office" is still starting: x"#))
        XCTAssertEqual(Networks.tailscaleReason(#"the network "A" could not start: the control server refused the auth key: bad"#),
                       "the control server refused the auth key: bad")
    }
}
