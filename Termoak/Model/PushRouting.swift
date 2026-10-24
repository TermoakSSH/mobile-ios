import Foundation

// Push notifications (0.7, docs-next/PUSH.md): what a received or tapped
// notification means, without the engine's types so the unit tests compile
// it alone. The app reads a payload with the engine's `parsePushPayload`
// (PushNotifications.swift) and falls back to `PushInfo(userInfo:)`.

/// A notification of the server, as the app needs it.
struct PushInfo: Equatable {
    enum Category: String, Equatable {
        /// Approve / Deny: both only open the app's own confirmation.
        case approval
        /// A server connection waits for a security key: open the app (the
        /// events socket gets the waiting request).
        case securityKey = "security_key"
        case info
        /// Remove the delivered notification with `tag`.
        case resolved
    }

    /// `ai_approval`, `ai_finished`, `session_shared`, `session_prompt`,
    /// `join_request`, `control_request`, `team_added`,
    /// `security_key_request`, `access_request`, `test`, `resolved`.
    var kind: String
    var category: Category
    /// The collapse key (APNs `apns-collapse-id`: the notification's
    /// identifier), else `<kind>-<sent_at>`.
    var tag: String
    /// The ids (`task_id`, `approval_id`, `session_id`, `participant`, `request_id`...).
    var data: [String: String]
    var title: String
    var expired: Bool

    /// Kinds that ask for a decision (also from servers that do not send `category`).
    static let approvalKinds: Set<String> = ["ai_approval", "join_request", "control_request", "access_request"]

    init(kind: String, category: Category, tag: String, data: [String: String] = [:], title: String = "", expired: Bool = false) {
        self.kind = kind
        self.category = category
        self.tag = tag
        self.data = data
        self.title = title
        self.expired = expired
    }

    /// From an APNs `userInfo`: the `termoak` dictionary of flat strings
    /// (the ids at the top level, as every server version sends them).
    init?(userInfo: [AnyHashable: Any], now: Date = Date()) {
        guard let raw = userInfo["termoak"] as? [String: Any] else { return nil }
        var flat: [String: String] = [:]
        for (k, v) in raw {
            if let s = v as? String { flat[k] = s } else if let n = v as? NSNumber { flat[k] = n.stringValue }
        }
        guard let kind = flat["type"], !kind.isEmpty else { return nil }
        let known: Set<String> = ["v", "type", "title", "body", "collapse", "server", "user", "sent_at", "expires_at", "category"]
        let category = flat["category"].flatMap(Category.init(rawValue:)) ?? Self.category(of: kind)
        let expiresAt = flat["expires_at"].flatMap(Int64.init)
        self.init(kind: kind,
                  category: category,
                  tag: flat["collapse"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(kind)-\(flat["sent_at"] ?? "0")",
                  data: flat.filter { !known.contains($0.key) },
                  title: flat["title"] ?? "",
                  expired: expiresAt.map { $0 <= Int64(now.timeIntervalSince1970 * 1000) } ?? false)
    }

    static func category(of kind: String) -> Category {
        if kind == "resolved" { return .resolved }
        if kind == "security_key_request" { return .securityKey }
        return approvalKinds.contains(kind) ? .approval : .info
    }
}

/// The notification categories and actions registered with the system
/// (the server sets `aps.category`).
enum PushCategoryId {
    static let approval = "TERMOAK_APPROVAL"
    static let securityKey = "TERMOAK_SECURITY_KEY"
}

enum PushActionId {
    static let approve = "TERMOAK_APPROVE"
    static let deny = "TERMOAK_DENY"
    static let open = "TERMOAK_OPEN"
    /// UNNotificationDismissActionIdentifier.
    static let dismiss = "com.apple.UNNotificationDismissActionIdentifier"
}

/// Where a tapped notification (or one of its actions) takes the app.
enum PushRoute: Equatable {
    case none
    /// Withdraw the delivered notification with this identifier.
    case remove(tag: String)
    /// The AI section (its tasks and pending approvals).
    case ai(taskId: String?)
    /// That server session (`owner`: one of yours, with its requests).
    case session(id: String, title: String, owner: Bool)
    case teams
    /// Just the app in front: the vault opens (app lock first) and the
    /// events socket answers the waiting request.
    case securityKey(requestId: String?)
    /// The app in front (test, access requests until phase 4b has a screen).
    case app

    /// Approve and Deny never decide: they open the same confirmation a tap
    /// opens (after the device and the app lock are unlocked).
    static func of(_ info: PushInfo, action: String?) -> PushRoute {
        if info.category == .resolved || info.kind == "resolved" { return .remove(tag: info.tag) }
        if action == PushActionId.dismiss { return .none }
        switch info.kind {
        case "ai_approval", "ai_finished":
            return .ai(taskId: info.data["task_id"])
        case "join_request", "control_request", "session_prompt":
            guard let id = info.data["session_id"] else { return .app }
            return .session(id: id, title: info.data["title"] ?? "", owner: true)
        case "session_shared":
            guard let id = info.data["session_id"] else { return .app }
            return .session(id: id, title: info.data["title"] ?? "", owner: false)
        case "team_added":
            return .teams
        case "security_key_request":
            return .securityKey(requestId: info.data["request_id"])
        default:
            return .app
        }
    }
}

/// Registration rules: only accounts whose server can send APNs get the
/// token, and permission is only asked when at least one can (a server
/// without APNs configured leaves the app inert: nothing asked, nothing
/// registered).
enum PushRegistration {
    /// The accounts to register the token on (`serverApns` per account id).
    static func accounts(_ serverApns: [String: Bool]) -> [String] {
        serverApns.filter(\.value).map(\.key).sorted()
    }

    static func shouldAskPermission(_ serverApns: [String: Bool]) -> Bool {
        serverApns.values.contains(true)
    }

    /// The device token as APNs wants it (hex).
    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}
