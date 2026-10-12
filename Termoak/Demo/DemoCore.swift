import Foundation
import TermoakKit

// The engine of the demo (DemoMode.swift): a real `TermoakCore` on an empty
// temporary vault (whatever the demo does not imitate gets the engine's own
// answer, without accounts and so without network) with the accounts,
// vaults, items, AI, server sessions, terminals and SFTP of DemoData.swift
// on top. Nothing here connects anywhere.

/// The demo's state, shared by the core and the accounts' handles (any thread).
final class DemoBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts = DemoData.hosts
    private var groups = DemoData.groups
    private var snippets = DemoData.snippets
    private var tasks = DemoData.tasks
    private var view: String?
    let keys = DemoData.keys
    let vaults = DemoData.vaults

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Accounts

    var accounts: [AccountInfo] { DemoData.accounts }
    var accountView: String? { locked { view } }
    func setAccountView(_ id: String?) { locked { view = id } }

    func account(_ id: String) throws -> AccountInfo {
        guard let a = accounts.first(where: { $0.id == id }) else { throw TermoakError.NotFound(message: id) }
        return a
    }

    // MARK: Items

    /// An item of `accountId`/`vaultId` is in `filter` (`nil`: everything).
    static func matches(_ accountId: String?, _ vaultId: String?, _ filter: ItemFilter?) -> Bool {
        guard let filter else { return true }
        guard let accountId else { return filter.includeDevice }
        if let ids = filter.accountIds, !ids.contains(accountId) { return false }
        if let ids = filter.vaultIds, !(vaultId.map(ids.contains) ?? false) { return false }
        return true
    }

    func vaults(_ filter: ItemFilter?) -> [VaultInfo] {
        vaults.filter { Self.matches($0.accountId, $0.id, filter) }
    }

    func hosts(_ filter: ItemFilter?) -> [SshHost] {
        locked { hosts.filter { Self.matches($0.accountId, $0.vaultId, filter) } }
    }

    func host(_ id: String, _ accountId: String?) throws -> SshHost {
        try locked {
            guard let h = hosts.first(where: { $0.id == id && (accountId == nil || $0.accountId == accountId) }) else {
                throw TermoakError.NotFound(message: id)
            }
            return h
        }
    }

    func save(_ host: SshHost) -> SshHost {
        var h = host
        if h.id.isEmpty { h.id = "h-\(UUID().uuidString.prefix(8).lowercased())" }
        if h.access == nil { h.access = h.accountId == nil ? .device : .manager }
        h.updatedAt = DemoData.now
        locked {
            if let i = hosts.firstIndex(where: { $0.id == h.id && $0.accountId == h.accountId }) {
                hosts[i] = h
            } else {
                hosts.append(h)
            }
        }
        return h
    }

    func deleteHost(_ id: String, _ accountId: String?) {
        locked { hosts.removeAll { $0.id == id && $0.accountId == accountId } }
    }

    func groups(_ filter: ItemFilter?) -> [HostGroup] {
        locked { groups.filter { Self.matches($0.accountId, $0.vaultId, filter) } }
    }

    func group(_ id: String, _ accountId: String?) throws -> HostGroup {
        try locked {
            guard let g = groups.first(where: { $0.id == id && (accountId == nil || $0.accountId == accountId) }) else {
                throw TermoakError.NotFound(message: id)
            }
            return g
        }
    }

    func save(_ group: HostGroup) -> HostGroup {
        var g = group
        if g.id.isEmpty { g.id = "group-\(UUID().uuidString.prefix(8).lowercased())" }
        if g.access == nil { g.access = g.accountId == nil ? .device : .manager }
        g.updatedAt = DemoData.now
        locked {
            if let i = groups.firstIndex(where: { $0.id == g.id && $0.accountId == g.accountId }) {
                groups[i] = g
            } else {
                groups.append(g)
            }
        }
        return g
    }

    func deleteGroup(_ id: String, _ accountId: String?) {
        locked {
            groups.removeAll { $0.id == id && $0.accountId == accountId }
            for i in hosts.indices where hosts[i].groupId == id && hosts[i].accountId == accountId { hosts[i].groupId = nil }
        }
    }

    func snippets(_ filter: ItemFilter?) -> [Snippet] {
        locked { snippets.filter { Self.matches($0.accountId, $0.vaultId, filter) } }
    }

    func snippet(_ id: String, _ accountId: String?) throws -> Snippet {
        try locked {
            guard let s = snippets.first(where: { $0.id == id && (accountId == nil || $0.accountId == accountId) }) else {
                throw TermoakError.NotFound(message: id)
            }
            return s
        }
    }

    func save(_ snippet: Snippet) -> Snippet {
        var s = snippet
        if s.id.isEmpty { s.id = "s-\(UUID().uuidString.prefix(8).lowercased())" }
        if s.access == nil { s.access = s.accountId == nil ? .device : .manager }
        s.updatedAt = DemoData.now
        locked {
            if let i = snippets.firstIndex(where: { $0.id == s.id && $0.accountId == s.accountId }) {
                snippets[i] = s
            } else {
                snippets.append(s)
            }
        }
        return s
    }

    func deleteSnippet(_ id: String, _ accountId: String?) {
        locked { snippets.removeAll { $0.id == id && $0.accountId == accountId } }
    }

    func keys(_ filter: ItemFilter?) -> [SshKey] {
        keys.filter { Self.matches($0.accountId, $0.vaultId, filter) }
    }

    func key(_ id: String, _ accountId: String?) throws -> SshKey {
        guard let k = keys.first(where: { $0.id == id && (accountId == nil || $0.accountId == accountId) }) else {
            throw TermoakError.NotFound(message: id)
        }
        return k
    }

    // MARK: AI (the Work account's)

    func tasks(of accountId: String) -> [AiTask] {
        accountId == DemoData.work ? locked { tasks } : []
    }

    func approvals(of accountId: String) -> [AiApproval] {
        tasks(of: accountId).flatMap(\.pendingApprovals)
    }

    func task(_ id: String) throws -> AiTask {
        try locked {
            guard let t = tasks.first(where: { $0.id == id }) else { throw TermoakError.NotFound(message: id) }
            return t
        }
    }

    /// A new task: the copilot's conversation about web-1.
    func createTask(_ request: AiTaskRequest) -> AiTask {
        let t = DemoData.copilot
        locked {
            tasks.removeAll { $0.id == t.id }
            tasks.insert(t, at: 0)
        }
        return t
    }

    /// Approved or denied: the task goes on and ends.
    func decide(task id: String, approval: String, approve: Bool) {
        locked {
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
            tasks[i].pendingApprovals.removeAll { $0.id == approval }
            tasks[i].updatedAt = DemoData.now
            if tasks[i].pendingApprovals.isEmpty {
                tasks[i].status = .completed
                tasks[i].finishedAt = DemoData.now
                tasks[i].result = approve ? demoText("Done.", "Hecho.") : demoText("Denied.", "Denegado.")
            }
        }
    }

    func update(task id: String, _ change: (inout AiTask) -> Void) {
        locked {
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
            change(&tasks[i])
        }
    }

    func deleteTask(_ id: String) {
        locked { tasks.removeAll { $0.id == id } }
    }

    func serverSessions(of accountId: String) -> ServerSessionList {
        accountId == DemoData.work ? DemoData.serverSessions : ServerSessionList(active: [], shared: [], recent: [])
    }

    var aiAccess: AiAccessInfo {
        AiAccessInfo(ownKeys: [], serverAi: true, creditUsd: 20, spentUsd: 3.42, remainingUsd: 16.58, providers: [])
    }
}

