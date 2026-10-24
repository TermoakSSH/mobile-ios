import Foundation

// Teams security in the app (0.7 phase 4d, docs-next/TEAMS-SECURITY.md
// §13.2): the rules the screens share, without the engine's types so the
// unit tests compile this file on its own (the Android app's AccessRules).
//
// - Roles a vault Admin can give (Connect only, Use, Edit, Admin) and who
//   may delete a vault (only implicit managers, never an explicit Admin).
// - What a vault's team policy hides (`AccessGates`): reveal/copy/export,
//   the AI, the private network picker; whether sessions are recorded.
// - The effective authentication of a host or group ("Team certificate",
//   its own or its nearest group's) and where a terminal opens.
// - Access windows (countdown and its ticks), durations, what an
//   `access_approval_required` error says (two shapes: the server's details
//   and the engine's own check), the request form, `access_request`
//   events, the session close reasons and the CA install command (a
//   heredoc: `install.sh` needs a manager's token, never `curl … | sh`).

/// A vault role, in rank order (never compare the names).
enum AccessLevel: Int, Comparable, CaseIterable {
    case unknown, connectOnly, useOnly, editor, manager

    static func < (a: AccessLevel, b: AccessLevel) -> Bool { a.rawValue < b.rawValue }

    /// No secrets on this device (Use only and Connect only).
    var noSecrets: Bool { self == .useOnly || self == .connectOnly }
}

/// What a vault's team policy lets this member do (and what to hide).
struct AccessGates: Equatable {
    /// Reveal or copy secrets, export keys, move or copy items out of the vault.
    var reveal: Bool
    /// AI actions on its hosts.
    var ai: Bool
    /// The private network picker.
    var networks: Bool
    /// Every session on its hosts is recorded ("Recorded").
    var recorded: Bool
    /// Some hosts have access policies (ask the server about them).
    var accessRules: Bool
    /// The vault's owner has an SSH CA ("Team certificate" works).
    var certificates: Bool

    /// This device's items, and vaults without a policy.
    static let all = AccessGates(reveal: true, ai: true, networks: true, recorded: false, accessRules: false, certificates: false)
}

/// The team policy flags of a vault as the engine gives them (`VaultInfo.policy`).
struct VaultPolicyFlags: Equatable {
    var revealAllowed = true
    var aiAllowed = true
    var networksAllowed = true
    var recordSessions = false
    var accessPolicies = false
    var certificates = false
}

/// A group as the authentication inheritance needs it.
struct GroupAuthLink: Equatable {
    let id: String
    let name: String
    let parentId: String?
    let auth: String?
}

/// The authentication that applies (`nil`: password/key) and the group it
/// comes from (`nil`: its own, or none).
struct EffectiveAuth: Equatable {
    let auth: String?
    let fromGroup: String?
    var teamCertificate: Bool { auth == AccessRules.teamCertificate }
}

/// What an `access_approval_required` error says.
struct AccessNeed: Equatable {
    var hostId: String?
    var vaultId: String?
    /// `host`, `group` or `vault`.
    var targetKind: String
    var targetId: String?
    var maxMinutes: Int
    /// A request of yours already waits.
    var pending: String?
    var canRequest: Bool
}

/// A request as the events socket sends it (the fields the app needs).
struct AccessEventRequest: Equatable {
    var id: String
    var requesterId: String
    var requesterName: String
    var targetLabel: String
    var minutes: Int
    var status: String
    var decidedByName: String?
    var decisionReason: String?
    var endsAt: Int64?
}

enum AccessNotice: Equatable {
    case created, approved, denied, deniedReason, revoked, expired, ended
}

enum AccessRequestProblem: Equatable { case reason, reasonLong, duration }

enum AccessStatusKey: Equatable { case pending, active, ended, denied, expired, cancelled, revoked, unknown }

/// Where a terminal of a host opens.
enum AccessRoute: Equatable { case device, server }

enum AccessRules {
    static let teamCertificate = "team_certificate"

    // MARK: Roles

    static func grantableRoles(teamsSecurity: Bool) -> [AccessLevel] {
        teamsSecurity ? [.connectOnly, .useOnly, .editor, .manager] : [.useOnly, .editor]
    }

