import XCTest

/// Who can do what in a team (Termoak/Model/TeamRules.swift), like the
/// desktop's tests.
final class TeamRulesTests: XCTestCase {
    func testMembersCanOnlyLookAndLeave() {
        let r = TeamRules(mine: .member)
        XCTAssertFalse(r.canRename)
        XCTAssertFalse(r.canDelete)
        XCTAssertFalse(r.canAddMembers)
        XCTAssertFalse(r.canSeeInvites)
        XCTAssertFalse(r.canRemove(.member))
        XCTAssertFalse(r.canSetRole(of: .member, to: .admin))
        XCTAssertEqual(r.roles(for: .admin), [.admin])
        XCTAssertTrue(r.canLeave)
    }

    func testAdminsManageMembersButNotOwners() {
        let r = TeamRules(mine: .admin)
        XCTAssertTrue(r.canRename)
        XCTAssertFalse(r.canDelete)
        XCTAssertTrue(r.canAddMembers)
        XCTAssertEqual(r.rolesToGrant, [.member, .admin])
        XCTAssertTrue(r.canRemove(.member))
        XCTAssertTrue(r.canRemove(.admin))
        XCTAssertFalse(r.canRemove(.owner))
        XCTAssertTrue(r.canSetRole(of: .member, to: .admin))
        XCTAssertFalse(r.canSetRole(of: .member, to: .owner))
        XCTAssertFalse(r.canSetRole(of: .owner, to: .member))
        XCTAssertFalse(r.canSetRole(of: .admin, to: .admin))
        XCTAssertEqual(r.roles(for: .member), [.member, .admin])
        XCTAssertEqual(r.roles(for: .owner), [.owner])
    }

    func testOwnersCanDoEverything() {
        let r = TeamRules(mine: .owner)
        XCTAssertTrue(r.canDelete)
        XCTAssertEqual(r.rolesToGrant, [.member, .admin, .owner])
        XCTAssertTrue(r.canRemove(.owner))
        XCTAssertTrue(r.canSetRole(of: .owner, to: .member))
        XCTAssertEqual(r.roles(for: .admin), [.member, .admin, .owner])
    }

    func testServerAdminOutsideTheTeam() {
        let r = TeamRules(mine: nil)
        XCTAssertTrue(r.canDelete)
        XCTAssertTrue(r.canAddMembers)
        XCTAssertFalse(r.canLeave)
    }
}
