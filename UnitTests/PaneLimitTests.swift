import XCTest

/// How many terminals a window shows side by side (Termoak/Model/Panes.swift).
final class PaneLimitTests: XCTestCase {
    func testPaneLimit() {
        // iPad (or Mac) with room: 4, whatever the layout.
        XCTAssertEqual(PaneLayout.paneLimit(pad: true, regularWidth: true, desktopLayout: true), 4)
        XCTAssertEqual(PaneLayout.paneLimit(pad: true, regularWidth: true, desktopLayout: false), 4)
        // iPhone Plus/Pro Max in landscape: 2 in the desktop layout only.
        XCTAssertEqual(PaneLayout.paneLimit(pad: false, regularWidth: true, desktopLayout: true), 2)
        XCTAssertEqual(PaneLayout.paneLimit(pad: false, regularWidth: true, desktopLayout: false), 1)
        // Narrow windows: no split view.
        XCTAssertEqual(PaneLayout.paneLimit(pad: true, regularWidth: false, desktopLayout: false), 1)
        XCTAssertEqual(PaneLayout.paneLimit(pad: false, regularWidth: false, desktopLayout: true), 1)
    }

    func testTwoPanesSideBySide() {
        XCTAssertEqual(PaneLayout.gridRows(2), [2])
        XCTAssertEqual(PaneLayout.neighbor(2, from: 0, .right), 1)
        XCTAssertEqual(PaneLayout.neighbor(2, from: 1, .right), 0)
        XCTAssertNil(PaneLayout.neighbor(2, from: 0, .up))
    }
}
