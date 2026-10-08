import XCTest

/// Telnet hosts, quick connect addresses, host logos and the layout of wide
/// windows (Termoak/Model/HostProtocols.swift, HostLogos.swift and
/// Layouts.swift, compiled directly into the target like HardwareKeys.swift).
final class HostLogicTests: XCTestCase {
    // MARK: Protocol switching

    func testDefaultPorts() {
        XCTAssertEqual(HostProtocol.defaultPort("ssh"), 22)
        XCTAssertEqual(HostProtocol.defaultPort("telnet"), 23)
        XCTAssertEqual(HostProtocol.defaultPort(" Telnet "), 23)
        // A later version's protocol is treated like SSH.
        XCTAssertEqual(HostProtocol.defaultPort("rdp"), 22)
        XCTAssertTrue(HostProtocol.isTelnet("TELNET"))
        XCTAssertFalse(HostProtocol.isTelnet("ssh"))
    }

    func testPortFollowsTheProtocolWhenDefaultOrEmpty() {
        let ssh = HostProtocol.ssh, telnet = HostProtocol.telnet
        XCTAssertEqual(HostProtocol.portAfterSwitch(from: ssh, to: telnet, text: ""), "23")
        XCTAssertEqual(HostProtocol.portAfterSwitch(from: ssh, to: telnet, text: " 22 "), "23")
        XCTAssertEqual(HostProtocol.portAfterSwitch(from: telnet, to: ssh, text: "23"), "")
        XCTAssertEqual(HostProtocol.portAfterSwitch(from: telnet, to: ssh, text: ""), "")
        XCTAssertEqual(HostProtocol.portAfterSwitch(from: telnet, to: telnet, text: "23"), "23")
    }

    func testOtherPortsStay() {
        XCTAssertEqual(HostProtocol.portAfterSwitch(from: "ssh", to: "telnet", text: "2222"), "2222")
        XCTAssertEqual(HostProtocol.portAfterSwitch(from: "telnet", to: "ssh", text: "2323"), "2323")
        // Text that is not a port is left for the form to flag.
        XCTAssertEqual(HostProtocol.portAfterSwitch(from: "ssh", to: "telnet", text: "abc"), "abc")
        XCTAssertEqual(HostProtocol.portAfterSwitch(from: "ssh", to: "telnet", text: "70000"), "70000")
    }

    // MARK: Quick connect addresses

    private func telnet(_ user: String?, _ host: String, _ port: UInt32?) -> QuickTarget {
        QuickTarget(protocol: "telnet", user: user, host: host, port: port)
    }

    private func ssh(_ user: String?, _ host: String, _ port: UInt32?) -> QuickTarget {
        QuickTarget(protocol: "ssh", user: user, host: host, port: port)
    }

    func testTelnetUrls() {
        XCTAssertEqual(QuickTarget.parse("telnet://10.0.0.1"), telnet(nil, "10.0.0.1", nil))
        XCTAssertEqual(QuickTarget.parse(" TELNET://admin@switch1:2323/ "), telnet("admin", "switch1", 2323))
        XCTAssertEqual(QuickTarget.parse("telnet://router"), telnet(nil, "router", nil))
        XCTAssertEqual(QuickTarget.parse("telnet://[2001:db8::1]:23"), telnet(nil, "2001:db8::1", 23))
        XCTAssertEqual(QuickTarget.parse("telnet towel.blinkenlights.nl 23"), telnet(nil, "towel.blinkenlights.nl", 23))
        XCTAssertEqual(QuickTarget.parse("telnet bbs"), telnet(nil, "bbs", nil))
    }

    func testWrongTelnetUrls() {
        XCTAssertNil(QuickTarget.parse("telnet://"))
        XCTAssertNil(QuickTarget.parse("telnet://h:0"))
        XCTAssertNil(QuickTarget.parse("telnet://h:99999"))
        XCTAssertNil(QuickTarget.parse("telnet://@h"))
        XCTAssertNil(QuickTarget.parse("telnet h 23 extra"))
        XCTAssertNil(QuickTarget.parse("telnet h port"))
    }

    func testSshAddresses() {
        XCTAssertEqual(QuickTarget.parse("root@web1.example.com"), ssh("root", "web1.example.com", nil))
        XCTAssertEqual(QuickTarget.parse("web1:2222"), ssh(nil, "web1", 2222))
        XCTAssertEqual(QuickTarget.parse("ssh deploy@10.0.0.5 -p 2200"), ssh("deploy", "10.0.0.5", 2200))
        XCTAssertEqual(QuickTarget.parse("ssh://bastion"), ssh(nil, "bastion", nil))
        XCTAssertEqual(QuickTarget.parse("[::1]:22"), ssh(nil, "::1", 22))
        // A search word is not an address.
        XCTAssertNil(QuickTarget.parse("production"))
        XCTAssertNil(QuickTarget.parse(""))
    }

