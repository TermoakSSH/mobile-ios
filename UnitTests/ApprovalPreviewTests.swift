import XCTest

/// What an AI approval shows and the decision sent with an edit or a reason
/// (Termoak/Model/ApprovalPreview.swift; the engine's typed preview is mapped
/// in AiEngine.swift).
final class ApprovalPreviewTests: XCTestCase {
    func testPreviewOfALiveEvent() {
        let p = ApprovalPreview.parse([
            "kind": "command", "host": "web", "command": "sudo systemctl restart nginx", "risk": "high",
            "reasons": [["code": "sudo", "text": "runs as root"], ["code": "system_path", "text": "writes to /etc"]],
            "explanation": "Reload the config", "editable": true,
        ])
        XCTAssertEqual(p.kind, "command")
        XCTAssertEqual(p.host, "web")
        XCTAssertEqual(p.risk, "high")
        XCTAssertEqual(p.reasons.map(\.code), ["sudo", "system_path"])
        XCTAssertEqual(ApprovalPreview.reasonPath(p.reasons[1].text), "/etc")
        XCTAssertNil(ApprovalPreview.reasonPath("runs as root"))
        XCTAssertEqual(p.editableText, "sudo systemctl restart nginx")

        let plan = ApprovalPreview.parse(["kind": "plan", "plan": "1. Check\n2. Fix", "risk": "low", "editable": true])
        XCTAssertEqual(plan.editableText, "1. Check\n2. Fix")

        let file = ApprovalPreview.parse(["kind": "file", "path": "/etc/hosts", "diff": "--- a\n+++ b\n@@ -1 +1 @@\n-a\n+b",
                                          "added": 1, "removed": 1, "new_file": false, "diff_truncated": true, "risk": "medium"])
        XCTAssertEqual(file.added, 1)
        XCTAssertEqual(file.removed, 1)
        XCTAssertTrue(file.diffTruncated)
        XCTAssertNil(file.editableText)
        XCTAssertEqual(ApprovalPreview.parse([:]).kind, "other")
        XCTAssertEqual(ApprovalPreview.parse([:]).risk, "low")
    }

    func testDiffLines() {
        let kinds = "--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n keep\n-old\n+new".split(separator: "\n").map(DiffLineKind.init)
        XCTAssertEqual(kinds, [.header, .header, .hunk, .context, .removed, .added])
    }

    func testDecisions() {
        let plain = ApprovalChoice(approve: true)
        XCTAssertNil(plain.cleanEdited)
        XCTAssertNil(plain.cleanReason)
        let edited = ApprovalChoice(approve: true, edited: "  ls -la \n")
        XCTAssertEqual(edited.cleanEdited, "ls -la")
        XCTAssertNil(ApprovalChoice(approve: true, edited: "   ").cleanEdited)
        let denied = ApprovalChoice(approve: false, edited: "ignored", reason: " too risky ")
        XCTAssertNil(denied.cleanEdited)
        XCTAssertEqual(denied.cleanReason, "too risky")
        XCTAssertNil(ApprovalChoice(approve: false, reason: "  ").cleanReason)
    }
}
