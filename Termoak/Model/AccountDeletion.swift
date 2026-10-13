import Foundation

// Deleting your account on its server (`DELETE /api/v1/me`, App Store rule:
// apps with sign-up let you delete the account in the app). The request and
// the server's refusals, read from the engine's English text, without the
// engine's types so the unit tests compile this file on its own.

/// An error response of the server as the engine writes it:
/// "the server responded 409 (last_admin): you are the only administrator…".
struct ServerFailure: Equatable {
    let status: Int
    /// The server's error code ("error" when the body had none).
    let code: String
    /// The server's message (English).
    let message: String

    /// `nil` if the text is not a server response.
    static func parse(_ text: String) -> ServerFailure? {
        guard let start = text.range(of: "the server responded ") else { return nil }
        let rest = text[start.upperBound...]
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard let status = Int(digits) else { return nil }
        let after = rest.dropFirst(digits.count)
        guard after.hasPrefix(" ("), let close = after.firstIndex(of: ")") else {
            return ServerFailure(status: status, code: "", message: "")
        }
        let code = String(after[after.index(after.startIndex, offsetBy: 2)..<close])
        var tail = after[after.index(after: close)...]
        if tail.hasPrefix(": ") { tail = tail.dropFirst(2) }
        return ServerFailure(status: status, code: code, message: String(tail))
    }
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
    /// `last_team_owner`: the only owner of these teams (as the server
    /// wrote them, "\"Ops\", \"Dev\""), when they could be read.
    case lastTeamOwner(teams: String?)
    /// `shared_vaults`: your vaults shared with people go with the account;
    /// confirm and send it again with `delete_shared_vaults`.
    case sharedVaults
    /// 404/405: a server without account deletion (an older version).
    case unsupported

    /// `nil` if the text is not one of these refusals.
    static func parse(_ text: String) -> AccountDeletionProblem? {
        guard let f = ServerFailure.parse(text) else { return nil }
        switch f.code {
        case "invalid_password": return .wrongPassword
        case "totp_required": return .codeRequired
        case "totp_invalid": return .codeInvalid
        case "last_admin": return .lastAdmin
        case "last_team_owner": return .lastTeamOwner(teams: teamNames(f.message))
        case "shared_vaults": return .sharedVaults
        default: break
        }
        return f.status == 404 || f.status == 405 ? .unsupported : nil
    }

    /// The teams in "you are the only owner of \"Ops\", \"Dev\": appoint
    /// another owner or delete the team first".
    private static func teamNames(_ message: String) -> String? {
        guard let a = message.range(of: "only owner of "),
              let b = message.range(of: ": appoint another owner", range: a.upperBound..<message.endIndex) else { return nil }
        let names = message[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespaces)
        return names.isEmpty ? nil : names
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
