import TermoakKit
import Foundation
import SwiftUI

// Live session sharing (like Termius Multiplayer): invitations, the people
// in a session, the keyboard (one driver at a time), the waiting room and
// joining with a link. Protocol: server docs/WEBSOCKET-PROTOCOL.md.

/// Why the server sent you away from a shared session for good (it does not
/// reconnect after these).
struct ShareEnd: Equatable {
    /// `revoked`, `kicked`, `expired`, `session_ended`, `join_denied` or `forbidden`.
    let code: String
    let message: String

    var title: String {
        switch code {
        case "revoked": return String(localized: "share.end.revoked.title")
        case "kicked": return String(localized: "share.end.kicked.title")
        case "expired": return String(localized: "share.end.expired.title")
        case "session_ended": return String(localized: "share.end.session_ended.title")
        case "join_denied": return String(localized: "share.end.join_denied.title")
        default: return String(localized: "share.end.forbidden.title")
        }
    }

    var text: String {
        switch code {
        case "revoked": return String(localized: "share.end.revoked.text")
        case "kicked": return String(localized: "share.end.kicked.text")
        case "expired": return String(localized: "share.end.expired.text")
        case "session_ended": return String(localized: "share.end.session_ended.text")
        case "join_denied": return String(localized: "share.end.join_denied.text")
        default: return String(localized: "share.end.forbidden.text")
        }
    }

    var icon: String {
        switch code {
        case "revoked": return "xmark.circle"
        case "kicked": return "person.fill.xmark"
        case "expired": return "clock"
        case "session_ended": return "power"
        case "join_denied": return "hand.raised.fill"
        default: return "lock.fill"
        }
    }
}

/// You are in the waiting room of a shared session.
struct WaitingRoom: Equatable {
    let title: String
    /// Name of who shares it.
    let owner: String
}

/// Owner: someone waits to be let in or asks for the keyboard.
struct ShareRequest: Identifiable, Equatable {
    enum Kind: Equatable {
        case join, control
    }

    let kind: Kind
    let participant: SessionParticipant

    var id: String { (kind == .join ? "join-" : "control-") + participant.id }
}

/// What the owner can do with the people in a shared session.
enum OwnerAction {
    case allowJoin(String)
    case denyJoin(String)
    /// For `minutes` (1-240), or until it is given back or taken (`nil`).
    case grantControl(String, minutes: UInt32? = nil)
    case denyControl(String)
    case takeControl
    /// `block`: also revokes the invitation they used.
    case kick(String, block: Bool)
    case stopSharing

    /// The participant it is about.
    var participantId: String? {
        switch self {
        case .allowJoin(let p), .denyJoin(let p), .grantControl(let p, _), .denyControl(let p): return p
        case .kick(let p, _): return p
        case .takeControl, .stopSharing: return nil
        }
    }
}

/// How long "Give control" hands the keyboard over, in minutes (`nil`:
/// until you take it back).
let controlDurations: [UInt32?] = [nil, 5, 15, 30, 60]

/// Time limits of automatic grants of the keyboard (share option), in minutes.
let controlLimits: [UInt32] = [5, 15, 30, 60, 120, 240]

/// "Until I take it back", "15 min".
func controlDurationTitle(_ minutes: UInt32?) -> String {
    guard let minutes else { return String(localized: "share.control.until_taken") }
    return String(localized: "share.control.minutes \(Int(minutes))")
}

/// Milliseconds since the epoch (as the library gives them) to a date.
func dateFromMillis(_ ms: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
}

// MARK: - Invitations

/// The invitation calls of a server session's account: the engine's own for
/// the current account, the generic API for any other one.
protocol SessionShareApi: AnyObject {
    func shareServerSessionWith(sessionId: String, target: ShareTarget, options: ShareOptions) async throws -> ShareInvite
    func listServerSessionShares(sessionId: String) async throws -> [SessionShareInfo]
    func updateServerSessionShare(sessionId: String, shareId: String, changes: ShareChanges) async throws -> SessionShareInfo
    func revokeServerSessionShare(sessionId: String, shareId: String) async throws
    func stopSharingServerSession(sessionId: String) async throws -> UInt32
}

extension TermoakCore: SessionShareApi {}

extension AccountHandle: SessionShareApi {
    func shareServerSessionWith(sessionId: String, target: ShareTarget, options: ShareOptions) async throws -> ShareInvite {
        var email: String?, teamId: String?, link = false
        switch target {
        case .user(let e): email = e
        case .team(let t): teamId = t
        case .link: link = true
        }
        let body = ShareJson.shareBody(email: email, teamId: teamId, link: link, control: options.control,
                                       expiresInMinutes: options.expiresInMinutes, requireApproval: options.requireApproval,
                                       autoGrant: options.autoGrant, controlMinutes: options.controlMinutes)
        let json = try await apiPost(path: "/api/v1/sessions/\(sessionId)/shares", bodyJson: ShareJson.encode(body))
        let i = ShareJson.invite(ShareJson.object(json))
        return ShareInvite(shareId: i.shareId, permission: i.permission, token: i.token, link: i.link, appLink: i.appLink)
    }