/// The engine of the demo.
final class DemoCore: TermoakCore, @unchecked Sendable {
    let backend = DemoBackend()
    private var current: String { DemoData.work }

    // MARK: Accounts and vaults

    override func accounts() -> [AccountInfo] { backend.accounts }
    override func currentAccount() -> AccountInfo? { backend.accounts.first(where: \.isCurrent) }
    override func accountView() -> String? { backend.accountView }
    override func setAccountView(accountId: String?) throws { backend.setAccountView(accountId) }
    override func vaults(filter: ItemFilter?) throws -> [VaultInfo] { backend.vaults(filter) }

    override func account(accountId: String) throws -> AccountHandle {
        DemoAccountHandle(backend: backend, info: try backend.account(accountId))
    }

    // MARK: Items

    override func listHosts(filter: ItemFilter?) throws -> [SshHost] { backend.hosts(filter) }
    override func getHost(id: String, accountId: String?) throws -> SshHost { try backend.host(id, accountId) }
    override func saveHost(host: SshHost, password: SecretChange) throws -> SshHost { backend.save(host) }
    override func deleteHost(id: String, accountId: String?) throws { backend.deleteHost(id, accountId) }
    override func hostHasProxyPassword(id: String, accountId: String?) throws -> Bool { false }
    override func hostPassword(id: String, accountId: String?) throws -> String? { nil }

