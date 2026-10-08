import XCTest

/// The engine's host key messages, read to be translated
/// (Termoak/Model/EngineMessages.swift).
final class EngineMessagesTests: XCTestCase {
    func testHostKeyMessages() {
        XCTAssertEqual(HostKeyProblem.parse(
            "the host key of web.example.com:2222 has CHANGED (expected SHA256:abc, got SHA256:xyz). Possible man-in-the-middle attack"),
            .changed(host: "web.example.com:2222", expected: "SHA256:abc", actual: "SHA256:xyz"))
        XCTAssertEqual(HostKeyProblem.parse("unknown host 10.0.0.5 with fingerprint SHA256:q+/w: it must be confirmed before connecting"),
                       .unknown(host: "10.0.0.5", fingerprint: "SHA256:q+/w"))
        XCTAssertEqual(HostKeyProblem.parse("host key rejected by the user (router)"), .rejected(host: "router"))
        XCTAssertNil(HostKeyProblem.parse("connection refused"))
        XCTAssertNil(HostKeyProblem.parse("host key rejected by the user ()"))
    }

    func testHostAndPortOfAChangedKey() {
        XCTAssertTrue(HostKeyProblem.hostAndPort("web.example.com:2222")! == ("web.example.com", 2222))
        XCTAssertTrue(HostKeyProblem.hostAndPort("2001:db8::1:22")! == ("2001:db8::1", 22))
        XCTAssertTrue(HostKeyProblem.hostAndPort("[2001:db8::1]:22")! == ("2001:db8::1", 22))
        XCTAssertNil(HostKeyProblem.hostAndPort("router"))
        XCTAssertNil(HostKeyProblem.hostAndPort(":22"))
        XCTAssertNil(HostKeyProblem.hostAndPort("host:99999"))
    }
}
