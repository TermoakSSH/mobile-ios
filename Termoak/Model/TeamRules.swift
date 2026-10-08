import Foundation

/// A role in a team, in order (the engine's `TeamRole` without the engine,
/// so the unit tests compile this file on its own).
enum TeamLevel: Int, Comparable {
    case member, admin, owner

    static func < (a: TeamLevel, b: TeamLevel) -> Bool { a.rawValue < b.rawValue }
}

/// What someone can do in a team, the desktop's rules (`views/teams.rs`):
/// admins add and remove members (not owners) and rename it; owners also
/// appoint owners and delete it. `mine == nil` is a server administrator who
/// is not in the team: they manage it like an owner (the server decides) but
/// cannot leave it.
struct TeamRules: Equatable {
    let mine: TeamLevel?

    private var manage: Bool { mine.map { $0 >= .admin } ?? true }
    private var owner: Bool { mine.map { $0 == .owner } ?? true }

    var canRename: Bool { manage }
    var canDelete: Bool { owner }
    var canAddMembers: Bool { manage }
    /// Invitations to sign up waiting to be used.
    var canSeeInvites: Bool { manage }
    /// The roles offered when adding someone.
    var rolesToGrant: [TeamLevel] { owner ? [.member, .admin, .owner] : [.member, .admin] }
    var canLeave: Bool { mine != nil }

    /// Can they change the role of someone with `target` to `to`?
    func canSetRole(of target: TeamLevel, to: TeamLevel) -> Bool {
        manage && target != to && (owner || (target != .owner && to != .owner))
    }

    /// The roles someone with `target` can be given (their own first).
    func roles(for target: TeamLevel) -> [TeamLevel] {
        [TeamLevel.member, .admin, .owner].filter { $0 == target || canSetRole(of: target, to: $0) }
    }

    /// Can they remove someone with `target` from the team?
    func canRemove(_ target: TeamLevel) -> Bool {
        manage && (target != .owner || owner)
    }
}
