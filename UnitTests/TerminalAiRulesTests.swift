import XCTest

/// The AI in the terminal: what is sent about a failed command, how a
/// `# request` line is erased, the chip's rule and the risk of a proposal.
final class TerminalAiRulesTests: XCTestCase {
    func testForAiHasCommandOutputAndExit() {
        XCTAssertEqual(TerminalAiRules.forAi(command: "make", output: "error: no rule\n", exitCode: 2),
                       "$ make\nerror: no rule\n\n(exit status 2)")
        XCTAssertEqual(TerminalAiRules.forAi(command: nil, output: "boom", exitCode: nil), "boom")
        XCTAssertEqual(TerminalAiRules.forAi(command: "true", output: "  \n", exitCode: nil), "$ true")
    }

    func testEraseIsOneBackspacePerCharacter() {
        XCTAssertEqual(TerminalAiRules.eraseBytes("# list"), Array(repeating: 0x7F, count: 6))
        XCTAssertEqual(TerminalAiRules.eraseBytes("# ñu"), Array(repeating: 0x7F, count: 4))
        XCTAssertEqual(TerminalAiRules.eraseBytes(""), [])
    }

    func testBracketedPasteIsNotACommand() {
        XCTAssertTrue(TerminalAiRules.isBracketedPaste(Data("\u{1b}[200~ls\r\u{1b}[201~".utf8)))
        XCTAssertFalse(TerminalAiRules.isBracketedPaste(Data("ls\r".utf8)))
    }

    func testPromptIsTheLineWithoutWhatWasTyped() {
        XCTAssertEqual(TerminalAiRules.prompt(screenLine: "ana@web:~$ ls -la", typed: "ls -la"), "ana@web:~$ ")
        XCTAssertEqual(TerminalAiRules.prompt(screenLine: "ana@web:~$ ls", typed: nil), "ana@web:~$ ls")
        // The screen does not show what was typed (a password): the whole line.
        XCTAssertEqual(TerminalAiRules.prompt(screenLine: "Password:", typed: "secret"), "Password:")
    }

    func testChipNeedsFailureSettingAiAndKeyboard() {
        XCTAssertTrue(TerminalAiRules.showsFixChip(failed: true, enabled: true, aiAvailable: true, canWrite: true))
        XCTAssertFalse(TerminalAiRules.showsFixChip(failed: false, enabled: true, aiAvailable: true, canWrite: true))
        XCTAssertFalse(TerminalAiRules.showsFixChip(failed: true, enabled: false, aiAvailable: true, canWrite: true))
        XCTAssertFalse(TerminalAiRules.showsFixChip(failed: true, enabled: true, aiAvailable: false, canWrite: true))
        XCTAssertFalse(TerminalAiRules.showsFixChip(failed: true, enabled: true, aiAvailable: true, canWrite: false))
    }

    func testCellsAndBlank() {
        XCTAssertEqual(TerminalAiRules.cellText("$\u{0} "), "$  ")
        XCTAssertTrue(TerminalAiRules.isBlank(TerminalAiRules.cellText("\u{0}\u{0} ")))
        XCTAssertFalse(TerminalAiRules.isBlank("x"))
    }

    func testRisk() {
        XCTAssertEqual(AiCommandRisk("read"), .read)
        XCTAssertEqual(AiCommandRisk("DANGEROUS"), .dangerous)
        XCTAssertEqual(AiCommandRisk("something"), .write)
        XCTAssertTrue(AiCommandRisk.dangerous.needsConfirmation)
        XCTAssertFalse(AiCommandRisk.write.needsConfirmation)
    }

    func testAiKeyIsInTheEditorOfOldLayouts() {
        let old = KeyboardLayout(bar: [.paste], groups: [])
        XCTAssertTrue(old.all.contains(where: { $0.id == ShortcutKey.ai.id }))
        XCTAssertEqual(KeyboardLayout.standard.all.filter { $0.id == ShortcutKey.ai.id }.count, 1)
        let data = try! JSONEncoder().encode(ShortcutKey.ai)
        XCTAssertEqual(try JSONDecoder().decode(ShortcutKey.self, from: data), ShortcutKey.ai)
    }
}
