import XCTest

/// Deleting the account: the request and the server's refusals from the
/// error's status, code and details (the engine's `apiError`;
/// Termoak/Model/AccountDeletion.swift).
final class AccountDeletionTests: XCTestCase {
    private func problem(_ status: Int, _ code: String, _ details: String = "{}") -> AccountDeletionProblem? {
        AccountDeletionProblem.from(ServerFailure(status: status, code: code, message: "message", detailsJson: details))
    }

    func testProblems() {
        XCTAssertEqual(problem(403, "invalid_password"), .wrongPassword)
        XCTAssertEqual(problem(401, "totp_required"), .codeRequired)
        XCTAssertEqual(problem(401, "totp_invalid"), .codeInvalid)
        XCTAssertEqual(problem(409, "last_admin"), .lastAdmin)
        // The teams come from the error's details, not from its text.
        XCTAssertEqual(problem(409, "last_team_owner", "{\"teams\":[\"Ops\",\"Dev\"]}"), .lastTeamOwner(teams: ["Ops", "Dev"]))
        XCTAssertEqual(problem(409, "last_team_owner"), .lastTeamOwner(teams: []))
        XCTAssertEqual(AccountDeletionProblem.quoted(["Ops", "Dev"]), "“Ops”, “Dev”")
        // The shared vaults that block it ({id, name, member_count}).
        XCTAssertEqual(
            problem(409, "shared_vaults",
                    "{\"vaults\":[{\"id\":\"v1\",\"name\":\"Ops\",\"member_count\":3},{\"id\":\"v2\",\"name\":\"Family\"},{\"name\":\"\"}]}"),
            .sharedVaults([SharedVault(name: "Ops", members: 3), SharedVault(name: "Family", members: nil)]))
        XCTAssertEqual(problem(409, "shared_vaults", "not json"), .sharedVaults([]))
        XCTAssertEqual(problem(404, "error"), .unsupported)
        XCTAssertEqual(problem(405, "error"), .unsupported)
        XCTAssertNil(problem(500, "internal"))
        XCTAssertNil(problem(0, "network_unavailable"))
    }

    func testBody() {
        XCTAssertEqual(AccountDeletion.body(password: "p\"w", totpCode: nil, deleteSharedVaults: false), "{\"password\":\"p\\\"w\"}")
        XCTAssertEqual(AccountDeletion.body(password: "pw", totpCode: " 123456 ", deleteSharedVaults: true),
                       "{\"delete_shared_vaults\":true,\"password\":\"pw\",\"totp_code\":\"123456\"}")
        XCTAssertEqual(AccountDeletion.body(password: "pw", totpCode: "  ", deleteSharedVaults: false), "{\"password\":\"pw\"}")
    }

    func testTwoFactorAndWord() {
        XCTAssertTrue(AccountDeletion.twoFactorEnabled(meJson: "{\"user\":{\"email\":\"a@example.com\",\"totp_enabled\":true}}"))
        XCTAssertFalse(AccountDeletion.twoFactorEnabled(meJson: "{\"user\":{\"totp_enabled\":false}}"))
        XCTAssertFalse(AccountDeletion.twoFactorEnabled(meJson: "null"))
        XCTAssertTrue(AccountDeletion.confirmed(" DELETE \n", word: "DELETE"))
        XCTAssertFalse(AccountDeletion.confirmed("delete", word: "DELETE"))
    }
}
