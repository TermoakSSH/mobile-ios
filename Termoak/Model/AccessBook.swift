import TermoakKit
import Foundation

// Teams security (0.7 phase 4d): the engine's types meet AccessRules.swift.

extension VaultRole {
    var level: AccessLevel {
        switch self {
        case .connectOnly: return .connectOnly
        case .useOnly: return .useOnly
        case .editor: return .editor
        case .manager: return .manager
        case .unknown: return .unknown
        }
    }

    static func of(_ level: AccessLevel) -> VaultRole {
        switch level {
        case .connectOnly: return .connectOnly
        case .useOnly: return .useOnly
        case .editor: return .editor
        case .manager: return .manager
        case .unknown: return .unknown
        }
    }
}

extension ItemAccess {
    var level: AccessLevel {
        switch self {
        case .device, .manager: return .manager
        case .editor: return .editor
        case .useOnly: return .useOnly
        case .connectOnly: return .connectOnly
        case .unknown: return .unknown
        }
    }
}

extension VaultInfo {
    var policyFlags: VaultPolicyFlags? {
        policy.map {
            VaultPolicyFlags(revealAllowed: $0.revealAllowed, aiAllowed: $0.aiAllowed, networksAllowed: $0.networksAllowed,
                             recordSessions: $0.recordSessions, accessPolicies: $0.accessPolicies, certificates: $0.certificates)
        }
    }

    var gates: AccessGates { AccessRules.gates(role.level, policyFlags) }
}

extension AccessTargetKind {
    var name: String {
        switch self {
        case .host: return "host"
        case .group: return "group"
        case .vault: return "vault"
        case .unknown: return "unknown"
        }
    }

    static func of(_ s: String) -> AccessTargetKind {
        switch s {
        case "host": return .host
        case "group": return .group
        case "vault": return .vault
        default: return .unknown
        }
    }
}

extension AccessRequestStatus {
    var name: String {
        switch self {
        case .pending: return "pending"
        case .approved: return "approved"
        case .denied: return "denied"
        case .expired: return "expired"
        case .cancelled: return "cancelled"
        case .revoked: return "revoked"
        case .unknown: return "unknown"
        }
    }
}

extension AccessRequestInfo {
    func statusKey(_ now: Int64) -> AccessStatusKey {
        AccessRules.statusKey(status: status.name, startsAt: startsAt, endsAt: endsAt, now: now)
    }
    func isActive(_ now: Int64) -> Bool {
        AccessRules.isActive(status: status.name, startsAt: startsAt, endsAt: endsAt, now: now)
    }
    var requester: String { requesterName.isEmpty ? requesterEmail : requesterName }
}

extension HostAccessInfo {
    var need: AccessNeed {
        AccessNeed(hostId: hostId, vaultId: vaultId, targetKind: policy?.targetKind.name ?? "host", targetId: policy?.targetId,
                   maxMinutes: max(Int(maxMinutes), 1), pending: pending?.id, canRequest: canRequest)
    }
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

/// The window of a host as the rows and the terminal show it.
enum HostWindow: Equatable {
    case open(endsAt: Int64)
    case pending
    case needed
}

/// The teams security state of every signed-in account, shared by every
/// screen (the desktop's and Android's AccessBook): which servers have it,
/// the requests you can decide and your own (read again on every
/// `access_request` event, which carries no `can_decide`; the engine
/// forgets its cached answers and certificates), each host's answer
/// (`GET /hosts/{id}/access`, asked again after events) and the teams that
/// require 2FA from you.
@MainActor
final class AccessBook: ObservableObject {
    static let shared = AccessBook()

    @Published private(set) var supported: [String: Bool] = [:]
    @Published private(set) var approvals: [String: [AccessRequestInfo]] = [:]
    @Published private(set) var mine: [String: [AccessRequestInfo]] = [:]
    @Published private(set) var hosts: [String: HostAccessInfo] = [:]
    @Published private(set) var team2fa: [String: [Team2faRequirement]] = [:]
    /// An `access_request` event of an account (terminals waiting for a window look again).
    @Published private(set) var revision = 0
    private var hostAt: [String: Date] = [:]
    var core: TermoakCore?

    private static let fresh: TimeInterval = 30

    func isSupported(_ accountId: String?) -> Bool { accountId.map { supported[$0] == true } ?? false }
    var anySupported: Bool { supported.values.contains(true) }

    private func handle(_ accountId: String) -> AccountHandle? { try? core?.account(accountId: accountId) }

    /// Reads `/info` of the account's server; then its requests and 2FA state.
    func start(_ accountId: String, core: TermoakCore) async {
        self.core = core
        guard let h = handle(accountId) else { return }
        if let info = try? await h.apiRequest(method: .get, path: "/api/v1/info", bodyJson: nil),
           let d = info.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            supported[accountId] = (o["features"] as? [String: Any])?["teams_security"] is [String: Any]
        }
        if isSupported(accountId) {
            await refresh(accountId)
            await refresh2fa(accountId)
        }
    }

