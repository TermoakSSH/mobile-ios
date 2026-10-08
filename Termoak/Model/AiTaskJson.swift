import Foundation

// AI tasks of server 0.6 through the generic API (the typed calls are C3):
// the new-task body with a plan first, a group or tag and one conversation
// per host; the providers and their models; what a task's JSON says about
// its hosts, plan and parent; the runbook. Without the engine's types, so
// the unit tests compile this file on its own.

/// What a new task asks for (`POST /api/v1/ai/tasks`).
struct NewAiTask: Equatable {
    var prompt: String
    /// `read_only`, `ask`, `confirm` or `auto`.
    var mode: String
    /// `provider` or `provider::model` (`nil`: the server's default).
    var provider: String?
    /// `low`, `medium` or `high` (`nil`: the provider's default).
    var effort: String?
    var hostIds: [String] = []
    /// Every host of this group (and its subgroups).
    var groupId: String?
    /// Every host with this tag.
    var tag: String?
    /// One conversation per host, with the per-host table.
    var fanOut = false
    /// A numbered plan to approve or edit before acting.
    var planFirst = false

    var body: [String: Any] {
        var b: [String: Any] = ["prompt": prompt.trimmingCharacters(in: .whitespacesAndNewlines), "mode": mode]
        if let provider, !provider.isEmpty { b["provider"] = provider }
        if let effort, !effort.isEmpty { b["effort"] = effort }
        if !hostIds.isEmpty { b["host_ids"] = hostIds }
        if let groupId { b["group_id"] = groupId }
        if let tag = tag?.trimmingCharacters(in: .whitespaces), !tag.isEmpty { b["tag"] = tag }
        if fanOut { b["fan_out"] = true }
        if planFirst { b["plan_first"] = true }
        return b
    }

    /// `provider::model`, or the provider alone with its default model.
    static func provider(_ key: String?, model: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        guard let model, !model.isEmpty else { return key }
        return "\(key)::\(model)"
    }
}

/// An AI provider of the server (`GET /api/v1/ai/providers`).
struct AiProviderInfo: Equatable, Identifiable {
    var key: String
    var label: String
    var available: Bool
    var hidden: Bool
    var defaultModel: String?
    var models: [String]
    /// Why it can't be used (when not available).
    var reason: String?
    var id: String { key }
}

struct AiProviderList: Equatable {
    /// The default provider's key.
    var defaultKey: String?
    var providers: [AiProviderInfo]

    /// The ones to offer: not hidden.
    var shown: [AiProviderInfo] { providers.filter { !$0.hidden } }
    var defaultProvider: AiProviderInfo? { providers.first { $0.key == defaultKey } }

    static func parse(_ json: String) -> AiProviderList {
        let v = AiJson.object(json)
        let rows = v["providers"] as? [[String: Any]] ?? []
        return AiProviderList(
            defaultKey: v["default"] as? String,
            providers: rows.compactMap { r in
                guard let key = r["key"] as? String else { return nil }
                return AiProviderInfo(key: key, label: r["label"] as? String ?? key, available: r["available"] as? Bool ?? true,
                                      hidden: r["hidden"] as? Bool ?? false, defaultModel: r["default_model"] as? String,
                                      models: r["models"] as? [String] ?? [], reason: r["reason"] as? String)
            })
    }
}

/// One host of a multi-host task (its own conversation).
struct AiHostRun: Equatable, Identifiable {
    var hostId: String
    var label: String
    /// The host's own task.
    var taskId: String
    /// `queued`, `running`, `waiting_approval`, `completed`, `failed`, `cancelled`.
    var status: String
    var summary: String?
    var error: String?
    var durationMs: Int64?
    var costMicros: Int64
    var pendingApprovals: Int
    var id: String { taskId }
}

/// What a task's JSON says beyond the typed `AiTask`.
struct AiTaskExtras: Equatable {
    /// `read_only`, `ask`, `confirm` or `auto`.
    var mode: String?
    /// The multi-host task this host's conversation belongs to.
    var parentId: String?
    var fanOut = false
    var hosts: [AiHostRun] = []
    var groupId: String?
    var tag: String?
    var planFirst = false
    /// The approved (or pending) plan.
    var plan: String?
    var planApproved = false
    /// Commands and file writes it ran.
    var steps = 0

    static func parse(_ json: String) -> AiTaskExtras {
        let v = AiJson.object(json)
        var e = AiTaskExtras()
        e.mode = v["mode"] as? String
        e.parentId = v["parent_id"] as? String
        e.fanOut = v["fan_out"] as? Bool ?? false
        e.groupId = v["group_id"] as? String
        e.tag = v["tag"] as? String
        e.planFirst = v["plan_first"] as? Bool ?? false
        if let plan = v["plan"] as? [String: Any] {
            e.plan = plan["text"] as? String
            e.planApproved = plan["approved"] as? Bool ?? false
        }
        e.steps = (v["steps"] as? [Any])?.count ?? 0
        e.hosts = (v["hosts"] as? [[String: Any]] ?? []).compactMap { r in
            guard let task = r["task_id"] as? String else { return nil }
            return AiHostRun(hostId: r["host_id"] as? String ?? "", label: r["label"] as? String ?? "", taskId: task,
                             status: r["status"] as? String ?? "", summary: r["summary"] as? String, error: r["error"] as? String,
                             durationMs: AiJson.int64(r["duration_ms"]), costMicros: AiJson.int64(r["cost_micros"]) ?? 0,
                             pendingApprovals: Int(AiJson.int64(r["pending_approvals"]) ?? 0))
        }
        return e
    }
}

/// A task's commands as a snippet to save (`GET …/runbook`).
struct AiRunbook: Equatable {
    var name: String
    var description: String
    var script: String
    var variables: [String]
    /// Commands and file writes in it (0: nothing to save).
    var steps: Int

    static func parse(_ json: String) -> AiRunbook {
        let v = AiJson.object(json)
        return AiRunbook(name: v["name"] as? String ?? "", description: v["description"] as? String ?? "",
                         script: v["script"] as? String ?? "", variables: v["variables"] as? [String] ?? [],
                         steps: Int(AiJson.int64(v["steps"]) ?? 0))
    }

    /// `POST …/runbook`: the name if typed (the task's title otherwise).
    static func saveBody(name: String) -> [String: Any] {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? [:] : ["name": n]
    }
}

/// "1 min 5 s", "800 ms": how long a host took.
func aiDuration(ms: Int64) -> String {
    if ms < 1000 { return "\(ms) ms" }
    let s = ms / 1000
    if s < 60 { return "\(s) s" }
    return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s"
}

enum AiJson {
    static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    static func encode(_ body: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let n as Int64: return n
        case let n as Int: return Int64(n)
        case let n as Double: return Int64(n)
        case let n as NSNumber: return n.int64Value
        default: return nil
        }
    }
}
