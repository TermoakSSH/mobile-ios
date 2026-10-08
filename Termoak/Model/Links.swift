import TermoakKit
import Foundation

// Every link and typed address goes through the engine's one parser
// (`parseLink` / `parseQuickConnect`), the same as Android and the desktop:
// `termoak://join|invite?server=…&token=…`, `https://<server>[/path]/join/<token>`
// (also `/api/v1/join/…`), `https://<server>[/path]/invite/<code>`,
// `ssh://` and `telnet://` addresses and, for quick connect, what is typed
// (`user@host:port`, `ssh user@host -p 2222`, `telnet host 23`).

/// What a link opened in the app, or pasted, is.
enum AppLink: Equatable {
    case join(JoinLink)
    case invite(InviteLink)
    case quickConnect(QuickTarget)

    init?(_ text: String) {
        switch parseLink(text: text) {
        case .join(let server, let token)?:
            self = .join(JoinLink(server: LinkServer.clean(server), token: token))
        case .invite(let server, let code)?:
            self = .invite(InviteLink(server: LinkServer.clean(server), token: code))
        case .quickConnect(let p, let user, let host, let port)?:
            self = .quickConnect(QuickTarget(protocol: p, user: user, host: host, port: port))
        case nil:
            return nil
        }
    }

    init?(_ url: URL) { self.init(url.absoluteString) }
}

extension JoinLink {
    static func parse(_ text: String) -> JoinLink? {
        if case .join(let link)? = AppLink(text) { return link }
        return nil
    }

    static func parse(_ url: URL) -> JoinLink? { parse(url.absoluteString) }
}

extension InviteLink {
    static func parse(_ text: String) -> InviteLink? {
        if case .invite(let link)? = AppLink(text) { return link }
        return nil
    }

    static func parse(_ url: URL) -> InviteLink? { parse(url.absoluteString) }
}

extension QuickTarget {
    /// An address typed in a search or in quick connect (plain words are
    /// not addresses, so it can run on every keystroke).
    static func parse(_ input: String) -> QuickTarget? {
        guard case .quickConnect(let p, let user, let host, let port)? = parseQuickConnect(text: input) else { return nil }
        return QuickTarget(protocol: p, user: user, host: host, port: port)
    }
}
