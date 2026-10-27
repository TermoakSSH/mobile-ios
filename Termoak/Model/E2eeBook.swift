import TermoakKit
import Foundation

// End-to-end encrypted vaults, SSO and the extended audit (0.7 phase 5c):
// the engine's types meet E2eeRules.swift, SsoRules.swift and AuditRules.swift.

extension VaultInfo {
    var e2eeFlags: VaultE2eeFlags? {
        e2ee.map { VaultE2eeFlags(keyVersion: $0.keyVersion, mayHoldKey: $0.mayHoldKey, hasWrap: $0.hasWrap, rekeyNeeded: $0.rekeyNeeded, pendingMembers: $0.pendingMembers) }
    }
}

extension E2eeRecoveryKeyCheck {
    var rules: RecoveryCheck { RecoveryCheck(valid: valid, reason: reason, words: Int(words), word: Int(word)) }
}

extension AuditFilterQuery {
    var engine: AuditQuery {
        AuditQuery(action: action, actor: actor, vaultId: vaultId, target: nil, since: since, until: nil, text: text, before: before, limit: limit)
    }
}

/// The E2EE, SSO and audit state of every signed-in account, shared by
/// every screen (the desktop's and Android's E2eeBook): which servers have
/// them (`/info features.e2ee|sso|audit_v2`, read when an account starts),
/// the account's key and whether this device holds it (the engine keeps it
/// in the account store sealed with the Keychain-protected device key), the
/// pairing requests this unlocked device can approve (read again on every
/// `e2ee` event), the edits waiting for an unlock after a sync, and the
/// vault keys this device already rotated by itself (once per vault and
/// key version, when the server flags `rekey_needed`).
@MainActor
final class E2eeBook: ObservableObject {
    static let shared = E2eeBook()

    struct Features: Equatable {
        var e2ee: Bool
        var sso: Bool
        var audit: AuditRules.Features?
    }

    @Published private(set) var features: [String: Features] = [:]
    @Published private(set) var status: [String: E2eeStatus] = [:]
    @Published private(set) var pairings: [String: [E2eePairingRequest]] = [:]
    @Published private(set) var waiting: [String: UInt64] = [:]
    /// A pairing request that was not there before (a dialog in front, a notification in the background).
    @Published var asking: (accountId: String, request: E2eePairingRequest)?
    /// Something to say after a sync (edits waiting, a key rotated by itself).
    @Published var notice: String?
    private var rotations: Set<String> = []
    var core: TermoakCore?

    private func handle(_ accountId: String) -> AccountHandle? { try? core?.account(accountId: accountId) }

    static func parseFeatures(_ info: String) -> Features {
        guard let d = info.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let f = o["features"] as? [String: Any] else { return Features(e2ee: false, sso: false, audit: nil) }
        return Features(e2ee: f["e2ee"] as? Bool ?? false, sso: f["sso"] as? Bool ?? false, audit: AuditRules.features(info))
    }

    func supported(_ accountId: String?) -> Bool { accountId.flatMap { features[$0]?.e2ee } ?? false }
    func ssoSupported(_ accountId: String?) -> Bool { accountId.flatMap { features[$0]?.sso } ?? false }
    func audit(_ accountId: String?) -> AuditRules.Features? { accountId.flatMap { features[$0]?.audit } }
    var anySupported: Bool { features.values.contains { $0.e2ee || $0.sso || $0.audit != nil } }
    var supportedAccounts: [String] { features.filter { $0.value.e2ee }.map(\.key).sorted() }

    func setUp(_ accountId: String?) -> Bool { accountId.flatMap { status[$0]?.setUp } ?? false }
    func unlocked(_ accountId: String?) -> Bool { accountId.flatMap { status[$0]?.unlocked } ?? false }
    var pairingCount: Int { pairings.values.reduce(0) { $0 + $1.count } }

    /// Reads `/info`, then the account's E2EE state.
    func start(_ accountId: String, core: TermoakCore) async {
        self.core = core
        guard let h = handle(accountId) else { return }
        if let info = try? await h.apiRequest(method: .get, path: "/api/v1/info", bodyJson: nil) {
            features[accountId] = Self.parseFeatures(info)
        }
        if supported(accountId) { await refresh(accountId) }
    }

    func forget(_ accountId: String) {
        features[accountId] = nil
        status[accountId] = nil
        pairings[accountId] = nil
        waiting[accountId] = nil
    }

    /// Reads the account's E2EE state again; pairings only on an unlocked device (the one that can approve them).
    func refresh(_ accountId: String) async {
        guard supported(accountId), let h = handle(accountId), let st = try? await h.e2eeStatus() else { return }
        status[accountId] = st
        var list: [E2eePairingRequest] = []
        if st.unlocked && st.pendingPairings > 0 { list = (try? await h.e2eePairings()) ?? [] }
        let now = nowMs()
        list = list.filter { $0.expiresAt > now }
        let before = Set((pairings[accountId] ?? []).map(\.id))
        pairings[accountId] = list
        if let fresh = list.first(where: { !before.contains($0.id) }) { asking = (accountId, fresh) }
    }

