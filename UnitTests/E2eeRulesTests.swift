import XCTest

/// E2EE, SSO and audit rules of the app (0.7 phase 5c).
final class E2eeRulesTests: XCTestCase {
    /// Made up (never a real account's phrase).
    let phrase = "abandon math mimic master filter design carbon crystal rookie group knife wrap absurd much snack melt grid rough chapter fever rubber humble room trophy"
    let words = ["abandon", "ability", "able", "absurd", "carbon", "chapter", "crystal", "design", "fever", "filter", "grid", "group", "humble",
                 "knife", "master", "math", "melt", "mimic", "much", "rookie", "room", "rough", "rubber", "snack", "trophy", "wrap"].sorted()

    func testPhraseGridAndDocument() {
        let n = E2eeRules.numberedWords(phrase)
        XCTAssertEqual(n.count, 24)
        XCTAssertEqual(n.first?.1, "abandon")
        XCTAssertEqual(n.last?.0, 24)
        let doc = E2eeRules.document(phrase, title: "T", account: "Account: ana@example.com", date: "Made on 2026-10-27", keep: "Keep it.")
        XCTAssertTrue(doc.contains(" 1. abandon"), doc)
        XCTAssertTrue(doc.contains("24. trophy"))
        XCTAssertEqual(E2eeRules.documentLines(phrase).count, 6)
        let page = E2eeRules.printPage(phrase, title: "T", account: "a<b>@x", date: "d", keep: "k")
        XCTAssertTrue(page.contains("a&lt;b&gt;@x"))
        XCTAssertTrue(page.contains("<span>24</span> trophy"))
    }

    func testConfirmationWords() {
        for seed: UInt64 in [1, 2, 99, UInt64.max, 0xdead_beef] {
            let p = E2eeRules.confirmPositions(seed)
            XCTAssertEqual(p.count, 3)
            XCTAssertTrue(p[0] < p[1] && p[1] < p[2] && p[2] < 24)
        }
        let pos = [0, 5, 23]
        XCTAssertTrue(E2eeRules.confirmMatches(phrase, pos, ["ABANDON", " design ", "trophy"]))
        XCTAssertTrue(E2eeRules.confirmMatches(phrase, pos, ["aban", "desi", "trop"]))
        XCTAssertFalse(E2eeRules.confirmMatches(phrase, pos, ["aba", "desi", "trop"]))
        XCTAssertFalse(E2eeRules.confirmMatches(phrase, pos, ["math", "design", "trophy"]))
    }

    func testLiveFeedbackAndSuggestions() {
        func check(_ valid: Bool, _ reason: String = "", _ n: Int = 0, _ word: Int = 0) -> (String) -> RecoveryCheck {
            { _ in RecoveryCheck(valid: valid, reason: reason, words: n, word: word) }
        }
        XCTAssertEqual(E2eeRules.feedback(" ", check: check(false, "word_count"), wordlist: words), .empty)
        XCTAssertEqual(E2eeRules.feedback(phrase, check: check(true), wordlist: words), .valid)
        XCTAssertEqual(E2eeRules.feedback("abandon math mi", check: check(false, "word_count", 3), wordlist: words), .typing(3))
        XCTAssertEqual(E2eeRules.feedback("abandon qqqq math", check: check(false, "word_count", 3), wordlist: words), .problem(reason: "unknown_word", word: 2, words: 3))
        XCTAssertEqual(E2eeRules.feedback(phrase, check: check(false, "checksum", 24), wordlist: words), .problem(reason: "checksum", word: 0, words: 24))
        XCTAssertNil(E2eeRules.firstUnknownWord("aban math mimi ", wordlist: words))
        XCTAssertEqual(E2eeRules.firstUnknownWord("abandon zz ", wordlist: words), 2)
        XCTAssertEqual(E2eeRules.tokens("1) ABANDON\n2) Math."), ["abandon", "math"])
        XCTAssertEqual(E2eeRules.suggestions("ab", wordlist: words), ["abandon", "ability", "able", "absurd"])
        XCTAssertEqual(E2eeRules.suggestions("knife ", wordlist: words), [])
        XCTAssertEqual(E2eeRules.complete("abandon ma", "math"), "abandon math ")
        XCTAssertEqual(E2eeRules.complete("ma", "math"), "math ")
    }

