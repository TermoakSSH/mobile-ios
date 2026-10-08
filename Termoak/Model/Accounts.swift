import TermoakKit
import Combine
import Foundation

/// What the lists show: one account, every account together or only the
/// items saved on this device ("This device" items appear in the first two
/// as well).
enum AccountScope: Equatable {
    case all
    case account(String)
    case device
}

/// Vault chosen in the chips above the hosts.
enum VaultFilter: Equatable {
    case all
    case vault(accountId: String, vaultId: String)
    /// Only "This device" items.
    case device
}

/// A message about something that happened in the background (a sync that
/// lost a vault, the data layout migration...).
struct AppNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

/// "Upload N items from this device to your Personal vault?", offered after
/// the first account is added.
struct UploadOffer: Identifiable, Equatable {
    var id: String { accountId }
    let accountId: String
}

/// The accounts signed in on this device (several servers at once), which
/// ones the lists show, their sync, their live events (one WebSocket per
/// account) and the pending AI approvals.
@MainActor
final class Accounts: ObservableObject {
    let core: TermoakCore

    /// Every account, in order.
    @Published private(set) var list: [AccountInfo] = []
    @Published private(set) var scope: AccountScope = .all
    /// Vaults of every account as of their last sync.
    @Published private(set) var vaults: [VaultInfo] = []
    /// Vault chips of the hosts list.
    @Published var vaultFilter: VaultFilter = .all
    /// The current account is signed in (`nil` while unknown). Server
    /// features that work with the current account (AI, teams, sharing)
    /// look at this.
    @Published private(set) var loggedIn: Bool?
    @Published private(set) var syncingIds: Set<String> = []
    @Published private(set) var syncErrors: [String: String] = [:]
    /// Accounts receiving live events from their server.
    @Published private(set) var liveIds: Set<String> = []
    @Published private(set) var pendingApprovals = 0
    /// Notices to show, one at a time.
    @Published var notice: AppNotice?
    /// Offer to upload the This-device items to the first account.
    @Published var uploadOffer: UploadOffer?
    /// The current account's server says its email is not verified yet:
    /// the code step opens (once per launch and account).
    @Published var verifyPrompt: VerifyPrompt?
    private var verifyPrompted: Set<String> = []
    /// Account chosen in the AI section (`nil`: the current one).
    @Published var aiAccountId: String?

    /// Something changed on a server (`ai`, `session`, `lagged`): reload.
    let changes = PassthroughSubject<String, Never>()
    /// The local items changed (a sync, a transfer, an account removed).
    let vaultChanged = PassthroughSubject<Void, Never>()
    /// Accounts were added, signed in, signed out or removed.
    let accountsChanged = PassthroughSubject<Void, Never>()
    /// Every event of an AI task (to follow it live in the copilot).
    let aiEvents = PassthroughSubject<AiEvent, Never>()
    /// Notices about sessions (toasts over any screen).
    let sessionNotices = PassthroughSubject<ShareNotice, Never>()

    private var queued: [AppNotice] = []
    private var events: [String: (task: Task<Void, Never>, subscription: EventSubscription?)] = [:]
    private var approvals: [String: Int] = [:]
    /// Account added from an empty device: after its first sync, offer to
    /// upload the This-device items.
    private var offerUploadTo: String?

    private static let deviceOnlyKey = "accounts_device_only"
    private static let layoutNoticeKey = "layout_notice_shown"

    init(core: TermoakCore) {
        self.core = core
        reload()
    }

    // ----- State -----

    /// Reads the accounts, the view and the vaults again (no network).
    func reload() {
        list = core.accounts()
        vaults = (try? core.vaults(filter: ItemFilter(accountIds: nil, vaultIds: nil, includeDevice: true))) ?? []
        if UserDefaults.standard.bool(forKey: Self.deviceOnlyKey) {
            scope = .device
        } else if let id = core.accountView(), list.contains(where: { $0.id == id }) {
            scope = .account(id)
        } else {
            scope = .all
        }
        if case .vault(let a, let v) = vaultFilter, !vaults.contains(where: { $0.accountId == a && $0.id == v }) {
            vaultFilter = .all
        }
        if let current = current {
            loggedIn = current.status == .active
        } else {
            loggedIn = false
        }
    }

