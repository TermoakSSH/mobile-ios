import TermoakKit
import Combine
import SwiftUI

@main
struct TermoakApp: App {
    @StateObject private var vault = LocalVault()
    @StateObject private var settings = AppSettings()

    init() {
        TerminalFont.registerBundled()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let core = vault.core {
                    Root(core: core, settings: settings)
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
        }
    }
}

/// State shared by every screen.
@MainActor
final class AppModel: ObservableObject {
    let core: TermoakCore
    let settings: AppSettings
    let account: Account
    let sessions: Sessions
    let tunnels: Tunnels
    private var subscriptions: Set<AnyCancellable> = []

    init(core: TermoakCore, settings: AppSettings) {
        self.core = core
        self.settings = settings
        account = Account(core: core)
        tunnels = Tunnels(core: core)
        sessions = Sessions(core: core, settings: settings, tunnels: tunnels)
        try? core.setDeviceName(name: UIDevice.current.name)
        // When launching logged in (or when logging in), your running server
        // sessions appear as sleeping tabs. Only once: coming back to the
        // foreground does not repeat it.
        account.$loggedIn
            .removeDuplicates()
            .sink { [weak self] loggedIn in
                Task { @MainActor in
                    guard let self else { return }
                    if loggedIn == true {
                        await self.sessions.restoreFromServer()
                    } else if loggedIn == false {
                        self.sessions.forgetServer()
                    }
                }
            }
            .store(in: &subscriptions)
    }
}

private struct Root: View {
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var phase

    init(core: TermoakCore, settings: AppSettings) {
        _model = StateObject(wrappedValue: AppModel(core: core, settings: settings))
    }

    var body: some View {
        RootContent()
            .environmentObject(model)
            .environmentObject(model.account)
            .environmentObject(model.sessions)
            .environmentObject(model.settings)
            .environmentObject(model.tunnels)
            .task { await model.account.refresh() }
            .onChange(of: phase) { newPhase in
                switch newPhase {
                case .background: model.sessions.enterBackground()
                case .active:
                    model.sessions.endBackground()
                    Task { await model.account.refresh() }
                default: break
                }
            }
    }
}

private struct RootContent: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Account
    @EnvironmentObject private var sessions: Sessions
    @EnvironmentObject private var settings: AppSettings
    @State private var welcomeDone = false

    var body: some View {
        if account.loggedIn == nil {
            ProgressView()
        } else if account.loggedIn == false && !settings.noServer && !welcomeDone {
            LoginView(welcome: true) { welcomeDone = true }
        } else {
            Home()
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
}
