import XCTest

/// Teams security rules of the app (0.7 phase 4d, TEAMS-SECURITY.md §13.2),
/// the same cases as the Android app's AccessRulesTest.
final class AccessRulesTests: XCTestCase {
    private let now: Int64 = 1_800_000_000_000

    func testRolesAndDeleting() {
        XCTAssertTrue(AccessLevel.connectOnly < .useOnly && AccessLevel.useOnly < .editor && AccessLevel.editor < .manager)
        XCTAssertEqual(AccessRules.grantableRoles(teamsSecurity: true), [.connectOnly, .useOnly, .editor, .manager])
        XCTAssertEqual(AccessRules.grantableRoles(teamsSecurity: false), [.useOnly, .editor])
        XCTAssertFalse(AccessRules.canDeleteVault(.manager, implicitManager: false))
        XCTAssertTrue(AccessRules.canDeleteVault(.manager, implicitManager: true))
        XCTAssertFalse(AccessRules.canDeleteVault(.editor, implicitManager: true))
        XCTAssertTrue(AccessLevel.connectOnly.noSecrets && AccessLevel.useOnly.noSecrets && !AccessLevel.editor.noSecrets)
    }

    func testGates() {
        XCTAssertEqual(AccessRules.gates(.editor, nil), AccessGates(reveal: true, ai: true, networks: true, recorded: false, accessRules: false, certificates: false))
        XCTAssertFalse(AccessRules.gates(.useOnly, nil).reveal)
        let noReveal = VaultPolicyFlags(revealAllowed: false)
        XCTAssertFalse(AccessRules.gates(.editor, noReveal).reveal)
        XCTAssertTrue(AccessRules.gates(.manager, noReveal).reveal)
        let all = VaultPolicyFlags(revealAllowed: true, aiAllowed: false, networksAllowed: false, recordSessions: true, accessPolicies: true, certificates: true)
        XCTAssertEqual(AccessRules.gates(.connectOnly, all), AccessGates(reveal: false, ai: false, networks: false, recorded: true, accessRules: true, certificates: true))
    }

    func testAuthenticationIsInherited() {
        let groups = [GroupAuthLink(id: "g1", name: "Prod", parentId: nil, auth: AccessRules.teamCertificate),
                      GroupAuthLink(id: "g2", name: "DB", parentId: "g1", auth: nil)]
        let e = AccessRules.effectiveAuth(own: nil, groupId: "g2", groups: groups)
        XCTAssertTrue(e.teamCertificate)
        XCTAssertEqual(e.fromGroup, "Prod")
        XCTAssertEqual(AccessRules.effectiveAuth(own: "future", groupId: "g2", groups: groups), EffectiveAuth(auth: "future", fromGroup: nil))
        XCTAssertNil(AccessRules.effectiveAuth(own: nil, groupId: nil, groups: groups).auth)
        let loop = [GroupAuthLink(id: "a", name: "A", parentId: "b", auth: nil), GroupAuthLink(id: "b", name: "B", parentId: "a", auth: nil)]
        XCTAssertNil(AccessRules.effectiveAuth(own: nil, groupId: "a", groups: loop).auth)
    }

    func testWhereATerminalOpens() {
        XCTAssertEqual(AccessRules.route(.editor, strict: true, telnet: false, teamCertificateUsable: false), .device)
        XCTAssertEqual(AccessRules.route(.useOnly, strict: false, telnet: false, teamCertificateUsable: false), .device)
        XCTAssertEqual(AccessRules.route(.connectOnly, strict: false, telnet: false, teamCertificateUsable: false), .server)
        XCTAssertEqual(AccessRules.route(.connectOnly, strict: false, telnet: false, teamCertificateUsable: true), .device)
        XCTAssertEqual(AccessRules.route(.useOnly, strict: true, telnet: false, teamCertificateUsable: false), .server)
        XCTAssertEqual(AccessRules.route(.connectOnly, strict: false, telnet: true, teamCertificateUsable: false), .device)
    }

