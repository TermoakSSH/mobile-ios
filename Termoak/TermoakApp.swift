import TermoakKit
import Combine
import SwiftUI

@main
struct TermoakApp: App {
    @StateObject private var vault = LocalVault()
    @StateObject private var settings = AppSettings()
    @ObservedObject private var lock = AppLock.shared
    @Environment(\.scenePhase) private var phase
    /// Link that opened the app (also before the vault is open).
    @State private var pendingURL: URL?

    /// The last link received and when (a Universal Link can arrive both
    /// ways: it is opened once).
    @State private var lastURL: (url: URL, at: Date)?

    init() {
        TerminalFont.registerBundled()
    }

    private func receive(_ url: URL) {
        if let last = lastURL, last.url == url, Date().timeIntervalSince(last.at) < 2 { return }
        lastURL = (url, Date())
        pendingURL = url
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let core = vault.core {
                    Root(core: core, settings: settings, pendingURL: $pendingURL)
                } else if let error = vault.error {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.trianglebadge.exclamationmark").font(.largeTitle)
                        Text("vault.open_failed").font(.headline)
                        Text(error).font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    ProgressView()
                }
            }
            .tint(Brand.blue)
            // The app lock covers everything (also the sign-in screens).
            .overlay { AppLockOverlay(lock: lock) }
            .animation(.easeOut(duration: 0.15), value: lock.locked || lock.covered)
            .onAppear { lock.unlock() }
            .onChange(of: phase) { lock.scenePhaseChanged($0) }
            .preferredColorScheme(settings.appTheme.colorScheme)
            .task { vault.open() }
            .onOpenURL { url in receive(url) }
            // Universal Links (https://termoak.com/join/<token>): the web
            // page's activity, in case it doesn't come through onOpenURL.
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { receive(url) }
            }
        }
    }
}

/// State shared by every screen.
@MainActor
final class AppModel: ObservableObject {
    let core: TermoakCore
    let settings: AppSettings
    let account: Accounts
    let sessions: Sessions
    let tunnels: Tunnels
    /// "Join with link" sheet (opened from a link or from Connections).
    @Published var joining: JoinSheetItem?
    private var subscriptions: Set<AnyCancellable> = []

    init(core: TermoakCore, settings: AppSettings) {
        self.core = core
        self.settings = settings
        account = Accounts(core: core)
        tunnels = Tunnels(core: core)
        sessions = Sessions(core: core, settings: settings, tunnels: tunnels)
        // A host's system detected after connecting: its logo in the lists.
        let accounts = account
        sessions.onHostChanged = { [weak accounts] in accounts?.vaultChanged.send() }
        try? core.setDeviceName(name: UIDevice.current.name)
        // Sharing notices in the background become notifications; a tap
        // opens the session.
        BackgroundNotices.shared.start()
        BackgroundNotices.shared.onOpen = { [weak self] id, title, owner in
            self?.openFromNotice(sessionId: id, title: title, owner: owner)
        }
        // The running server sessions of every signed-in account appear as
        // sleeping tabs: at launch and when an account signs in. Those of an
        // account that signs out go away.
        account.accountsChanged
            .sink { [weak self] in
                Task { @MainActor in await self?.restoreServerSessions() }
            }
            .store(in: &subscriptions)
    }

    /// Server sessions of the signed-in accounts (only new ones are added).
    func restoreServerSessions() async {
        let active = account.list.filter { $0.status == .active }.map(\.id)
        sessions.forgetServer(keeping: Set(active))
        await sessions.restoreFromServer(accounts: active)
    }

    /// A link was opened (`termoak://join?…` or `https://…/join/<token>`).
    /// Returns whether it was an invitation link.
    @discardableResult
    func handleURL(_ url: URL) -> Bool {
        guard let link = JoinLink.parse(url) else { return false }
        if sessions.showing {
            // The terminal covers the home screen: close it first so the
            // sheet can be shown.
            sessions.showing = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.joining = JoinSheetItem(link: link)
            }
        } else {
            joining = JoinSheetItem(link: link)
        }
        return true
    }

    /// Joins after the sheet closes (the terminal opens over the home screen).
    func join(_ link: JoinLink, mode: ServerTerminal.JoinMode, title: String) {
        joining = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sessions.join(link, mode: mode, title: title)
        }
    }

    /// A notice of the events WebSocket about sessions.
    func sessionNotice(_ n: ShareNotice) {
        guard let id = n.sessionId else { return }
        let onScreen = sessions.showing && sessions.current?.shareSessionId == id
        switch n.type {
        case "session_shared":
            sessions.notices.post(ShareToast(kind: .shared, sessionId: id, title: n.title, name: n.by ?? "", participantId: nil))
            BackgroundNotices.shared.notify(.shared, sessionId: id, title: n.title, name: n.by ?? "", participantId: nil)
        case "join_request", "control_request":
            guard let pid = n.participantId else { return }
            let join = n.type == "join_request"
            BackgroundNotices.shared.notify(join ? .join : .control, sessionId: id, title: n.title,
                                            name: n.participantName ?? "", participantId: pid)
            // The terminal on screen already shows it.
            if onScreen { return }
            sessions.notices.post(ShareToast(kind: join ? .join : .control, sessionId: id,
                                             title: n.title, name: n.participantName ?? "", participantId: pid))
        case "control_granted", "control_revoked":
            // You were given the keyboard of a session you joined, or it was
            // taken back (the terminal on screen says it itself).
            if onScreen { return }
            sessions.notices.post(ShareToast(kind: n.type == "control_granted" ? .controlGranted : .controlRevoked,
                                             sessionId: id, title: n.title, name: n.by ?? "", participantId: nil))
        default:
            break
        }
    }

    /// A notification was tapped: to that session (over whatever is on screen).
    private func openFromNotice(sessionId: String, title: String, owner: Bool) {
        joining = nil
        sessions.openSession(sessionId, title: title, owner: owner)
    }
}

