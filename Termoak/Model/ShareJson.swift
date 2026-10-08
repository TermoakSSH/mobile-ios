import Foundation

// The invitations of a server session through the generic API of an account
// (`AccountHandle.apiPost`…), for sessions of an account that is not the
// current one: the engine has these calls only for the current account
// (`TermoakCore.shareServerSessionWith`…). The bodies and the fields read
// back are the engine's (core termoak-ffi `share_body_with`, `update_share`,
// `SessionShareInfo::from_json`, `ShareInvite::from_json`). Without the
// engine's types, so the unit tests compile this file on its own.

enum ShareJson {
    /// `POST /api/v1/sessions/{id}/shares`: for a person (`email`), a team
    /// (`teamId`) or a link.
    static func shareBody(email: String?, teamId: String?, link: Bool, control: Bool, expiresInMinutes: Int64?,
                          requireApproval: Bool?, autoGrant: Bool, controlMinutes: UInt32?) -> [String: Any] {
        var body: [String: Any] = [
            "permission": control ? "control" : "view",
            "expires_in_minutes": expiresInMinutes.map { $0 as Any } ?? NSNull(),
            "auto_grant": autoGrant,
        ]
        if let requireApproval { body["require_approval"] = requireApproval }
        if let controlMinutes { body["control_minutes"] = controlMinutes }
        if let email {
            body["email"] = email.trimmingCharacters(in: .whitespaces)
        } else if let teamId {
            body["team_id"] = teamId
        } else if link {
            body["link"] = true
        }
        return body
    }

    /// `PATCH /api/v1/sessions/{id}/shares/{share}`: only what changes.
    static func changesBody(control: Bool?, expiresInMinutes: Int64?, noExpiry: Bool, requireApproval: Bool?,
                            autoGrant: Bool?, controlMinutes: UInt32?, noControlLimit: Bool) -> [String: Any] {
        var body: [String: Any] = ["no_expiry": noExpiry]
        if let control { body["permission"] = control ? "control" : "view" }
        if let expiresInMinutes { body["expires_in_minutes"] = expiresInMinutes }
        if let requireApproval { body["require_approval"] = requireApproval }
        if let autoGrant { body["auto_grant"] = autoGrant }
        if noControlLimit {
            body["no_control_limit"] = true
        } else if let controlMinutes {
            body["control_minutes"] = controlMinutes
        }
        return body
    }

    static func encode(_ body: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    static func array(_ json: String) -> [[String: Any]] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
    }

    /// An invitation as the server lists it.
    struct Share: Equatable {
        enum Kind: Equatable { case user, team, link }
        var id = ""
        var sessionId = ""
        var kind = Kind.user
        var control = false
        var userId: String?
        var userEmail: String?
        var userName: String?
        var teamId: String?
        var teamName: String?
        var expiresAt: Int64?
        var revoked = false
        var active = true
        var requireApproval = false
        var autoGrant = false
        var createdAt: Int64 = 0
        var participants: UInt32 = 0
        var controlMinutes: UInt32?
    }

    static func share(_ v: [String: Any]) -> Share {
        var s = Share()
        s.id = v["id"] as? String ?? ""
        s.sessionId = v["session_id"] as? String ?? ""
        if v["is_link"] as? Bool == true {
            s.kind = .link
        } else if v["team_id"] is String {
            s.kind = .team
        }
        s.control = v["permission"] as? String == "control"
        s.userId = v["user_id"] as? String
        s.userEmail = v["user_email"] as? String
        s.userName = v["user_name"] as? String
        s.teamId = v["team_id"] as? String
        s.teamName = v["team_name"] as? String
        s.expiresAt = int64(v["expires_at"])
        s.revoked = v["revoked"] as? Bool ?? false
        s.active = v["active"] as? Bool ?? !s.revoked
        s.requireApproval = v["require_approval"] as? Bool ?? false
        s.autoGrant = v["auto_grant"] as? Bool ?? false
        s.createdAt = int64(v["created_at"]) ?? 0
        s.participants = int64(v["participants"]).map { UInt32(clamping: $0) } ?? 0
        s.controlMinutes = int64(v["control_minutes"]).map { UInt32(clamping: $0) }
        return s
    }

    /// The answer to a new invitation: its id and permission, and the link
    /// (only for link invitations).
    struct Invite: Equatable {
        var shareId = ""
        var permission = ""
        var token: String?
        var link: String?
        var appLink: String?
    }

    static func invite(_ v: [String: Any]) -> Invite {
        let share = v["share"] as? [String: Any] ?? [:]
        return Invite(shareId: share["id"] as? String ?? "", permission: share["permission"] as? String ?? "",
                      token: v["token"] as? String, link: v["link"] as? String, appLink: v["app_link"] as? String)
    }

    /// `{"revoked": N}` of stopping every invitation.
    static func revokedCount(_ v: [String: Any]) -> UInt32 {
        int64(v["revoked"]).map { UInt32(clamping: $0) } ?? 0
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let n as Int64: return n
        case let n as Int: return Int64(n)
        case let n as Double: return Int64(n)
        case let n as NSNumber: return n.int64Value
        default: return nil
        }
    }
}