    func listServerSessionShares(sessionId: String) async throws -> [SessionShareInfo] {
        let json = try await apiGet(path: "/api/v1/sessions/\(sessionId)/shares")
        return ShareJson.array(json).map { Self.info(ShareJson.share($0)) }
    }

    func updateServerSessionShare(sessionId: String, shareId: String, changes: ShareChanges) async throws -> SessionShareInfo {
        let body = ShareJson.changesBody(control: changes.control, expiresInMinutes: changes.expiresInMinutes, noExpiry: changes.noExpiry,
                                         requireApproval: changes.requireApproval, autoGrant: changes.autoGrant,
                                         controlMinutes: changes.controlMinutes, noControlLimit: changes.noControlLimit)
        let json = try await apiPatch(path: "/api/v1/sessions/\(sessionId)/shares/\(shareId)", bodyJson: ShareJson.encode(body))
        return Self.info(ShareJson.share(ShareJson.object(json)))
    }

    func revokeServerSessionShare(sessionId: String, shareId: String) async throws {
        _ = try await apiDelete(path: "/api/v1/sessions/\(sessionId)/shares/\(shareId)")
    }

    func stopSharingServerSession(sessionId: String) async throws -> UInt32 {
        ShareJson.revokedCount(ShareJson.object(try await apiDelete(path: "/api/v1/sessions/\(sessionId)/shares")))
    }

    private static func info(_ s: ShareJson.Share) -> SessionShareInfo {
        let kind: ShareKind
        switch s.kind {
        case .user: kind = .user
        case .team: kind = .team
        case .link: kind = .link
        }
        return SessionShareInfo(id: s.id, sessionId: s.sessionId, kind: kind, control: s.control, userId: s.userId,
                                userEmail: s.userEmail, userName: s.userName, teamId: s.teamId, teamName: s.teamName,
                                expiresAt: s.expiresAt, revoked: s.revoked, active: s.active, requireApproval: s.requireApproval,
                                autoGrant: s.autoGrant, createdAt: s.createdAt, participants: s.participants,
                                controlMinutes: s.controlMinutes)
    }
}

extension TermoakCore {
    /// Who manages the invitations of a server session of `accountId`: the
    /// engine for the current account (or `nil`), that account otherwise.
    func shareApi(for accountId: String?) -> SessionShareApi {
        if let accountId, currentAccount()?.id != accountId, let handle = try? account(accountId: accountId) {
            return handle
        }
        return self
    }
}

/// Where the invitations of a session are managed: a session that lives on
/// the server (through its account) or a terminal of this device shared
/// through it (relay).
enum ShareBackend {
    case server(SessionShareApi, sessionId: String)
    case relay(SharedTerminal)

    func invite(_ target: ShareTarget, _ options: ShareOptions) async throws -> ShareInvite {
        switch self {
        case let .server(core, id): return try await core.shareServerSessionWith(sessionId: id, target: target, options: options)
        case let .relay(shared): return try await shared.invite(target: target, options: options)
        }
    }

    func list() async throws -> [SessionShareInfo] {
        switch self {
        case let .server(core, id): return try await core.listServerSessionShares(sessionId: id)
        case let .relay(shared): return try await shared.listInvites()
        }
    }

    func update(_ shareId: String, _ changes: ShareChanges) async throws -> SessionShareInfo {
        switch self {
        case let .server(core, id): return try await core.updateServerSessionShare(sessionId: id, shareId: shareId, changes: changes)
        case let .relay(shared): return try await shared.updateInvite(shareId: shareId, changes: changes)
        }
    }

    func revoke(_ shareId: String) async throws {
        switch self {
        case let .server(core, id): try await core.revokeServerSessionShare(sessionId: id, shareId: shareId)
        case let .relay(shared): try await shared.revokeInvite(shareId: shareId)
        }
    }

    /// Revokes every invitation: everyone but you leaves.
    func revokeAll() async throws {
        switch self {
        case let .server(core, id): _ = try await core.stopSharingServerSession(sessionId: id)
        case let .relay(shared): try await shared.revokeAllInvites()
        }
    }
}

/// How long an invitation lasts.
enum ShareExpiry: Int64, CaseIterable, Identifiable {
    case never = 0
    case halfHour = 30
    case hour = 60
    case day = 1440
    case week = 10080

    var id: Int64 { rawValue }
    var minutes: Int64? { self == .never ? nil : rawValue }

    var title: String {
        switch self {
        case .never: return String(localized: "share.expiry.never")
        case .halfHour: return String(localized: "share.expiry.half_hour")
        case .hour: return String(localized: "share.expiry.hour")
        case .day: return String(localized: "share.expiry.day")
        case .week: return String(localized: "share.expiry.week")
        }
    }
}

extension SessionAccess {
    /// "View only", "Can request control" or "Owner".
    var shareLabel: String {
        switch self {
        case .owner: return String(localized: "share.access.owner")
        case .control: return String(localized: "share.permission.control")
        case .view: return String(localized: "share.permission.view")
        }
    }
}