    func forget(_ accountId: String) {
        supported[accountId] = nil
        approvals[accountId] = nil
        mine[accountId] = nil
        team2fa[accountId] = nil
        for k in hosts.keys where k.hasPrefix("\(accountId)/") { hosts[k] = nil; hostAt[k] = nil }
    }

    // MARK: Requests

    var waitingCount: Int { approvals.values.reduce(0) { $0 + $1.filter { $0.status == .pending && $0.canDecide }.count } }

    func refresh(_ accountId: String) async {
        guard isSupported(accountId), let h = handle(accountId) else { return }
        if let a = try? await h.accessRequests(scope: .approvals, status: nil) { approvals[accountId] = a.sorted { $0.createdAt > $1.createdAt } }
        if let m = try? await h.accessRequests(scope: .mine, status: nil) { mine[accountId] = m.sorted { $0.createdAt > $1.createdAt } }
        revision += 1
    }

    /// An `access_request` event: the engine forgets, the lists and every
    /// host asked before are read again.
    func onEvent(_ accountId: String) async {
        handle(accountId)?.forgetAccess()
        await refresh(accountId)
        for k in hosts.keys where k.hasPrefix("\(accountId)/") {
            _ = await ask(accountId, String(k.dropFirst(accountId.count + 1)), force: true)
        }
    }

    func remember(_ accountId: String, _ r: AccessRequestInfo) {
        var list = mine[accountId] ?? []
        list.removeAll { $0.id == r.id }
        mine[accountId] = [r] + list
        revision += 1
    }

    // MARK: Hosts

    func host(_ accountId: String?, _ hostId: String?) -> HostAccessInfo? {
        guard let accountId, let hostId else { return nil }
        return hosts["\(accountId)/\(hostId)"]
    }

    @discardableResult
    func ask(_ accountId: String, _ hostId: String, force: Bool = false) async -> HostAccessInfo? {
        guard isSupported(accountId) else { return nil }
        let k = "\(accountId)/\(hostId)"
        if !force, let at = hostAt[k], Date().timeIntervalSince(at) < Self.fresh { return hosts[k] }
        hostAt[k] = Date()
        guard let h = handle(accountId), let a = try? await h.hostAccess(hostId: hostId) else { return hosts[k] }
        hosts[k] = a
        return a
    }

    func window(_ accountId: String?, _ hostId: String?, now: Int64 = nowMs()) -> HostWindow? {
        guard let a = host(accountId, hostId), !a.exempt, a.mode != .direct else { return nil }
        if let end = a.grant?.endsAt, end > now { return .open(endsAt: end) }
        return a.pending != nil ? .pending : .needed
    }

    // MARK: 2FA

    func refresh2fa(_ accountId: String) async {
        guard isSupported(accountId), let h = handle(accountId), let list = try? await h.team2faRequirements() else { return }
        team2fa[accountId] = list
    }

    var team2faAll: [(account: String, req: Team2faRequirement)] {
        team2fa.flatMap { a, l in l.map { (a, $0) } }
    }
}

// MARK: - Texts

/// The texts of teams security: error codes (always the app's), close
/// reasons, durations, states and notices.
enum AccessTexts {
    static func error(_ code: String) -> String? {
        switch code {
        case "connect_only": return String(localized: "error.connect_only")
        case "secret_reveal_forbidden": return String(localized: "error.secret_reveal_forbidden")
        case "access_approval_required": return String(localized: "error.access_approval_required")
        case "access_needs_server": return String(localized: "error.access_needs_server")
        case "access_request_exists": return String(localized: "error.access_request_exists")
        case "access_request_not_needed": return String(localized: "error.access_request_not_needed")
        case "access_request_closed": return String(localized: "error.access_request_closed")
        case "access_duration_too_long": return String(localized: "error.access_duration_too_long")
        case "self_approval_forbidden": return String(localized: "error.self_approval_forbidden")
        case "not_an_approver": return String(localized: "error.not_an_approver")
        case "ca_not_configured": return String(localized: "error.ca_not_configured")
        case "ca_exists": return String(localized: "error.ca_exists")
        case "certificate_key_not_owned": return String(localized: "error.certificate_key_not_owned")
        case "certificate_key_revoked": return String(localized: "error.certificate_key_revoked")
        case "certificate_proof_invalid": return String(localized: "error.certificate_proof_invalid")
        case "certificate_no_principals": return String(localized: "error.certificate_no_principals")
        case "team_2fa_required": return String(localized: "error.team_2fa_required")
        case "policy_requires_2fa": return String(localized: "error.policy_requires_2fa")
        case "ai_forbidden_by_policy": return String(localized: "error.ai_forbidden_by_policy")
        case "networks_forbidden_by_policy": return String(localized: "error.networks_forbidden_by_policy")
        case "recording_required": return String(localized: "error.recording_required")
        case "invalid_reason": return String(localized: "error.invalid_reason")
        default: return nil
        }
    }

