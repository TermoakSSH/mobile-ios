import XCTest

/// Push notifications (Termoak/Model/PushRouting.swift): reading APNs
/// payloads as the server sends them, where a tap or an action goes, the
/// withdrawals, and the registration rules (inert without APNs).
final class PushRoutingTests: XCTestCase {
    /// The `termoak` dictionary of an APNs payload (server 0.7.0-next.7).
    private func apns(_ termoak: [String: Any], category: String? = nil) -> [AnyHashable: Any] {
        var aps: [String: Any] = ["alert": ["title": "T", "body": "B"]]
        if let category { aps["category"] = category }
        return ["aps": aps, "termoak": termoak]
    }

    func testApprovalPayloadAndActions() throws {
        let info = try XCTUnwrap(PushInfo(userInfo: apns([
            "v": "1", "type": "ai_approval", "category": "approval", "collapse": "approval-a1",
            "task_id": "t1", "approval_id": "a1", "sent_at": "1000", "server": "srv", "user": "u1",
        ], category: PushCategoryId.approval)))
        XCTAssertEqual(info.kind, "ai_approval")
        XCTAssertEqual(info.category, .approval)
        XCTAssertEqual(info.tag, "approval-a1")
        XCTAssertEqual(info.data, ["task_id": "t1", "approval_id": "a1"])
        XCTAssertFalse(info.expired)
        // A tap, Approve and Deny all open the AI's confirmation: nothing decided.
        for action in [nil, "com.apple.UNNotificationDefaultActionIdentifier", PushActionId.approve, PushActionId.deny] {
            XCTAssertEqual(PushRoute.of(info, action: action), .ai(taskId: "t1"))
        }
        XCTAssertEqual(PushRoute.of(info, action: PushActionId.dismiss), PushRoute.none)
    }

    func testSessionsTeamsAndOthers() throws {
        let join = try XCTUnwrap(PushInfo(userInfo: apns(["type": "join_request", "session_id": "s1",
                                                           "participant": "p1", "collapse": "join_request-p1"])))
        XCTAssertEqual(join.category, .approval) // from the kind (no `category`)
        XCTAssertEqual(PushRoute.of(join, action: PushActionId.approve), .session(id: "s1", title: "", owner: true))
        let control = try XCTUnwrap(PushInfo(userInfo: apns(["type": "control_request", "session_id": "s2"])))
        XCTAssertEqual(PushRoute.of(control, action: nil), .session(id: "s2", title: "", owner: true))
        let prompt = try XCTUnwrap(PushInfo(userInfo: apns(["type": "session_prompt", "session_id": "s3", "prompt_id": "q"])))
        XCTAssertEqual(prompt.category, .info)
        XCTAssertEqual(PushRoute.of(prompt, action: nil), .session(id: "s3", title: "", owner: true))
        let shared = try XCTUnwrap(PushInfo(userInfo: apns(["type": "session_shared", "session_id": "s4"])))
        XCTAssertEqual(PushRoute.of(shared, action: nil), .session(id: "s4", title: "", owner: false))
        let team = try XCTUnwrap(PushInfo(userInfo: apns(["type": "team_added", "team_id": "x"])))
        XCTAssertEqual(PushRoute.of(team, action: nil), .teams)
        let done = try XCTUnwrap(PushInfo(userInfo: apns(["type": "ai_finished", "task_id": "t9", "status": "failed"])))
        XCTAssertEqual(PushRoute.of(done, action: nil), .ai(taskId: "t9"))
        // Phase 4b: an access request opens the app (no screen yet), as do tests.
        let access = try XCTUnwrap(PushInfo(userInfo: apns(["type": "access_request", "request_id": "r"])))
        XCTAssertEqual(access.category, .approval)
        XCTAssertEqual(PushRoute.of(access, action: PushActionId.deny), .app)
        let test = try XCTUnwrap(PushInfo(userInfo: apns(["type": "test"])))
        XCTAssertEqual(PushRoute.of(test, action: nil), .app)
        // A session request without its id still opens the app.
        let broken = try XCTUnwrap(PushInfo(userInfo: apns(["type": "join_request"])))
        XCTAssertEqual(PushRoute.of(broken, action: nil), .app)
    }

    func testSecurityKeyRequest() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let live = try XCTUnwrap(PushInfo(userInfo: apns([
            "type": "security_key_request", "category": "security_key", "collapse": "sk-r1",
            "request_id": "r1", "expires_at": "1060000",
        ], category: PushCategoryId.securityKey), now: now))
        XCTAssertEqual(live.category, .securityKey)
        XCTAssertFalse(live.expired)
        XCTAssertEqual(PushRoute.of(live, action: PushActionId.open), .securityKey(requestId: "r1"))
        let late = try XCTUnwrap(PushInfo(userInfo: apns(["type": "security_key_request", "request_id": "r1",
                                                           "expires_at": "999000"]), now: now))
        XCTAssertTrue(late.expired)
        XCTAssertEqual(late.category, .securityKey)
    }

    func testResolvedRemovesTheTaggedNotification() throws {
        let gone = try XCTUnwrap(PushInfo(userInfo: ["aps": ["content-available": 1],
                                                     "termoak": ["v": "1", "type": "resolved", "category": "resolved",
                                                                 "collapse": "approval-a1", "sent_at": "5"]]))
        XCTAssertEqual(gone.category, .resolved)
        // Whatever the action: the identifier APNs gave the alert (apns-collapse-id).
        XCTAssertEqual(PushRoute.of(gone, action: nil), .remove(tag: "approval-a1"))
        XCTAssertEqual(PushRoute.of(gone, action: PushActionId.dismiss), .remove(tag: "approval-a1"))
        // Without a collapse key the tag is kind-sent_at (as the engine's PushEvent.tag).
        let plain = try XCTUnwrap(PushInfo(userInfo: apns(["type": "test", "sent_at": "42"])))
        XCTAssertEqual(plain.tag, "test-42")
    }

    func testNotOurs() {
        XCTAssertNil(PushInfo(userInfo: [:]))
        XCTAssertNil(PushInfo(userInfo: ["termoak": ["task_id": "t1"]]))
        XCTAssertNil(PushInfo(userInfo: ["aps": ["alert": "hi"]]))
        XCTAssertNil(PushInfo(userInfo: ["termoak": ["type": ""]]))
        // Old servers' numbers are read too.
        let n = PushInfo(userInfo: ["termoak": ["type": "test", "sent_at": NSNumber(value: 7)]])
        XCTAssertEqual(n?.tag, "test-7")
    }

    func testRegistrationIsInertWithoutApns() {
        // No server can send APNs (today): nothing asked, nothing registered.
        XCTAssertFalse(PushRegistration.shouldAskPermission([:]))
        XCTAssertFalse(PushRegistration.shouldAskPermission(["a": false, "b": false]))
        XCTAssertEqual(PushRegistration.accounts(["a": false, "b": false]), [])
        // Only the accounts whose server can.
        XCTAssertTrue(PushRegistration.shouldAskPermission(["a": false, "b": true]))
        XCTAssertEqual(PushRegistration.accounts(["c": true, "a": false, "b": true]), ["b", "c"])
        XCTAssertEqual(PushRegistration.hex(Data([0x00, 0xab, 0x10, 0xff])), "00ab10ff")
    }
}
