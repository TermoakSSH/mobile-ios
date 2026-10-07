import XCTest

/// What the keys of a hardware keyboard send (Termoak/Model/HardwareKeys.swift).
/// The target compiles that file and Keys.swift directly (no app host), so
/// these run in a second: `xcodebuild test -scheme Termoak -only-testing:TermoakTests`.
final class HardwareKeysTests: XCTestCase {
    // HID usages (UIKeyboardHIDUsage) used below.
    private enum HID {
        static let a = 0x04, c = 0x06, b = 0x05, e = 0x08, f = 0x09, n = 0x11, two = 0x1F, one = 0x1E
        static let enter = 0x28, esc = 0x29, backspace = 0x2A, tab = 0x2B, space = 0x2C
        static let minus = 0x2D, openBracket = 0x2F, closeBracket = 0x30, backslash = 0x31
        static let semicolon = 0x33, grave = 0x35, period = 0x37, slash = 0x38
        static let f1 = 0x3A, f5 = 0x3E, f10 = 0x43, f12 = 0x45
        static let insert = 0x49, home = 0x4A, pageUp = 0x4B, deleteForward = 0x4C, end = 0x4D, pageDown = 0x4E
        static let right = 0x4F, left = 0x50, down = 0x51, up = 0x52
        static let capsLock = 0x39, leftShift = 0xE1, leftControl = 0xE0, leftOption = 0xE2, leftCommand = 0xE3
        static let f13 = 0x68, keypadEnter = 0x58
    }

    private func key(_ usage: Int, _ typed: String = "", _ unmodified: String? = nil) -> HardwareKey {
        guard let k = HardwareKey(hidUsage: usage, characters: typed, charactersIgnoringModifiers: unmodified ?? typed) else {
            XCTFail("no key for usage \(usage)")
            return .special(.esc)
        }
        return k
    }

    private func send(_ usage: Int, _ typed: String = "", _ unmodified: String? = nil,
                      _ modifiers: ModifierKeys = [], _ options: KeyEncodingOptions = KeyEncodingOptions()) -> HardwareKeyResult {
        HardwareKeyMap.result(for: key(usage, typed, unmodified), modifiers: modifiers, options: options)
    }

    private func bytes(_ s: String) -> HardwareKeyResult { .send(Array(s.utf8)) }

    private let app = KeyEncodingOptions(applicationCursor: true)
    private let noMeta = KeyEncodingOptions(optionAsMeta: false)

    // MARK: Keys that are not ours

    func testModifierAndLockKeysAreNotKeys() {
        for usage in [HID.capsLock, HID.leftShift, HID.leftControl, HID.leftOption, HID.leftCommand, HID.f13] {
            XCTAssertNil(HardwareKey(hidUsage: usage, characters: "", charactersIgnoringModifiers: ""), "usage \(usage)")
        }
    }

    func testPlainTextGoesToTheTextSystem() {
        XCTAssertEqual(send(HID.a, "a"), .system)
        XCTAssertEqual(send(HID.a, "A", "a", .shift), .system)
        XCTAssertEqual(send(HID.space, " "), .system)
        // ñ, and the dead keys of a Spanish layout (´ ` ^ ¨) compose in the text system.
        XCTAssertEqual(send(HID.semicolon, "ñ"), .system)
        XCTAssertEqual(send(0x34, "", "´"), .system)
        XCTAssertEqual(send(HID.openBracket, "", "`"), .system)
        XCTAssertEqual(send(HID.openBracket, "", "^", .shift), .system)
        XCTAssertEqual(send(0x34, "", "¨", .shift), .system)
    }

    func testCommandShortcutsAreTheSystems() {
        XCTAssertEqual(send(HID.c, "c", "c", .command), .system)
        XCTAssertEqual(send(HID.c, "c", "c", [.command, .shift]), .system)
        XCTAssertEqual(send(HID.up, "", "", .command), .system)
        XCTAssertEqual(send(HID.left, "", "", [.command, .option]), .system)
    }