    /// The current account (the one shown; in "All accounts", the first
    /// active one).
    var current: AccountInfo? { list.first(where: \.isCurrent) ?? list.first }

    /// Email of the current account.
    var user: String? { current?.email }
    /// Server of the current account.
    var server: String? { current?.serverUrl }
    var live: Bool { current.map { liveIds.contains($0.id) } ?? false }
    var syncing: Bool { !syncingIds.isEmpty }
    var syncError: String? { current.flatMap { syncErrors[$0.id] } }
    var lastSync: Date? { current?.lastSyncAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } }

    /// Signed-in accounts (the AI and server sessions work with these).
    var active: [AccountInfo] { list.filter { $0.status == .active } }

    /// The account the AI section works with: the one chosen there, the
    /// current one, or the first signed in.
    var aiAccount: AccountInfo? {
        if let chosen = account(aiAccountId), chosen.status == .active { return chosen }
        if let current, current.status == .active { return current }
        return active.first
    }

    func account(_ id: String?) -> AccountInfo? {
        guard let id else { return nil }
        return list.first { $0.id == id }
    }

    /// The accounts of the current scope.
    var scoped: [AccountInfo] {
        switch scope {
        case .all: return list
        case .account(let id): return list.filter { $0.id == id }
        case .device: return []
        }
    }

    /// Several accounts are shown together: rows get the account's avatar.
    var showsAccountBadges: Bool { scoped.count > 1 }

    /// Vaults of the accounts shown.
    var scopedVaults: [VaultInfo] {
        let ids = Set(scoped.filter(\.vaultsSupported).map(\.id))
        return vaults.filter { ids.contains($0.accountId) }
    }

    /// More than one vault is shown: vault chips and pickers appear.
    var showsVaults: Bool { scopedVaults.count > 1 }

    func vault(_ accountId: String?, _ vaultId: String?) -> VaultInfo? {
        guard let accountId, let vaultId else { return nil }
        return vaults.first { $0.accountId == accountId && $0.id == vaultId }
    }

    func vaults(of accountId: String) -> [VaultInfo] {
        vaults.filter { $0.accountId == accountId }
    }

    /// Items of the current scope (keys, snippets, identities...).
    var itemFilter: ItemFilter {
        switch scope {
        case .all: return ItemFilter(accountIds: nil, vaultIds: nil, includeDevice: true)
        case .account(let id): return ItemFilter(accountIds: [id], vaultIds: nil, includeDevice: true)
        case .device: return ItemFilter(accountIds: [], vaultIds: nil, includeDevice: true)
        }
    }

    /// Hosts of the current scope and vault chip.
    var hostFilter: ItemFilter {
        switch vaultFilter {
        case .all: return itemFilter
        case .vault(let a, let v): return ItemFilter(accountIds: [a], vaultIds: [v], includeDevice: false)
        case .device: return ItemFilter(accountIds: [], vaultIds: nil, includeDevice: true)
        }
    }

    // ----- Where new items go -----

    /// Every place where you can save an item: This device and the vaults
    /// where you are an Editor (an account of a server without vaults is
    /// one place).
    var places: [ItemPlace] {
        var out: [ItemPlace] = [.device]
        // An account waiting for its email code cannot sync yet.
        for a in list where a.status != .unverified {
            if a.vaultsSupported {
                let writable = vaults(of: a.id).filter(\.canWrite)
                out += writable.map { ItemPlace(accountId: a.id, vaultId: $0.id) }
            } else {
                out.append(ItemPlace(accountId: a.id, vaultId: nil))
            }
        }
        return out
    }

    /// "Personal", "Ops · ana@example.com", "This device"...
    func placeTitle(_ p: ItemPlace) -> String {
        guard let accountId = p.accountId else { return String(localized: "accounts.this_device") }
        let acc = account(accountId)
        let vaultName = vault(accountId, p.vaultId)?.displayName
        let accountName = acc?.email ?? "?"
        guard let vaultName else { return accountName }
        return list.count > 1 ? "\(vaultName) · \(accountName)" : vaultName
    }

    /// The place of an existing item.
    func place(accountId: String?, vaultId: String?) -> ItemPlace {
        ItemPlace(accountId: accountId, vaultId: accountId == nil ? nil : vaultId)
    }

    /// Where a new item goes: the vault chosen in the chips, otherwise the
    /// last vault used in the account shown, otherwise its personal vault
    /// (This device without accounts).
    var defaultPlace: ItemPlace {
        let all = places
        switch vaultFilter {
        case .vault(let a, let v):
            let p = ItemPlace(accountId: a, vaultId: v)
            if all.contains(p) { return p }
        case .device:
            return .device
        case .all:
            break
        }
        let acc: AccountInfo?
        switch scope {
        case .device: return .device
        case .account(let id): acc = account(id)
        case .all: acc = current
        }
        guard let acc else { return .device }
        if let last = UserDefaults.standard.string(forKey: "last_vault.\(acc.id)") {
            let p = ItemPlace(accountId: acc.id, vaultId: last)
            if all.contains(p) { return p }
        }
        let personal = vaults(of: acc.id).first { $0.kind == .personal }
        let p = ItemPlace(accountId: acc.id, vaultId: personal?.id)
        return all.contains(p) ? p : (all.first { $0.accountId == acc.id } ?? .device)
    }

    /// Remembers the vault a new item was saved to.
    func rememberPlace(_ p: ItemPlace) {
        guard let a = p.accountId, let v = p.vaultId else { return }
        UserDefaults.standard.set(v, forKey: "last_vault.\(a)")
    }

    /// The vault of an item is Strict (Use-only members connect through
    /// the server).
    func isStrict(accountId: String?, vaultId: String?) -> Bool {
        vault(accountId, vaultId)?.strict ?? false
    }

    /// Shows one account, all of them, or only This device (no network).
    func setScope(_ s: AccountScope) {
        do {
            switch s {
            case .all:
                try core.setAccountView(accountId: nil)
            case .account(let id):
                try core.setAccountView(accountId: id)
            case .device:
                break
            }
        } catch {
            post(String(localized: "common.error"), userMessage(error))
        }
        UserDefaults.standard.set(s == .device, forKey: Self.deviceOnlyKey)
        vaultFilter = .all
        reload()
        vaultChanged.send()
    }

    // ----- Quick connect -----

    /// The host to connect to for an address typed in a search or in quick
    /// connect: the saved one with that address, protocol, user and port if
    /// there is one; otherwise it is saved as a new host first (so its
    /// password, fingerprint and history have a place), like the desktop.
    func quickConnectHost(_ t: QuickTarget, among hosts: [SshHost]) throws -> SshHost {
        let existing = hosts.first { (h: SshHost) -> Bool in
            guard h.address.caseInsensitiveCompare(t.host) == .orderedSame, h.isTelnet == t.isTelnet else { return false }
            let sameUser: Bool = t.user == nil || h.settings.username == t.user
            return sameUser && h.effectivePort == t.effectivePort
        }
        if let existing { return existing }
        var host = SshHost(label: t.display, address: t.host)
        host.protocol = t.protocol
        host.settings.username = t.user
        // Telnet hosts keep their port written out (like the editor).
        host.settings.port = t.port ?? (t.isTelnet ? HostProtocol.defaultPort(t.protocol) : nil)
        if !list.isEmpty {
            let place = defaultPlace
            host.accountId = place.accountId
            host.vaultId = place.vaultId
            host.syncMode = place.accountId == nil ? .deviceOnly : .synced
        }
        let saved = try core.saveHost(host: host, password: .keep)
        vaultChanged.send()
        sync()
        return saved
    }

    // ----- Start -----

    /// On launch and when coming back to the foreground: the accounts, their
    /// events and a sync.
    func refresh() async {
        reload()
        for a in list where a.status == .active {
            await refreshApprovals(a.id)
        }
        updateEvents()
        if !active.isEmpty { await syncLocaleIfNeeded() }
        checkLayoutNotice()
    }

    /// Once after the update that moved the data to one store per account.
    private func checkLayoutNotice() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.layoutNoticeKey) else { return }
        let backup = URL(fileURLWithPath: core.dataDir()).appendingPathComponent("termoak.db.pre-accounts")
        guard FileManager.default.fileExists(atPath: backup.path) else { return }
        d.set(true, forKey: Self.layoutNoticeKey)
        let message = list.isEmpty
            ? String(localized: "accounts.layout_notice.device")
            : String(localized: "accounts.layout_notice.accounts \(list.map(\.email).joined(separator: ", "))")
        post(String(localized: "accounts.layout_notice.title"), message)
    }

    // ----- Signing in, up and out -----

    /// Signs in to a server (adds the account or signs it in again) and
    /// makes it current. Throws `TotpRequired` without a two-step code.
    func signIn(server: ServerChoice, email: String, password: String, totp: String?) async throws -> AccountInfo {
        let first = list.isEmpty
        let info = try await core.signIn(server: server, email: email, password: password, totpCode: totp)
        added(info, first: first)
        return info
    }

    /// Creates an account. With email verification it stays `unverified`
    /// until `verify`.
    func signUp(server: ServerChoice, email: String, name: String, password: String, invite: String?, acceptTerms: Bool = false) async throws -> AccountInfo {
        let first = list.isEmpty
        let info = try await core.signUp(server: server, email: email, name: name, password: password, invite: invite, acceptTerms: acceptTerms)
        added(info, first: first)
        return info
    }

    /// The six-digit code from the verification email.
    func verify(_ accountId: String, code: String, totp: String?) async throws -> AccountInfo {
        let info = try await core.verifyAccount(accountId: accountId, code: code, totpCode: totp)
        added(info, first: offerUploadTo == accountId)
        return info
    }

    func resendCode(_ accountId: String) async throws {
        try await core.resendAccountCode(accountId: accountId)
    }

    private func added(_ info: AccountInfo, first: Bool) {
        if first { offerUploadTo = info.id }
        UserDefaults.standard.set(false, forKey: Self.deviceOnlyKey)
        reload()
        accountsChanged.send()
        vaultChanged.send()
        if info.status == .active {
            updateEvents()
            sync(info.id)
            Task { await syncLocaleIfNeeded() }
        }
    }

    /// Changes not uploaded yet of an account.
    func unsynced(_ accountId: String) -> UInt64 {
        (try? core.unsyncedChanges(accountId: accountId).total) ?? 0
    }

    /// Signs out of an account and deletes its data on this device. With
    /// unsynced changes and `discard == false` nothing happens
    /// (`signedOut == false`).
    func signOut(_ accountId: String, discard: Bool) async throws -> SignOutReport {
        stopEvents(accountId)
        let report = try await core.signOutAccount(accountId: accountId, discardUnsynced: discard)
        if report.signedOut {
            approvals[accountId] = nil
            syncErrors[accountId] = nil
            if offerUploadTo == accountId { offerUploadTo = nil }
            pendingApprovals = approvals.values.reduce(0, +)
        }
        reload()
        updateEvents()
        accountsChanged.send()
        vaultChanged.send()
        return report
    }

    // ----- Sync -----

    /// Syncs every signed-in account.
    func sync() {
        for a in list where a.status == .active { sync(a.id) }
    }

    /// One sync round of an account. Its report may bring notices (vaults
    /// shared with you or lost, changes discarded).
    func sync(_ accountId: String) {
        guard !syncingIds.contains(accountId),
              let info = account(accountId), info.status == .active,
              let handle = try? core.account(accountId: accountId) else { return }
        syncingIds.insert(accountId)
        Task {
            defer { syncingIds.remove(accountId) }
            do {
                let report = try await handle.syncNow()
                syncErrors[accountId] = nil
                reload()
                vaultChanged.send()
                announce(report, of: info)
                if offerUploadTo == accountId {
                    offerUploadTo = nil
                    if deviceItemCount() > 0 { uploadOffer = UploadOffer(accountId: accountId) }
                }
            } catch TermoakError.NotLoggedIn, TermoakError.SessionExpired {
                syncErrors[accountId] = String(localized: "account.session_expired")
                stopEvents(accountId)
                reload()
                accountsChanged.send()
            } catch TermoakError.EmailNotVerified {
                reload()
                accountsChanged.send()
                askForCode(accountId)
            } catch {
                syncErrors[accountId] = userMessage(error)
                reload()
            }
        }
    }

    private func announce(_ r: SyncReport, of info: AccountInfo) {
        var lines: [String] = []
        if !r.vaultsAdded.isEmpty {
            lines.append(String(localized: "accounts.sync.vaults_added \(r.vaultsAdded.map(\.name).joined(separator: ", "))"))
        }
        if !r.vaultsLost.isEmpty {
            lines.append(String(localized: "accounts.sync.vaults_lost \(r.vaultsLost.map(\.name).joined(separator: ", "))"))
        }
        for d in r.discarded where d.count > 0 {
            lines.append(String(localized: "accounts.sync.discarded \(Int(d.count)) \(d.vaultName)"))
        }
        guard !lines.isEmpty else { return }
        let title = list.count > 1 ? info.email : String(localized: "accounts.sync.title")
        post(title, lines.joined(separator: "\n"))
    }

    /// Items saved only on this device (to offer uploading them).
    func deviceItemCount() -> Int {
        let f = ItemFilter(accountIds: [], vaultIds: nil, includeDevice: true)
        var n = 0
        n += (try? core.listHosts(filter: f).count) ?? 0
        n += (try? core.listGroups(filter: f).count) ?? 0
        n += (try? core.listKeys(filter: f).count) ?? 0
        n += (try? core.listIdentities(filter: f).count) ?? 0
        n += (try? core.listSnippets(filter: f).count) ?? 0
        n += (try? core.listForwards(hostId: nil, filter: f).count) ?? 0
        return n
    }

    /// Opens the code step of the current account when its server asks for
    /// the email code (like Android), once per launch.
    private func askForCode(_ accountId: String) {
        guard let info = account(accountId), info.isCurrent || list.count == 1,
              verifyPrompt == nil, verifyPrompted.insert(accountId).inserted else { return }
        verifyPrompt = VerifyPrompt(account: info)
    }

    // ----- Notices -----

    func post(_ title: String, _ message: String) {
        let n = AppNotice(title: title, message: message)
        if notice == nil { notice = n } else { queued.append(n) }
    }

    /// The notice on screen was closed: the next one, if any.
    func noticeDismissed() {
        notice = nil
        guard !queued.isEmpty else { return }
        let next = queued.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.notice = next }
    }

    // ----- AI approvals -----

    func refreshApprovals() async {
        for a in list where a.status == .active { await refreshApprovals(a.id) }
    }

    private func refreshApprovals(_ accountId: String) async {
        guard let handle = try? core.account(accountId: accountId) else { return }
        approvals[accountId] = (try? await handle.listPendingApprovals().count) ?? approvals[accountId] ?? 0
        pendingApprovals = approvals.values.reduce(0, +)
    }

    // ----- Account language -----

    /// Language the app is shown in (`en`, `es`...).
    static var appLanguage: String {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return language == "Base" ? "en" : language
    }

    /// Saves the app language in every signed-in account (each through its
    /// own `AccountHandle`) so their servers write the emails in it, like
    /// Android. Only where it differs.
    func syncLocaleIfNeeded() async {
        let language = Self.appLanguage
        for a in active {
            guard let handle = try? core.account(accountId: a.id) else { continue }
            if let user = try? await handle.currentUser(), user.locale.lowercased() == language.lowercased() { continue }
            _ = try? await handle.setLocale(locale: language)
        }
    }

    // ----- Live events -----

    // TODO(push): the iOS app has no APNs plumbing yet (no `aps-environment`
    // entitlement, no app delegate asking for a device token), so join and
    // control requests only reach the owner through these WebSockets while
    // the app is open. When it is added: register the token with every
    // account's server and route a tap by its `user_id` and `server`.

    /// One events WebSocket per signed-in account.
    private func updateEvents() {
        let active = Set(list.filter { $0.status == .active }.map(\.id))
        for id in events.keys where !active.contains(id) { stopEvents(id) }
        for id in active where events[id] == nil { startEvents(id) }
    }

    private func startEvents(_ accountId: String) {
        let task = Task { [weak self] in
            var delay: UInt64 = 2
            while !Task.isCancelled {
                guard let self, let handle = try? self.core.account(accountId: accountId) else { return }
                let listener = EventListener()
                // On the main queue, in order: the AI text chunks have to
                // arrive exactly as they come out.
                listener.onReceive = { [weak self] json in DispatchQueue.main.async { self?.receive(json, from: accountId) } }
                do {
                    let sub = try await handle.subscribeEvents(listener: listener)
                    if Task.isCancelled {
                        sub.unsubscribe()
                        return
                    }
                    self.events[accountId]?.subscription = sub
                    self.liveIds.insert(accountId)
                    delay = 2
                    await listener.waitUntilClosed()
                } catch TermoakError.NotLoggedIn, TermoakError.SessionExpired {
                    self.liveIds.remove(accountId)
                    return
                } catch {
                    // Retried below.
                }
                self.liveIds.remove(accountId)
                self.events[accountId]?.subscription?.unsubscribe()
                self.events[accountId]?.subscription = nil
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 60)
            }
        }
        events[accountId] = (task, nil)
    }

    private func stopEvents(_ accountId: String) {
        guard let e = events.removeValue(forKey: accountId) else { return }
        e.task.cancel()
        e.subscription?.unsubscribe()
        liveIds.remove(accountId)
    }

    private func receive(_ json: String, from accountId: String) {
        guard let data = json.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        switch type {
        case "hello":
            if let n = event["pending_approvals"] as? Int {
                approvals[accountId] = n
                pendingApprovals = approvals.values.reduce(0, +)
            }
        case "ai", "lagged":
            if type == "ai", let task = event["task_id"] as? String, let ev = event["event"] as? [String: Any] {
                aiEvents.send(AiEvent(taskId: task, event: ev))
            }
            Task { await refreshApprovals(accountId) }
            if type == "lagged" { sync(accountId) }
            changes.send(type)
        case "session":
            if let notice = event["notice"] as? [String: Any], let n = ShareNotice(notice) {
                sessionNotices.send(n)
            }
            changes.send(type)
        case "vault":
            // A vault changed, was shared with you or taken away: sync to
            // see it (and to get the notice).
            sync(accountId)
        default:
            break
        }
    }
}

/// The email-code step to open for an account (`LoginView(resume:)`).
struct VerifyPrompt: Identifiable, Equatable {
    let account: AccountInfo
    var id: String { account.id }
}

/// An event of an AI task (`{"type":"ai","task_id":…,"event":{…}}`).
struct AiEvent {
    let taskId: String
    /// `type` (`text`, `tool_call`, `status`...) and its fields.
    let event: [String: Any]
}

/// Receives the server events (background thread).
private final class EventListener: ServerEventListener, @unchecked Sendable {
    var onReceive: (String) -> Void = { _ in }
    private var continuation: CheckedContinuation<Void, Never>?
    private var closed = false
    private let lock = NSLock()

    func onEvent(eventJson: String) {
        onReceive(eventJson)
    }

    func onClosed(reason: String?) {
        lock.lock()
        closed = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }

    func waitUntilClosed() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if closed {
                lock.unlock()
                c.resume()
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }
}
