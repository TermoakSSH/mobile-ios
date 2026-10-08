import Foundation

// What an AI approval shows (server 0.6 `preview`: the risk and its reasons,
// the exact command, the file's diff or the plan) and the decision with an
// edit or a reason. Without the engine's types so the unit tests compile this
// file on its own: AiEngine.swift makes one from the engine's
// `AiApprovalPreview` (typed calls) and `parse` reads the live events' JSON.

struct ApprovalPreview: Equatable {
    struct Reason: Equatable {
        /// `pipe`, `sudo`, `rm_rf`, `system_path`... (translated by the app).
        var code: String
        /// The server's English text (shown for an unknown code).
        var text: String
    }

    /// `command` (run_command), `terminal` (send_to_terminal), `file`
    /// (write_file), `plan` or `other`.
    var kind = "other"
    var host: String?
    var command: String?
    var path: String?
    var diff: String?
    var diffTruncated = false
    var added: Int?
    var removed: Int?
    var newFile = false
    var diffError: String?
    /// `low`, `medium` or `high`.
    var risk = "low"
    var reasons: [Reason] = []
    var explanation: String?
    var plan: String?
    /// The command or plan can be edited before approving.
    var editable = false

    /// What "Edit and approve" starts from: the command, or the plan.
    var editableText: String? {
        guard editable else { return nil }
        return kind == "plan" ? plan : command
    }

    /// From an `approval_requested` event's `preview` (server events are JSON).
    static func parse(_ v: [String: Any]) -> ApprovalPreview {
        var p = ApprovalPreview()
        p.kind = v["kind"] as? String ?? "other"
        p.host = v["host"] as? String
        p.command = v["command"] as? String
        p.path = v["path"] as? String
        p.diff = v["diff"] as? String
        p.diffTruncated = v["diff_truncated"] as? Bool ?? false
        p.added = int(v["added"])
        p.removed = int(v["removed"])
        p.newFile = v["new_file"] as? Bool ?? false
        p.diffError = v["diff_error"] as? String
        p.risk = v["risk"] as? String ?? "low"
        p.reasons = (v["reasons"] as? [[String: Any]] ?? []).map {
            Reason(code: $0["code"] as? String ?? "", text: $0["text"] as? String ?? "")
        }
        p.explanation = v["explanation"] as? String
        p.plan = v["plan"] as? String
        p.editable = v["editable"] as? Bool ?? false
        return p
    }

    /// `system_path`'s folder ("writes to /etc" → "/etc").
    static func reasonPath(_ text: String) -> String? {
        guard let r = text.range(of: "writes to ") else { return nil }
        let path = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let n as Int64: return Int(n)
        case let n as Double: return Int(n)
        case let n as NSNumber: return n.intValue
        default: return nil
        }
    }
}

/// A line of a unified diff, to color it.
enum DiffLineKind: Equatable {
    case added, removed, hunk, header, context

    init(_ line: Substring) {
        if line.hasPrefix("+++") || line.hasPrefix("---") {
            self = .header
        } else if line.hasPrefix("@@") {
            self = .hunk
        } else if line.hasPrefix("+") {
            self = .added
        } else if line.hasPrefix("-") {
            self = .removed
        } else {
            self = .context
        }
    }
}

/// What you decide about an approval.
struct ApprovalChoice: Equatable {
    var approve: Bool
    /// Approve this one and the rest of the task (autonomous mode).
    var always = false
    /// Approve this command or plan instead of the model's.
    var edited: String?
    /// Why it was denied (sent to the AI).
    var reason: String?

    /// The edit to send: only when approving, `nil` when empty.
    var cleanEdited: String? {
        guard approve, let e = edited?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty else { return nil }
        return e
    }

    /// The reason to send (`nil` when empty).
    var cleanReason: String? {
        guard let r = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return nil }
        return r
    }
}