extension SessionShareInfo {
    /// Who it is for: a person, a team or anyone with the link.
    var targetName: String {
        switch kind {
        case .user: return userName.flatMap { $0.isEmpty ? nil : $0 } ?? userEmail ?? String(localized: "share.kind.user")
        case .team: return teamName ?? String(localized: "share.kind.team")
        case .link: return String(localized: "share.kind.link")
        }
    }

    var icon: String {
        switch kind {
        case .user: return "person.fill"
        case .team: return "person.3.fill"
        case .link: return "link"
        }
    }
}

// MARK: - Joining with a link

/// An invitation link: `termoak://join?server=…&token=…` (the app link) or
/// the web one, `https://server/join/<token>` (also `/api/v1/join/<token>`),
/// which is what a universal link would bring.
struct JoinLink: Equatable {
    /// Base URL of the server (no trailing slash).
    let server: String
    let token: String

    static func parse(_ text: String) -> JoinLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return parse(url)
    }

    static func parse(_ url: URL) -> JoinLink? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = c.scheme?.lowercased() else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        if scheme == "termoak" {
            guard c.host?.lowercased() == "join" else { return nil }
            let items = c.queryItems ?? []
            guard let server = items.first(where: { $0.name == "server" })?.value,
                  let serverURL = URL(string: server), let s = serverURL.scheme?.lowercased(), s == "https" || s == "http",
                  let token = items.first(where: { $0.name == "token" })?.value ?? parts.last,
                  valid(token) else { return nil }
            return JoinLink(server: normalize(server), token: token)
        }
        guard scheme == "https" || scheme == "http", let host = c.host,
              let i = parts.lastIndex(of: "join"), i + 1 < parts.count, valid(parts[i + 1]) else { return nil }
        // What comes before `/join` is the server's own path (if it lives under
        // one), without `/api/v1` nor the language of the website (`/es`).
        var prefix = Array(parts[..<i])
        if prefix.suffix(2) == ["api", "v1"] { prefix.removeLast(2) }
        if prefix.count == 1, prefix[0].count == 2 { prefix = [] }
        var base = URLComponents()
        base.scheme = scheme
        base.host = host
        base.port = c.port
        base.path = prefix.isEmpty ? "" : "/" + prefix.joined(separator: "/")
        guard let server = base.string else { return nil }
        return JoinLink(server: normalize(server), token: parts[i + 1])
    }

    /// Server URLs compared without case or trailing slash.
    static func normalize(_ server: String) -> String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func sameServer(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        return normalize(a).lowercased() == normalize(b).lowercased()
    }

    private static func valid(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }
}

/// The "Join with link" sheet: with the link already known (opened from a
/// link) or to paste one.
struct JoinSheetItem: Identifiable {
    let id = UUID()
    let link: JoinLink?
}

// MARK: - Notices of the whole app

/// A session notice of the events WebSocket (`{"type":"session","notice":…}`).
struct ShareNotice {
    /// `session_shared`, `join_request`, `control_request`, `control_granted`...
    let type: String
    let sessionId: String?
    let title: String
    let participantId: String?
    let participantName: String?
    /// Who shared it with you (`session_shared`).
    let by: String?

    init?(_ notice: [String: Any]) {
        guard let type = notice["type"] as? String else { return nil }
        self.type = type
        let session = notice["session"] as? [String: Any]
        sessionId = (notice["session_id"] as? String) ?? (session?["id"] as? String)
        title = (notice["title"] as? String) ?? (session?["title"] as? String) ?? ""
        let participant = notice["participant"] as? [String: Any]
        participantId = participant?["id"] as? String
        participantName = participant?["name"] as? String
        by = notice["by"] as? String
    }
}

/// A toast over any screen: someone wants to join or asks for the keyboard
/// of one of your sessions, or shared a session with you.
struct ShareToast: Identifiable, Equatable {
    enum Kind: Equatable {
        case join, control, shared
        /// You were given the keyboard of a session you joined, or it was taken back.
        case controlGranted, controlRevoked
    }

    let id = UUID()
    let kind: Kind
    let sessionId: String
    /// Title of the session.
    let title: String
    /// Who asks (or who shared it).
    let name: String
    let participantId: String?
}

@MainActor
final class ShareNotices: ObservableObject {
    @Published private(set) var toasts: [ShareToast] = []

    func post(_ toast: ShareToast) {
        toasts.removeAll {
            $0.kind == toast.kind && $0.sessionId == toast.sessionId && $0.participantId == toast.participantId
        }
        toasts.append(toast)
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        let id = toast.id
        let seconds: UInt64 = toast.kind == .join || toast.kind == .control ? 60 : 8
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            self?.dismiss(id)
        }
    }

    func dismiss(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    /// The request of that participant was answered (here or in the terminal).
    func resolve(participantId: String) {
        toasts.removeAll { $0.participantId == participantId }
    }
}

extension ServerSession {
    /// Who shares it: `ownerName` from the server, or the owner among the
    /// people inside (servers before 0.3 do not send the name).
    var sharedBy: String? {
        if let name = ownerName?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        return participants.first(where: { $0.kind == .owner })?.name
    }
}
