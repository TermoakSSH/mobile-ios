import XCTest

/// Invitations of a session of another account through the generic API
/// (Termoak/Model/ShareJson.swift): the same bodies and fields as the engine.
final class ShareJsonTests: XCTestCase {
    private func roundTrip(_ body: [String: Any]) -> [String: Any] {
        ShareJson.object(ShareJson.encode(body))
    }

    func testShareBodies() {
        let link = roundTrip(ShareJson.shareBody(email: nil, teamId: nil, link: true, control: false, expiresInMinutes: nil,
                                                 requireApproval: true, autoGrant: false, controlMinutes: nil))
        XCTAssertEqual(link["permission"] as? String, "view")
        XCTAssertEqual(link["link"] as? Bool, true)
        XCTAssertEqual(link["require_approval"] as? Bool, true)
        XCTAssertTrue(link["expires_in_minutes"] is NSNull)
        XCTAssertNil(link["email"])
        XCTAssertNil(link["control_minutes"])

        let person = roundTrip(ShareJson.shareBody(email: " ana@example.com ", teamId: nil, link: false, control: true,
                                                   expiresInMinutes: 1440, requireApproval: nil, autoGrant: true, controlMinutes: 15))
        XCTAssertEqual(person["permission"] as? String, "control")
        XCTAssertEqual(person["email"] as? String, "ana@example.com")
        XCTAssertEqual((person["expires_in_minutes"] as? NSNumber)?.int64Value, 1440)
        XCTAssertEqual(person["auto_grant"] as? Bool, true)
        XCTAssertEqual((person["control_minutes"] as? NSNumber)?.intValue, 15)
        XCTAssertNil(person["require_approval"])
        XCTAssertNil(person["link"])

        let team = roundTrip(ShareJson.shareBody(email: nil, teamId: "t-1", link: false, control: false, expiresInMinutes: 60,
                                                 requireApproval: false, autoGrant: false, controlMinutes: nil))
        XCTAssertEqual(team["team_id"] as? String, "t-1")
    }

    func testChangesBody() {
        let b = roundTrip(ShareJson.changesBody(control: false, expiresInMinutes: nil, noExpiry: true, requireApproval: nil,
                                                autoGrant: nil, controlMinutes: 30, noControlLimit: true))
        XCTAssertEqual(b["permission"] as? String, "view")
        XCTAssertEqual(b["no_expiry"] as? Bool, true)
        XCTAssertEqual(b["no_control_limit"] as? Bool, true)
        // No limit wins over a new one.
        XCTAssertNil(b["control_minutes"])
        XCTAssertNil(b["expires_in_minutes"])
        let c = roundTrip(ShareJson.changesBody(control: nil, expiresInMinutes: 60, noExpiry: false, requireApproval: true,
                                                autoGrant: true, controlMinutes: 30, noControlLimit: false))
        XCTAssertNil(c["permission"])
        XCTAssertEqual((c["control_minutes"] as? NSNumber)?.intValue, 30)
        XCTAssertEqual((c["expires_in_minutes"] as? NSNumber)?.intValue, 60)
    }

    func testSharesAndInvites() {
        let list = ShareJson.array("""
        [{"id":"s1","session_id":"x","is_link":true,"permission":"control","expires_at":1700000000000,
          "revoked":false,"require_approval":true,"auto_grant":true,"created_at":5,"participants":2,"control_minutes":15},
         {"id":"s2","session_id":"x","team_id":"t","team_name":"Ops","permission":"view","revoked":true,"active":false},
         {"id":"s3","session_id":"x","user_id":"u","user_email":"ana@example.com","permission":"view","team_id":null}]
        """).map(ShareJson.share)
        XCTAssertEqual(list.map(\.kind), [.link, .team, .user])
        XCTAssertEqual(list[0].control, true)
        XCTAssertEqual(list[0].expiresAt, 1_700_000_000_000)
        XCTAssertEqual(list[0].participants, 2)
        XCTAssertEqual(list[0].controlMinutes, 15)
        XCTAssertEqual(list[0].active, true)
        XCTAssertEqual(list[1].teamName, "Ops")
        XCTAssertEqual(list[1].active, false)
        XCTAssertEqual(list[2].userEmail, "ana@example.com")
        XCTAssertNil(list[2].expiresAt)

        let invite = ShareJson.invite(ShareJson.object("""
        {"share":{"id":"s9","permission":"view"},"token":"tok","link":"https://termoak.com/join/tok","app_link":"termoak://join?token=tok"}
        """))
        XCTAssertEqual(invite, ShareJson.Invite(shareId: "s9", permission: "view", token: "tok",
                                                link: "https://termoak.com/join/tok", appLink: "termoak://join?token=tok"))
        XCTAssertEqual(ShareJson.revokedCount(ShareJson.object("{\"revoked\":3}")), 3)
        XCTAssertEqual(ShareJson.revokedCount([:]), 0)
    }
}