    func testDisplayAndPorts() {
        XCTAssertEqual(telnet("a", "h", 2323).display, "telnet://a@h:2323")
        XCTAssertEqual(telnet(nil, "2001:db8::1", 23).display, "telnet://[2001:db8::1]:23")
        XCTAssertEqual(ssh("root", "h", nil).display, "root@h")
        XCTAssertEqual(telnet(nil, "h", nil).effectivePort, 23)
        XCTAssertEqual(ssh(nil, "h", nil).effectivePort, 22)
        XCTAssertTrue(telnet(nil, "h", nil).isTelnet)
    }

    // MARK: Logos

    func testChosenLogoFirst() {
        XCTAssertEqual(HostLogo.resolve(icon: "router", os: "ubuntu")?.id, "router")
        XCTAssertEqual(HostLogo.resolve(icon: " Debian ", os: nil)?.id, "debian")
    }

    func testDetectedSystemThenNothing() {
        XCTAssertEqual(HostLogo.resolve(icon: nil, os: "ubuntu")?.id, "ubuntu")
        XCTAssertEqual(HostLogo.resolve(icon: nil, os: "linuxmint")?.id, "mint")
        XCTAssertEqual(HostLogo.resolve(icon: nil, os: "raspbian")?.id, "raspberrypi")
        XCTAssertEqual(HostLogo.resolve(icon: nil, os: "darwin")?.id, "macos")
        XCTAssertEqual(HostLogo.resolve(icon: nil, os: "opensuse-tumbleweed")?.id, "opensuse")
        XCTAssertNil(HostLogo.resolve(icon: nil, os: nil))
        XCTAssertNil(HostLogo.resolve(icon: nil, os: "plan9"))
    }

    func testUnknownOrGenericIdsAreNotDetected() {
        // A later version's logo: automatic.
        XCTAssertEqual(HostLogo.resolve(icon: "hologram", os: "debian")?.id, "debian")
        XCTAssertNil(HostLogo.resolve(icon: "hologram", os: nil))
        // A system called "server" is not the generic server logo.
        XCTAssertNil(HostLogo.forOs("server"))
    }

    func testLogoCatalog() {
        let ids = HostLogo.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(HostLogo.systems.count, 26)
        XCTAssertEqual(HostLogo.generics.count, 13)
        XCTAssertEqual(HostLogo.byId("ubuntu")?.assetName, "HostLogo/ubuntu")
        XCTAssertEqual(HostLogo.byId("server")?.kind, .generic(symbol: "server.rack"))
    }

    // MARK: Layout of wide windows

    func testAutomaticLayout() {
        XCTAssertTrue(WideLayout.automatic.usesDesktop(pad: true, regularWidth: true))
        XCTAssertFalse(WideLayout.automatic.usesDesktop(pad: true, regularWidth: false))
        // An iPhone Plus/Pro Max in landscape keeps the phone layout.
        XCTAssertFalse(WideLayout.automatic.usesDesktop(pad: false, regularWidth: true))
        XCTAssertFalse(WideLayout.automatic.usesDesktop(pad: false, regularWidth: false))
    }

    func testPhoneAndDesktopLayouts() {
        XCTAssertFalse(WideLayout.phone.usesDesktop(pad: true, regularWidth: true))
        XCTAssertTrue(WideLayout.desktop.usesDesktop(pad: false, regularWidth: true))
        XCTAssertTrue(WideLayout.desktop.usesDesktop(pad: true, regularWidth: true))
        // Narrow windows always get the phone layout.
        XCTAssertFalse(WideLayout.desktop.usesDesktop(pad: false, regularWidth: false))
        XCTAssertFalse(WideLayout.desktop.usesDesktop(pad: true, regularWidth: false))
        XCTAssertEqual(WideLayout(rawValue: "automatic"), .automatic)
    }

    // MARK: Latency

    func testLatencyBadge() {
        XCTAssertEqual(Latency.text(nil), "—")
        XCTAssertEqual(Latency.text(0.3), "<1 ms")
        XCTAssertEqual(Latency.text(42.7), "42 ms")
        XCTAssertEqual(Latency.level(nil), .unknown)
        XCTAssertEqual(Latency.level(149), .good)
        XCTAssertEqual(Latency.level(150), .fair)
        XCTAssertEqual(Latency.level(399), .fair)
        XCTAssertEqual(Latency.level(400), .poor)
    }
}
