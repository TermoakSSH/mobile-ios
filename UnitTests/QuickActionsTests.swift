import XCTest

/// Home-screen Quick Actions: their identifiers and the hosts offered
/// (Termoak/Model/QuickActions.swift).
final class QuickActionsTests: XCTestCase {
    func testActionsRoundTrip() {
        for action in [QuickAction.quickConnect, .join, .host(id: "h1", accountId: "a1"), .host(id: "h2", accountId: nil)] {
            XCTAssertEqual(QuickAction(type: action.type, userInfo: action.userInfo), action)
        }
        XCTAssertNil(QuickAction(type: "com.termoak.host", userInfo: [:]))
        XCTAssertNil(QuickAction(type: "com.other", userInfo: nil))
    }

    func testRecentHosts() {
        var r = RecentHosts()
        for k in ["a", "b", "c", "a"] { r.record(k) }
        XCTAssertEqual(r.keys, ["a", "c", "b"])
        for i in 0..<20 { r.record("k\(i)") }
        XCTAssertEqual(r.keys.count, RecentHosts.limit)
        XCTAssertEqual(r.keys.first, "k19")
    }

    func testFavoritesFirstThenRecentOnlyExisting() {
        let r = RecentHosts(keys: ["x", "gone", "y", "f1"])
        XCTAssertEqual(r.pick(favorites: ["f1", "f2"], available: ["f1", "f2", "x", "y"]), ["f1", "f2", "x"])
        XCTAssertEqual(r.pick(favorites: [], available: ["x", "y"]), ["x", "y"])
        XCTAssertEqual(r.pick(favorites: [], available: []), [])
    }
}
