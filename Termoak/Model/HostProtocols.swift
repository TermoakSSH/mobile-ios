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
/// host: `user@host:port`, `telnet://[user@]host[:port]`... Read by the
/// engine's `parseQuickConnect` (Links.swift).
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
}
