import Foundation

// Pure rules of the AI in the terminal (no engine, no UI), with unit tests:
// what is sent about a command that failed, how a `# request` line is
// erased before typing the AI's command, and how the AI's risk reads.

enum TerminalAiRules {
    /// How long the "Command failed" chip stays if nothing else happens
    /// (like the desktop's).
    static let chipSeconds: Double = 60

    /// The chip shows under a failed command when the setting is on, there
    /// is an AI to ask and you can type in the terminal.
    static func showsFixChip(failed: Bool, enabled: Bool, aiAvailable: Bool, canWrite: Bool) -> Bool {
        failed && enabled && aiAvailable && canWrite
    }

    /// A command and the end of its output as the AI gets it, like the
    /// desktop's: `$ command`, the output and the exit status. Redact it
    /// before sending (`redactSecrets`).
    static func forAi(command: String?, output: String, exitCode: Int32?) -> String {
        var s = ""
        if let command { s += "$ \(command)\n" }
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { s += output + "\n" }
        if let exitCode { s += "(exit status \(exitCode))\n" }
        return s.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    /// Backspaces that erase a typed line (one per character, as the
    /// shells' line editors delete them), like the desktop does.
    static func eraseBytes(_ line: String) -> [UInt8] {
        Array(repeating: 0x7F, count: line.unicodeScalars.count)
    }

    /// What is sent is a bracketed paste (the shell does not run its lines).
    static func isBracketedPaste(_ data: Data) -> Bool {
        data.starts(with: Array("\u{1b}[200~".utf8))
    }

    /// The prompt in front of the typed line: the cursor line on screen
    /// without what was typed (the whole line when that is not known).
    static func prompt(screenLine: String, typed: String?) -> String {
        guard let typed, !typed.isEmpty else { return screenLine }
        var line = screenLine
        while line.hasSuffix(" ") && !typed.hasSuffix(" ") { line.removeLast() }
        guard line.hasSuffix(typed) else { return screenLine }
        return String(line.dropLast(typed.count))
    }

    /// Text of terminal cells: empty cells come as NUL.
    static func cellText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{0}", with: " ")
    }

    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// How risky the AI says its proposed command is (`AiCommandSuggestion.risk`).
enum AiCommandRisk: String, Equatable {
    case read, write, dangerous

    /// Unknown values count as changing the system, like the desktop.
    init(_ raw: String) {
        self = AiCommandRisk(rawValue: raw.lowercased()) ?? .write
    }

    /// Asks before typing it.
    var needsConfirmation: Bool { self == .dangerous }

    var title: String {
        switch self {
        case .read: return String(localized: "terminal.ai.risk_read")
        case .write: return String(localized: "terminal.ai.risk_write")
        case .dangerous: return String(localized: "terminal.ai.risk_dangerous")
        }
    }

    var symbol: String {
        switch self {
        case .read: return "eye"
        case .write: return "pencil"
        case .dangerous: return "exclamationmark.triangle.fill"
        }
    }
}