    override func listGroups(filter: ItemFilter?) throws -> [HostGroup] { backend.groups(filter) }
    override func getGroup(id: String, accountId: String?) throws -> HostGroup { try backend.group(id, accountId) }
    override func saveGroup(group: HostGroup) throws -> HostGroup { backend.save(group) }
    override func deleteGroup(id: String, accountId: String?) throws { backend.deleteGroup(id, accountId) }

    override func listSnippets(filter: ItemFilter?) throws -> [Snippet] { backend.snippets(filter) }
    override func getSnippet(id: String, accountId: String?) throws -> Snippet { try backend.snippet(id, accountId) }
    override func saveSnippet(snippet: Snippet) throws -> Snippet { backend.save(snippet) }
    override func deleteSnippet(id: String, accountId: String?) throws { backend.deleteSnippet(id, accountId) }

    override func listKeys(filter: ItemFilter?) throws -> [SshKey] { backend.keys(filter) }
    override func getKey(id: String, accountId: String?) throws -> SshKey { try backend.key(id, accountId) }

    /// The status dots: every host answers but staging-worker.
    override func probeHosts(hosts: [ItemRef], off: [String], concurrency: UInt32) async throws -> [HostProbe] {
        hosts.map { ref in
            let ms = DemoData.latency(ref.id)
            return HostProbe(hostId: ref.id, accountId: ref.accountId, status: ms == nil ? .down : .up, ms: ms,
                             checkedAt: DemoData.now, skipped: nil, address: nil, port: 22)
        }
    }

    // MARK: Terminals and SFTP

    override func connectTerminal(hostId: String, cols: UInt32, rows: UInt32, auth: AuthHandler, listener: TerminalListener,
                                  accountId: String?, telnetAutoLogin: Bool, record: Bool,
                                  keyChanged: HostKeyChangeHandler?) async throws -> TerminalHandle {
        let host = try backend.host(hostId, accountId)
        // As long as a quick connection takes.
        try? await Task.sleep(nanoseconds: 300_000_000)
        return DemoTerminalHandle(host: host, listener: listener, cols: Int(cols), rows: Int(rows))
    }

    override func connect(hostId: String, auth: AuthHandler, accountId: String?,
                          keyChanged: HostKeyChangeHandler?) async throws -> SshSession {
        let host = try backend.host(hostId, accountId)
        try? await Task.sleep(nanoseconds: 200_000_000)
        return DemoSshSession(host: host)
    }

    override func shareTerminal(terminal: TerminalHandle, title: String) async throws -> SharedTerminal {
        DemoSharedTerminal()
    }

    // MARK: The current account's server (the AI, server sessions)

    override func listAiTasks(limit: UInt32) async throws -> [AiTask] { backend.tasks(of: current) }
    override func listPendingApprovals() async throws -> [AiApproval] { backend.approvals(of: current) }
    override func getAiTask(taskId: String) async throws -> AiTask { try backend.task(taskId) }
    override func createAiTask(request: AiTaskRequest) async throws -> AiTask { backend.createTask(request) }
    override func sendAiMessage(taskId: String, text: String) async throws -> AiTask { try backend.task(taskId) }
    override func cancelAiTask(taskId: String) async throws {
        backend.update(task: taskId) { $0.status = .cancelled; $0.pendingApprovals = [] }
    }
    override func setAiTaskMode(taskId: String, mode: AiPermissionMode) async throws {
        backend.update(task: taskId) { $0.mode = mode }
    }
    override func decideApproval(taskId: String, approvalId: String, approve: Bool, always: Bool) async throws {
        backend.decide(task: taskId, approval: approvalId, approve: approve)
    }
    override func decideApprovalWith(taskId: String, approvalId: String, decision: AiDecision) async throws {
        backend.decide(task: taskId, approval: approvalId, approve: decision.approve)
    }
    override func deleteAiTask(taskId: String) async throws { backend.deleteTask(taskId) }
    override func getRunbook(taskId: String) async throws -> AiRunbook { throw DemoMode.unavailable }
    override func saveRunbook(taskId: String, vaultId: String?, name: String?) async throws -> Snippet { throw DemoMode.unavailable }
    override func listAiProviders() async throws -> AiProviders { DemoData.providers }
    override func aiExplain(text: String, question: String?, context: AiAssistContext?, provider: String?) async throws -> AiExplanation {
        throw DemoMode.unavailable
    }
    override func aiSuggest(request: String, context: AiAssistContext?, provider: String?) async throws -> AiCommandSuggestion {
        throw DemoMode.unavailable
    }
    override func aiAccess() async throws -> AiAccessInfo { backend.aiAccess }
    override func listAiKeys() async throws -> [AiKeyInfo] { [] }
    override func isLoggedIn() async throws -> Bool { true }

