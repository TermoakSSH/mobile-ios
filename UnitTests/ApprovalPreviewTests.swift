import XCTest

/// What an AI approval shows and the decision sent with an edit or a reason
/// (Termoak/Model/ApprovalPreview.swift).
final class ApprovalPreviewTests: XCTestCase {
    func testPreviewsFromTheListAndFromATask() {
        let list = """
        [{"id":"a1","task_id":"t","tool":"run_command","input":{},"summary":"","status":"pending","created_at":1,
          "preview":{"kind":"command","host":"web","command":"sudo systemctl restart nginx","risk":"high",
                     "reasons":[{"code":"sudo","text":"runs as root"},{"code":"system_path","text":"writes to /etc"}],
                     "explanation":"Reload the config","editable":true}},
         {"id":"a2","task_id":"t","tool":"run_command","input":{},"summary":"","status":"pending","created_at":1}]
        """
        let p = ApprovalPreview.byApproval(json: list)
        XCTAssertEqual(p.count, 1)
        let a1 = p["a1"]!
        XCTAssertEqual(a1.kind, "command")
        XCTAssertEqual(a1.host, "web")
        XCTAssertEqual(a1.risk, "high")
        XCTAssertEqual(a1.reasons.map(\.code), ["sudo", "system_path"])
        XCTAssertEqual(ApprovalPreview.reasonPath(a1.reasons[1].text), "/etc")
        XCTAssertEqual(a1.editableText, "sudo systemctl restart nginx")

        let task = """
        {"id":"t","pending_approvals":[{"id":"p1","preview":{"kind":"plan","plan":"1. Check\\n2. Fix","risk":"low","editable":true}},
                                       {"id":"f1","preview":{"kind":"file","path":"/etc/hosts","diff":"--- a\\n+++ b\\n@@ -1 +1 @@\\n-a\\n+b",
                                                              "added":1,"removed":1,"new_file":false,"diff_truncated":true,"risk":"medium"}}]}
        """
        let q = ApprovalPreview.byApproval(json: task)
        XCTAssertEqual(q["p1"]?.editableText, "1. Check\n2. Fix")
        XCTAssertEqual(q["f1"]?.added, 1)
        XCTAssertEqual(q["f1"]?.diffTruncated, true)
        XCTAssertNil(q["f1"]?.editableText)
        XCTAssertEqual(ApprovalPreview.byApproval(json: "not json"), [:])
    }

    func testDiffLines() {
        let kinds = "--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n keep\n-old\n+new".split(separator: "\n").map(DiffLineKind.init)
        XCTAssertEqual(kinds, [.header, .header, .hunk, .context, .removed, .added])
    }

    func testDecisionBodies() {
        XCTAssertTrue(ApprovalChoice(approve: true).isPlain)
        XCTAssertTrue(ApprovalChoice(approve: true, always: true).isPlain)
        let edited = ApprovalChoice(approve: true, edited: "  ls -la \n")
        XCTAssertFalse(edited.isPlain)
        XCTAssertEqual(edited.body["edited"] as? String, "ls -la")
        XCTAssertEqual(edited.body["approve"] as? Bool, true)
        let denied = ApprovalChoice(approve: false, edited: "ignored", reason: " too risky ")
        XCTAssertNil(denied.body["edited"])
        XCTAssertEqual(denied.body["reason"] as? String, "too risky")
        XCTAssertNil(ApprovalChoice(approve: false, reason: "  ").body["reason"])
    }
}
