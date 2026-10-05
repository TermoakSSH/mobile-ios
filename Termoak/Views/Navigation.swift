import TermoakKit
import SwiftUI

/// Tabs of the home screen, like Termius's: the vault (hosts and what they
/// use), the open connections and your profile (account and settings).
enum HomeTab: Hashable {
    case vault, connections, profile
}

/// Sections of the vault. On the phone the hosts list is the root and the
/// others are tiles at its top; on a wide screen they go in a sidebar.
enum VaultSection: String, CaseIterable, Identifiable, Hashable {
    case hosts, keychain, portForwarding, snippets, knownHosts
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hosts: return String(localized: "nav.hosts")
        case .keychain: return String(localized: "nav.keychain")
        case .portForwarding: return String(localized: "nav.port_forwarding")
        case .snippets: return String(localized: "nav.snippets")
        case .knownHosts: return String(localized: "nav.known_hosts")
        }
    }

    var icon: String {
        switch self {
        case .hosts: return "server.rack"
        case .keychain: return "key.fill"
        case .portForwarding: return "arrow.left.arrow.right"
        case .snippets: return "chevron.left.forwardslash.chevron.right"
        case .knownHosts: return "checkmark.shield.fill"
        }
    }

    var tint: Color {
        switch self {
        case .hosts: return Brand.blue
        case .keychain: return Brand.amber
        case .portForwarding: return Brand.green
        case .snippets: return Color.purple
        case .knownHosts: return Color.teal
        }
    }

    /// The sections shown as tiles above the hosts (on the phone).
    static let shortcuts: [VaultSection] = [.keychain, .portForwarding, .snippets, .knownHosts]

    /// The screen of the section (inside a navigation view).
    @MainActor @ViewBuilder var screen: some View {
        switch self {
        case .hosts: HostsView(groupId: nil)
        case .keychain: KeychainView()
        case .portForwarding: PortForwardingView()
        case .snippets: SnippetsView()
        case .knownHosts: KnownHostsView()
        }
    }
}

/// The selected tab, so a screen can send you to another one.
@MainActor
final class HomeRouter: ObservableObject {
    @Published var tab: HomeTab = .vault
}

/// The app: Vault, Connections and Profile. A tab bar at the bottom on the
/// phone; on iPadOS 18 the same tabs go at the top on their own.
struct Home: View {
    @StateObject private var router = HomeRouter()
    @EnvironmentObject private var sessions: Sessions
    @EnvironmentObject private var account: Account

    var body: some View {
        TabView(selection: $router.tab) {
            VaultTab()
                .tabItem { Label("nav.vault", systemImage: "server.rack") }
                .tag(HomeTab.vault)
            ConnectionsView()
                .tabItem { Label("nav.connections", systemImage: "terminal") }
                .badge(sessions.open.count + account.pendingApprovals)
                .tag(HomeTab.connections)
            SettingsView()
                .tabItem { Label("nav.profile", systemImage: "person.crop.circle") }
                .tag(HomeTab.profile)
        }
        .environmentObject(router)
    }
}

/// The vault: a stack with the hosts at the root on the phone (and on an
/// iPad in a narrow split view), a sidebar with every section on an iPad.
private struct VaultTab: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: VaultSection? = .hosts

    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular {
            NavigationView {
                VaultSidebar(selection: $selection)
                HostsView(groupId: nil)
            }
            .navigationViewStyle(.columns)
        } else {
            NavigationView {
                HostsView(groupId: nil, shortcuts: true)
            }
            .navigationViewStyle(.stack)
        }
    }
}

private struct VaultSidebar: View {
    @Binding var selection: VaultSection?

    var body: some View {
        List {
            ForEach(VaultSection.allCases) { s in
                NavigationLink(tag: s, selection: $selection) {
                    s.screen
                } label: {
                    Label {
                        Text(s.title)
                    } icon: {
                        Image(systemName: s.icon).foregroundColor(s.tint)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("nav.vault")
    }
}