    override func listServerSessions() async throws -> ServerSessionList { backend.serverSessions(of: current) }
    override func attachServerSession(sessionId: String, listener: ServerTerminalListener) async throws -> ServerTerminalHandle {
        throw DemoMode.unavailable
    }
    override func joinLink(token: String, listener: ServerTerminalListener) async throws -> ServerTerminalHandle {
        throw DemoMode.unavailable
    }
    override func openServerSession(hostId: String, cols: UInt32, rows: UInt32, title: String?, record: Bool?,
                                    accountId: String?) async throws -> ServerSession {
        throw DemoMode.unavailable
    }
    override func closeServerSession(sessionId: String) async throws {}
    override func sessionActivity(sessionId: String) async throws -> SessionActivity? { nil }
    override func subscribeEvents(listener: ServerEventListener) async throws -> EventSubscription {
        DemoEventSubscription(listener: listener)
    }
    override func syncNow() async throws -> SyncReport { SyncReport(pushed: 0, pulled: 0, rev: 1) }

    override func apiGet(path: String) async throws -> String { throw DemoMode.unavailable }
    override func apiPost(path: String, bodyJson: String?) async throws -> String { throw DemoMode.unavailable }
    override func apiPatch(path: String, bodyJson: String?) async throws -> String { throw DemoMode.unavailable }
    override func apiPut(path: String, bodyJson: String?) async throws -> String { throw DemoMode.unavailable }
    override func apiDelete(path: String) async throws -> String { throw DemoMode.unavailable }
    override func apiRequest(method: HttpMethod, path: String, bodyJson: String?) async throws -> String { throw DemoMode.unavailable }
}

/// An account of the demo.
final class DemoAccountHandle: DemoAccountHandleBase, @unchecked Sendable {
    private let backend: DemoBackend
    private let account: AccountInfo

    init(backend: DemoBackend, info: AccountInfo) {
        self.backend = backend
        account = info
        super.init()
    }

    required init(unsafeFromHandle handle: UInt64) {
        backend = DemoBackend()
        account = DemoData.accounts[0]
        super.init(unsafeFromHandle: handle)
    }

    private var accountId: String { account.id }

    override func id() -> String { accountId }
    override func info() throws -> AccountInfo { account }
    override func refreshInfo() async throws -> AccountInfo { account }
    override func currentUser() async throws -> ServerUser {
        ServerUser(id: account.userId ?? "", email: account.email, name: account.name, isAdmin: false, disabled: false,
                   twoFactor: true, createdAt: DemoData.ago(minutes: 60 * 24 * 400), locale: Bundle.main.preferredLocalizations.first ?? "en")
    }
    override func setLocale(locale: String) async throws -> ServerUser { try await currentUser() }
    override func twoFactorStatus() async throws -> TwoFactorStatus { TwoFactorStatus(enabled: true, recoveryCodesLeft: 8) }
    override func syncNow() async throws -> SyncReport {
        try? await Task.sleep(nanoseconds: 300_000_000)
        return SyncReport(pushed: 0, pulled: 0, rev: 1, accountId: accountId)
    }
    override func subscribeEvents(listener: ServerEventListener) async throws -> EventSubscription {
        DemoEventSubscription(listener: listener)
    }
    override func registerPushToken(platform: PushPlatform, token: String, sandbox: Bool) async throws -> Bool { false }
    override func unregisterPushToken() async throws {}

    // Vaults and teams.
    override func listVaults() async throws -> [VaultInfo] { backend.vaults.filter { $0.accountId == accountId } }
    override func vaultMembers(vaultId: String) async throws -> [VaultMember] {
        vaultId == DemoData.opsVault ? DemoData.opsMembers : []
    }
    override func vaultAudit(vaultId: String, limit: UInt32, before: Int64?) async throws -> [AuditEvent] { [] }
    override func listTeams() async throws -> [Team] { accountId == DemoData.work ? DemoData.teams : [] }
    override func listTeamMembers(teamId: String) async throws -> [TeamMember] { [] }
    override func listTeamInvites(teamId: String) async throws -> [AccountInvite] { [] }

