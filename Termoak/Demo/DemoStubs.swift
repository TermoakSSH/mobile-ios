import Foundation
import TermoakKit

// Demo mode only (DemoMode.swift): stand-ins for the engine's handles that
// answer every call without the engine. Objects made with `init(noHandle:)`
// have no Rust object behind them: any method not overridden here would
// reach the engine with an empty handle and crash, so each class overrides
// all of them (calls the demo does not imitate throw `DemoMode.unavailable`).
// Written from the generated API of core (TermoakFFI.swift): when core adds
// methods to these classes, add them here too.

/// An account of the server, answered by the demo.
class DemoAccountHandleBase: AccountHandle, @unchecked Sendable {
    init() { super.init(noHandle: AccountHandle.NoHandle()) }
    required init(unsafeFromHandle handle: UInt64) { super.init(unsafeFromHandle: handle) }

    override func addTeamMember(teamId: String, email: String, role: TeamRole) async throws -> [TeamMember] { throw DemoMode.unavailable }
    override func createTeam(name: String) async throws -> Team { throw DemoMode.unavailable }
    override func currentUser() async throws -> ServerUser { throw DemoMode.unavailable }
    override func deleteTeam(teamId: String) async throws { throw DemoMode.unavailable }
    override func disableTwoFactor(password: String, code: String) async throws { throw DemoMode.unavailable }
    override func enableTwoFactor(code: String) async throws -> [String] { throw DemoMode.unavailable }
    override func inviteToTeam(teamId: String, email: String, role: TeamRole) async throws -> TeamInviteResult { throw DemoMode.unavailable }
    override func leaveTeam(teamId: String) async throws { throw DemoMode.unavailable }
    override func listServerSessionShares(sessionId: String) async throws -> [SessionShareInfo] { throw DemoMode.unavailable }
    override func listTeamInvites(teamId: String) async throws -> [AccountInvite] { throw DemoMode.unavailable }
    override func listTeamMembers(teamId: String) async throws -> [TeamMember] { throw DemoMode.unavailable }
    override func listTeams() async throws -> [Team] { throw DemoMode.unavailable }
    override func registerPushToken(platform: PushPlatform, token: String, sandbox: Bool) async throws -> Bool { throw DemoMode.unavailable }
    override func registerWebPush(endpoint: String, p256dh: String, auth: String) async throws -> Bool { throw DemoMode.unavailable }
    override func pushStatus() async throws -> PushStatus { throw DemoMode.unavailable }
    override func setPushPreferences(preferences: PushPreferences) async throws -> PushPreferences { throw DemoMode.unavailable }
    override func removeTeamMember(teamId: String, userId: String) async throws { throw DemoMode.unavailable }
    override func renameTeam(teamId: String, name: String) async throws -> Team { throw DemoMode.unavailable }
    override func revokeServerSessionShare(sessionId: String, shareId: String) async throws { throw DemoMode.unavailable }
    override func revokeTeamInvite(teamId: String, inviteId: String) async throws { throw DemoMode.unavailable }
    override func sendTestPush() async throws { throw DemoMode.unavailable }
    override func setLocale(locale: String) async throws -> ServerUser { throw DemoMode.unavailable }
    override func setTeamMemberRole(teamId: String, userId: String, role: TeamRole) async throws -> [TeamMember] { throw DemoMode.unavailable }
    override func setupTwoFactor() async throws -> TwoFactorSetup { throw DemoMode.unavailable }
    override func shareServerSessionWith(sessionId: String, target: ShareTarget, options: ShareOptions) async throws -> ShareInvite { throw DemoMode.unavailable }
    override func stopSharingServerSession(sessionId: String) async throws -> UInt32 { throw DemoMode.unavailable }
    override func twoFactorStatus() async throws -> TwoFactorStatus { throw DemoMode.unavailable }
    override func unregisterPushToken() async throws { throw DemoMode.unavailable }
    override func updateServerSessionShare(sessionId: String, shareId: String, changes: ShareChanges) async throws -> SessionShareInfo { throw DemoMode.unavailable }
    override func addVaultMember(vaultId: String, target: VaultMemberTarget, role: VaultRole) async throws -> VaultMember { throw DemoMode.unavailable }
    override func aiAccess() async throws -> AiAccessInfo { throw DemoMode.unavailable }
    override func apiDelete(path: String) async throws -> String { throw DemoMode.unavailable }
    override func apiGet(path: String) async throws -> String { throw DemoMode.unavailable }
    override func apiPatch(path: String, bodyJson: String?) async throws -> String { throw DemoMode.unavailable }
    override func apiPost(path: String, bodyJson: String?) async throws -> String { throw DemoMode.unavailable }
    override func apiPut(path: String, bodyJson: String?) async throws -> String { throw DemoMode.unavailable }
    override func apiRequest(method: HttpMethod, path: String, bodyJson: String?) async throws -> String { throw DemoMode.unavailable }
    override func attachServerSession(sessionId: String, listener: ServerTerminalListener) async throws -> ServerTerminalHandle { throw DemoMode.unavailable }
    override func cancelAiTask(taskId: String) async throws { throw DemoMode.unavailable }
    override func closeServerSession(sessionId: String) async throws { throw DemoMode.unavailable }
    override func createAiTask(request: AiTaskRequest) async throws -> AiTask { throw DemoMode.unavailable }
    override func createVault(vault: NewVault) async throws -> VaultInfo { throw DemoMode.unavailable }
    override func decideApproval(taskId: String, approvalId: String, approve: Bool, always: Bool) async throws { throw DemoMode.unavailable }
    override func deleteVault(vaultId: String, confirmName: String) async throws { throw DemoMode.unavailable }
    override func getAiTask(taskId: String) async throws -> AiTask { throw DemoMode.unavailable }
    override func getServerSession(sessionId: String) async throws -> ServerSession { throw DemoMode.unavailable }
    override func id() -> String { "" }
    override func info() throws -> AccountInfo { throw DemoMode.unavailable }
    override func leaveVault(vaultId: String) async throws { throw DemoMode.unavailable }
    override func listAiTasks(limit: UInt32) async throws -> [AiTask] { throw DemoMode.unavailable }
    override func listPendingApprovals() async throws -> [AiApproval] { throw DemoMode.unavailable }
    override func listServerSessions() async throws -> ServerSessionList { throw DemoMode.unavailable }
    override func listVaults() async throws -> [VaultInfo] { throw DemoMode.unavailable }
    override func openServerSession(hostId: String, cols: UInt32, rows: UInt32, title: String?, record: Bool?) async throws -> ServerSession { throw DemoMode.unavailable }
    override func refreshInfo() async throws -> AccountInfo { throw DemoMode.unavailable }
    override func removeVaultMember(vaultId: String, memberId: String) async throws { throw DemoMode.unavailable }
    override func sendAiMessage(taskId: String, text: String) async throws -> AiTask { throw DemoMode.unavailable }
    override func serverSftpHome(hostId: String) async throws -> String { throw DemoMode.unavailable }
    override func serverSftpList(hostId: String, path: String) async throws -> [RemoteFile] { throw DemoMode.unavailable }
    override func sessionActivity(sessionId: String) async throws -> SessionActivity? { throw DemoMode.unavailable }
    override func setAiTaskMode(taskId: String, mode: AiPermissionMode) async throws { throw DemoMode.unavailable }
    override func setVaultMemberRole(vaultId: String, memberId: String, role: VaultRole) async throws -> VaultMember { throw DemoMode.unavailable }
    override func subscribeEvents(listener: ServerEventListener) async throws -> EventSubscription { throw DemoMode.unavailable }
    override func syncNow() async throws -> SyncReport { throw DemoMode.unavailable }
    override func updateVault(vaultId: String, changes: VaultChanges) async throws -> VaultInfo { throw DemoMode.unavailable }
    override func vaultAudit(vaultId: String, limit: UInt32, before: Int64?) async throws -> [AuditEvent] { throw DemoMode.unavailable }
    override func vaultMembers(vaultId: String) async throws -> [VaultMember] { throw DemoMode.unavailable }
    override func aiExplain(text: String, question: String?, context: AiAssistContext?, provider: String?) async throws -> AiExplanation { throw DemoMode.unavailable }
    override func aiSuggest(request: String, context: AiAssistContext?, provider: String?) async throws -> AiCommandSuggestion { throw DemoMode.unavailable }
    override func decideApprovalWith(taskId: String, approvalId: String, decision: AiDecision) async throws { throw DemoMode.unavailable }
    override func deleteAiTask(taskId: String) async throws { throw DemoMode.unavailable }
    override func getRunbook(taskId: String) async throws -> AiRunbook { throw DemoMode.unavailable }
    override func listAiProviders() async throws -> AiProviders { throw DemoMode.unavailable }
    override func saveRunbook(taskId: String, vaultId: String?, name: String?) async throws -> Snippet { throw DemoMode.unavailable }
    override func downloadRecording(sessionId: String, localPath: String, listener: TransferListener?, cancel: TransferHandle?) async throws -> UInt64 { throw DemoMode.unavailable }
    override func serverSftpChmod(hostId: String, path: String, mode: UInt32) async throws { throw DemoMode.unavailable }
    override func serverSftpDelete(hostId: String, path: String, recursive: Bool) async throws { throw DemoMode.unavailable }
    override func serverSftpDownload(hostId: String, remotePath: String, localPath: String, listener: TransferListener?, cancel: TransferHandle?) async throws -> UInt64 { throw DemoMode.unavailable }
    override func serverSftpMkdir(hostId: String, path: String, parents: Bool) async throws { throw DemoMode.unavailable }
    override func serverSftpRead(hostId: String, path: String, maxBytes: UInt64) async throws -> Data { throw DemoMode.unavailable }
    override func serverSftpRename(hostId: String, from: String, to: String) async throws { throw DemoMode.unavailable }
    override func serverSftpStat(hostId: String, path: String) async throws -> RemoteFile { throw DemoMode.unavailable }
    override func serverSftpUpload(hostId: String, localPath: String, remotePath: String, listener: TransferListener?, cancel: TransferHandle?) async throws -> UInt64 { throw DemoMode.unavailable }
    override func serverSftpWrite(hostId: String, path: String, data: Data) async throws -> UInt64 { throw DemoMode.unavailable }
}