    func decided(_ accountId: String, _ pairingId: String) {
        pairings[accountId] = (pairings[accountId] ?? []).filter { $0.id != pairingId }
        if asking?.request.id == pairingId { asking = nil }
    }

    /// After a sync: the edits waiting for an unlock (said when their number
    /// grows), and the keys this unlocked device rotates by itself. Returns
    /// whether it rotated one (the caller syncs again).
    func synced(_ accountId: String, report: SyncReport, vaults: [VaultInfo]) async -> Bool {
        guard supported(accountId) else { return false }
        let before = waiting[accountId] ?? 0
        waiting[accountId] = report.e2eeWaiting
        if report.e2eeWaiting > before { notice = String(localized: "e2ee.notice.waiting \(Int(report.e2eeWaiting))") }
        if status[accountId] == nil { await refresh(accountId) }
        guard let h = handle(accountId) else { return false }
        var rotated = false
        for v in vaults where v.accountId == accountId && E2eeRules.shouldRotate(v.e2eeFlags, unlocked: unlocked(accountId)) {
            guard let version = v.e2ee?.keyVersion, rotations.insert("\(v.id):\(version)").inserted else { continue }
            // A race with another key holder ends in e2ee_stale: nothing to do.
            if let n = try? await h.e2eeRotateVault(vaultId: v.id) {
                rotated = true
                notice = String(localized: "vault_e2ee.auto_rotated \(v.name) \(String(n))")
            }
        }
        return rotated
    }
}

// MARK: - Texts

/// The texts of E2EE, SSO and the audit: every new error code (always the
/// app's), the refusal reasons of a recovery phrase, `sso_required` naming
/// the team.
enum E2eeTexts {
    static func error(_ code: String, details: [String: Any] = [:]) -> String? {
        if code == "e2ee_recovery_key_invalid", let reason = details["reason"] as? String {
            return recoveryReason(reason, word: details["word"] as? Int ?? 0, words: details["words"] as? Int ?? 0)
        }
        if code == "sso_required", let team = details["team_name"] as? String, !team.isEmpty {
            return String(localized: "error.sso_required_team \(team)")
        }
        guard E2eeRules.errorCodes.contains(code) else { return nil }
        return NSLocalizedString("error." + code, comment: "")
    }

    static func recoveryReason(_ reason: String, word: Int, words: Int) -> String {
        switch reason {
        case "word_count": return String(localized: "e2ee.recovery.reason.word_count \(String(E2eeRules.words)) \(words)")
        case "unknown_word": return String(localized: "e2ee.recovery.reason.unknown_word \(String(word))")
        case "checksum": return String(localized: "e2ee.recovery.reason.checksum")
        case "old_format": return String(localized: "e2ee.recovery.reason.old_format")
        default: return String(localized: "error.e2ee_recovery_key_invalid")
        }
    }

    static func details(_ info: ApiErrorInfo) -> [String: Any] {
        guard let d = info.detailsJson.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    static func of(_ error: Error) -> String? {
        guard let e = error as? TermoakError else { return nil }
        if let info = e.apiError, let t = Self.error(info.code, details: details(info)) { return t }
        switch e {
        case .E2eeLocked: return String(localized: "error.e2ee_locked")
        case .SsoRequired: return String(localized: "error.sso_required")
        default: return nil
        }
    }

    static func code(_ error: Error) -> String? { (error as? TermoakError)?.apiError?.code }

    /// The server can only use the host's credentials if this device sends them (a server session, a host test).
    static func needsUnlock(_ error: Error) -> Bool { code(error) == "e2ee_unlock_required" }

    /// This device can't open the host's credentials, or the server needs them.
    static func isLocked(_ error: Error) -> Bool {
        if case .E2eeLocked = error as? TermoakError { return true }
        return ["e2ee_locked", "e2ee_unlock_required"].contains(code(error) ?? "")
    }

    /// A password sign-in refused because the team requires single sign-on: (team id, team name).
    static func ssoRequired(_ error: Error) -> (String?, String?)? {
        guard let e = error as? TermoakError else { return nil }
        let info = e.apiError
        var isSso = info?.code == "sso_required"
        if case .SsoRequired = e { isSso = true }
        guard isSso else { return nil }
        let d = info.map(details) ?? [:]
        return (d["team_id"] as? String, d["team_name"] as? String)
    }

    static func feedbackText(_ f: E2eeRules.Feedback) -> String? {
        switch f {
        case .empty: return nil
        case .valid: return String(localized: "e2ee.unlock.recovery_valid")
        case .typing(let n): return String(localized: "e2ee.unlock.recovery_typing \(n)")
        case .problem(let reason, let word, let words): return recoveryReason(reason, word: word, words: words)
        }
    }
}

/// The engine's recovery phrase helpers (pure functions of the library).
enum RecoveryWords {
    static let list: [String] = e2eeRecoveryWordlist()
    static func check(_ text: String) -> RecoveryCheck { e2eeRecoveryKeyCheck(text: text).rules }
    static func feedback(_ text: String) -> E2eeRules.Feedback { E2eeRules.feedback(text, check: check, wordlist: list) }
}
