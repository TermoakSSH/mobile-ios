import Foundation

/// The output of a command run on one server (`exec`), as the app shows and
/// shares it. Without the engine's types, for the unit tests.
struct ExecOutput: Equatable {
    var stdout: String
    var stderr: String
    var exitCode: UInt32?
    var signal: String?
    var timedOut: Bool
    var truncated: Bool
    var durationMs: UInt64

    /// It ended with exit code 0 (not killed, not timed out).
    var succeeded: Bool { exitCode == 0 && signal == nil && !timedOut }

    /// stdout, then stderr, without a trailing newline.
    var combined: String {
        let parts = [stdout, stderr].map { $0.hasSuffix("\n") ? String($0.dropLast()) : $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: "\n")
    }
}

enum ExecReport {
    /// Every server's output for sharing:
    ///
    ///     ## web (exit 0)
    ///     …output…
    ///
    /// `status`: the server's status line (the app's language), `output`:
    /// `nil` for a server that didn't run it.
    static func text(_ rows: [(name: String, status: String, output: ExecOutput?)]) -> String {
        rows.map { row in
            var block = "## \(row.name) (\(row.status))"
            if let out = row.output?.combined, !out.isEmpty { block += "\n" + out }
            return block
        }
        .joined(separator: "\n\n") + "\n"
    }
}