    // MARK: Esc

    func testEscape() {
        XCTAssertEqual(send(HID.esc), .send([0x1B]))
        // ⌘. on keyboards without Esc, and Ctrl+[ (also on a Spanish layout,
        // where that key is the dead `).
        XCTAssertEqual(send(HID.period, ".", ".", .command), .send([0x1B]))
        XCTAssertEqual(send(HID.openBracket, "\u{1b}", "[", .control), .send([0x1B]))
        XCTAssertEqual(send(HID.openBracket, "", "`", .control), .send([0x1B]))
        XCTAssertEqual(send(HID.esc, "", "", .option), .send([0x1B, 0x1B]))
    }

    // MARK: Ctrl

    func testControlLetters() {
        XCTAssertEqual(send(HID.a, "\u{1}", "a", .control), .send([0x01]))
        XCTAssertEqual(send(HID.c, "\u{3}", "c", .control), .send([0x03]))
        // Ctrl+Shift+letter is the same control byte.
        XCTAssertEqual(send(HID.c, "\u{3}", "C", [.control, .shift]), .send([0x03]))
        XCTAssertEqual(send(0x1D, "\u{1a}", "z", .control), .send([0x1A]))
    }

    func testControlSymbols() {
        XCTAssertEqual(send(HID.space, "\0", " ", .control), .send([0x00]))
        XCTAssertEqual(send(HID.two, "", "2", .control), .send([0x00]))
        XCTAssertEqual(send(HID.two, "", "@", [.control, .shift]), .send([0x00]))
        XCTAssertEqual(send(HID.backslash, "", "\\", .control), .send([0x1C]))
        XCTAssertEqual(send(HID.closeBracket, "", "]", .control), .send([0x1D]))
        XCTAssertEqual(send(0x23, "", "6", .control), .send([0x1E]))
        XCTAssertEqual(send(HID.minus, "", "-", .control), .send([0x1F]))
        XCTAssertEqual(send(HID.minus, "", "_", [.control, .shift]), .send([0x1F]))
        XCTAssertEqual(send(HID.slash, "", "/", .control), .send([0x1F]))
        XCTAssertEqual(send(HID.slash, "", "?", [.control, .shift]), .send([0x7F]))
    }

    func testControlUsesTheUSKeyOnOtherLayouts() {
        // Spanish layout: the key of US `]` is `+`, the one of US `\` is `ç`.
        XCTAssertEqual(send(HID.closeBracket, "", "+", .control), .send([0x1D]))
        XCTAssertEqual(send(HID.backslash, "", "ç", .control), .send([0x1C]))
        // A key without a control byte sends itself (Ctrl+1, Ctrl+ñ).
        XCTAssertEqual(send(HID.one, "1", "1", .control), bytes("1"))
        XCTAssertEqual(send(HID.semicolon, "ñ", "ñ", .control), bytes("ñ"))
    }

    func testControlTabIsAnAppShortcut() {
        XCTAssertEqual(send(HID.tab, "\t", "\t", .control), .ignore)
        XCTAssertEqual(send(HID.tab, "\t", "\t", [.control, .shift]), .ignore)
    }

    // MARK: Option (Meta or characters)

    func testOptionAsMeta() {
        XCTAssertEqual(send(HID.b, "∫", "b", .option), .send([0x1B, 0x62]))
        XCTAssertEqual(send(HID.f, "ƒ", "f", .option), .send([0x1B, 0x66]))
        XCTAssertEqual(send(HID.b, "ı", "b", [.option, .shift]), .send([0x1B, 0x42]))
        XCTAssertEqual(send(HID.period, "≥", ".", .option), .send([0x1B, 0x2E]))
        // A dead key under Option (US Option+E) is Meta-e, not a composition.
        XCTAssertEqual(send(HID.e, "", "e", .option), .send([0x1B, 0x65]))
        // Ctrl+Option+x: Esc + the control byte.
        XCTAssertEqual(send(HID.a, "", "a", [.control, .option]), .send([0x1B, 0x01]))
    }

