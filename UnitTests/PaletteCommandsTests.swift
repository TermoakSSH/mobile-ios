import XCTest

final class PaletteCommandsTests: XCTestCase {
    func testNothingOpen() {
        XCTAssertEqual(PaletteCommand.available(.init()), [.toggleTheme])
    }

    func testOneTerminalShown() {
        let s = PaletteCommand.State(tabs: 1, terminalShown: true, splitAvailable: true, splitActive: false)
        XCTAssertEqual(PaletteCommand.available(s), [.home, .closeTab, .zoomIn, .zoomOut, .zoomReset, .toggleTheme])
    }

    func testSplitView() {
        let s = PaletteCommand.State(tabs: 3, terminalShown: true, splitAvailable: true, splitActive: true)
        let a = PaletteCommand.available(s)
        XCTAssertTrue(a.contains(.addToSplit) && a.contains(.focusMode) && a.contains(.broadcast) && a.contains(.nextTab))
        let phone = PaletteCommand.State(tabs: 3, terminalShown: false, splitAvailable: false, splitActive: false)
        XCTAssertFalse(PaletteCommand.available(phone).contains(.addToSplit))
        XCTAssertFalse(PaletteCommand.available(phone).contains(.closeTab))
    }

    func testKeys() {
        XCTAssertEqual(PaletteCommand.zoomIn.key, "cmd:zoomIn")
        XCTAssertEqual(PaletteKey.host("device/1"), "host:device/1")
        XCTAssertFalse(PaletteKey.remembered(PaletteKey.tab(UUID())))
        XCTAssertTrue(PaletteKey.remembered("host:a/b"))
    }
}
