import Foundation

// Home-screen Quick Actions (touch and hold the app's icon): Quick connect,
// Join with a link and up to three hosts (favourites, then the ones opened
// last). The identifiers and the list of recent hosts, without UIKit, so the
// unit tests compile this file on its own.

enum QuickAction: Equatable {
    case quickConnect
    case join
    /// `accountId`: `nil` for a This-device host.
    case host(id: String, accountId: String?)

    static let quickConnectType = "com.termoak.quick-connect"
    static let joinType = "com.termoak.join"
    static let hostType = "com.termoak.host"

    /// `UIApplicationShortcutItem.type`.
    var type: String {
        switch self {
        case .quickConnect: return Self.quickConnectType
        case .join: return Self.joinType
        case .host: return Self.hostType
        }
    }

    /// `UIApplicationShortcutItem.userInfo` (property-list values only).
    var userInfo: [String: String] {
        guard case .host(let id, let accountId) = self else { return [:] }
        var info = ["host": id]
        if let accountId { info["account"] = accountId }
        return info
    }

    init?(type: String, userInfo: [String: Any]?) {
        switch type {
        case Self.quickConnectType: self = .quickConnect
        case Self.joinType: self = .join
        case Self.hostType:
            guard let id = userInfo?["host"] as? String, !id.isEmpty else { return nil }
            self = .host(id: id, accountId: userInfo?["account"] as? String)
        default: return nil
        }
    }
}

/// The hosts opened last (most recent first), as `itemKey`s
/// (`account/id`, `device/id`), to offer them as Quick Actions.
struct RecentHosts: Equatable {
    static let limit = 10
    private(set) var keys: [String]

    init(keys: [String] = []) {
        self.keys = Array(keys.prefix(Self.limit))
    }

    mutating func record(_ key: String) {
        keys.removeAll { $0 == key }
        keys.insert(key, at: 0)
        if keys.count > Self.limit { keys.removeLast(keys.count - Self.limit) }
    }

    /// Up to `count` hosts for the Quick Actions: the favourites first (in
    /// the order given), then the ones opened last; `available` are the
    /// hosts that exist (`itemKey`s).
    func pick(favorites: [String], available: Set<String>, count: Int = 3) -> [String] {
        var out: [String] = []
        for k in favorites + keys where available.contains(k) && !out.contains(k) {
            out.append(k)
            if out.count == count { break }
        }
        return out
    }
}