    func testOptionTypesCharactersWhenNotMeta() {
        // Spanish layout: @ # € [ ] { } \ | ~ are Option combinations.
        XCTAssertEqual(send(HID.two, "@", "2", .option, noMeta), .system)
        XCTAssertEqual(send(0x20, "#", "3", .option, noMeta), .system)
        XCTAssertEqual(send(HID.e, "€", "e", .option, noMeta), .system)
        XCTAssertEqual(send(HID.openBracket, "[", "`", .option, noMeta), .system)
        XCTAssertEqual(send(HID.semicolon, "~", "ñ", .option, noMeta), .system)
        XCTAssertEqual(send(HID.one, "|", "1", .option, noMeta), .system)
        // Ctrl still works, without the Esc prefix.
        XCTAssertEqual(send(HID.a, "", "a", [.control, .option], noMeta), .send([0x01]))
    }

    // MARK: Tab, Enter, Backspace, Delete

    func testTabAndShiftTab() {
        XCTAssertEqual(send(HID.tab, "\t"), .send([0x09]))
        XCTAssertEqual(send(HID.tab, "\t", "\t", .shift), bytes("\u{1b}[Z"))
        XCTAssertEqual(send(HID.tab, "\t", "\t", .option), .send([0x1B, 0x09]))
    }

    func testEnterAndBackspace() {
        // Without modifiers the text system sends them (and repeats Backspace).
        XCTAssertEqual(send(HID.enter, "\r"), .system)
        XCTAssertEqual(send(HID.backspace, "\u{8}"), .system)
        XCTAssertEqual(send(HID.keypadEnter, "\r"), .system)
        XCTAssertEqual(send(HID.enter, "\r", "\r", .shift), .send([0x0D]))
        XCTAssertEqual(send(HID.enter, "\r", "\r", .option), .send([0x1B, 0x0D]))
        XCTAssertEqual(send(HID.backspace, "", "", .control), .send([0x08]))
        XCTAssertEqual(send(HID.backspace, "", "", .option), .send([0x1B, 0x7F]))
    }

    func testForwardDeleteAndInsert() {
        XCTAssertEqual(send(HID.deleteForward), bytes("\u{1b}[3~"))
        XCTAssertEqual(send(HID.deleteForward, "", "", .control), bytes("\u{1b}[3;5~"))
        XCTAssertEqual(send(HID.insert), bytes("\u{1b}[2~"))
    }

    // MARK: Arrows, Home/End, PgUp/PgDn

    func testArrows() {
        XCTAssertEqual(send(HID.up), bytes("\u{1b}[A"))
        XCTAssertEqual(send(HID.down), bytes("\u{1b}[B"))
        XCTAssertEqual(send(HID.right), bytes("\u{1b}[C"))
        XCTAssertEqual(send(HID.left), bytes("\u{1b}[D"))
    }

    func testArrowsInApplicationCursorMode() {
        XCTAssertEqual(send(HID.up, "", "", [], app), bytes("\u{1b}OA"))
        XCTAssertEqual(send(HID.left, "", "", [], app), bytes("\u{1b}OD"))
        XCTAssertEqual(send(HID.home, "", "", [], app), bytes("\u{1b}OH"))
        XCTAssertEqual(send(HID.end, "", "", [], app), bytes("\u{1b}OF"))
        // With modifiers it is always CSI.
        XCTAssertEqual(send(HID.up, "", "", .control, app), bytes("\u{1b}[1;5A"))
    }

