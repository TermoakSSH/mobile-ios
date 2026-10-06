import TermoakKit
import Combine
import SwiftUI

@main
struct TermoakApp: App {
    @StateObject private var vault = LocalVault()
    @StateObject private var settings = AppSettings()
    /// Link that opened the app (also before the vault is open).
    @State private var pendingURL: URL?

    init() {
        TerminalFont.registerBundled()
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
            .preferredColorScheme(settings.appTheme.colorScheme)
            .task { vault.open() }
            .onOpenURL { url in pendingURL = url }
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
        try? core.setDeviceName(name: UIDevice.current.name)
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
        switch n.type {
        case "session_shared":
            sessions.notices.post(ShareToast(kind: .shared, sessionId: id, title: n.title, name: n.by ?? "", participantId: nil))
        case "join_request", "control_request":
            guard let pid = n.participantId else { return }
            // The terminal on screen already shows it.
            if sessions.showing, sessions.current?.shareSessionId == id { return }
            sessions.notices.post(ShareToast(kind: n.type == "join_request" ? .join : .control, sessionId: id,
                                             title: n.title, name: n.participantName ?? "", participantId: pid))
        default:
            break
        }
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
                switch newPhase {
                case .background: model.sessions.enterBackground()
                case .active:
                    model.sessions.endBackground()
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
            } else {
                Home()
                    .overlay(alignment: .top) { ShareToasts(notices: sessions.notices) }
                    .fullScreenCover(isPresented: $sessions.showing) {
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
