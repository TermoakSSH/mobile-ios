import TermoakKit
import SwiftUI

/// Sections of the vault (like Termius's side menu).
enum AppSection: String, CaseIterable, Identifiable {
    case hosts, keychain, snippets, knownHosts, sessions, ai, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hosts: return String(localized: "nav.hosts")
        case .keychain: return String(localized: "nav.keychain")
        case .snippets: return String(localized: "nav.snippets")
        case .knownHosts: return String(localized: "nav.known_hosts")
        case .sessions: return String(localized: "nav.sessions")
        case .ai: return String(localized: "nav.ai")
        case .settings: return String(localized: "nav.settings")
        }
    }

    var icon: String {
        switch self {
        case .hosts: return "server.rack"
        case .keychain: return "key"
        case .snippets: return "chevron.left.forwardslash.chevron.right"
        case .knownHosts: return "checkmark.shield"
        case .sessions: return "clock.arrow.circlepath"
        case .ai: return "sparkles"
        case .settings: return "gearshape"
        }
    }

    static let vault: [AppSection] = [.hosts, .keychain, .snippets, .knownHosts]
    static let server: [AppSection] = [.sessions, .ai]
}

@MainActor
final class Navigator: ObservableObject {
    @Published var section: AppSection = .hosts
    @Published var menuOpen = false

    func go(_ s: AppSection) {
        section = s
        withAnimation(.easeOut(duration: 0.2)) { menuOpen = false }
    }
}

/// ☰ button in the top bar of each section.
struct MenuButton: ToolbarContent {
    @EnvironmentObject private var nav: Navigator

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { nav.menuOpen = true }
            } label: { Image(systemName: "line.3.horizontal") }
            .accessibilityLabel("nav.menu")
        }
    }
}

/// The app: the chosen section, the side menu and the terminal bar.
struct Vault: View {
    @StateObject private var nav = Navigator()
    @EnvironmentObject private var sessions: Sessions

    var body: some View {
        ZStack(alignment: .leading) {
            content
                .safeAreaInset(edge: .bottom) { TerminalBar() }
            if nav.menuOpen {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { nav.menuOpen = false } }
                    .transition(.opacity)
                SideMenu()
                    .frame(width: 300)
                    .transition(.move(edge: .leading))
            }
        }
        .environmentObject(nav)
    }

    @ViewBuilder private var content: some View {
        switch nav.section {
        case .hosts: HostsView(groupId: nil)
        case .sessions: SessionsView()
        case .ai: AiView()
        case .settings: SettingsView()
        case .keychain:
            NavigationView { KeychainView().toolbar { MenuButton() } }.navigationViewStyle(.stack)
        case .snippets:
            NavigationView { SnippetsView().toolbar { MenuButton() } }.navigationViewStyle(.stack)
        case .knownHosts:
            NavigationView { KnownHostsView().toolbar { MenuButton() } }.navigationViewStyle(.stack)
        }
    }
}

private struct SideMenu: View {
    @EnvironmentObject private var nav: Navigator
    @EnvironmentObject private var account: Account
    @EnvironmentObject private var sessions: Sessions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image("Logo").resizable().frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "Termoak").font(.headline)
                    Text(account.loggedIn == true
                         ? (account.server ?? "").replacingOccurrences(of: "https://", with: "")
                         : String(localized: "nav.device_only"))
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)

            Button { nav.go(.settings) } label: {
                HStack(spacing: 12) {
                    HostTile(name: account.user ?? "?", os: nil, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.loggedIn == true ? (account.user ?? String(localized: "common.connected"))
                             : String(localized: "common.log_in"))
                            .font(.subheadline).foregroundColor(.primary).lineLimit(1)
                        Text(account.loggedIn == true
                             ? (account.live ? String(localized: "nav.account.synced_live") : String(localized: "nav.account.synced"))
                             : String(localized: "nav.account.sync_hint"))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    if account.loggedIn == true {
                        Circle().fill(account.live ? Brand.green : Brand.amber).frame(width: 8, height: 8)
                    }
                }
                .padding(12)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SideMenuHeader(String(localized: "nav.header.vault"))
                    ForEach(AppSection.vault) { SideMenuEntry(section: $0) }
                    SideMenuHeader(String(localized: "nav.header.server"))
                    ForEach(AppSection.server) { s in
                        SideMenuEntry(section: s, badge: s == .ai ? account.pendingApprovals : 0)
                    }
                    if !sessions.open.isEmpty {
                        SideMenuHeader(String(localized: "nav.header.terminals"))
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { nav.menuOpen = false }
                            sessions.showing = true
                        } label: {
                            Label("nav.terminals.open \(sessions.open.count)", systemImage: "terminal")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.vertical, 12)
                        }
                        .foregroundColor(.primary)
                    }
                }
                .padding(.horizontal, 8)
            }
            Divider().padding(.horizontal, 16)
            SideMenuEntry(section: .settings).padding(.horizontal, 8).padding(.vertical, 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemBackground).ignoresSafeArea())
    }
}

private struct SideMenuHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold)).foregroundColor(.secondary)
            .padding(.leading, 16).padding(.top, 18).padding(.bottom, 4)
    }
}

private struct SideMenuEntry: View {
    let section: AppSection
    var badge = 0
    @EnvironmentObject private var nav: Navigator

    var body: some View {
        Button { nav.go(section) } label: {
            HStack(spacing: 14) {
                Image(systemName: section.icon).frame(width: 22)
                Text(section.title)
                Spacer()
                if badge > 0 {
                    Text(verbatim: "\(badge)").font(.caption2.bold()).foregroundColor(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Brand.red, in: Capsule())
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(nav.section == section ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12))
            .foregroundColor(nav.section == section ? .accentColor : .primary)
        }
    }
}

/// Open terminals, always at hand at the bottom (like Termius's connection bar).
private struct TerminalBar: View {
    @EnvironmentObject private var sessions: Sessions

    var body: some View {
        if !sessions.open.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "terminal").foregroundColor(.accentColor)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sessions.open) { s in
                            TerminalChip(session: s) { sessions.show(s.id) }
                        }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.bar)
        }
    }
}

private struct TerminalChip: View {
    @ObservedObject var session: TerminalSession
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if session.asleep {
                    Image(systemName: "icloud").font(.caption2).foregroundColor(.secondary)
                } else {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(session.title ?? session.label).font(.footnote.weight(.medium)).lineLimit(1).frame(maxWidth: 140)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .foregroundColor(.primary)
    }

    private var color: Color {
        switch session.state {
        case .connected: return Brand.green
        case .connecting: return Brand.amber
        case .closed: return Brand.red
        }
    }
}