    func testPassphraseAndPairing() {
        XCTAssertEqual(E2eeRules.strength("short"), .tooShort)
        XCTAssertEqual(E2eeRules.strength("aaaaaaaaaaaa"), .weak)
        XCTAssertTrue(E2eeRules.strength("correct horse battery staple") >= .good)
        XCTAssertTrue(E2eeRules.passphraseOk("", "", required: false))
        XCTAssertFalse(E2eeRules.passphraseOk("", "", required: true))
        XCTAssertFalse(E2eeRules.passphraseOk("12345678", "12345679", required: true))
        XCTAssertEqual(E2eeRules.pairingLeft(expiresAt: 70_000, now: 0), "1:10")
        XCTAssertEqual(E2eeRules.pairingLeft(expiresAt: 0, now: 5_000), "0:00")
        XCTAssertEqual(E2eeRules.spacedCode("482913"), "482 913")
    }

    func testVaultStates() {
        let e = VaultE2eeFlags(keyVersion: 2, mayHoldKey: true, hasWrap: true, rekeyNeeded: false, pendingMembers: 0)
        XCTAssertEqual(E2eeRules.badge(nil, unlocked: true), .none)
        XCTAssertEqual(E2eeRules.badge(e, unlocked: true), .e2ee)
        XCTAssertEqual(E2eeRules.badge(e, unlocked: false), .locked)
        var noKey = e; noKey.mayHoldKey = false; noKey.hasWrap = false
        XCTAssertEqual(E2eeRules.badge(noKey, unlocked: false), .e2ee)
        XCTAssertEqual(E2eeRules.keyState(noKey, setUp: true, unlocked: true), .noKeyRole)
        var waiting = e; waiting.hasWrap = false
        XCTAssertEqual(E2eeRules.keyState(waiting, setUp: false, unlocked: false), .setUpFirst)
        XCTAssertEqual(E2eeRules.keyState(waiting, setUp: true, unlocked: true), .waiting)
        XCTAssertEqual(E2eeRules.keyState(e, setUp: true, unlocked: false), .unlockFirst)
        XCTAssertEqual(E2eeRules.keyState(e, setUp: true, unlocked: true), .holder)
        var flagged = e; flagged.rekeyNeeded = true
        XCTAssertTrue(E2eeRules.shouldRotate(flagged, unlocked: true))
        XCTAssertFalse(E2eeRules.shouldRotate(flagged, unlocked: false))
        XCTAssertFalse(E2eeRules.shouldRotate(e, unlocked: true))
        var pending = e; pending.pendingMembers = 2
        XCTAssertTrue(E2eeRules.hasPending(pending, unlocked: true))
        XCTAssertEqual(E2eeRules.errorCodes.count, 38)
    }

