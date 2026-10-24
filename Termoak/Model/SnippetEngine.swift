import Foundation
import TermoakKit

/// The core's snippet templates for the app's forms (SnippetVars.swift has
/// the logic around them): the variables to ask, each target's built-ins,
/// the rendering per target and the values remembered on this device.
enum SnippetEngine {
    static func vars(_ list: [SnippetVariable]) -> [SnipVar] {
        list.map { v in
            let kind: SnipKind
            switch v.kind {
            case .builtin: kind = .builtin
            case .prompt: kind = .prompt
            case .select: kind = .select
            case .secret: kind = .secret
            }
            return SnipVar(key: v.key, kind: kind, label: v.label, defaultValue: v.defaultValue,
                           options: v.options, needsHost: v.needsHost)
        }
    }

    /// The variables to ask before running `script`: with a host, its
    /// built-ins are filled; when some target has no host they are asked.
    static func prompts(_ script: String, everyTargetHasHost: Bool) -> [SnipVar] {
        vars(snippetPrompts(script: script, context: everyTargetHasHost ? SnippetContext(host: "") : nil))
    }

    /// The built-ins of a host (`nil` if it can't be read: then the host's
    /// built-ins are asked like without a host).
    static func context(_ core: TermoakCore, hostId: String?, accountId: String?) -> SnippetContext? {
        guard let hostId else { return nil }
        return try? core.snippetContext(hostId: hostId, accountId: accountId)
    }

    /// The text for one target: the asked values and its own built-ins.
    static func render(_ script: String, values: [String: String], vars: [SnipVar], context: SnippetContext?) -> String? {
        let v = SnippetVars.values(values, forTargetWithHost: context?.host != nil, vars: vars)
        return try? renderSnippetWith(script: script, values: v, context: context)
    }

    /// The values remembered for a snippet (and host).
    static func remembered(_ core: TermoakCore, snippet: Snippet, hostId: String?) -> [String: String] {
        guard !snippet.id.isEmpty else { return [:] }
        return (try? core.snippetValues(snippetId: snippet.id, hostId: hostId)) ?? [:]
    }

    /// Remembers a run's values (never secrets: dropped here and by the core).
    static func remember(_ core: TermoakCore, snippet: Snippet, hostId: String?, values: [String: String], vars: [SnipVar]) {
        guard !snippet.id.isEmpty else { return }
        try? core.rememberSnippetValues(snippetId: snippet.id, hostId: hostId, script: snippet.script,
                                        values: SnippetVars.rememberable(values, vars: vars))
    }

    /// The translated text of an issue of the editor.
    static func issueText(_ issue: SnippetIssue, script: String) -> String {
        let pos = SnippetVars.position(in: script, offset: Int(issue.start))
        let text: String
        switch SnippetVars.issue(issue.message) {
        case .noLabel: text = String(localized: "snippets.issue.no_label")
        case .labelTooLong: text = String(localized: "snippets.issue.label_too_long \(SnippetVars.maxLabel)")
        case .selectOptions: text = String(localized: "snippets.issue.select_options")
        case .secretDefault: text = String(localized: "snippets.issue.secret_default")
        case .tooMany: text = String(localized: "snippets.issue.too_many \(SnippetVars.maxVariables)")
        case .kindConflict(let name, let kind):
            text = String(localized: "snippets.issue.kind_conflict \(name) \(kind.map(kindText) ?? "?")")
        case .other(let m): text = m
        }
        return String(localized: "snippets.issue.line \(pos.line) \(pos.column) \(issue.tag) \(text)")
    }

    static func kindText(_ k: SnipKind) -> String {
        switch k {
        case .builtin: return String(localized: "snippets.kind.builtin")
        case .prompt: return String(localized: "snippets.kind.prompt")
        case .select: return String(localized: "snippets.kind.select")
        case .secret: return String(localized: "snippets.kind.secret")
        }
    }

    /// "Env · one of: dev, prod", for the editor's list.
    static func variableText(_ v: SnipVar) -> String {
        switch v.kind {
        case .builtin: return String(localized: "snippets.vars.kind_builtin \(v.label)")
        case .prompt:
            if let d = v.defaultValue, !d.isEmpty { return String(localized: "snippets.vars.kind_prompt_default \(v.label) \(d)") }
            return String(localized: "snippets.vars.kind_prompt \(v.label)")
        case .select: return String(localized: "snippets.vars.kind_select \(v.label) \(v.options.joined(separator: ", "))")
        case .secret: return String(localized: "snippets.vars.kind_secret \(v.label)")
        }
    }
}
