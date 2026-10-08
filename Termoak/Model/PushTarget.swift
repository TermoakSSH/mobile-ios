import Foundation

/// What a tapped push notification is about (`userInfo["termoak"]`).
struct PushTarget: Equatable {
    /// `ai_approval`, `ai_done`, `session_shared`, `join_request`, `control_request`...
    let type: String
    let taskId: String?
    let sessionId: String?
    let title: String

    init?(_ userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo["termoak"] as? [String: Any] else { return nil }
        let data = raw.compactMapValues { $0 as? String }
        guard let type = data["type"] else { return nil }
        self.type = type
        taskId = data["task_id"]
        sessionId = data["session_id"]
        title = data["title"] ?? ""
    }

    var isAi: Bool { type.hasPrefix("ai") }
    /// A request of one of your sessions (you are its owner).
    var isOwnSession: Bool { type == "join_request" || type == "control_request" }
}