    func testArrowsWithModifiers() {
        XCTAssertEqual(send(HID.up, "", "", .shift), bytes("\u{1b}[1;2A"))
        XCTAssertEqual(send(HID.up, "", "", .option), bytes("\u{1b}[1;3A"))
        XCTAssertEqual(send(HID.right, "", "", .control), bytes("\u{1b}[1;5C"))
        XCTAssertEqual(send(HID.left, "", "", [.control, .shift]), bytes("\u{1b}[1;6D"))
        XCTAssertEqual(send(HID.down, "", "", [.control, .option, .shift]), bytes("\u{1b}[1;8B"))
        XCTAssertEqual(send(HID.right, "", "", [.option, .shift]), bytes("\u{1b}[1;4C"))
        // Option+←/→ alone: a word (Meta-b / Meta-f), also with Option as characters.
        XCTAssertEqual(send(HID.left, "", "", .option), .send([0x1B, 0x62]))
        XCTAssertEqual(send(HID.right, "", "", .option, noMeta), .send([0x1B, 0x66]))
    }

    func testHomeEndPages() {
        XCTAssertEqual(send(HID.home), bytes("\u{1b}[H"))
        XCTAssertEqual(send(HID.end), bytes("\u{1b}[F"))
        XCTAssertEqual(send(HID.home, "", "", .control), bytes("\u{1b}[1;5H"))
        XCTAssertEqual(send(HID.pageUp), bytes("\u{1b}[5~"))
        XCTAssertEqual(send(HID.pageDown), bytes("\u{1b}[6~"))
        XCTAssertEqual(send(HID.pageUp, "", "", .control), bytes("\u{1b}[5;5~"))
        // Shift+PgUp/PgDn scroll the terminal's own history, like xterm.
        XCTAssertEqual(send(HID.pageUp, "", "", .shift), .scrollPage(up: true))
        XCTAssertEqual(send(HID.pageDown, "", "", .shift), .scrollPage(up: false))
    }

    // MARK: Function keys

    func testFunctionKeys() {
        XCTAssertEqual(send(HID.f1), bytes("\u{1b}OP"))
        XCTAssertEqual(send(HID.f1 + 3), bytes("\u{1b}OS"))
        XCTAssertEqual(send(HID.f5), bytes("\u{1b}[15~"))
        XCTAssertEqual(send(HID.f5 + 1), bytes("\u{1b}[17~"))
        XCTAssertEqual(send(HID.f10), bytes("\u{1b}[21~"))
        XCTAssertEqual(send(HID.f12 - 1), bytes("\u{1b}[23~"))
        XCTAssertEqual(send(HID.f12), bytes("\u{1b}[24~"))
        XCTAssertEqual(send(HID.f1, "", "", .shift), bytes("\u{1b}[1;2P"))
        XCTAssertEqual(send(HID.f5, "", "", .control), bytes("\u{1b}[15;5~"))
    }

    // MARK: The key bar's Ctrl and Alt

    func testStickyModifiersOfTheBar() {
        let ctrl = KeyEncodingOptions(stickyControl: true)
        let alt = KeyEncodingOptions(stickyAlt: true)
        XCTAssertEqual(send(HID.up, "", "", [], ctrl), bytes("\u{1b}[1;5A"))
        XCTAssertEqual(send(HID.left, "", "", [], alt), bytes("\u{1b}[1;3D"))
        XCTAssertEqual(send(HID.backspace, "", "", [], ctrl), .send([0x08]))
        // Characters with the bar's modifiers: SwiftTerm applies them.
        XCTAssertEqual(send(HID.c, "c", "c", [], ctrl), .system)
        XCTAssertEqual(send(HID.n, "n", "n", [], alt), .system)
    }

    // MARK: Control bytes

    func testControlCode() {
        XCTAssertEqual(HardwareKeyMap.controlCode("a"), 0x01)
        XCTAssertEqual(HardwareKeyMap.controlCode("Z"), 0x1A)
        XCTAssertEqual(HardwareKeyMap.controlCode("@"), 0x00)
        XCTAssertEqual(HardwareKeyMap.controlCode("?"), 0x7F)
        XCTAssertNil(HardwareKeyMap.controlCode("1"))
        XCTAssertNil(HardwareKeyMap.controlCode("ñ"))
        XCTAssertNil(HardwareKeyMap.controlCode("ab"))
        XCTAssertNil(HardwareKeyMap.controlCode(""))
    }

    // MARK: Lists (hosts, files)

