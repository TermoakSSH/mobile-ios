import XCTest

/// When the app lock asks again (Termoak/Model/LockPolicy.swift).
final class LockPolicyTests: XCTestCase {
    func testLocksAfterTheChosenTimeInTheBackground() {
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(LockPolicy.shouldLock(enabled: false, delay: .immediately, backgroundedAt: t0, now: t0.addingTimeInterval(999)))
        XCTAssertFalse(LockPolicy.shouldLock(enabled: true, delay: .immediately, backgroundedAt: nil, now: t0))
        XCTAssertTrue(LockPolicy.shouldLock(enabled: true, delay: .immediately, backgroundedAt: t0, now: t0))
        XCTAssertFalse(LockPolicy.shouldLock(enabled: true, delay: .fiveMinutes, backgroundedAt: t0, now: t0.addingTimeInterval(299)))
        XCTAssertTrue(LockPolicy.shouldLock(enabled: true, delay: .fiveMinutes, backgroundedAt: t0, now: t0.addingTimeInterval(300)))
        XCTAssertEqual(LockDelay(rawValue: 900), .fifteenMinutes)
    }
}
