import Foundation

// Pure rules of the AI screens (no engine types, so the unit tests compile
// this file on its own): what a new task asks for, the provider and model
// choice, why a provider can't be used, how long a host took, and the labels
// of the copilot's context chips. AiEngine.swift turns them into the
// engine's typed requests.

/// What a new task asks for, cleaned up (the permissions go apart: they are
/// the engine's `AiPermissionMode`).
struct NewAiTask: Equatable {
    var prompt: String
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

    var cleanPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    var cleanProvider: String? { provider.flatMap { $0.isEmpty ? nil : $0 } }
    var cleanEffort: String? { effort.flatMap { $0.isEmpty ? nil : $0 } }
    var cleanTag: String? {
        guard let t = tag?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        return t
    }

    /// `provider::model`, or the provider alone with its default model.
    static func provider(_ key: String?, model: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        guard let model, !model.isEmpty else { return key }
        return "\(key)::\(model)"
    }
}

/// Why a provider can't be used, in the app's language by its stable code
/// (`AiProvider.reasonCode`); `nil` for an unknown code (the server's
/// English text is shown then).
func aiProviderReason(code: String?) -> String? {
    switch code {
    case "not_configured": return String(localized: "ai.provider.reason.not_configured")
    case "own_key_required": return String(localized: "ai.provider.reason.own_key_required")
    case "plan": return String(localized: "ai.provider.reason.plan")
    default: return nil
    }
}

/// "1 min 5 s", "800 ms": how long a host took.
func aiDuration(ms: Int64) -> String {
    if ms < 1000 { return "\(ms) ms" }
    let s = ms / 1000
    if s < 60 { return "\(s) s" }
    return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s"
}

/// Labels of the copilot's context chips (the chips' text comes from the
/// engine, already redacted).
enum CopilotChipLabel {
    /// The command as the chip shows it: its first line, at most 32
    /// characters ("…" at the end when cut).
    static func command(_ command: String?) -> String? {
        guard let first = command?.split(separator: "\n", omittingEmptySubsequences: true).first else { return nil }
        let line = first.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return line.count > 32 ? String(line.prefix(31)) + "…" : line
    }

    /// Lines of a selection (a final newline doesn't count).
    static func lines(_ text: String) -> Int {
        var t = Substring(text)
        while t.last == "\n" { t = t.dropLast() }
        return t.isEmpty ? 0 : t.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}
