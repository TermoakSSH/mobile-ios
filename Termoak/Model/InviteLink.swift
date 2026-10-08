import Foundation

/// A `termoak://invite?server=…&token=…` link: an invitation to create an
/// account on a server (and join a team), like the desktop's. Without the
/// engine's types so the unit tests compile this file on its own.
struct InviteLink: Equatable, Identifiable {
    /// Base URL of the server (http or https, no trailing slash).
    let server: String
    let token: String
    var id: String { "\(server)#\(token)" }

    static func parse(_ text: String) -> InviteLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }
        return parse(url)
    }

    static func parse(_ url: URL) -> InviteLink? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = c.scheme?.lowercased(), scheme == "termoak" || scheme == "aceitunoak",
              c.host?.lowercased() == "invite" else { return nil }
        let items = c.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value?.trimmingCharacters(in: .whitespaces)
        }
        guard var server = value("server"), let token = value("token"), !token.isEmpty,
              let serverURL = URL(string: server), let s = serverURL.scheme?.lowercased(), s == "https" || s == "http",
              serverURL.host?.isEmpty == false else { return nil }
        while server.hasSuffix("/") { server.removeLast() }
        guard token.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) })
        else { return nil }
        return InviteLink(server: server, token: token)
    }
}