    // The AI.
    override func listAiTasks(limit: UInt32) async throws -> [AiTask] { backend.tasks(of: accountId) }
    override func listPendingApprovals() async throws -> [AiApproval] { backend.approvals(of: accountId) }
    override func getAiTask(taskId: String) async throws -> AiTask { try backend.task(taskId) }
    override func createAiTask(request: AiTaskRequest) async throws -> AiTask { backend.createTask(request) }
    override func sendAiMessage(taskId: String, text: String) async throws -> AiTask { try backend.task(taskId) }
    override func cancelAiTask(taskId: String) async throws {
        backend.update(task: taskId) { $0.status = .cancelled; $0.pendingApprovals = [] }
    }
    override func setAiTaskMode(taskId: String, mode: AiPermissionMode) async throws {
        backend.update(task: taskId) { $0.mode = mode }
    }
    override func decideApproval(taskId: String, approvalId: String, approve: Bool, always: Bool) async throws {
        backend.decide(task: taskId, approval: approvalId, approve: approve)
    }
    override func decideApprovalWith(taskId: String, approvalId: String, decision: AiDecision) async throws {
        backend.decide(task: taskId, approval: approvalId, approve: decision.approve)
    }
    override func deleteAiTask(taskId: String) async throws { backend.deleteTask(taskId) }
    override func listAiProviders() async throws -> AiProviders { DemoData.providers }
    override func aiAccess() async throws -> AiAccessInfo { backend.aiAccess }

    // Server sessions.
    override func listServerSessions() async throws -> ServerSessionList { backend.serverSessions(of: accountId) }
    override func listServerSessionShares(sessionId: String) async throws -> [SessionShareInfo] { [] }
    override func closeServerSession(sessionId: String) async throws {}
    override func sessionActivity(sessionId: String) async throws -> SessionActivity? { nil }
}

/// Live events of an account: none arrive; it closes when unsubscribed.
final class DemoEventSubscription: DemoEventSubscriptionBase, @unchecked Sendable {
    private let listener: ServerEventListener

    init(listener: ServerEventListener) {
        self.listener = listener
        super.init()
    }

    required init(unsafeFromHandle handle: UInt64) {
        fatalError("the demo makes its own subscriptions")
    }

    override func unsubscribe() {
        listener.onClosed(reason: nil)
    }
}

/// A terminal to a host of the demo: it shows the host's screen
/// (DemoScreens.swift), drawn again when its size changes, and echoes
/// what is typed.
final class DemoTerminalHandle: DemoTerminalHandleBase, @unchecked Sendable {
    private let host: SshHost
    private let listener: TerminalListener
    private let connection: DemoSshSession
    private let lock = NSLock()
    private var cols: Int
    private var rows: Int
    private var generation = 0
    private var closed = false

    init(host: SshHost, listener: TerminalListener, cols: Int, rows: Int) {
        self.host = host
        self.listener = listener
        self.cols = cols
        self.rows = rows
        connection = DemoSshSession(host: host)
        super.init()
        draw(after: 0.3)
    }

    required init(unsafeFromHandle handle: UInt64) {
        fatalError("the demo makes its own terminals")
    }

    /// Draws the screen after `delay` seconds (unless the size changes again meanwhile).
    private func draw(after delay: Double) {
        lock.lock()
        generation += 1
        let mine = generation
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.generation == mine && !self.closed
            let (c, r) = (self.cols, self.rows)
            self.lock.unlock()
            guard current else { return }
            let user = self.host.settings.username ?? "deploy"
            self.listener.onOutput(data: DemoScreens.screen(host: self.host.label, os: self.host.os, user: user, cols: c, rows: r,
                                                            broadcast: DemoMode.scene == .split))
        }
    }

    override func resize(cols: UInt32, rows: UInt32) throws {
        lock.lock()
        let changed = Int(cols) != self.cols || Int(rows) != self.rows
        self.cols = Int(cols)
        self.rows = Int(rows)
        lock.unlock()
        if changed { draw(after: 0.2) }
    }

    /// The shell's echo of what is typed (Return gives the prompt again).
    override func write(data: Data) throws {
        guard host.label != "web-2" else { return }
        var out = ""
        for byte in data {
            switch byte {
            case 13:
                let user = host.settings.username ?? "deploy"
                let path = host.label == "web-1" ? "~/app" : "~"
                out += "\r\n" + DemoScreens.render(DemoScreens.prompt(user, host.label, path), cols: 1000)
            case 127, 8: out += "\u{8} \u{8}"
            case 32...126: out += String(UnicodeScalar(byte))
            default: break
            }
        }
        if !out.isEmpty { listener.onOutput(data: Data(out.utf8)) }
    }

    override func writeText(text: String) throws { try write(data: Data(text.utf8)) }

    override func latencyMs(timeoutMs: UInt32) async throws -> Double {
        Double(DemoData.latency(host.id) ?? 30)
    }

    override func session() -> SshSession { connection }

    override func status() -> TerminalStatus {
        lock.lock()
        defer { lock.unlock() }
        return closed ? .closed(exitCode: nil, reason: nil) : .running
    }

    override func closeTerminal() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}