    /// Only implicit managers (the owner of a shared vault, the team's owners
    /// and admins) delete a vault; an explicit Admin manages it.
    static func canDeleteVault(_ role: AccessLevel, implicitManager: Bool) -> Bool {
        role == .manager && implicitManager
    }

    // MARK: Gates

    static func gates(_ role: AccessLevel, _ policy: VaultPolicyFlags?) -> AccessGates {
        let canRead = role >= .editor
        return AccessGates(
            reveal: canRead && (role == .manager || policy?.revealAllowed != false),
            ai: policy?.aiAllowed != false,
            networks: policy?.networksAllowed != false,
            recorded: policy?.recordSessions == true,
            accessRules: policy?.accessPolicies == true,
            certificates: policy?.certificates == true)
    }

    // MARK: Authentication

    static func effectiveAuth(own: String?, groupId: String?, groups: [GroupAuthLink]) -> EffectiveAuth {
        if let own { return EffectiveAuth(auth: own, fromGroup: nil) }
        var next = groupId
        var hops = 0
        while let id = next, hops < 16 {
            hops += 1
            guard let g = groups.first(where: { $0.id == id }) else { break }
            if let a = g.auth { return EffectiveAuth(auth: a, fromGroup: g.name) }
            next = g.parentId
        }
        return EffectiveAuth(auth: nil, fromGroup: nil)
    }

    /// Connect only members, and Use only members of Strict vaults, connect
    /// from this device only with a team certificate (the engine certifies
    /// a key made just for it); otherwise through the server. Telnet stays
    /// here (its tab says why).
    static func route(_ level: AccessLevel, strict: Bool, telnet: Bool, teamCertificateUsable: Bool) -> AccessRoute {
        let noLocalSecrets = level == .connectOnly || (level == .useOnly && strict)
        if !noLocalSecrets || telnet || teamCertificateUsable { return .device }
        return .server
    }

    // MARK: Windows

    /// Seconds left until `endsAt` (ms), never negative.
    static func remainingSecs(_ endsAt: Int64, now: Int64) -> Int64 { (max(endsAt - now, 0) + 999) / 1000 }

    /// Every second in the last two minutes, else every 15 seconds.
    static func tick(_ secsLeft: Int64) -> TimeInterval { secsLeft <= 120 ? 1 : 15 }

    /// The countdown turns to a warning colour in the last five minutes.
    static func endingSoon(_ secsLeft: Int64) -> Bool { secsLeft <= 300 }

    /// (hours, minutes, seconds): seconds only under a minute, minutes rounded up.
    static func left(_ secs: Int64) -> (hours: Int64, minutes: Int64, seconds: Int64?) {
        let s = max(secs, 0)
        if s < 60 { return (0, 0, s) }
        let m = (s + 59) / 60
        return (m / 60, m % 60, nil)
    }

    /// Durations offered when asking (minutes), up to `max`; `max` itself always.
    static func durationChoices(_ max: Int) -> [Int] {
        var v = [15, 30, 60, 120, 240, 480, 1440, 4320, 10080].filter { $0 < max }
        if max > 0 { v.append(max) }
        return v
    }

    // MARK: Requests

