import TermoakKit
import Combine
import Foundation

/// Account state on the server: login, sync, pending AI approvals and live
/// events (WebSocket).
@MainActor
final class Account: ObservableObject {
    let core: TermoakCore

    /// `nil` while unknown.
    @Published private(set) var loggedIn: Bool?
    @Published private(set) var server: String?
    @Published private(set) var user: String?
    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?
    @Published var syncError: String?
    @Published private(set) var pendingApprovals = 0
    /// Receiving live events from the server.
    @Published private(set) var live = false

    /// Something changed on the server (`ai`, `session`, `lagged`): reload.
    let changes = PassthroughSubject<String, Never>()
    /// The local vault changed while syncing.
    let vaultChanged = PassthroughSubject<Void, Never>()
    /// Every event of an AI task (to follow it live in the copilot).
    let aiEvents = PassthroughSubject<AiEvent, Never>()

    private var subscription: EventSubscription?
    private var eventsTask: Task<Void, Never>?

    init(core: TermoakCore) {
        self.core = core
    }

    func refresh() async {
        let isLoggedIn = (try? await core.isLoggedIn()) ?? false
        loggedIn = isLoggedIn
        server = try? await core.serverUrl()
        user = try? await core.serverUser()
        if isLoggedIn {
            await refreshApprovals()
            startEvents()
            await syncLocaleIfNeeded()
        } else {
            stopEvents()
        }
    }

    func logIn(server: String, email: String, password: String, code: String?) async throws {
        try await core.login(url: server, email: email, password: password, totpCode: code)
        await refresh()
        sync()
    }

    func logOut() {
        stopEvents()
        Task {
            try? await core.logout()
            pendingApprovals = 0
            await refresh()
        }
    }

    func sync() {
        guard !syncing, loggedIn == true else { return }
        syncing = true
        Task {
            defer { syncing = false }
            do {
                _ = try await core.syncNow()
                lastSync = Date()
                syncError = nil
                vaultChanged.send()
            } catch TermoakError.NotLoggedIn {
                // No server: nothing to sync.
            } catch TermoakError.SessionExpired {
                syncError = String(localized: "account.session_expired")
                await refresh()
            } catch {
                syncError = errorMessage(error)
            }
        }
    }

    func refreshApprovals() async {
        pendingApprovals = (try? await core.listPendingApprovals().count) ?? 0
    }

    // ----- Account language -----

    /// Language the app is shown in (`en`, `es`...): the one iOS picked from
    /// the app's localizations (per-app language in the system settings).
    static var appLanguage: String {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return language == "Base" ? "en" : language
    }

    /// Saves the app language in the account (`PATCH /api/v1/me` with
    /// `{"locale": ...}`, see core/docs/I18N.md) so the server writes its emails in
    /// it. Called on every refresh while logged in (launch, login, coming back
    /// to the foreground); it only changes the account when the language
    /// differs from the one already saved there.
    func syncLocaleIfNeeded() async {
        let language = Self.appLanguage
        guard let user = try? await core.currentUser(),
              user.locale.lowercased() != language.lowercased() else { return }
        // Not important if it fails: it is retried on the next refresh.
        _ = try? await core.setLocale(locale: language)
    }

    // ----- Live events -----

    private func startEvents() {
        guard eventsTask == nil else { return }
        eventsTask = Task { [weak self] in
            var delay: UInt64 = 2
            while !Task.isCancelled {
                guard let self else { return }
                let listener = EventListener()
                // On the main queue, in order: the AI text chunks have to
                // arrive exactly as they come out.
                listener.onReceive = { [weak self] json in DispatchQueue.main.async { self?.receive(json) } }
                do {
                    let sub = try await self.core.subscribeEvents(listener: listener)
                    self.subscription = sub
                    self.live = true
                    delay = 2
                    await listener.waitUntilClosed()
                } catch TermoakError.NotLoggedIn {
                    break
                } catch {
                    // Retried below.
                }
                self.live = false
                self.subscription?.unsubscribe()
                self.subscription = nil
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 60)
            }
        }
    }

    private func stopEvents() {
        eventsTask?.cancel()
        eventsTask = nil
        subscription?.unsubscribe()
        subscription = nil
        live = false
    }

    private func receive(_ json: String) {
        guard let data = json.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        switch type {
        case "hello":
            if let n = event["pending_approvals"] as? Int { pendingApprovals = n }
        case "ai", "lagged":
            if type == "ai", let task = event["task_id"] as? String, let ev = event["event"] as? [String: Any] {
                aiEvents.send(AiEvent(taskId: task, event: ev))
            }
            Task { await refreshApprovals() }
            changes.send(type)
        case "session":
            changes.send(type)
        default:
            break
        }
    }
}

/// An event of an AI task (`{"type":"ai","task_id":…,"event":{…}}`).
struct AiEvent {
    let taskId: String
    /// `type` (`text`, `tool_call`, `status`...) and its fields.
    let event: [String: Any]
}

/// Receives the server events (background thread).
private final class EventListener: ServerEventListener, @unchecked Sendable {
    var onReceive: (String) -> Void = { _ in }
    private var continuation: CheckedContinuation<Void, Never>?
    private var closed = false
    private let lock = NSLock()

    func onEvent(eventJson: String) {
        onReceive(eventJson)
    }

    func onClosed(reason: String?) {
        lock.lock()
        closed = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }

    func waitUntilClosed() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if closed {
                lock.unlock()
                c.resume()
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }
}