    static func closeReason(_ reason: String) -> String? {
        switch reason {
        case "access_expired": return String(localized: "access.closed.access_expired")
        case "access_revoked": return String(localized: "access.closed.access_revoked")
        case "vault_access_revoked": return String(localized: "access.closed.vault_access_revoked")
        default: return nil
        }
    }

    /// The error's text when it is a teams security one (by code, or by the server's English text).
    static func of(_ error: Error) -> String? {
        if let info = (error as? TermoakError)?.apiError, let t = Self.error(info.code) { return t }
        return serverText(errorMessage(error))
    }

    /// A close reason or one of the server's English texts in words (`nil`: not one).
    static func serverText(_ text: String) -> String? {
        if let r = closeReason(text.trimmingCharacters(in: .whitespaces)) { return r }
        return AccessRules.code(ofMessage: text).flatMap { closeReason($0) ?? error($0) }
    }

    /// The need for an approval in an error (`nil`: not `access_approval_required`).
    static func need(_ error: Error, hostId: String?) -> AccessNeed? {
        guard let info = (error as? TermoakError)?.apiError, info.code == "access_approval_required" else { return nil }
        return AccessRules.need(json: info.detailsJson, hostId: hostId)
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return String(localized: "access.duration.minutes \(String(minutes))") }
        if minutes % 1440 == 0 { return String(localized: "access.duration.days \(minutes / 1440)") }
        if minutes % 60 == 0 { return String(localized: "access.duration.hours \(String(minutes / 60))") }
        return String(localized: "access.duration.hours_minutes \(String(minutes / 60)) \(String(minutes % 60))")
    }

    static func left(_ secs: Int64) -> String {
        let l = AccessRules.left(secs)
        if let s = l.seconds { return String(localized: "access.time.seconds \(String(s))") }
        if l.hours == 0 { return String(localized: "access.time.minutes \(String(l.minutes))") }
        return String(localized: "access.time.hours \(String(l.hours)) \(String(format: "%02d", Int(l.minutes)))")
    }

    static func clock(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    static func date(_ ms: Int64) -> String {
        DateFormatter.localizedString(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000), dateStyle: .medium, timeStyle: .none)
    }

    static func dateTime(_ ms: Int64) -> String {
        DateFormatter.localizedString(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000), dateStyle: .medium, timeStyle: .short)
    }

    static func status(_ k: AccessStatusKey) -> String {
        switch k {
        case .pending: return String(localized: "access.status.pending")
        case .active: return String(localized: "access.status.active")
        case .ended: return String(localized: "access.status.ended")
        case .denied: return String(localized: "access.status.denied")
        case .expired: return String(localized: "access.status.expired")
        case .cancelled: return String(localized: "access.status.cancelled")
        case .revoked: return String(localized: "access.status.revoked")
        case .unknown: return String(localized: "access.status.unknown")
        }
    }

    static func notice(_ n: AccessNotice, _ r: AccessEventRequest) -> String {
        let t = r.targetLabel
        switch n {
        case .created: return String(localized: "access.notice.created \(r.requesterName) \(t) \(duration(r.minutes))")
        case .approved: return String(localized: "access.notice.approved \(t) \(r.endsAt.map(clock) ?? "")")
        case .denied: return String(localized: "access.notice.denied \(t)")
        case .deniedReason: return String(localized: "access.notice.denied_reason \(t) \(r.decisionReason ?? "")")
        case .revoked: return String(localized: "access.notice.revoked \(r.decidedByName ?? "") \(t)")
        case .expired: return String(localized: "access.notice.expired \(t)")
        case .ended: return String(localized: "access.notice.ended \(t)")
        }
    }

    static func roleTitle(_ l: AccessLevel) -> String {
        switch l {
        case .connectOnly: return String(localized: "vaults.role.connect_only")
        case .useOnly: return String(localized: "vaults.role.use_only")
        case .editor: return String(localized: "vaults.role.editor")
        case .manager: return String(localized: "vaults.role.manager")
        case .unknown: return "?"
        }
    }

    static func roleHint(_ l: AccessLevel) -> String {
        switch l {
        case .connectOnly: return String(localized: "vaults.role_hint.connect_only")
        case .useOnly: return String(localized: "vaults.role_hint.use_only")
        case .editor: return String(localized: "vaults.role_hint.editor")
        case .manager: return String(localized: "vaults.role_hint.manager")
        case .unknown: return String(localized: "vaults.role_hint.unknown")
        }
    }

    static func targetLabel(_ r: AccessRequestInfo) -> String {
        switch r.targetKind {
        case .group: return String(localized: "access.target_group \(r.targetLabel)")
        case .vault: return String(localized: "access.target_vault \(r.targetLabel)")
        default: return r.targetLabel
        }
    }

    static func purpose(_ p: String) -> String {
        switch p {
        case "device": return String(localized: "certs.purpose.device")
        case "server": return String(localized: "certs.purpose.server")
        case "credentials": return String(localized: "certs.purpose.credentials")
        default: return p
        }
    }
}