/// An SSH connection of the demo: its SFTP shows DemoData's files, and
/// transfers advance to a point and wait there until they are cancelled.
final class DemoSshSession: DemoSshSessionBase, @unchecked Sendable {
    private let host: SshHost
    private let lock = NSLock()
    private var closed = false

    init(host: SshHost) {
        self.host = host
        super.init()
    }

    required init(unsafeFromHandle handle: UInt64) {
        fatalError("the demo makes its own connections")
    }

    override func accountId() -> String? { host.accountId }
    override func hostId() -> String { host.id }
    override func isTelnet() -> Bool { false }
    override func `protocol`() -> String { "ssh" }

    override func isClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    override func details() -> ConnectionDetails {
        ConnectionDetails(label: host.label, address: host.address, port: 22, username: host.settings.username ?? "",
                          serverKeyType: "ssh-ed25519", serverFingerprint: "SHA256:Zq3vY0rM1oVq9pD7m2Xc8bN4hT6kL1sE5wA0uJ7fR2g",
                          banner: nil, via: [])
    }

    override func disconnect() async throws { close() }

    private func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    override func startAutoForwards() async throws -> [ActiveForward] { [] }

    override func sftpHome() async throws -> String { DemoData.home }
    override func sftpList(path: String) async throws -> [RemoteFile] { DemoData.files(in: path) }

    override func sftpStat(path: String) async throws -> RemoteFile {
        let parent = (path as NSString).deletingLastPathComponent
        if let f = DemoData.files(in: parent.isEmpty ? "/" : parent).first(where: { $0.path == path }) { return f }
        throw TermoakError.Sftp(message: "No such file")
    }

    override func sftpRead(path: String, maxBytes: UInt64) async throws -> Data {
        Data("# \((path as NSString).lastPathComponent)\n\nDemo.\n".utf8)
    }

    override func sftpWrite(path: String, data: Data) async throws {}
    override func sftpMkdir(path: String, recursive: Bool) async throws {}
    override func sftpRename(from: String, to: String) async throws {}
    override func sftpRemove(path: String, recursive: Bool) async throws {}
    override func sftpChmod(path: String, mode: UInt32) async throws {}

    override func sftpDownload(remotePath: String, localPath: String, listener: TransferListener?,
                               cancel: TransferHandle?) async throws -> UInt64 {
        let size = (try? await sftpStat(path: remotePath).size) ?? 52_428_800
        let stop = remotePath.contains("dump") ? 0.64 : 0.82
        return try await transfer(total: size, until: stop, listener: listener, cancel: cancel)
    }

    override func sftpUpload(localPath: String, remotePath: String, listener: TransferListener?,
                             cancel: TransferHandle?) async throws -> UInt64 {
        try await transfer(total: 51_380_224, until: 0.31, listener: listener, cancel: cancel)
    }

    /// Advances to `until` of `total` in a couple of seconds and waits there
    /// until it is cancelled.
    private func transfer(total: UInt64, until: Double, listener: TransferListener?, cancel: TransferHandle?) async throws -> UInt64 {
        let steps = 12
        for i in 1...steps {
            if cancel?.isCancelled() == true || Task.isCancelled { throw TermoakError.Cancelled(message: "cancelled") }
            let done = UInt64(Double(total) * until * Double(i) / Double(steps))
            listener?.onProgress(transferred: done, total: total)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        while cancel?.isCancelled() != true && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        throw TermoakError.Cancelled(message: "cancelled")
    }
}

/// A terminal of the demo shared through the server (for the copilot).
final class DemoSharedTerminal: DemoSharedTerminalBase, @unchecked Sendable {
    private let relayId = "relay-\(UUID().uuidString.prefix(8).lowercased())"

    override func sessionId() -> String { relayId }
    override func resize(cols: UInt32, rows: UInt32) async throws {}
    override func setListener(listener: SharedTerminalListener) async throws {}
    override func stop() async throws {}
    override func listInvites() async throws -> [SessionShareInfo] { [] }
}
