import XCTest

/// Pure rules of the AI screens (Termoak/Model/AiTasks.swift): a new task's
/// options cleaned up, the provider choice, durations and the copilot's chip labels.
final class AiTasksTests: XCTestCase {
    func testNewTaskCleanup() {
        var t = NewAiTask(prompt: "  check disk \n")
        XCTAssertEqual(t.cleanPrompt, "check disk")
        XCTAssertNil(t.cleanProvider)
        XCTAssertNil(t.cleanEffort)
        XCTAssertNil(t.cleanTag)
        t.provider = ""
        t.effort = ""
        t.tag = "   "
        XCTAssertNil(t.cleanProvider)
        XCTAssertNil(t.cleanEffort)
        XCTAssertNil(t.cleanTag)
        t.provider = NewAiTask.provider("claude", model: "opus")
        t.effort = "high"
        t.tag = " web "
        XCTAssertEqual(t.cleanProvider, "claude::opus")
        XCTAssertEqual(t.cleanEffort, "high")
        XCTAssertEqual(t.cleanTag, "web")
        XCTAssertEqual(NewAiTask.provider("gpt", model: nil), "gpt")
        XCTAssertEqual(NewAiTask.provider("gpt", model: ""), "gpt")
        XCTAssertNil(NewAiTask.provider(nil, model: "x"))
    }

    func testProviderReasons() {
        for code in ["not_configured", "own_key_required", "plan"] { XCTAssertNotNil(aiProviderReason(code: code), code) }
        XCTAssertNil(aiProviderReason(code: "something_new"))
        XCTAssertNil(aiProviderReason(code: nil))
    }

    func testDurations() {
        XCTAssertEqual(aiDuration(ms: 800), "800 ms")
        XCTAssertEqual(aiDuration(ms: 5_000), "5 s")
        XCTAssertEqual(aiDuration(ms: 65_000), "1 min 5 s")
        XCTAssertEqual(aiDuration(ms: 120_000), "2 min")
    }

    func testChipLabels() {
        XCTAssertEqual(CopilotChipLabel.command("  make test \nsecond line"), "make test")
        XCTAssertEqual(CopilotChipLabel.command(String(repeating: "a", count: 40)), String(repeating: "a", count: 31) + "…")
        XCTAssertNil(CopilotChipLabel.command(nil))
        XCTAssertNil(CopilotChipLabel.command("  \n"))
        XCTAssertEqual(CopilotChipLabel.lines("one"), 1)
        XCTAssertEqual(CopilotChipLabel.lines("one\ntwo\n"), 2)
        XCTAssertEqual(CopilotChipLabel.lines("a\n\nb"), 3)
        XCTAssertEqual(CopilotChipLabel.lines("\n"), 0)
    }
}
