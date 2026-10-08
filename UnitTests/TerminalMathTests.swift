import XCTest

/// Pinch, links, tab names (Termoak/Model/TerminalMath.swift).
final class TerminalMathTests: XCTestCase {
    func testPinchChangesTheSizeInWholePoints() {
        XCTAssertEqual(FontPinch.size(start: 13, scale: 1.05, minimum: 8, maximum: 24), 13)
        XCTAssertEqual(FontPinch.size(start: 13, scale: 0.95, minimum: 8, maximum: 24), 13)
        XCTAssertEqual(FontPinch.size(start: 13, scale: 1.5, minimum: 8, maximum: 24), 20)
        XCTAssertEqual(FontPinch.size(start: 13, scale: 0.5, minimum: 8, maximum: 24), 8)
        XCTAssertEqual(FontPinch.size(start: 20, scale: 3, minimum: 8, maximum: 24), 24)
        XCTAssertEqual(FontPinch.size(start: 13, scale: 0, minimum: 8, maximum: 24), 13)
    }

    func testLinkUnderTheTap() {
        let line = "see https://termoak.com/docs. and more"
        XCTAssertNil(TerminalLinks.link(in: line, at: 0))
        XCTAssertEqual(TerminalLinks.link(in: line, at: 4), "https://termoak.com/docs")
        XCTAssertEqual(TerminalLinks.link(in: line, at: 20), "https://termoak.com/docs")
        // The final dot is not part of it.
        XCTAssertNil(TerminalLinks.link(in: line, at: 28))
        XCTAssertNil(TerminalLinks.link(in: line, at: 30))
        XCTAssertNil(TerminalLinks.link(in: line, at: 200))
        XCTAssertEqual(TerminalLinks.link(in: "(http://a.example/x_(1))", at: 5), "http://a.example/x_(1)")
        XCTAssertEqual(TerminalLinks.link(in: "url=https://h.example/?q=1", at: 10), "https://h.example/?q=1")
        // Before the scheme, inside the same word: not the link.
        XCTAssertNil(TerminalLinks.link(in: "url=https://h.example/", at: 1))
        XCTAssertNil(TerminalLinks.link(in: "ftp://h.example/x", at: 3))
        XCTAssertNil(TerminalLinks.link(in: "https:// nothing", at: 2))
    }

    func testTabTitle() {
        XCTAssertEqual(TabTitle.display(custom: "prod", title: "vim", label: "web"), "prod")
        XCTAssertEqual(TabTitle.display(custom: "  ", title: "vim", label: "web"), "vim")
        XCTAssertEqual(TabTitle.display(custom: nil, title: "", label: "web"), "web")
        XCTAssertEqual(TabTitle.display(custom: nil, title: nil, label: "web"), "web")
    }
}
