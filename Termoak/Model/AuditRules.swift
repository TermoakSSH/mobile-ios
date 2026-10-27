import Foundation

// The extended audit in the app (0.7 phase 5c, docs-next/E2EE-SSO-AUDIT.md
// §4, as the desktop's `audit.rs` and Android's AuditRules.kt): filter
// presets and time ranges, the actions in words, a short summary of an
// entry's details, export names, team retention and the sinks' states. No
// engine types here (unit tested on Linux).

/// The filter of a search (the engine's `AuditQuery` fields).
struct AuditFilterQuery: Equatable {
    var action: String?
    var actor: String?
    var vaultId: String?
    var since: Int64?
    var text: String?
    var before: Int64?
    var limit: UInt32?
}

enum AuditPreset: String, CaseIterable, Identifiable {
    case all, access, certificates, policy, e2ee, sso, signIns
    var id: String { rawValue }

    /// The `action` filter (`nil`: every action).
    var actions: String? {
        switch self {
        case .all: return nil
        case .access: return "access.*,access_policy.*"
        case .certificates: return "cert.*,ca.*"
        case .policy: return "team.policy,access_policy.*,team.role_changed"
        case .e2ee: return "e2ee.*"
        case .sso: return "sso.*,auth.login_refused"
        case .signIns: return "auth.*,sso.login,sso.login_failed"
        }
    }

    /// Localization key.
    var label: String {
        switch self {
        case .all: return "audit.preset.all"
        case .access: return "audit.preset.access"
        case .certificates: return "audit.preset.certificates"
        case .policy: return "audit.preset.policy"
        case .e2ee: return "audit.preset.e2ee"
        case .sso: return "audit.preset.sso"
        case .signIns: return "audit.preset.sign_ins"
        }
    }
}

enum AuditRange: String, CaseIterable, Identifiable {
    case any, day, week, month, quarter
    var id: String { rawValue }

    var days: Int64? {
        switch self {
        case .any: return nil
        case .day: return 1
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        }
    }

    func since(_ now: Int64) -> Int64? { days.map { now - $0 * 86_400_000 } }

    var label: String { "audit.range." + rawValue }
}

struct AuditFilters: Equatable {
    var preset: AuditPreset = .all
    /// More actions typed by hand (comma list, `*` prefixes).
    var actions = ""
    var actor = ""
    var vaultId: String?
    var range: AuditRange = .any
    var text = ""

    func query(now: Int64, before: Int64? = nil) -> AuditFilterQuery {
        let list = (preset.actions?.split(separator: ",").map(String.init) ?? [])
            + actions.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        let actor = self.actor.trimmingCharacters(in: .whitespaces)
        let text = self.text.trimmingCharacters(in: .whitespaces)
        return AuditFilterQuery(
            action: list.isEmpty ? nil : list.joined(separator: ","), actor: actor.isEmpty ? nil : actor, vaultId: vaultId,
            since: range.since(now), text: text.isEmpty ? nil : text, before: before, limit: AuditRules.page
        )
    }

    /// Every entry matching, oldest first (no page).
    func exportQuery(now: Int64) -> AuditFilterQuery {
        var q = query(now: now)
        q.limit = nil
        return q
    }
}

enum AuditSinkState { case paused, failing, delivered, waiting }

enum AuditRules {
    /// Entries per page.
    static let page: UInt32 = 50
    static let formats = ["csv", "json", "ndjson"]

    /// The next page: older than the last entry (`nil` when the last page was not full).
    static func nextBefore(lastId: Int64?, lastPage: Int) -> Int64? { lastPage < Int(page) ? nil : lastId }