    func testListKeys() {
        XCTAssertEqual(NavKey(hidUsage: HID.up), .up)
        XCTAssertEqual(NavKey(hidUsage: HID.enter), .enter)
        XCTAssertEqual(NavKey(hidUsage: HID.keypadEnter), .enter)
        XCTAssertEqual(NavKey(hidUsage: HID.space), .space)
        XCTAssertEqual(NavKey(hidUsage: HID.backspace), .delete)
        XCTAssertEqual(NavKey(hidUsage: HID.deleteForward), .delete)
        XCTAssertEqual(NavKey(hidUsage: HID.esc), .escape)
        XCTAssertNil(NavKey(hidUsage: HID.a))
    }

    func testMoveHighlight() {
        let items = ["a", "b", "c"]
        XCTAssertEqual(moveHighlight(nil, in: items, .down), "a")
        XCTAssertEqual(moveHighlight(nil, in: items, .up), "c")
        XCTAssertEqual(moveHighlight("a", in: items, .down), "b")
        XCTAssertEqual(moveHighlight("c", in: items, .down), "c")
        XCTAssertEqual(moveHighlight("a", in: items, .up), "a")
        XCTAssertEqual(moveHighlight("b", in: items, .home), "a")
        XCTAssertEqual(moveHighlight("a", in: items, .end), "c")
        XCTAssertEqual(moveHighlight("a", in: items, .pageDown), "c")
        XCTAssertEqual(moveHighlight("gone", in: items, .down), "a")
        XCTAssertNil(moveHighlight("gone", in: items, .enter))
        XCTAssertNil(moveHighlight("a", in: [String](), .down))
    }

    func testMoveInGrid() {
        // Two sections of cards, three per row:
        //   a b c      g h
        //   d e
        //   (empty section)
        let sections = [["a", "b", "c", "d", "e"], [], ["g", "h"]]
        XCTAssertEqual(moveInGrid(nil, in: sections, columns: 3, .down), "a")
        XCTAssertEqual(moveInGrid(nil, in: sections, columns: 3, .left), "h")
        XCTAssertEqual(moveInGrid("a", in: sections, columns: 3, .right), "b")
        XCTAssertEqual(moveInGrid("e", in: sections, columns: 3, .right), "g")
        XCTAssertEqual(moveInGrid("g", in: sections, columns: 3, .left), "e")
        XCTAssertEqual(moveInGrid("a", in: sections, columns: 3, .left), "a")
        XCTAssertEqual(moveInGrid("b", in: sections, columns: 3, .down), "e")
        // Nothing under c: the last card of its section.
        XCTAssertEqual(moveInGrid("c", in: sections, columns: 3, .down), "e")
        // From the last row, into the next section (the empty one is skipped).
        XCTAssertEqual(moveInGrid("d", in: sections, columns: 3, .down), "g")
        XCTAssertEqual(moveInGrid("e", in: sections, columns: 3, .down), "h")
        XCTAssertEqual(moveInGrid("h", in: sections, columns: 3, .down), "h")
        XCTAssertEqual(moveInGrid("e", in: sections, columns: 3, .up), "b")
        XCTAssertEqual(moveInGrid("h", in: sections, columns: 3, .up), "e")
        XCTAssertEqual(moveInGrid("g", in: sections, columns: 3, .up), "d")
        XCTAssertEqual(moveInGrid("b", in: sections, columns: 3, .up), "b")
        XCTAssertEqual(moveInGrid("c", in: sections, columns: 3, .end), "h")
        XCTAssertEqual(moveInGrid("h", in: sections, columns: 3, .home), "a")
        // One column: a list.
        XCTAssertEqual(moveInGrid("a", in: sections, columns: 1, .down), "b")
        XCTAssertEqual(moveInGrid("e", in: sections, columns: 1, .down), "g")
        XCTAssertNil(moveInGrid("gone", in: sections, columns: 3, .enter))
        XCTAssertNil(moveInGrid("a", in: [[String]](), columns: 3, .down))
    }
}
