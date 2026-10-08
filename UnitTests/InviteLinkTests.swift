import XCTest

/// The server of a link (Termoak/Model/InviteLink.swift); the links
/// themselves are read by the engine's parseLink, tested in core.
final class InviteLinkTests: XCTestCase {
    func testServerKeepsItsPath() {
        XCTAssertEqual(LinkServer.clean(" https://ssh.example.com/ "), "https://ssh.example.com")
        XCTAssertEqual(LinkServer.clean("https://example.com:8443/termoak"), "https://example.com:8443/termoak")
        XCTAssertEqual(LinkServer.clean("http://10.0.0.5:8080/apps/termoak/"), "http://10.0.0.5:8080/apps/termoak")
    }

    func testLanguageOfTheWebsiteIsNotAPath() {
        XCTAssertEqual(LinkServer.clean("https://termoak.com/es"), "https://termoak.com")
        XCTAssertEqual(LinkServer.clean("https://termoak.com/en/"), "https://termoak.com")
        XCTAssertEqual(LinkServer.clean("https://example.com/t1"), "https://example.com/t1")
        XCTAssertEqual(LinkServer.clean("https://example.com/es/termoak"), "https://example.com/es/termoak")
    }
}