    static func exportName(scope: String, format: String, date: String) -> String {
        let s = String(scope.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "termoak-audit-\(s.isEmpty ? "audit" : s)-\(date).\(format)"
    }

    /// Actions → localization keys (unknown ones are shown as they are).
    static let actions: [String: String] = [
        "e2ee.setup": "audit.action.e2ee_setup",
        "e2ee.seal": "audit.action.e2ee_seal",
        "e2ee.passphrase_removed": "audit.action.e2ee_passphrase_removed",
        "e2ee.key_rotate": "audit.action.e2ee_key_rotate",
        "e2ee.reset": "audit.action.e2ee_reset",
        "e2ee.pairing_request": "audit.action.e2ee_pairing_request",
        "e2ee.pairing_approve": "audit.action.e2ee_pairing_approve",
        "e2ee.pairing_deny": "audit.action.e2ee_pairing_deny",
        "e2ee.enable": "audit.action.e2ee_enable",
        "e2ee.rotate": "audit.action.e2ee_rotate",
        "e2ee.disable": "audit.action.e2ee_disable",
        "e2ee.wraps_add": "audit.action.e2ee_wraps_add",
        "e2ee.unlock": "audit.action.e2ee_unlock",
        "sso.config": "audit.action.sso_config",
        "sso.domain_add": "audit.action.sso_domain_add",
        "sso.domain_verify": "audit.action.sso_domain_verify",
        "sso.domain_check_failed": "audit.action.sso_domain_check_failed",
        "sso.domain_remove": "audit.action.sso_domain_remove",
        "sso.login": "audit.action.sso_login",
        "sso.login_failed": "audit.action.sso_login_failed",
        "sso.link": "audit.action.sso_link",
        "sso.unlink": "audit.action.sso_unlink",
        "sso.user_created": "audit.action.sso_user_created",
        "auth.login_refused": "audit.action.auth_login_refused",
        "audit.export": "audit.action.audit_export",
        "audit.settings": "audit.action.audit_settings",
        "audit.sink_create": "audit.action.audit_sink_create",
        "audit.sink_update": "audit.action.audit_sink_update",
        "audit.sink_delete": "audit.action.audit_sink_delete",
        "audit.test": "audit.action.audit_test",
        "access.request": "audit.action.access_request",
        "access.approve": "audit.action.access_approve",
        "access.deny": "audit.action.access_deny",
        "access.revoke": "audit.action.access_revoke",
        "access.cancel": "audit.action.access_cancel",
        "access_policy.set": "audit.action.access_policy_set",
        "access_policy.delete": "audit.action.access_policy_delete",
        "cert.issue": "audit.action.cert_issue",
        "cert.revoke": "audit.action.cert_revoke",
        "ca.create": "audit.action.ca_create",
        "ca.rotate": "audit.action.ca_rotate",
        "ca.disable": "audit.action.ca_disable",
        "team.policy": "audit.action.team_policy",
        "vault.create": "audit.action.vault_create",
        "vault.update": "audit.action.vault_update",
        "vault.delete": "audit.action.vault_delete",
        "vault.member_add": "audit.action.vault_member_add",
        "vault.member_removed": "audit.action.vault_member_removed",
        "vault.role_changed": "audit.action.vault_role_changed",
        "vault.transfer": "audit.action.vault_transfer",
        "auth.devices_revoked": "audit.action.auth_devices_revoked",
        "auth.email_changed": "audit.action.auth_email_changed",
        "auth.email_verified": "audit.action.auth_email_verified",
        "auth.password_reset": "audit.action.auth_password_reset",
        "network.up": "audit.action.network_up",
        "network.down": "audit.action.network_down",
        "network.key_generated": "audit.action.network_key_generated",
        "team.principal_changed": "audit.action.team_principal_changed",
        "team.invite_created": "audit.action.team_invite_created",
        "team.invite_revoked": "audit.action.team_invite_revoked",
        "secret.reveal": "audit.action.secret_reveal",
        "secret.use": "audit.action.secret_use",
        "auth.login": "audit.action.auth_login",
        "auth.register": "audit.action.auth_register",
        "auth.password_changed": "audit.action.auth_password_changed",
        "auth.2fa_enabled": "audit.action.auth_2fa_enabled",
        "auth.2fa_disabled": "audit.action.auth_2fa_disabled",
        "auth.device_revoked": "audit.action.auth_device_revoked",
        "admin.user_created": "audit.action.admin_user_created",
        "admin.user_updated": "audit.action.admin_user_updated",
        "admin.password_reset": "audit.action.admin_password_reset",
        "admin.2fa_reset": "audit.action.admin_2fa_reset",
        "admin.device_revoked": "audit.action.admin_device_revoked",
        "admin.invite_created": "audit.action.admin_invite_created",
        "admin.invite_revoked": "audit.action.admin_invite_revoked",
        "team.created": "audit.action.team_created",
        "team.deleted": "audit.action.team_deleted",
        "team.member_added": "audit.action.team_member_added",
        "team.member_removed": "audit.action.team_member_removed",
        "team.role_changed": "audit.action.team_role_changed",
        "team.left": "audit.action.team_left",
        "session.open": "audit.action.session_open",
        "session.close": "audit.action.session_close",
        "session.attach": "audit.action.session_attach",
        "session.share": "audit.action.session_share",
        "session.share_revoked": "audit.action.session_share_revoked",
        "sftp.upload": "audit.action.sftp_upload",
        "sftp.download": "audit.action.sftp_download",
        "sftp.rename": "audit.action.sftp_rename",
        "sftp.delete": "audit.action.sftp_delete",
        "exec.batch": "audit.action.exec_batch",
        "key.create": "audit.action.key_create",
        "ai.task.mode": "audit.action.ai_task_mode",
        "ai.approval.approved": "audit.action.ai_approval_approved",
        "ai.approval.denied": "audit.action.ai_approval_denied",
    ]

    static func actionKey(_ action: String) -> String? { actions[action] ?? actions[action.replacingOccurrences(of: "-", with: "_")] }

    /// A short summary of an entry's details ("device: Pixel · reason: …").
    static func detailSummary(_ json: String, max: Int = 160) -> String {
        guard let data = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let parts: [String] = o.keys.sorted().compactMap { k in
            switch o[k] {
            case nil, is NSNull: return nil
            case let s as String: return "\(k): \(s)"
            case let a as [Any]: return a.isEmpty ? nil : "\(k): \(a.map { "\($0)" }.joined(separator: ", "))"
            case let v?: return "\(k): \(v)"
            }
        }
        let s = parts.joined(separator: " · ")
        return s.count > max ? String(s.prefix(max)) + "…" : s
    }

    enum Retention: Equatable {
        case ok(UInt32?)
        case invalid
    }

    /// Retention in days: 1 to the server's maximum; empty is the server's default.
    static func parseRetention(_ text: String, max: Int) -> Retention {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .ok(nil) }
        guard let d = Int(t), (1...max).contains(d) else { return .invalid }
        return .ok(UInt32(d))
    }

