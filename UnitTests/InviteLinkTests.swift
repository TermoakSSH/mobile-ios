import XCTest

/// `termoak://invite` links (Termoak/Model/InviteLink.swift).
final class InviteLinkTests: XCTestCase {
    func testInviteLinks() {
        XCTAssertEqual(InviteLink.parse("termoak://invite?server=https%3A%2F%2Fssh.example.com%2F&token=abc_DEF-123"),
                       InviteLink(server: "https://ssh.example.com", token: "abc_DEF-123"))
        XCTAssertEqual(InviteLink.parse(" aceitunoak://invite?token=x1&server=http://10.0.0.2:8080 "),
                       InviteLink(server: "http://10.0.0.2:8080", token: "x1"))
        XCTAssertNil(InviteLink.parse("abc_DEF-123"))
        XCTAssertNil(InviteLink.parse("https://example.com/?token=x"))
        XCTAssertNil(InviteLink.parse("termoak://invite?token=x"))
        XCTAssertNil(InviteLink.parse("termoak://invite?server=https%3A%2F%2Fa.b&token"))
        XCTAssertNil(InviteLink.parse("termoak://invite?server=&token=abc"))
        XCTAssertNil(InviteLink.parse("termoak://invite?server=ftp://a.b&token=abc"))
        XCTAssertNil(InviteLink.parse("termoak://invite?server=https://a.b&token=a%20b"))
        // A join link is not an invitation.
        XCTAssertNil(InviteLink.parse("termoak://join?server=https://a.b&token=abc"))
    }
}
