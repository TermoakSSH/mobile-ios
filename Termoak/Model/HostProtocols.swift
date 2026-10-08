import Foundation

// Protocols of a host (SSH or Telnet) and the quick connect address, without
// the engine's types so the unit tests compile this file on its own.

/// The protocols a host can use, as stored in `SshHost.protocol`. A value a
/// later version writes (`rdp`...) is kept as it is and treated like SSH.
enum HostProtocol {
    static let ssh = "ssh"
    static let telnet = "telnet"

    static func isTelnet(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespaces).lowercased() == telnet
    }

    /// 23 for Telnet, 22 otherwise.
    static func defaultPort(_ value: String) -> UInt32 {
        isTelnet(value) ? 23 : 22
    }

    /// The port after the protocol changes from `from` to `to` (like the
    /// desktop): empty or the old protocol's default becomes the new one's
    /// (written out for Telnet, empty for SSH); any other port, or text that
    /// is not a port, stays.
    static func portAfterSwitch(from: String, to: String, text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        if from == to { return text }
        let port: UInt32?
        if text.isEmpty {
            port = nil
        } else if let p = UInt32(text), p > 0, p <= 65535 {
            port = p
        } else {
            return text
        }
        if let port, port != defaultPort(from) { return String(port) }
        return isTelnet(to) ? String(defaultPort(to)) : ""
    }
}

/// An address typed in quick connect (⌘K / ⌘T) to connect without a saved
/// host: `user@host:port`, `telnet://[user@]host[:port]`...
struct QuickTarget: Equatable {
    var `protocol` = HostProtocol.ssh
    var user: String?
    var host: String
    var port: UInt32?

    var isTelnet: Bool { HostProtocol.isTelnet(`protocol`) }

    /// The port it connects to (the protocol's default when none was typed).
    var effectivePort: UInt32 { port ?? HostProtocol.defaultPort(`protocol`) }

    /// As typed back: `telnet://admin@switch1:2323`, `[2001:db8::1]:2222`.
    var display: String {
        var h = host
        if port != nil && host.contains(":") { h = "[\(host)]" }
        var s = isTelnet ? "telnet://" : ""
        if let user { s += "\(user)@" }
        s += h
        if let port { s += ":\(port)" }
        return s
    }

    /// Reads `user@host:port`, `host:port`, `user@host`, `[v6]:port`,
    /// `ssh user@host -p port`, `ssh://…`, and for Telnet
    /// `telnet://[user@]host[:port]` or `telnet host [port]` (the same rules
    /// as the desktop app). Only text that looks like an address (it has `@`,
    /// `:` or `.`, or a scheme) counts, so a search word is not a host.
    static func parse(_ input: String) -> QuickTarget? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rest = stripPrefix(text, "telnet://") {
            guard var t = address(trimSlashes(rest), any: true) else { return nil }
            t.protocol = HostProtocol.telnet
            return t
        }
        if let rest = stripPrefix(text, "ssh://") {
            return address(trimSlashes(rest), any: true)
        }
        if let rest = stripPrefix(text, "telnet ") {
            // `telnet host [port]`, as on the command line.
            let words = rest.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let host = words.first, words.count <= 2 else { return nil }
            var port: UInt32?
            if words.count == 2 {
                guard let p = parsePort(words[1]) else { return nil }
                port = p
            }
            guard var t = address(host, any: true) else { return nil }
            if port != nil { t.port = port }
            t.protocol = HostProtocol.telnet
            return t
        }
        var body = text
        if let rest = stripPrefix(body, "ssh ") { body = rest.trimmingCharacters(in: .whitespaces) }
        var flagPort: UInt32?
        if let range = body.range(of: " -p ") {
            guard let p = parsePort(body[range.upperBound...].trimmingCharacters(in: .whitespaces)) else { return nil }
            flagPort = p
            body = body[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        guard body.contains(where: { "@:.".contains($0) }) else { return nil }
        guard var t = address(body, any: false) else { return nil }
        if flagPort != nil { t.port = flagPort }
        return t
    }

    private static func stripPrefix(_ text: String, _ prefix: String) -> String? {
        guard text.count >= prefix.count, text.prefix(prefix.count).lowercased() == prefix else { return nil }
        return String(text.dropFirst(prefix.count))
    }

    private static func trimSlashes(_ text: String) -> String {
        var t = text
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    private static func parsePort(_ text: String) -> UInt32? {
        guard let p = UInt16(text), p > 0 else { return nil }
        return UInt32(p)
    }

    /// `[user@]host[:port]` (`any`: a bare name counts too).
    private static func address(_ text: String, any: Bool) -> QuickTarget? {
        if text.isEmpty || text.contains(where: { $0.isWhitespace }) { return nil }
        if !any && !text.contains(where: { "@:.".contains($0) }) { return nil }
        var user: String?
        var rest = text
        if let at = text.lastIndex(of: "@") {
            let u = String(text[..<at])
            if u.isEmpty { return nil }
            user = u
            rest = String(text[text.index(after: at)...])
        }
        var host: String
        var port: UInt32?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") {
                guard let p = parsePort(String(after.dropFirst())) else { return nil }
                port = p
            } else if !after.isEmpty {
                return nil
            }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            host = String(rest[..<colon])
            guard let p = parsePort(String(rest[rest.index(after: colon)...])) else { return nil }
            port = p
        } else {
            host = rest
        }
        let valid = !host.isEmpty && host.allSatisfy { $0.isLetter || $0.isNumber || ".-_:%".contains($0) }
        return valid ? QuickTarget(protocol: HostProtocol.ssh, user: user, host: host, port: port) : nil
    }
}
