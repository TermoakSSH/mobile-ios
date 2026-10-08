import XCTest

/// What a tapped push notification opens (Termoak/Model/PushTarget.swift).
final class PushTargetTests: XCTestCase {
    func testApprovalAndSessions() {
        let ai = PushTarget(["termoak": ["type": "ai_approval", "task_id": "t1"]])
        XCTAssertEqual(ai?.taskId, "t1")
        XCTAssertEqual(ai?.isAi, true)
        let join = PushTarget(["termoak": ["type": "join_request", "session_id": "s1", "title": "web"]])
        XCTAssertEqual(join?.sessionId, "s1")
        XCTAssertEqual(join?.title, "web")
        XCTAssertEqual(join?.isOwnSession, true)
        XCTAssertEqual(join?.isAi, false)
        let shared = PushTarget(["termoak": ["type": "session_shared", "session_id": "s2"] as [String: Any]])
        XCTAssertEqual(shared?.isOwnSession, false)
        XCTAssertEqual(shared?.title, "")
    }

    func testNotOurs() {
        XCTAssertNil(PushTarget([:]))
        XCTAssertNil(PushTarget(["termoak": ["task_id": "t1"]]))
        XCTAssertNil(PushTarget(["aps": ["alert": "hi"]]))
    }
}
