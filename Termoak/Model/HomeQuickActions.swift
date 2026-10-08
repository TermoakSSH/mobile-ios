import TermoakKit
import SwiftUI
import UIKit

/// What arrives from the system outside SwiftUI: the Quick Action chosen on
/// the app's icon (at launch or later) and, as a fallback, the links the
/// scene delegate receives (the app opens each link once).
@MainActor
final class SystemRouter: ObservableObject {
    static let shared = SystemRouter()

    @Published var action: QuickAction?
    @Published var url: URL?

    func receive(_ item: UIApplicationShortcutItem) {
        action = QuickAction(type: item.type, userInfo: item.userInfo.map { $0 as [String: Any] })
    }
}

/// The app's delegate (SwiftUI adaptor): it gives the window scene our
/// delegate, which receives the Quick Actions (a Quick Action that launched
/// the app comes with the scene's connection options), and receives the
/// push device token.
final class TermoakAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem {
            Task { @MainActor in SystemRouter.shared.receive(item) }
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = TermoakSceneDelegate.self
        return configuration
    }

    // Push (only asked for when it is on in the build: Push.enabled).
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in Push.shared.received(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}
}

/// The window scene's delegate. SwiftUI still makes the window; this only
/// hears the Quick Actions chosen while the app runs, and passes on the
/// links too in case they don't reach SwiftUI's `onOpenURL` with our
/// delegate in place (the app opens each link once).
final class TermoakSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            SystemRouter.shared.receive(shortcutItem)
            completionHandler(true)
        }
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        let url = connectionOptions.urlContexts.first?.url
            ?? connectionOptions.userActivities.first(where: { $0.activityType == NSUserActivityTypeBrowsingWeb })?.webpageURL
        if let url { Task { @MainActor in SystemRouter.shared.url = url } }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        Task { @MainActor in SystemRouter.shared.url = url }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL else { return }
        Task { @MainActor in SystemRouter.shared.url = url }
    }
}

/// The hosts opened last, kept on this device for the Quick Actions.
@MainActor
enum RecentHostsStore {
    private static let key = "recent_hosts"

    static var current: RecentHosts {
        RecentHosts(keys: UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func record(_ host: SshHost) {
        var r = current
        r.record(host.key)
        UserDefaults.standard.set(r.keys, forKey: key)
    }

    /// The Quick Actions of the app's icon: Quick connect, Join with a link
    /// and up to three hosts (favourites first, then the ones opened last).
    static func updateShortcutItems(core: TermoakCore) {
        let everything = ItemFilter(accountIds: nil, vaultIds: nil, includeDevice: true)
        let hosts = (try? core.listHosts(filter: everything)) ?? []
        let byKey = Dictionary(hosts.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let favorites = hosts.filter(\.favorite)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map(\.key)
        let picked = current.pick(favorites: favorites, available: Set(byKey.keys)).compactMap { byKey[$0] }
        var items = [
            item(.quickConnect, title: String(localized: "quick_connect.title"), symbol: "bolt.horizontal"),
            item(.join, title: String(localized: "connections.join_link"), symbol: "link"),
        ]
        items += picked.map { h in
            item(.host(id: h.id, accountId: h.accountId), title: h.displayName,
                 subtitle: (h.settings.username.map { "\($0)@" } ?? "") + h.address,
                 symbol: h.favorite ? "star" : "terminal")
        }
        UIApplication.shared.shortcutItems = items
    }

    private static func item(_ action: QuickAction, title: String, subtitle: String? = nil, symbol: String) -> UIApplicationShortcutItem {
        UIApplicationShortcutItem(type: action.type, localizedTitle: title, localizedSubtitle: subtitle,
                                  icon: UIApplicationShortcutIcon(systemImageName: symbol),
                                  userInfo: action.userInfo.mapValues { $0 as NSString })
    }
}