/// An SSH connection, answered by the demo.
class DemoSshSessionBase: SshSession, @unchecked Sendable {
    init() { super.init(noHandle: SshSession.NoHandle()) }
    required init(unsafeFromHandle handle: UInt64) { super.init(unsafeFromHandle: handle) }

    override func accountId() -> String? { nil }
    override func details() -> ConnectionDetails { ConnectionDetails(label: "", address: "", port: 22, username: "", serverKeyType: nil, serverFingerprint: nil, banner: nil, via: []) }
    override func detectOs() async throws -> String? { throw DemoMode.unavailable }
    override func detectOsInfo() async throws -> RemoteOs? { throw DemoMode.unavailable }
    override func disconnect() async throws { throw DemoMode.unavailable }
    override func exec(command: String, timeoutSecs: UInt32) async throws -> ExecResult { throw DemoMode.unavailable }
    override func hostId() -> String { "" }
    override func isClosed() -> Bool { false }
    override func isTelnet() -> Bool { false }
    override func openTerminal(cols: UInt32, rows: UInt32, listener: TerminalListener, record: Bool) async throws -> TerminalHandle { throw DemoMode.unavailable }
    override func `protocol`() -> String { "ssh" }
    override func sftpChmod(path: String, mode: UInt32) async throws { throw DemoMode.unavailable }
    override func sftpDownload(remotePath: String, localPath: String, listener: TransferListener?, cancel: TransferHandle?) async throws -> UInt64 { throw DemoMode.unavailable }
    override func sftpHome() async throws -> String { throw DemoMode.unavailable }
    override func sftpList(path: String) async throws -> [RemoteFile] { throw DemoMode.unavailable }
    override func sftpMkdir(path: String, recursive: Bool) async throws { throw DemoMode.unavailable }
    override func sftpRead(path: String, maxBytes: UInt64) async throws -> Data { throw DemoMode.unavailable }
    override func sftpRemove(path: String, recursive: Bool) async throws { throw DemoMode.unavailable }
    override func sftpRename(from: String, to: String) async throws { throw DemoMode.unavailable }
    override func sftpStat(path: String) async throws -> RemoteFile { throw DemoMode.unavailable }
    override func sftpUpload(localPath: String, remotePath: String, listener: TransferListener?, cancel: TransferHandle?) async throws -> UInt64 { throw DemoMode.unavailable }
    override func sftpWrite(path: String, data: Data) async throws { throw DemoMode.unavailable }
    override func startAutoForwards() async throws -> [ActiveForward] { throw DemoMode.unavailable }
    override func startForward(forwardId: String) async throws -> ActiveForward { throw DemoMode.unavailable }
    override func startForwardSpec(kind: ForwardKind, bindAddress: String, bindPort: UInt32, destHost: String?, destPort: UInt32?) async throws -> ActiveForward { throw DemoMode.unavailable }
}

