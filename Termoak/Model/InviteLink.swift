import Foundation

/// An invitation to create an account on a server (and join a team), from a
/// `termoak://invite?server=…&token=…` link or `https://<server>/invite/<code>`,
/// like the desktop's. It is read by the engine's `parseLink` (Links.swift).
struct InviteLink: Equatable, Identifiable {
    /// Base URL of the server (http or https, no trailing slash).
    let server: String
    let token: String
    var id: String { "\(server)#\(token)" }
}

/// The server of a link, as the app keeps it.
enum LinkServer {
    /// Without spaces or trailing slashes, and without the website's language
    /// when it is the whole path: the site also serves its links under
    /// `/es/join/<token>` (scripts/apple-app-site-association.sh), and `/es`
    /// is not where the server lives. A real path (`/termoak`) stays.
    static func clean(_ server: String) -> String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard var c = URLComponents(string: s) else { return s }
        let parts = c.path.split(separator: "/")
        if parts.count == 1, parts[0].count == 2, parts[0].allSatisfy({ $0.isASCII && $0.isLetter }) {
            c.path = ""
            return c.string ?? s
        }
        return s
    }
}