private struct Root: View {
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @Binding var pendingURL: URL?

    init(core: TermoakCore, settings: AppSettings, pendingURL: Binding<URL?>) {
        _model = StateObject(wrappedValue: AppModel(core: core, settings: settings))
        _pendingURL = pendingURL
    }

    /// Opens the link that arrived (an invitation link to join a session).
    private func openPendingURL() {
        guard let url = pendingURL else { return }
        pendingURL = nil
        model.handleURL(url)
    }

    var body: some View {
        RootContent()
            .onAppear { openPendingURL() }
            .onChange(of: pendingURL) { _ in openPendingURL() }
            .environmentObject(model)
            .environmentObject(model.account)
            .environmentObject(model.sessions)
            .environmentObject(model.settings)
            .environmentObject(model.tunnels)
            .task {
                await model.account.refresh()
                await model.restoreServerSessions()
                model.account.sync()
            }
            .onChange(of: phase) { newPhase in
                BackgroundNotices.shared.inBackground = newPhase == .background
                switch newPhase {
                case .background: model.sessions.enterBackground()
                case .active:
                    model.sessions.returnedToForeground()
                    Task {
                        await model.account.refresh()
                        await model.sessions.refreshServer(accounts: model.account.list.filter { $0.status == .active }.map(\.id))
                    }
                default: break
                }
            }
    }
}

private struct RootContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @EnvironmentObject private var sessions: Sessions
    @EnvironmentObject private var settings: AppSettings
    /// Regular on an iPad with room (or an iPhone Plus/Pro Max in
    /// landscape): the desktop layout, as Settings says.
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var welcomeDone = false
    /// The welcome screen is on: it stays until it finishes (an account
    /// waiting for its email code is already in the list).
    @State private var inWelcome = false

    var body: some View {
        Group {
            if account.loggedIn == nil {
                ProgressView()
            } else if (account.list.isEmpty || inWelcome) && !settings.noServer && !welcomeDone
                        && model.joining == nil && sessions.open.isEmpty {
                LoginView(welcome: true) { welcomeDone = true }
                    .onAppear { inWelcome = true }
            } else if usesDesktopLayout(sizeClass, settings.wideLayout) {
                // iPad with room: like the desktop app (tabs on top, sidebar).
                DesktopShell()
            } else {
                Home()
                    .overlay(alignment: .top) { ShareToasts(notices: sessions.notices) }
                    // The terminal closes itself (`sessions.showing = false`).
                    // The cover also goes away when rotating or a new layout
                    // setting turns this into the desktop layout: the
                    // terminal stays on screen there (its connection lives in
                    // `sessions` either way).
                    .fullScreenCover(isPresented: Binding(get: { sessions.showing }, set: { _ in })) {
                        TerminalScreenView()
                            .environmentObject(model)
                            .environmentObject(model.account)
                            .environmentObject(sessions)
                            .environmentObject(settings)
                            .environmentObject(model.tunnels)
                    }
            }
        }
        .sheet(item: $model.joining) { item in
            JoinLinkView(link: item.link)
                .environmentObject(model)
                .environmentObject(model.account)
        }
        .onReceive(account.sessionNotices) { model.sessionNotice($0) }
        // Notices of the syncs (vaults shared or lost, changes discarded)
        // and of the update that moved the data to one store per account.
        .alert(account.notice?.title ?? "", isPresented: Binding(get: { account.notice != nil },
                                                               set: { if !$0 { account.noticeDismissed() } })) {
            Button("common.ok", role: .cancel) {}
        } message: { Text(account.notice?.message ?? "") }
        .sheet(item: $account.uploadOffer) { offer in
            UploadDeviceItemsView(accountId: offer.accountId)
                .environmentObject(model)
                .environmentObject(account)
        }
    }
}
