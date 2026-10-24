import Foundation

// Snippet variables (docs/SSH-PRO.md §7 in TermoakSSH/core): the fields of
// the run forms, the issues the editor shows and the values each target
// gets. The core parses (`parseSnippet`, `snippetPrompts`) and renders
// (`renderSnippetWith`); this is what the app does around it, without the
// engine's types, so the unit tests compile this file on its own.
//
// - Prompts (`{{name}}`, `{{prompt:Label|default}}`): text fields with their
//   default; selects (`{{select:Label|a|b}}`): a picker; secrets
//   (`{{secret:Label}}`): masked, never remembered nor prefilled.
// - Built-ins (`{{host}}`, `{{user}}`, `{{date}}`...) are filled per host;
//   without a host (a local terminal) the host ones are asked.
// - Values are remembered on this device per snippet and host (the core's
//   `snippetValues`, never secrets).

enum SnipKind: Equatable {
    case builtin, prompt, select, secret
}

/// A variable to ask (the core's `SnippetVariable`).
struct SnipVar: Equatable {
    var key: String
    var kind: SnipKind
    var label: String
    var defaultValue: String?
    var options: [String]
    /// A host built-in (`host`, `user`...): asked only without a host.
    var needsHost: Bool

    /// Its value may be remembered (never a secret).
    var rememberable: Bool { kind != .secret }
}

/// A field of the run form.
struct SnipField: Equatable {
    var variable: SnipVar
    var value: String
}

enum SnippetVars {
    /// The longest label and the most variables (core `template`).
    static let maxLabel = 64
    static let maxVariables = 50

    /// The fields for `vars`, with the remembered values (never for
    /// secrets) or the defaults; a select keeps only one of its options.
    static func fields(_ vars: [SnipVar], remembered: [String: String]) -> [SnipField] {
        vars.map { v in
            let saved = v.rememberable ? remembered[v.key] : nil
            var value: String
            switch v.kind {
            case .select:
                value = [saved, v.defaultValue, v.options.first].compactMap { $0 }.first { v.options.contains($0) } ?? ""
            case .secret:
                value = ""
            case .prompt, .builtin:
                value = saved ?? v.defaultValue ?? ""
            }
            return SnipField(variable: v, value: value)
        }
    }

    /// The values typed, or the label of the first one missing.
    static func values(_ fields: [SnipField]) -> Result<[String: String], Missing> {
        var out: [String: String] = [:]
        for f in fields {
            if f.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .failure(Missing(label: f.variable.label))
            }
            out[f.variable.key] = f.value
        }
        return .success(out)
    }

    struct Missing: Error, Equatable {
        let label: String
    }

    /// The values a target gets: one with a host fills its own host
    /// built-ins (asked only because some target had none).
    static func values(_ all: [String: String], forTargetWithHost hasHost: Bool, vars: [SnipVar]) -> [String: String] {
        guard hasHost else { return all }
        var v = all
        for x in vars where x.needsHost { v.removeValue(forKey: x.key) }
        return v
    }

    /// What may be remembered of a run (never secrets; the core drops them too).
    static func rememberable(_ values: [String: String], vars: [SnipVar]) -> [String: String] {
        let secrets = Set(vars.filter { !$0.rememberable }.map(\.key))
        return values.filter { !secrets.contains($0.key) }
    }

    /// A startup snippet that would ask (prompts with a host, one without
    /// default): at login only built-ins and defaults are filled.
    static func startupAsks(_ prompts: [SnipVar]) -> Bool {
        prompts.contains { $0.defaultValue == nil }
    }

    /// Line and column (from 1) of a character offset (Unicode scalars, as
    /// the core counts).
    static func position(in script: String, offset: Int) -> (line: Int, column: Int) {
        var line = 1, column = 1
        for (i, c) in script.unicodeScalars.enumerated() {
            if i >= offset { break }
            if c == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return (line, column)
    }

    /// The meaning of a core issue message (translated by the app).
    enum Issue: Equatable {
        case noLabel
        case labelTooLong
        case selectOptions
        case secretDefault
        case tooMany
        /// "Env" is already a variable of another kind.
        case kindConflict(name: String, kind: SnipKind?)
        case other(String)
    }

    static func issue(_ message: String) -> Issue {
        if message == "the variable has no label" { return .noLabel }
        if message.hasPrefix("the label is longer than") { return .labelTooLong }
        if message.hasPrefix("a select needs at least one option") { return .selectOptions }
        if message == "a secret cannot have a default value" { return .secretDefault }
        if message.hasPrefix("a snippet can have at most") { return .tooMany }
        // "\"Env\" is already a select variable"
        if message.hasPrefix("\""), let r = message.range(of: "\" is already a "), message.hasSuffix(" variable"),
           message.index(message.endIndex, offsetBy: -" variable".count) >= r.upperBound {
            let name = String(message[message.index(after: message.startIndex)..<r.lowerBound])
            let kind = String(message[r.upperBound..<message.index(message.endIndex, offsetBy: -" variable".count)])
            let k: SnipKind? = ["built-in": .builtin, "prompt": .prompt, "select": .select, "secret": .secret][kind]
            return .kindConflict(name: name, kind: k)
        }
        return .other(message)
    }
}
