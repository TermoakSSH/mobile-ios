import TermoakKit
import UIKit
import UserNotifications

/// Push notifications (APNs) with the app closed (0.7, docs-next/PUSH.md):
/// AI approvals, join and keyboard requests, security key requests,
/// sessions shared with you, finished tasks, new teams.
///
/// Each account's server says whether it can send APNs (`pushStatus()
/// .serverApns`). Only then does the app ask for permission and register the
/// system token on that account; with no such server (today: the APNs key is
/// not configured yet) nothing is asked and nothing registered. The token is
/// unregistered from an account before signing out of it.
///
/// Approve / Deny on a notification only open the app's confirmation; the
/// app lock applies. A `resolved` push (background, `content-available`)
/// removes the delivered notification with that tag. A security key request
/// only brings the app forward: the vault opens and the events socket
/// answers the waiting request, never from the background.
@MainActor
final class Push: ObservableObject {
    static let shared = Push()

    /// Push is wired in this build (`TermoakPush` in Info.plist; it needs
    /// the `aps-environment` entitlement).
    static var enabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "TermoakPush") as? Bool ?? false
    }

    /// Development builds get the APNs sandbox's tokens.
    static var sandbox: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Each signed-in account's notifications (nil: not read yet; a server
    /// before 0.7 has no `/push` and stays out).
    @Published private(set) var statuses: [String: PushStatus] = [:]
    /// Accounts whose server could not tell (older than 0.7, offline...).
    @Published private(set) var unknown: Set<String> = []
    /// The system's permission.
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// The system's device token (hex) once APNs gave it.
    private(set) var token: String?
    private var core: TermoakCore?
    private var accounts: () -> [String] = { [] }

    /// At launch: the categories, then each account's status (permission
    /// and token only where a server can send APNs).
    func start(core: TermoakCore, accounts: @escaping () -> [String]) {
        guard Self.enabled else { return }
        self.core = core
        self.accounts = accounts
        Self.registerCategories()
        Task { await refresh() }
    }

    /// Reads every signed-in account's status again (Settings, launch).
    func refresh() async {
        guard Self.enabled, let core else { return }
        let ids = accounts()
        for id in statuses.keys where !ids.contains(id) { statuses[id] = nil }
        for id in ids {
            guard let handle = try? core.account(accountId: id) else { continue }
            if let st = try? await handle.pushStatus() {
                statuses[id] = st
                unknown.remove(id)
            } else {
                statuses[id] = nil
                unknown.insert(id)
            }
        }
        await updateAuthorization()
        await askIfUseful()
    }

    /// Permission and the token, once some server can send APNs.
    private func askIfUseful() async {
        guard PushRegistration.shouldAskPermission(statuses.mapValues(\.serverApns)) else { return }
        let center = UNUserNotificationCenter.current()
        if authorization == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            await updateAuthorization()
        }
        if authorization == .authorized || authorization == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    private func updateAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// The app delegate got the token: on the accounts whose server can use it.
    func received(deviceToken: Data) {
        guard Self.enabled else { return }
        token = PushRegistration.hex(deviceToken)
        for id in PushRegistration.accounts(statuses.mapValues(\.serverApns)) { register(id) }
    }

    /// One account (just signed in, or every account when the token arrives).
    func register(_ accountId: String) {
        guard Self.enabled, let core else { return }
        let sandbox = Self.sandbox
        Task {
            guard let handle = try? core.account(accountId: accountId) else { return }
            if statuses[accountId] == nil {
                guard let st = try? await handle.pushStatus() else { unknown.insert(accountId); return }
                statuses[accountId] = st
            }
            guard statuses[accountId]?.serverApns == true else { return }
            guard let token else { await askIfUseful(); return }
            if (try? await handle.registerPushToken(platform: .apns, token: token, sandbox: sandbox)) != nil,
               let st = try? await handle.pushStatus() {
                statuses[accountId] = st
            }
        }
    }

    /// Before signing out of an account: its server stops notifying this device.
    func unregister(_ accountId: String) async {
        guard Self.enabled, let core else { return }
        defer { statuses[accountId] = nil }
        guard statuses[accountId]?.registered == true, let handle = try? core.account(accountId: accountId) else { return }
        try? await handle.unregisterPushToken()
    }

    /// Which notifications this device gets from an account's server.
    func setPreferences(_ accountId: String, _ prefs: PushPreferences) async throws {
        guard let core else { return }
        let saved = try await core.account(accountId: accountId).setPushPreferences(preferences: prefs)
        statuses[accountId]?.preferences = saved
    }

    func sendTest(_ accountId: String) async throws {
        guard let core else { return }
        try await core.account(accountId: accountId).sendTestPush()
    }

    // ----- Received notifications -----

    /// A notification's payload: the engine's reading, else the app's own.
    nonisolated static func info(_ userInfo: [AnyHashable: Any]) -> PushInfo? {
        if let ev = event(userInfo) {
            return PushInfo(kind: ev.kind, category: category(ev.category), tag: ev.tag, data: ev.data,
                            title: ev.title, expired: ev.expired)
        }
        return PushInfo(userInfo: userInfo)
    }

    private nonisolated static func event(_ userInfo: [AnyHashable: Any]) -> PushEvent? {
        var plain: [String: Any] = [:]
        for (k, v) in userInfo { if let k = k as? String { plain[k] = v } }
        guard plain["termoak"] != nil, JSONSerialization.isValidJSONObject(plain),
              let data = try? JSONSerialization.data(withJSONObject: plain),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return try? parsePushPayload(text: text)
    }

    private nonisolated static func category(_ c: PushCategory) -> PushInfo.Category {
        switch c {
        case .approval: return .approval
        case .securityKey: return .securityKey
        case .info: return .info
        case .resolved: return .resolved
        }
    }

    /// A background push (`content-available`): a `resolved` one removes the
    /// notification it withdraws. Nothing else runs in the background.
    nonisolated static func receivedInBackground(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let info = info(userInfo), case .remove(let tag) = PushRoute.of(info, action: nil) else { return false }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [tag])
        return true
    }

    /// Approve / Deny (approvals) and Open (security keys). Every action
    /// brings the app forward and asks to unlock the device; none decides.
    static func registerCategories() {
        let options: UNNotificationActionOptions = [.foreground, .authenticationRequired]
        let approve = UNNotificationAction(identifier: PushActionId.approve,
                                           title: String(localized: "push.action.approve"), options: options)
        let deny = UNNotificationAction(identifier: PushActionId.deny,
                                        title: String(localized: "push.action.deny"), options: options)
        let open = UNNotificationAction(identifier: PushActionId.open,
                                        title: String(localized: "push.action.open"), options: options)
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: PushCategoryId.approval, actions: [approve, deny],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: PushCategoryId.securityKey, actions: [open],
                                   intentIdentifiers: [], options: []),
        ])
    }
}