/// A terminal of this device, answered by the demo.
class DemoTerminalHandleBase: TerminalHandle, @unchecked Sendable {
    init() { super.init(noHandle: TerminalHandle.NoHandle()) }
    required init(unsafeFromHandle handle: UInt64) { super.init(unsafeFromHandle: handle) }

    override func closeTerminal() {}
    override func isTelnet() -> Bool { false }
    override func latencyMs(timeoutMs: UInt32) async throws -> Double { throw DemoMode.unavailable }
    override func `protocol`() -> String { "ssh" }
    override func recordingPath() -> String? { nil }
    override func resize(cols: UInt32, rows: UInt32) throws { throw DemoMode.unavailable }
    override func session() -> SshSession { DemoSshSessionBase() }
    override func snapshot() -> Data { Data() }
    override func status() -> TerminalStatus { .running }
    override func textTail(maxChars: UInt32) -> String { "" }
    override func write(data: Data) throws { throw DemoMode.unavailable }
    override func writeText(text: String) throws { throw DemoMode.unavailable }
}

/// A terminal shared through the server, answered by the demo.
class DemoSharedTerminalBase: SharedTerminal, @unchecked Sendable {
    init() { super.init(noHandle: SharedTerminal.NoHandle()) }
    required init(unsafeFromHandle handle: UInt64) { super.init(unsafeFromHandle: handle) }

