import XCTest

/// Snippets with variables (Termoak/Model/SnippetVars.swift, core
/// docs/SSH-PRO.md §7): the run form's fields (defaults, remembered values,
/// selects, secrets never prefilled nor remembered), missing values, what
/// each target gets, the startup warning and the editor's issues.
final class SnippetVarsTests: XCTestCase {
    private let branch = SnipVar(key: "Branch", kind: .prompt, label: "Branch", defaultValue: "main", options: [], needsHost: false)
    private let env = SnipVar(key: "Env", kind: .select, label: "Env", defaultValue: "dev", options: ["dev", "prod"], needsHost: false)
    private let token = SnipVar(key: "Token", kind: .secret, label: "Token", defaultValue: nil, options: [], needsHost: false)
    private let host = SnipVar(key: "host", kind: .builtin, label: "host", defaultValue: nil, options: [], needsHost: true)
    private let free = SnipVar(key: "service", kind: .prompt, label: "service", defaultValue: nil, options: [], needsHost: false)

    func testFieldsStartWithDefaults() {
        let f = SnippetVars.fields([branch, env, token, free], remembered: [:])
        XCTAssertEqual(f.map(\.value), ["main", "dev", "", ""])
    }

    func testRememberedValuesWinButNeverForSecrets() {
        let f = SnippetVars.fields([branch, env, token], remembered: ["Branch": "release", "Env": "prod", "Token": "leaked"])
        XCTAssertEqual(f.map(\.value), ["release", "prod", ""])
    }

    func testASelectKeepsOnlyItsOptions() {
        let f = SnippetVars.fields([env], remembered: ["Env": "staging"])
        XCTAssertEqual(f[0].value, "dev")
    }

    func testMissingValues() {
        var f = SnippetVars.fields([branch, token], remembered: [:])
        XCTAssertEqual(SnippetVars.values(f), .failure(SnippetVars.Missing(label: "Token")))
        f[1].value = "s3cret"
        XCTAssertEqual(SnippetVars.values(f), .success(["Branch": "main", "Token": "s3cret"]))
    }

    func testATargetWithAHostFillsItsOwnBuiltins() {
        let all = ["host": "typed.example", "Branch": "main"]
        XCTAssertEqual(SnippetVars.values(all, forTargetWithHost: true, vars: [host, branch]), ["Branch": "main"])
        XCTAssertEqual(SnippetVars.values(all, forTargetWithHost: false, vars: [host, branch]), all)
    }

    func testSecretsAreNotRemembered() {
        XCTAssertEqual(SnippetVars.rememberable(["Branch": "main", "Token": "x"], vars: [branch, token]), ["Branch": "main"])
    }

    func testStartupSnippetsThatAsk() {
        XCTAssertFalse(SnippetVars.startupAsks([branch, env]))
        XCTAssertTrue(SnippetVars.startupAsks([branch, free]))
        XCTAssertTrue(SnippetVars.startupAsks([token]))
        XCTAssertFalse(SnippetVars.startupAsks([]))
    }

    func testIssuePositions() {
        let script = "echo hi\nls {{prompt:}}"
        let p = SnippetVars.position(in: script, offset: 11)
        XCTAssertEqual(p.line, 2)
        XCTAssertEqual(p.column, 4)
        XCTAssertEqual(SnippetVars.position(in: "ñ{{x}}", offset: 1).column, 2, "characters, not bytes")
    }

    func testIssueMessages() {
        XCTAssertEqual(SnippetVars.issue("the variable has no label"), .noLabel)
        XCTAssertEqual(SnippetVars.issue("the label is longer than 64 characters"), .labelTooLong)
        XCTAssertEqual(SnippetVars.issue("a select needs at least one option ({{select:Name|a|b}})"), .selectOptions)
        XCTAssertEqual(SnippetVars.issue("a secret cannot have a default value"), .secretDefault)
        XCTAssertEqual(SnippetVars.issue("a snippet can have at most 50 variables"), .tooMany)
        XCTAssertEqual(SnippetVars.issue("\"Env\" is already a select variable"), .kindConflict(name: "Env", kind: .select))
        XCTAssertEqual(SnippetVars.issue("\"host\" is already a built-in variable"), .kindConflict(name: "host", kind: .builtin))
        XCTAssertEqual(SnippetVars.issue("something new"), .other("something new"))
    }
}
