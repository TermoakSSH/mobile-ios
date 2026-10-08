import XCTest

/// authorized_keys, text files and typed paths (Termoak/Model/KeyTools.swift).
final class KeyToolsTests: XCTestCase {
    private let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbc ana@phone"

    func testKeyIdentity() {
        XCTAssertEqual(AuthorizedKeys.identity(key), "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbc")
        XCTAssertEqual(AuthorizedKeys.identity("no-pty,from=\"10.0.0.1\" ecdsa-sha2-nistp256 AAAAE2 x"), "ecdsa-sha2-nistp256 AAAAE2")
        XCTAssertNil(AuthorizedKeys.identity("# a comment"))
        XCTAssertNil(AuthorizedKeys.identity("ssh-rsa"))
    }

    func testAlreadyInstalled() {
        let file = "# keys\nssh-rsa AAAAB3 old\nno-pty ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbc other comment\n"
        XCTAssertTrue(AuthorizedKeys.contains(file, publicKey: key))
        XCTAssertFalse(AuthorizedKeys.contains("ssh-ed25519 AAAAOTHER x\n", publicKey: key))
        XCTAssertFalse(AuthorizedKeys.contains("#ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbc\n", publicKey: key))
        XCTAssertFalse(AuthorizedKeys.contains("", publicKey: key))
    }

    func testAppending() {
        XCTAssertEqual(AuthorizedKeys.appending("", publicKey: key + "\n"), key + "\n")
        XCTAssertEqual(AuthorizedKeys.appending("ssh-rsa A b\n", publicKey: key), "ssh-rsa A b\n" + key + "\n")
        XCTAssertEqual(AuthorizedKeys.appending("ssh-rsa A b", publicKey: key), "ssh-rsa A b\n" + key + "\n")
    }

    func testTextFiles() {
        XCTAssertEqual(TextFiles.decode(Data("port 22\n".utf8)), "port 22\n")
        XCTAssertNil(TextFiles.decode(Data([0x7f, 0x45, 0x00, 0x46])))
        XCTAssertNil(TextFiles.decode(Data([0xff, 0xfe, 0xfd])))
        XCTAssertEqual(TextFiles.decode(Data()), "")
    }

    func testGoToPath() {
        XCTAssertEqual(TextFiles.resolve("/etc/nginx/", current: "/home/ana", home: "/home/ana"), "/etc/nginx")
        XCTAssertEqual(TextFiles.resolve("~", current: "/", home: "/home/ana"), "/home/ana")
        XCTAssertEqual(TextFiles.resolve("~/logs", current: "/", home: "/home/ana"), "/home/ana/logs")
        XCTAssertEqual(TextFiles.resolve("src", current: "/srv/app", home: "/home/ana"), "/srv/app/src")
        XCTAssertEqual(TextFiles.resolve("/", current: "/srv", home: "/root"), "/")
        XCTAssertNil(TextFiles.resolve("  ", current: "/", home: "/"))
    }
}