    /// `GET /teams/{id}/audit/settings`.
    struct RetentionView: Equatable {
        var days: Int?
        var defaultDays: Int
        var maxDays: Int
    }

    static func retentionView(_ json: String) -> RetentionView? {
        guard let data = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return RetentionView(days: o["retention_days"] as? Int, defaultDays: o["default_retention_days"] as? Int ?? 365, maxDays: o["max_retention_days"] as? Int ?? 3650)
    }

    /// What `/info features.audit_v2` says (`nil`: no extended audit).
    struct Features: Equatable {
        var exports: [String]
        var retention: Bool
        var sinks: [String]
    }

    static func features(_ infoJson: String) -> Features? {
        guard let data = infoJson.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let f = o["features"] as? [String: Any], let a = f["audit_v2"] as? [String: Any] else { return nil }
        func list(_ k: String, _ all: [String]) -> [String] {
            if let l = a[k] as? [String] { return l }
            if a[k] as? Bool == true { return all }
            return []
        }
        return Features(exports: list("export", formats), retention: a["retention"] as? Bool ?? false, sinks: list("sinks", ["webhook", "syslog"]))
    }

    /// Where a sink delivers, in one line.
    static func sinkTarget(kind: String, url: String?, host: String?, port: UInt16?, transport: String?) -> String {
        if kind == "syslog" {
            let tls = transport != "tcp"
            return "syslog\(tls ? "+tls" : "")://\(host ?? ""):\(port.map(Int.init) ?? (tls ? 6514 : 514))"
        }
        return url ?? ""
    }

    static func sinkState(enabled: Bool, failures: Int64, lastSuccessAt: Int64?) -> AuditSinkState {
        if !enabled { return .paused }
        if failures > 0 { return .failing }
        return lastSuccessAt != nil ? .delivered : .waiting
    }

    /// Who did it (`user:<id>` or the id itself, by the names known).
    static func actor(_ actor: String, names: [String: String]) -> String {
        let id = actor.hasPrefix("user:") ? String(actor.dropFirst(5)) : actor
        return names[id] ?? actor
    }
}
