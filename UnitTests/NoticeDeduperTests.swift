import XCTest

/// Sharing notices that arrive twice become one notification
/// (Termoak/Model/NoticeDeduper.swift).
final class NoticeDeduperTests: XCTestCase {
    func testTheSameNoticeOnlyOnceWithinTheWindow() {
        var d = NoticeDeduper(window: 15)
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(d.isNew("join:s1:p1", at: t0))
        XCTAssertFalse(d.isNew("join:s1:p1", at: t0.addingTimeInterval(5)))
        XCTAssertTrue(d.isNew("control:s1:p1", at: t0.addingTimeInterval(5)))
        XCTAssertTrue(d.isNew("join:s1:p2", at: t0.addingTimeInterval(6)))
        XCTAssertTrue(d.isNew("join:s1:p1", at: t0.addingTimeInterval(16)))
    }
}