    func testSsoCallbacksAndPkce() {
        XCTAssertTrue(SsoRules.isCallback("termoak://sso?code=abc&state=xyz"))
        XCTAssertFalse(SsoRules.isCallback("termoak://join/abc"))
        XCTAssertFalse(SsoRules.isCallback(nil))
        XCTAssertEqual(SsoRules.query("termoak://sso?code=a%2Bb&state=s1")["code"], "a+b")
        XCTAssertEqual(SsoRules.linkResult("termoak://sso?code=c&state=s1", state: "s1"), .linked)
        XCTAssertEqual(SsoRules.linkResult("termoak://sso?code=c&state=x", state: "s1"), .failed("sso_state_invalid"))
        XCTAssertEqual(SsoRules.linkResult("termoak://sso?error=sso_identity_taken&state=s1", state: "s1"), .failed("sso_identity_taken"))
        // FIPS 180-4 and RFC 7636 appendix B.
        XCTAssertEqual(Sha256.hash(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined(),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SsoRules.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(SsoRules.token().count, 43)
        let body = SsoRules.linkBody(teamId: "t1", state: "s", verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", deviceName: "iPhone")
        XCTAssertTrue(body.contains("\"redirect_uri\":\"termoak:\\/\\/sso\"") || body.contains("\"redirect_uri\":\"termoak://sso\""), body)
        XCTAssertTrue(body.contains("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"))
        XCTAssertFalse(body.contains("dBjftJeZ"))
        XCTAssertTrue(SsoRules.looksLikeEmail("ana@corp.example"))
        XCTAssertFalse(SsoRules.looksLikeEmail("ana@corp"))
    }

    func testSsoFormAndDomains() {
        var f = SsoRules.newForm("microsoft")
        XCTAssertFalse(f.requireEmailVerified)
        XCTAssertEqual(try? SsoRules.check(f, hasSecret: false, canEnforce: false).get(), nil)
        if case .failure(let e) = SsoRules.check(f, hasSecret: false, canEnforce: false) { XCTAssertEqual(e.key, "sso.form.client_id_required") }
        f.clientId = " c "
        if case .failure(let e) = SsoRules.check(f, hasSecret: false, canEnforce: false) { XCTAssertEqual(e.key, "sso.form.tenant_required") }
        f.tenant = "tid"; f.enforce = true; f.scopes = "offline_access, email"; f.clientSecret = "s3"
        let ok = try! SsoRules.check(f, hasSecret: false, canEnforce: false).get()
        XCTAssertEqual(ok.form.clientId, "c")
        XCTAssertEqual(ok.tenant, "tid")
        XCTAssertEqual(ok.issuer, "")
        XCTAssertEqual(ok.scopes, ["openid", "email", "profile", "offline_access"])
        XCTAssertFalse(ok.enforce)
        XCTAssertEqual(ok.secret, "s3")
        var g = SsoRules.newForm("google"); g.clientId = "c"
        if case .failure(let e) = SsoRules.check(g, hasSecret: false, canEnforce: true) { XCTAssertEqual(e.key, "sso.form.secret_required_google") }
        XCTAssertNotNil(try? SsoRules.check(g, hasSecret: true, canEnforce: true).get())
        XCTAssertEqual(SsoRules.extraScopes(["openid", "email", "profile", "groups"]), "groups")
        XCTAssertEqual(SsoRules.zoneLine(name: "_termoak-challenge.corp.example", value: "termoak-verify=abc"),
                       "_termoak-challenge.corp.example. 300 IN TXT \"termoak-verify=abc\"")
        XCTAssertTrue(SsoRules.domainValid("corp.example"))
        XCTAssertFalse(SsoRules.domainValid("localhost"))
        XCTAssertFalse(SsoRules.domainValid("-bad.example"))
        XCTAssertEqual(SsoRules.domainState(verified: false, lastError: "no TXT"), .failed)
        XCTAssertEqual(SsoRules.domainState(verified: true, lastError: nil), .verified)
    }

    func testAudit() {
        let now: Int64 = 1_800_000_000_000
        let q = AuditFilters(preset: .sso, actions: "vault.*, e2ee.unlock", actor: " ana@example.com ", range: .week, text: " db ").query(now: now)
        XCTAssertEqual(q.action, "sso.*,auth.login_refused,vault.*,e2ee.unlock")
        XCTAssertEqual(q.actor, "ana@example.com")
        XCTAssertEqual(q.since, now - 7 * 86_400_000)
        XCTAssertEqual(q.text, "db")
        XCTAssertEqual(q.limit, 50)
        XCTAssertNil(AuditFilters().query(now: now).action)
        XCTAssertNil(AuditFilters(preset: .e2ee).exportQuery(now: now).limit)
        XCTAssertEqual(AuditRules.nextBefore(lastId: 9, lastPage: 50), 9)
        XCTAssertNil(AuditRules.nextBefore(lastId: 9, lastPage: 10))
        XCTAssertEqual(AuditRules.exportName(scope: "Ops Team", format: "csv", date: "2026-10-27"), "termoak-audit-ops-team-2026-10-27.csv")
        XCTAssertEqual(AuditRules.exportName(scope: "***", format: "json", date: "2026-10-27"), "termoak-audit-audit-2026-10-27.json")
        XCTAssertEqual(AuditRules.detailSummary("{\"device\":\"Pixel\",\"none\":null,\"list\":[],\"reason\":\"lost\"}"), "device: Pixel · reason: lost")
        XCTAssertEqual(AuditRules.parseRetention(" ", max: 3650), .ok(nil))
        XCTAssertEqual(AuditRules.parseRetention("90", max: 3650), .ok(90))
        XCTAssertEqual(AuditRules.parseRetention("0", max: 3650), .invalid)
        XCTAssertEqual(AuditRules.retentionView("{\"retention_days\":30,\"default_retention_days\":365,\"max_retention_days\":3650}")?.days, 30)
        XCTAssertNil(AuditRules.retentionView("{\"retention_days\":null,\"default_retention_days\":365,\"max_retention_days\":3650}")?.days)
        let f = AuditRules.features("{\"features\":{\"audit_v2\":{\"export\":[\"csv\",\"json\",\"ndjson\"],\"retention\":true,\"sinks\":[\"webhook\",\"syslog\"]}}}")
        XCTAssertEqual(f?.exports, ["csv", "json", "ndjson"])
        XCTAssertNil(AuditRules.features("{\"features\":{}}"))
        XCTAssertEqual(AuditRules.sinkTarget(kind: "syslog", url: nil, host: "siem.example", port: nil, transport: "tls"), "syslog+tls://siem.example:6514")
        XCTAssertEqual(AuditRules.sinkTarget(kind: "syslog", url: nil, host: "siem.example", port: nil, transport: "tcp"), "syslog://siem.example:514")
        XCTAssertEqual(AuditRules.sinkState(enabled: false, failures: 3, lastSuccessAt: nil), .paused)
        XCTAssertEqual(AuditRules.sinkState(enabled: true, failures: 3, lastSuccessAt: 1), .failing)
        XCTAssertEqual(AuditRules.sinkState(enabled: true, failures: 0, lastSuccessAt: 1), .delivered)
        XCTAssertEqual(AuditRules.actor("user:u1", names: ["u1": "ana"]), "ana")
        for a in ["e2ee.setup", "e2ee.unlock", "sso.login", "auth.login_refused", "audit.export", "auth.login", "secret.reveal"] {
            XCTAssertNotNil(AuditRules.actionKey(a), a)
        }
    }

    /// The shared vectors (core `e2ee_vectors.json`): the fingerprint and the pairing code from their definitions.
    func testSharedVectors() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = here.appendingPathComponent("core/crates/termoak-core/tests/e2ee_vectors.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("no core checkout next to the tests") }
        let v = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let uk = v["user_key"] as! [String: Any]
        let pub = [UInt8](Data(base64Encoded: uk["public_b64"] as! String)!)
        let fp = Sha256.hash(pub).prefix(16).map { String(format: "%02x", $0) }.joined()
        let groups = stride(from: 0, to: 32, by: 4).map { i -> String in let s = fp.index(fp.startIndex, offsetBy: i); return String(fp[s..<fp.index(s, offsetBy: 4)]) }
        XCTAssertEqual(groups.joined(separator: " "), uk["fingerprint"] as? String)
        let p = v["pairing"] as! [String: Any]
        let input = Array("termoak:e2ee:pairing-code:v1:\(p["pairing_id"] as! String):".utf8) + [UInt8](Data(base64Encoded: p["device_public_b64"] as! String)!)
        let h = Sha256.hash(input)
        let n = (UInt32(h[0]) << 24 | UInt32(h[1]) << 16 | UInt32(h[2]) << 8 | UInt32(h[3])) % 1_000_000
        XCTAssertEqual(String(format: "%06d", n), p["code"] as? String)
    }
}