    static func need(_ d: [String: Any], hostId: String? = nil) -> AccessNeed {
        func s(_ k: String) -> String? { (d[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var pending: String?
        if let p = d["pending"] as? [String: Any] { pending = (p["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        else if let p = d["pending"] as? String, !p.isEmpty { pending = p }
        let max = (d["max_minutes"] as? Int) ?? (d["max_minutes"] as? NSNumber)?.intValue ?? 0
        return AccessNeed(hostId: s("host_id") ?? hostId, vaultId: s("vault_id"), targetKind: s("target_kind") ?? "host",
                          targetId: s("target_id"), maxMinutes: max > 0 ? max : 60, pending: pending,
                          canRequest: (d["can_request"] as? Bool) ?? true)
    }

    /// From an error's details JSON text.
    static func need(json: String?, hostId: String? = nil) -> AccessNeed {
        let d = json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return need(d, hostId: hostId)
    }

    static func requestProblem(minutes: Int, max: Int, reason: String) -> AccessRequestProblem? {
        let n = reason.trimmingCharacters(in: .whitespacesAndNewlines).count
        if n == 0 { return .reason }
        if n > 500 { return .reasonLong }
        if minutes <= 0 || minutes > max { return .duration }
        return nil
    }

    static func statusKey(status: String, startsAt: Int64?, endsAt: Int64?, now: Int64) -> AccessStatusKey {
        switch status {
        case "pending": return .pending
        case "approved": return isActive(status: status, startsAt: startsAt, endsAt: endsAt, now: now) ? .active : .ended
        case "denied": return .denied
        case "expired": return .expired
        case "cancelled": return .cancelled
        case "revoked": return .revoked
        default: return .unknown
        }
    }

    static func isActive(status: String, startsAt: Int64?, endsAt: Int64?, now: Int64) -> Bool {
        status == "approved" && (startsAt ?? .max) <= now && (endsAt ?? 0) > now
    }

    /// An `access_request` message of the events socket: its event and request.
    static func event(_ json: [String: Any]) -> (event: String, request: AccessEventRequest)? {
        guard json["type"] as? String == "access_request", let r = json["request"] as? [String: Any],
              let id = r["id"] as? String, !id.isEmpty else { return nil }
        func i64(_ k: String) -> Int64? { (r[k] as? NSNumber)?.int64Value ?? (r[k] as? Int).map(Int64.init) }
        let name = (r["requester_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (r["requester_email"] as? String) ?? ""
        return (json["event"] as? String ?? "",
                AccessEventRequest(id: id, requesterId: r["requester_id"] as? String ?? "", requesterName: name,
                                   targetLabel: r["target_label"] as? String ?? "", minutes: (r["minutes"] as? Int) ?? 0,
                                   status: r["status"] as? String ?? "", decidedByName: r["decided_by_name"] as? String,
                                   decisionReason: r["decision_reason"] as? String, endsAt: i64("ends_at")))
    }

    static func notice(me: String?, event: String, request r: AccessEventRequest) -> AccessNotice? {
        let mine = me != nil && me == r.requesterId
        switch event {
        case "created": return mine ? nil : .created
        case "approved": return mine ? .approved : nil
        case "denied": return !mine ? nil : ((r.decisionReason ?? "").isEmpty ? .denied : .deniedReason)
        case "revoked": return mine ? .revoked : nil
        case "expired": return mine ? .expired : nil
        case "ended": return mine ? .ended : nil
        default: return nil
        }
    }

    // MARK: Close reasons

    static let closeReasons = ["access_expired", "access_revoked", "vault_access_revoked"]

    static func isCloseReason(_ r: String?) -> Bool { r.map { closeReasons.contains($0) } ?? false }

    /// The server closes a session with `access_expired`/`access_revoked`
    /// and then ends the shared session with `session_ended`: the first stays.
    static func keptReason(previous: String?, next: String) -> String {
        if let previous, isCloseReason(previous), !isCloseReason(next) { return previous }
        return next
    }

    /// Error codes of teams security (TEAMS-SECURITY.md §7): each has an
    /// `error.<code>` text, always used.
    static let errorCodes = [
        "connect_only", "secret_reveal_forbidden", "access_approval_required", "access_needs_server",
        "access_request_exists", "access_request_not_needed", "access_request_closed", "access_duration_too_long",
        "self_approval_forbidden", "not_an_approver", "ca_not_configured", "ca_exists", "certificate_key_not_owned",
        "certificate_key_revoked", "certificate_proof_invalid", "certificate_no_principals", "team_2fa_required",
        "policy_requires_2fa", "ai_forbidden_by_policy", "networks_forbidden_by_policy", "recording_required",
        "invalid_reason",
    ]

    /// The server's (or the engine's) English texts of these codes, for
    /// places that only carry the text: matched by a part of them.
    static func code(ofMessage text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if closeReasons.contains(t) || errorCodes.contains(t) { return t }
        let low = t.lowercased()
        let parts: [(String, String)] = [
            ("connect only members connect", "connect_only"),
            ("needs an approved access window", "access_approval_required"),
            ("there is no certificate authority", "ca_not_configured"),
            ("the team does not allow private networks", "networks_forbidden_by_policy"),
            ("requires two-step verification", "team_2fa_required"),
            ("must be recorded", "recording_required"),
        ]
        return parts.first { low.contains($0.0) }?.1
    }

    // MARK: The CA

    /// The command to paste on a host: the script in a heredoc, run as root.
    static func installCommand(_ script: String) -> String {
        var body = script
        while body.hasSuffix("\n") { body.removeLast() }
        return "sudo sh -s <<'TERMOAK_CA'\n\(body)\nTERMOAK_CA\n"
    }

    static func sshdLines(base: [String], optional: [String], krl: Bool, principals: Bool) -> [String] {
        base + optional.filter { ($0.hasPrefix("RevokedKeys") && krl) || ($0.hasPrefix("AuthorizedPrincipalsFile") && principals) }
    }

    static func principalValid(_ p: String) -> Bool {
        (1...64).contains(p.count) && p.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "._@+-".unicodeScalars.contains($0)
        }
    }

    static func defaultPrincipal(_ email: String) -> String {
        let local = email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? email
        return String(local.lowercased().map { c -> Character in
            (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || "._-".contains(c) ? c : "_"
        })
    }

    static func templates(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func number(_ text: String, in range: ClosedRange<Int>) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces)).flatMap { range.contains($0) ? $0 : nil }
    }

    static func looksLikePublicKey(_ s: String) -> Bool {
        let p = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard p.count >= 2 else { return false }
        let t = String(p[0])
        return (t.hasPrefix("ssh-") || t.hasPrefix("ecdsa-") || t.hasPrefix("sk-")) && p[1].count > 40
            && p[1].allSatisfy { $0.isLetter || $0.isNumber || "+/=".contains($0) }
    }

    /// The policy that applies to a host or group without its own: its
    /// nearest group's, else the vault's. Returns the target `(kind, id)`.
    static func inheritedTarget(kind: String, groupOfHost: String?, parentOf: (String) -> String?,
                                hasPolicy: (String, String) -> Bool, vaultId: String) -> (String, String)? {
        if kind == "vault" { return nil }
        var g = kind == "host" ? groupOfHost : nil
        var hops = 0
        while let id = g, hops < 16 {
            hops += 1
            if hasPolicy("group", id) { return ("group", id) }
            g = parentOf(id)
        }
        return hasPolicy("vault", vaultId) ? ("vault", vaultId) : nil
    }
}

/// An asciicast v2 recording: output replayed into a terminal, `r` resizes.
struct Asciicast: Equatable {
    enum Event: Equatable {
        case output(time: Double, data: String)
        case resize(time: Double, cols: Int, rows: Int)
        var time: Double {
            switch self { case .output(let t, _), .resize(let t, _, _): return t }
        }
    }

    var width: Int
    var height: Int
    var events: [Event]
    var duration: Double { events.last?.time ?? 0 }

    static func parse(_ text: String) -> Asciicast? {
        var lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }[...]
        guard let first = lines.popFirst(), let hd = first.data(using: .utf8),
              let header = try? JSONSerialization.jsonObject(with: hd) as? [String: Any],
              (header["version"] as? Int) == 2 else { return nil }
        let w = min(max((header["width"] as? Int) ?? 80, 1), 1000)
        let h = min(max((header["height"] as? Int) ?? 24, 1), 500)
        var events: [Event] = []
        var last = 0.0
        for l in lines {
            guard let d = l.data(using: .utf8), let a = try? JSONSerialization.jsonObject(with: d) as? [Any], a.count >= 3 else { continue }
            let t = max((a[0] as? NSNumber)?.doubleValue ?? last, last)
            last = t
            switch a[1] as? String {
            case "o": events.append(.output(time: t, data: a[2] as? String ?? ""))
            case "r": if let (c, r) = size(a[2] as? String ?? "") { events.append(.resize(time: t, cols: c, rows: r)) }
            default: break
            }
        }
        return Asciicast(width: w, height: h, events: events)
    }

    static func size(_ s: String) -> (Int, Int)? {
        let p = s.split(separator: "x")
        guard p.count == 2, let c = Int(p[0]), let r = Int(p[1]), (1...1000).contains(c), (1...500).contains(r) else { return nil }
        return (c, r)
    }

    static let speeds: [Double] = [1, 2, 4, 8]

    /// Seconds to wait before an event (long pauses cut to 2 s).
    static func wait(previous: Double, time: Double, speed: Double) -> Double { min(max(time - previous, 0), 2) / speed }
}
