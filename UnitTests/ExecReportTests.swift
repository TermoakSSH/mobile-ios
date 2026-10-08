import XCTest

/// The output of a command run on several servers (Termoak/Model/ExecReport.swift).
final class ExecReportTests: XCTestCase {
    func testOutputAndSuccess() {
        let ok = ExecOutput(stdout: "up 3 days\n", stderr: "", exitCode: 0, signal: nil, timedOut: false, truncated: false, durationMs: 40)
        XCTAssertTrue(ok.succeeded)
        XCTAssertEqual(ok.combined, "up 3 days")
        let failed = ExecOutput(stdout: "a\n", stderr: "boom\n", exitCode: 2, signal: nil, timedOut: false, truncated: false, durationMs: 1)
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(failed.combined, "a\nboom")
        XCTAssertFalse(ExecOutput(stdout: "", stderr: "", exitCode: nil, signal: "KILL", timedOut: false, truncated: false, durationMs: 1).succeeded)
        XCTAssertFalse(ExecOutput(stdout: "", stderr: "", exitCode: 0, signal: nil, timedOut: true, truncated: false, durationMs: 1).succeeded)
    }

    func testSharedText() {
        let out = ExecOutput(stdout: "ok\n", stderr: "", exitCode: 0, signal: nil, timedOut: false, truncated: false, durationMs: 1)
        XCTAssertEqual(ExecReport.text([(name: "web", status: "exit 0", output: out), (name: "db", status: "Couldn't connect", output: nil)]),
                       "## web (exit 0)\nok\n\n## db (Couldn't connect)\n")
    }
}
