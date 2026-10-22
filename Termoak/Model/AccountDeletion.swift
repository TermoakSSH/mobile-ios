import Foundation

// Deleting your account on its server (`DELETE /api/v1/me`, App Store rule:
// apps with sign-up let you delete the account in the app). The request and
// the server's refusals, from the error's status, code and details (the
// engine's `apiError`, core 0.7), without the engine's types so the unit
// tests compile this file on its own.

/// An error response of the server, as the engine's `apiError` gives it.
struct ServerFailure: Equatable {
    let status: Int
    /// The server's stable error code.
    let code: String
    /// The server's message (English).
    let message: String
    /// The error's other fields (`teams`, `vaults`...), a JSON object.
    var detailsJson: String = "{}"

    var details: [String: Any] {
        guard let data = detailsJson.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return o
    }
}

/// A shared vault that would go with the account: its name and how many
/// people use it.
struct SharedVault: Equatable {
    let name: String
    let members: Int?
}

/// Why the server did not delete the account.
enum AccountDeletionProblem: Equatable {
    /// `invalid_password`.
    case wrongPassword
    /// `totp_required`: the account has two-step verification.
    case codeRequired
    /// `totp_invalid`.
    case codeInvalid
    /// `last_admin`: the only administrator of the server.
    case lastAdmin
    /// `last_team_owner`: the only owner of these teams (the error's
    /// `teams`; empty when it has none).
    case lastTeamOwner(teams: [String])
    /// `shared_vaults`: your vaults shared with people go with the account
    /// (the error's `vaults`); confirm and send it again with
    /// `delete_shared_vaults`.
    case sharedVaults([SharedVault])
    /// 404/405: a server without account deletion (an older version).
    case unsupported

    /// `nil` if the error is not one of these refusals.
    static func from(_ f: ServerFailure) -> AccountDeletionProblem? {
        switch f.code {
        case "invalid_password": return .wrongPassword
        case "totp_required": return .codeRequired
        case "totp_invalid": return .codeInvalid
        case "last_admin": return .lastAdmin
        case "last_team_owner":
            let teams = (f.details["teams"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
            return .lastTeamOwner(teams: teams)
        case "shared_vaults":
            let vaults = (f.details["vaults"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.compactMap { v -> SharedVault? in
                guard let name = v["name"] as? String, !name.isEmpty else { return nil }
                return SharedVault(name: name, members: (v["member_count"] as? NSNumber)?.intValue)
            }
            return .sharedVaults(vaults)
        default: break
        }
        return f.status == 404 || f.status == 405 ? .unsupported : nil
    }

    /// The teams as the message shows them: “Ops”, “Dev”.
    static func quoted(_ teams: [String]) -> String {
        teams.map { "“\($0)”" }.joined(separator: ", ")
    }
}

enum AccountDeletion {
    static let path = "/api/v1/me"

    /// Body of `DELETE /api/v1/me`: the password, the two-step code (if the
    /// account has it) and, after confirming, `delete_shared_vaults`.
    static func body(password: String, totpCode: String?, deleteSharedVaults: Bool) -> String {
        var body: [String: Any] = ["password": password]
        if let code = totpCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
            body["totp_code"] = code
        }
        if deleteSharedVaults { body["delete_shared_vaults"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// `GET /api/v1/me` says the account has two-step verification
    /// (`user.totp_enabled`).
    static func twoFactorEnabled(meJson: String) -> Bool {
        guard let data = meJson.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        let user = object["user"] as? [String: Any] ?? object
        return user["totp_enabled"] as? Bool ?? false
    }

    /// The confirmation word was typed (trimmed, exactly).
    static func confirmed(_ typed: String, word: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines) == word
    }
}
