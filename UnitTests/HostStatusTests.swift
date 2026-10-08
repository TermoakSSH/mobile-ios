import XCTest

final class HostStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func check(_ secondsAgo: TimeInterval, _ target: String = "web:22") -> HostCheck {
        HostCheck(dot: .up(ms: 10), checkedAt: now.addingTimeInterval(-secondsAgo), target: target)
    }

    func testNeverCheckedIsDue() {
        XCTAssertEqual(HostStatusPlan.due([("a", "web:22")], checks: [:], inFlight: [], now: now), ["a"])
    }

    func testOncePerMinute() {
        let hosts = [(key: "a", target: "web:22"), (key: "b", target: "web:22")]
        let checks = ["a": check(30), "b": check(60)]
        XCTAssertEqual(HostStatusPlan.due(hosts, checks: checks, inFlight: [], now: now), ["b"])
    }

    func testChangedTargetIsDueAtOnce() {
        let checks = ["a": check(5, "web:22")]
        XCTAssertEqual(HostStatusPlan.due([("a", "web:2222")], checks: checks, inFlight: [], now: now), ["a"])
    }

    func testInFlightAndRepeatedAreLeftOut() {
        let hosts = [(key: "a", target: "x:22"), (key: "b", target: "x:22"), (key: "b", target: "x:22")]
        XCTAssertEqual(HostStatusPlan.due(hosts, checks: [:], inFlight: ["a"], now: now), ["b"])
    }

    func testTarget() {
        XCTAssertEqual(HostStatusPlan.target(address: "Web.Example.com", port: nil, telnet: false), "web.example.com:22")
        XCTAssertEqual(HostStatusPlan.target(address: "router", port: nil, telnet: true), "router:23")
        XCTAssertEqual(HostStatusPlan.target(address: "h", port: 2222, telnet: false), "h:2222")
    }

    func testLatency() {
        XCTAssertEqual(HostStatusPlan.latency(12), "12 ms")
        XCTAssertEqual(HostStatusPlan.latency(999), "999 ms")
        XCTAssertEqual(HostStatusPlan.latency(1234), "1.2 s")
        XCTAssertEqual(HostStatusPlan.latency(2960), "3.0 s")
    }

    func testToggled() {
        XCTAssertEqual(HostStatusPlan.toggled(["a"], "b"), ["a", "b"])
        XCTAssertEqual(HostStatusPlan.toggled(["a", "b"], "a"), ["b"])
    }
}