    override func allowJoin(participantId: String) async throws { throw DemoMode.unavailable }
    override func denyControl(participantId: String) async throws { throw DemoMode.unavailable }
    override func denyJoin(participantId: String) async throws { throw DemoMode.unavailable }
    override func grantControl(participantId: String, minutes: UInt32?) async throws { throw DemoMode.unavailable }
    override func invite(target: ShareTarget, options: ShareOptions) async throws -> ShareInvite { throw DemoMode.unavailable }
    override func inviteLink(control: Bool, expiresInMinutes: Int64?) async throws -> ShareInvite { throw DemoMode.unavailable }
    override func inviteTeam(teamId: String, control: Bool) async throws -> ShareInvite { throw DemoMode.unavailable }
    override func inviteUser(email: String, control: Bool) async throws -> ShareInvite { throw DemoMode.unavailable }
    override func kick(participantId: String, revokeShare: Bool) async throws { throw DemoMode.unavailable }
    override func listInvites() async throws -> [SessionShareInfo] { throw DemoMode.unavailable }
    override func resize(cols: UInt32, rows: UInt32) async throws { throw DemoMode.unavailable }
    override func revokeAllInvites() async throws { throw DemoMode.unavailable }
    override func revokeInvite(shareId: String) async throws { throw DemoMode.unavailable }
    override func sessionId() -> String { "" }
    override func setListener(listener: SharedTerminalListener) async throws { throw DemoMode.unavailable }
    override func stop() async throws { throw DemoMode.unavailable }
    override func takeControl() async throws { throw DemoMode.unavailable }
    override func updateInvite(shareId: String, changes: ShareChanges) async throws -> SessionShareInfo { throw DemoMode.unavailable }
}

/// The live events of an account, answered by the demo.
class DemoEventSubscriptionBase: EventSubscription, @unchecked Sendable {
    init() { super.init(noHandle: EventSubscription.NoHandle()) }
    required init(unsafeFromHandle handle: UInt64) { super.init(unsafeFromHandle: handle) }

    override func unsubscribe() {}
}