    func testCountdownsAndDurations() {
        XCTAssertEqual(AccessRules.remainingSecs(now + 59_001, now: now), 60)
        XCTAssertEqual(AccessRules.remainingSecs(now - 5, now: now), 0)
        XCTAssertEqual(AccessRules.tick(120), 1)
        XCTAssertEqual(AccessRules.tick(121), 15)
        XCTAssertTrue(AccessRules.endingSoon(300))
        XCTAssertFalse(AccessRules.endingSoon(301))
        XCTAssertEqual(AccessRules.left(45).seconds, 45)
        let l = AccessRules.left(65 * 60)
        XCTAssertEqual(l.hours, 1)
        XCTAssertEqual(l.minutes, 5)
        XCTAssertNil(l.seconds)
        XCTAssertEqual(AccessRules.durationChoices(60), [15, 30, 60])
        XCTAssertEqual(AccessRules.durationChoices(45), [15, 30, 45])
    }

    func testTheTwoShapesOfApprovalRequired() {
        let server = AccessRules.need(json: #"{"host_id":"h1","policy_id":"p1","target_kind":"group","target_id":"g1","max_minutes":120}"#)
        XCTAssertEqual(server, AccessNeed(hostId: "h1", vaultId: nil, targetKind: "group", targetId: "g1", maxMinutes: 120, pending: nil, canRequest: true))
        let engine = AccessRules.need(json: #"{"host_id":"h1","vault_id":"v1","target_kind":"vault","target_id":"v1","max_minutes":30,"pending":{"id":"r9"},"can_request":false}"#)
        XCTAssertEqual(engine, AccessNeed(hostId: "h1", vaultId: "v1", targetKind: "vault", targetId: "v1", maxMinutes: 30, pending: "r9", canRequest: false))
        XCTAssertEqual(AccessRules.need(json: nil, hostId: "h2"), AccessNeed(hostId: "h2", vaultId: nil, targetKind: "host", targetId: nil, maxMinutes: 60, pending: nil, canRequest: true))
    }

    func testRequestFormEventsAndNotices() {
        XCTAssertEqual(AccessRules.requestProblem(minutes: 60, max: 60, reason: "  "), .reason)
        XCTAssertEqual(AccessRules.requestProblem(minutes: 60, max: 60, reason: String(repeating: "x", count: 501)), .reasonLong)
        XCTAssertEqual(AccessRules.requestProblem(minutes: 120, max: 60, reason: "deploy"), .duration)
        XCTAssertNil(AccessRules.requestProblem(minutes: 60, max: 60, reason: "deploy"))
        let json: [String: Any] = ["type": "access_request", "event": "approved",
                                   "request": ["id": "r1", "requester_id": "me", "requester_name": "", "requester_email": "me@example.com",
                                               "target_label": "web1", "minutes": 30, "status": "approved", "ends_at": NSNumber(value: now + 1_800_000)]]
        let ev = AccessRules.event(json)!
        XCTAssertEqual(ev.event, "approved")
        XCTAssertEqual(ev.request.requesterName, "me@example.com")
        XCTAssertEqual(ev.request.endsAt, now + 1_800_000)
        XCTAssertEqual(AccessRules.notice(me: "me", event: "approved", request: ev.request), .approved)
        XCTAssertNil(AccessRules.notice(me: "other", event: "approved", request: ev.request))
        XCTAssertEqual(AccessRules.notice(me: "approver", event: "created", request: ev.request), .created)
        var denied = ev.request
        denied.decisionReason = "not now"
        XCTAssertEqual(AccessRules.notice(me: "me", event: "denied", request: denied), .deniedReason)
        XCTAssertNil(AccessRules.event(["type": "vault"]))
        XCTAssertEqual(AccessRules.statusKey(status: "approved", startsAt: now - 10, endsAt: now + 10, now: now), .active)
        XCTAssertEqual(AccessRules.statusKey(status: "approved", startsAt: now - 10, endsAt: now - 1, now: now), .ended)
    }

    func testCloseReasonsAndCodes() {
        XCTAssertEqual(AccessRules.keptReason(previous: "access_expired", next: "session_ended"), "access_expired")
        XCTAssertEqual(AccessRules.keptReason(previous: nil, next: "access_revoked"), "access_revoked")
        XCTAssertEqual(AccessRules.keptReason(previous: "access_expired", next: "access_revoked"), "access_revoked")
        XCTAssertEqual(AccessRules.code(ofMessage: "\"web1\" needs an approved access window: request access"), "access_approval_required")
        XCTAssertEqual(AccessRules.code(ofMessage: "there is no certificate authority for this vault"), "ca_not_configured")
        XCTAssertEqual(AccessRules.code(ofMessage: "access_expired"), "access_expired")
        XCTAssertNil(AccessRules.code(ofMessage: "connection refused"))
        XCTAssertEqual(AccessRules.errorCodes.count, 22)
    }

    func testTheCa() {
        let cmd = AccessRules.installCommand("#!/bin/sh\nset -eu\necho ok\n")
        XCTAssertTrue(cmd.hasPrefix("sudo sh -s <<'TERMOAK_CA'\n#!/bin/sh\n"))
        XCTAssertTrue(cmd.hasSuffix("echo ok\nTERMOAK_CA\n"))
        XCTAssertFalse(cmd.contains("curl"))
        let opt = ["RevokedKeys /etc/ssh/termoak_revoked.krl", "AuthorizedPrincipalsFile /etc/ssh/termoak_principals/%u"]
        XCTAssertEqual(AccessRules.sshdLines(base: ["TrustedUserCAKeys x"], optional: opt, krl: true, principals: false).count, 2)
        XCTAssertEqual(AccessRules.sshdLines(base: ["TrustedUserCAKeys x"], optional: opt, krl: true, principals: true).count, 3)
        XCTAssertTrue(AccessRules.principalValid("prod-admin"))
        XCTAssertFalse(AccessRules.principalValid("has space"))
        XCTAssertEqual(AccessRules.defaultPrincipal("Ana.Maria+x@example.com"), "ana.maria_x")
        XCTAssertEqual(AccessRules.templates(" {login}, ,deploy "), ["{login}", "deploy"])
        XCTAssertEqual(AccessRules.number("24", in: 1...720), 24)
        XCTAssertNil(AccessRules.number("721", in: 1...720))
        XCTAssertTrue(AccessRules.looksLikePublicKey("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl ana"))
        XCTAssertFalse(AccessRules.looksLikePublicKey("not a key"))
        let parents = ["g2": "g1"]
        let has: (String, String) -> Bool = { k, id in (k == "group" && id == "g1") || (k == "vault" && id == "v1") }
        XCTAssertEqual(AccessRules.inheritedTarget(kind: "host", groupOfHost: "g2", parentOf: { parents[$0] }, hasPolicy: has, vaultId: "v1")?.1, "g1")
        XCTAssertEqual(AccessRules.inheritedTarget(kind: "host", groupOfHost: nil, parentOf: { parents[$0] }, hasPolicy: has, vaultId: "v1")?.0, "vault")
        XCTAssertNil(AccessRules.inheritedTarget(kind: "vault", groupOfHost: nil, parentOf: { _ in nil }, hasPolicy: has, vaultId: "v1"))
    }

    func testAsciicast() {
        let c = Asciicast.parse("""
        {"version":2,"width":100,"height":30}
        [0.1,"o","$ "]
        [0.5,"i","ls\\r"]
        [0.4,"o","a b"]
        [1.0,"r","120x40"]
        not json
        [3.0,"o","bye"]
        """)!
        XCTAssertEqual(c.width, 100)
        XCTAssertEqual(c.events.count, 4)
        XCTAssertEqual(c.events[1].time, 0.5)
        XCTAssertEqual(c.events[2], .resize(time: 1.0, cols: 120, rows: 40))
        XCTAssertEqual(c.duration, 3.0)
        XCTAssertNil(Asciicast.parse(#"{"version":1}"#))
        XCTAssertEqual(Asciicast.wait(previous: 0, time: 10, speed: 1), 2)
        XCTAssertEqual(Asciicast.wait(previous: 1, time: 2, speed: 4), 0.25)
    }
}
