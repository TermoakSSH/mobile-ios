import Foundation

// Engine messages the app translates, read from the engine's English text
// (core termoak-ssh `SshError`), without the engine's types so the unit
// tests compile this file on its own.

/// Why the server's key was not accepted (`TermoakError.HostKey`).
enum HostKeyProblem: Equatable {
    /// The key is not the one saved in Known hosts: possible attack.
    case changed(host: String, expected: String, actual: String)
    /// Not in Known hosts and it could not be confirmed.
    case unknown(host: String, fingerprint: String)
    /// You did not trust it.
    case rejected(host: String)

    /// `nil` if the text is not one of the engine's host key messages.
    static func parse(_ message: String) -> HostKeyProblem? {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // "the host key of {host} has CHANGED (expected {e}, got {a}). Possible man-in-the-middle attack"
        if let host = between(m, "the host key of ", " has CHANGED ("),
           let expected = between(m, " (expected ", ", got "),
           let actual = between(m, ", got ", ")") {
            return .changed(host: host, expected: expected, actual: actual)
        }
        // "unknown host {host} with fingerprint {f}: it must be confirmed before connecting"
        if let host = between(m, "unknown host ", " with fingerprint "),
           let fingerprint = between(m, " with fingerprint ", ": it must be confirmed") {
            return .unknown(host: host, fingerprint: fingerprint)
        }
        // "host key rejected by the user ({host})"
        if let host = between(m, "host key rejected by the user (", ")") {
            return .rejected(host: host)
        }
        return nil
    }

    /// The engine writes the host as `host:port` (`[v6]` brackets or not):
    /// the name and the port, to find its entries in Known hosts.
    static func hostAndPort(_ text: String) -> (host: String, port: UInt32)? {
        guard let colon = text.lastIndex(of: ":"), let port = UInt32(text[text.index(after: colon)...]),
              port > 0, port <= 65535 else { return nil }
        var host = String(text[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? nil : (host, port)
    }

    /// The text between `start` and the next `end` after it.
    private static func between(_ text: String, _ start: String, _ end: String) -> String? {
        guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex) else { return nil }
        let value = String(text[a.upperBound..<b.lowerBound])
        return value.isEmpty ? nil : value
    }
}
