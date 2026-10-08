import TermoakKit
import UIKit
import UserNotifications

/// Push notifications (APNs) with the app closed: AI approvals, sessions
/// shared with you, join and keyboard requests of your sessions. The system
/// token is registered on EVERY signed-in account (each server notifies its
/// own events), on a new sign-in too, and unregistered from an account
/// before signing out of it.
///
/// Off until the build can receive them: it needs the `aps-environment`
/// entitlement and the servers' APNs credentials (see the README). The
/// Info.plist key `TermoakPush` (YES) turns it on; without it nothing asks
/// for permission nor registers anything.
@MainActor
final class Push {
    static let shared = Push()

    /// Push is wired in this build (`TermoakPush` in Info.plist).
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

    /// The system's device token (hex) once APNs gave it.
    private(set) var token: String?
    private var core: TermoakCore?
    private var accounts: () -> [String] = { [] }

    /// At launch: asks for permission (once, the system remembers) and for
    /// the device token. `accounts`: the signed-in accounts' ids.
    func start(core: TermoakCore, accounts: @escaping () -> [String]) {
        guard Self.enabled else { return }
        self.core = core
        self.accounts = accounts
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// The app delegate got the token: on every signed-in account.
    func received(deviceToken: Data) {
        guard Self.enabled else { return }
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        for id in accounts() { register(id) }
    }

    /// One account (just signed in, or all of them when the token arrives).
    func register(_ accountId: String) {
        guard Self.enabled, let token, let core else { return }
        let sandbox = Self.sandbox
        Task {
            _ = try? await core.account(accountId: accountId)
                .registerPushToken(platform: .apns, token: token, sandbox: sandbox)
        }
    }

    /// Before signing out of an account: its server stops notifying this device.
    func unregister(_ accountId: String) async {
        guard Self.enabled, token != nil, let core, let handle = try? core.account(accountId: accountId) else { return }
        try? await handle.unregisterPushToken()
    }
}
