import TermoakKit
import Foundation

// Helpers for items that live in several places: This device, or a vault of
// one of the accounts.

/// What the app's lists use as identity: the same item seen through two
/// accounts appears twice, with the same id.
func itemKey(_ accountId: String?, _ id: String) -> String {
    "\(accountId ?? "device")/\(id)"
}

extension SshHost {
    var key: String { itemKey(accountId, id) }
    /// Use-only vault: connect, never see its secrets or change it.
    var isUseOnly: Bool { access == .useOnly }
    var canEdit: Bool { !isUseOnly }
    var displayName: String { label.isEmpty ? address : label }
}

extension HostGroup {
    var key: String { itemKey(accountId, id) }
    var canEdit: Bool { access != .useOnly }
}

extension SshKey {
    var key: String { itemKey(accountId, id) }
    var isUseOnly: Bool { access == .useOnly }
}

extension SshIdentity {
    var key: String { itemKey(accountId, id) }
    var isUseOnly: Bool { access == .useOnly }
}

extension Snippet {
    var key: String { itemKey(accountId, id) }
    var canEdit: Bool { access != .useOnly }
}

extension PortForward {
    var key: String { itemKey(accountId, id) }
    var canEdit: Bool { access != .useOnly }
}

extension KnownHost {
    var key: String { itemKey(accountId, id) }
}

extension AccountInfo {
    /// "ana@example.com" or, on another server, "ana@example.com · ssh.example.com".
    var title: String { name.isEmpty ? email : name }
    var initial: String {
        let source = name.isEmpty ? email : name
        return source.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }
    /// Server shown next to the account (nothing for the official one).
    var serverLabel: String? { official ? nil : serverName }
}

extension VaultInfo {
    var key: String { itemKey(accountId, id) }
    /// "Personal" is translated, not stored per language.
    var displayName: String {
        kind == .personal ? String(localized: "vaults.personal") : name
    }
    var canWrite: Bool { role == .editor || role == .manager }
    var canManage: Bool { role == .manager }
}

extension VaultRole {
    var title: String {
        switch self {
        case .useOnly: return String(localized: "vaults.role.use_only")
        case .editor: return String(localized: "vaults.role.editor")
        case .manager: return String(localized: "vaults.role.manager")
        case .unknown: return "?"
        }
    }
}

/// Icons a vault can have (stored by name, shown with SF Symbols).
let vaultIcons: [(name: String, symbol: String)] = [
    ("vault", "lock.shield"), ("folder", "folder"), ("server", "server.rack"), ("cloud", "cloud"),
    ("briefcase", "briefcase"), ("house", "house"), ("star", "star"), ("key", "key"),
    ("terminal", "terminal"), ("globe", "globe"), ("bolt", "bolt"), ("person", "person.2"),
]

func vaultSymbol(_ icon: String?, kind: VaultKind) -> String {
    if let icon, let match = vaultIcons.first(where: { $0.name == icon }) { return match.symbol }
    switch kind {
    case .personal: return "person.crop.circle"
    case .team: return "person.3"
    default: return "lock.shield"
    }
}

/// Where a new item is saved: This device, or a vault of an account.
struct ItemPlace: Hashable, Identifiable {
    let accountId: String?
    let vaultId: String?
    var id: String { "\(accountId ?? "device")/\(vaultId ?? "-")" }

    static let device = ItemPlace(accountId: nil, vaultId: nil)
}

/// Text of an error for the user: the rules of vaults and accounts are
/// translated here; anything else keeps the engine's message.
func userMessage(_ error: Error) -> String {
    guard let e = error as? TermoakError else { return errorMessage(error) }
    switch e {
    case .VaultReadOnly: return String(localized: "error.vault_read_only")
    case .SecretHidden: return String(localized: "error.secret_hidden")
    case .UseOnlyStrict: return String(localized: "error.use_only_strict")
    case .UseOnlyNeedsServer: return String(localized: "error.use_only_needs_server")
    case .SessionExpired: return String(localized: "account.session_expired")
    case .NotLoggedIn: return String(localized: "error.not_logged_in")
    case .EmailNotVerified: return String(localized: "error.email_not_verified")
    case .Network(let message): return String(localized: "error.network \(message)")
    // SFTP, tunnels, commands or a server session asked of a Telnet host.
    case .NotSupportedForTelnet: return String(localized: "error.not_supported_for_telnet")
    default: return errorMessage(error)
    }
}

/// The parts of the server API that both the current account (`TermoakCore`)
/// and one account (`AccountHandle`) have: the AI, server sessions and sync.
protocol AccountApi: AnyObject {
    func createAiTask(request: AiTaskRequest) async throws -> AiTask
    func sendAiMessage(taskId: String, text: String) async throws -> AiTask
    func getAiTask(taskId: String) async throws -> AiTask
    func cancelAiTask(taskId: String) async throws
    func setAiTaskMode(taskId: String, mode: AiPermissionMode) async throws
    func decideApproval(taskId: String, approvalId: String, approve: Bool, always: Bool) async throws
    func listAiTasks(limit: UInt32) async throws -> [AiTask]
    func listPendingApprovals() async throws -> [AiApproval]
    func listServerSessions() async throws -> ServerSessionList
    func attachServerSession(sessionId: String, listener: ServerTerminalListener) async throws -> ServerTerminalHandle
    func closeServerSession(sessionId: String) async throws
    func sessionActivity(sessionId: String) async throws -> SessionActivity?
}

extension TermoakCore: AccountApi {}
extension AccountHandle: AccountApi {}

extension TermoakCore {
    /// The API of an account (`nil`: the current one).
    func api(for accountId: String?) -> AccountApi {
        if let accountId, let handle = try? account(accountId: accountId) { return handle }
        return self
    }

    /// Teams of an account (for sharing a vault or creating a team vault).
    func teams(of accountId: String) async throws -> [Team] {
        let json = try await account(accountId: accountId).apiGet(path: "/api/v1/teams")
        guard let data = json.data(using: .utf8),
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let id = r["id"] as? String, let name = r["name"] as? String else { return nil }
            let role: TeamRole?
            switch r["role"] as? String {
            case "owner": role = .owner
            case "admin": role = .admin
            case "member": role = .member
            default: role = nil
            }
            return Team(id: id, name: name, role: role,
                        memberCount: UInt32((r["member_count"] as? Int) ?? 0),
                        createdAt: Int64((r["created_at"] as? Int) ?? 0))
        }
    }
}
