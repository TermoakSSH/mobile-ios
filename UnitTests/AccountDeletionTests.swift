import XCTest

/// Deleting the account: the request and the server's refusals as the
/// engine writes them (Termoak/Model/AccountDeletion.swift).
final class AccountDeletionTests: XCTestCase {
    func testServerFailure() {
        XCTAssertEqual(ServerFailure.parse("the server responded 403 (invalid_password): the password is not correct"),
                       ServerFailure(status: 403, code: "invalid_password", message: "the password is not correct"))
        XCTAssertEqual(ServerFailure.parse("the server responded 405 (error): "),
                       ServerFailure(status: 405, code: "error", message: ""))
        XCTAssertNil(ServerFailure.parse("network: connection refused"))
        XCTAssertNil(ServerFailure.parse("the server responded soon"))
    }

    func testProblems() {
        XCTAssertEqual(AccountDeletionProblem.parse("the server responded 403 (invalid_password): the password is not correct"), .wrongPassword)
        XCTAssertEqual(AccountDeletionProblem.parse("the server responded 401 (totp_required): enter the two-step verification code"), .codeRequired)
        XCTAssertEqual(AccountDeletionProblem.parse("the server responded 401 (totp_invalid): the verification code is not correct"), .codeInvalid)
        XCTAssertEqual(AccountDeletionProblem.parse(
            "the server responded 409 (last_admin): you are the only administrator: appoint another one before deleting your account"), .lastAdmin)
        XCTAssertEqual(AccountDeletionProblem.parse(
            "the server responded 409 (last_team_owner): you are the only owner of \"Ops\", \"Dev\": appoint another owner or delete the team first"),
            .lastTeamOwner(teams: "\"Ops\", \"Dev\""))
        XCTAssertEqual(AccountDeletionProblem.parse("the server responded 409 (last_team_owner): something else"), .lastTeamOwner(teams: nil))
        XCTAssertEqual(AccountDeletionProblem.parse(
            "the server responded 409 (shared_vaults): your shared vaults with members will be deleted with the account: confirm with delete_shared_vaults"),
            .sharedVaults)
        XCTAssertEqual(AccountDeletionProblem.parse("the server responded 404 (error): Not Found"), .unsupported)
        XCTAssertEqual(AccountDeletionProblem.parse("the server responded 405 (error): "), .unsupported)
        XCTAssertNil(AccountDeletionProblem.parse("the server responded 500 (internal): boom"))
        XCTAssertNil(AccountDeletionProblem.parse("Not available in the demo"))
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
