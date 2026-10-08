import Foundation
import UserNotifications

/// Sharing notices while the app is in the background (the few seconds iOS
/// keeps it running after leaving it): someone wants to join or asks for the
/// keyboard of a session you share, or shares a session with you. They
/// become local notifications (like Android's "sharing" channel); tapping
/// one opens that session. Push with the app closed: PushNotifications.swift
/// (its taps arrive here too).
@MainActor
final class BackgroundNotices: NSObject {
    static let shared = BackgroundNotices()

    enum Kind: String {
        case join, control, shared
    }

    /// The app is in the background (set from the scene phase).
    var inBackground = false
    /// A notification was tapped: open that session (`owner`: one of yours).
    var onOpen: ((_ sessionId: String, _ title: String, _ owner: Bool) -> Void)?
    /// A push notification was tapped (PushNotifications.swift).
    var onPush: ((PushTarget) -> Void)?

    private var recent = NoticeDeduper(window: 15)
    private var asked = UserDefaults.standard.bool(forKey: "notifications_asked")

    /// Asks once for permission to notify (when you start sharing).
    func requestPermission() {
        guard !asked else { return }
        asked = true
        UserDefaults.standard.set(true, forKey: "notifications_asked")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Becomes the notification center's delegate (taps on our notifications).
    func start() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// A request or a share: a notification if the app is in the background
    /// (the same one from the terminal and from the server's events only once).
    func notify(_ kind: Kind, sessionId: String, title: String, name: String, participantId: String?) {
        guard recent.isNew("\(kind.rawValue):\(sessionId):\(participantId ?? name)", at: Date()) else { return }
        guard inBackground else { return }
        let session = title.isEmpty ? String(localized: "common.session") : title
        let who = name.isEmpty ? String(localized: "share.someone") : name
        let content = UNMutableNotificationContent()
        switch kind {
        case .join:
            content.title = String(localized: "share.notice.join_title")
            content.body = String(localized: "share.toast.join \(who) \(session)")
        case .control:
            content.title = String(localized: "share.notice.control_title")
            content.body = String(localized: "share.toast.control \(who) \(session)")
        case .shared:
            content.title = String(localized: "share.notice.shared_title")
            content.body = String(localized: "share.toast.shared \(who) \(session)")
        }
        content.sound = .default
        content.threadIdentifier = "sharing"
        content.userInfo = ["session_id": sessionId, "title": title, "owner": kind != .shared]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension BackgroundNotices: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let push = PushTarget(info) {
            Task { @MainActor in
                BackgroundNotices.shared.onPush?(push)
                completionHandler()
            }
            return
        }
        let sessionId = info["session_id"] as? String
        let title = info["title"] as? String ?? ""
        let owner = info["owner"] as? Bool ?? true
        Task { @MainActor in
            if let sessionId { BackgroundNotices.shared.onOpen?(sessionId, title, owner) }
            completionHandler()
        }
    }

    /// In the foreground the app shows its own toasts.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}
