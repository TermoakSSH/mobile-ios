import TermoakKit
import SwiftUI

/// The Home tab of the desktop layout: the sidebar and the chosen section
/// next to it. The sections are the same screens as on the phone.
struct DesktopHome: View {
    @Binding var section: DesktopSection
    let sidebarCollapsed: Bool
    @EnvironmentObject private var account: Accounts
    @EnvironmentObject private var sessions: Sessions
    /// For the screens that send you to a tab of the phone layout
    /// (Connections → "Go to the vault").
    @StateObject private var router = HomeRouter()

    var body: some View {
        HStack(spacing: 0) {
            DesktopSidebar(section: $section, collapsed: sidebarCollapsed)
            Divider()
            content
                .id(section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environmentObject(router)
        .onReceive(router.$tab.dropFirst()) { tab in
            switch tab {
            case .vault: section = .hosts
            case .connections: section = .serverSessions
            case .profile: section = .settings
            }
        }
        // The count of running server sessions next to Server sessions.
        .task { await sessions.refreshServer(accounts: activeAccounts) }
        .onReceive(account.changes) { kind in
            guard kind == "session" || kind == "lagged" else { return }
            Task { await sessions.refreshServer(accounts: activeAccounts) }
        }
    }

    private var activeAccounts: [String] {
        account.list.filter { $0.status == .active }.map(\.id)
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .hosts:
            HostsView(groupId: nil, desktop: true)
        case .keychain, .snippets, .portForwarding, .knownHosts:
            page {
                if let v = section.vaultSection { v.screen }
            }
        case .ai:
            page { AiView() }
        case .serverSessions:
            // It has its own navigation.
            ConnectionsView()
        case .teams:
            page { TeamsView() }
        case .vaults:
            page { VaultsView() }
        case .settings:
            SettingsView()
        }
    }

    /// A section with its own navigation (one column: the window already
    /// has the sidebar).
    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationView { content() }
            .navigationViewStyle(.stack)
    }
}

/// The sidebar: the app and the account switcher (and the vaults), the
/// sections in three groups, and the account's state at the bottom.
/// Collapsed, only the icons.
struct DesktopSidebar: View {
    @Binding var section: DesktopSection
    let collapsed: Bool
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @EnvironmentObject private var sessions: Sessions
    @EnvironmentObject private var settings: AppSettings
    @State private var addingAccount = false
    @State private var managingAccounts = false
    /// Hosts saved on This device while accounts are shown (the vault picker
    /// offers them).
    @State private var deviceItems = false

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    group(String(localized: "nav.vault"), DesktopSection.vaultGroup)
                    group(String(localized: "desktop.group.server"), DesktopSection.serverGroup)
                    group(String(localized: "desktop.group.app"), DesktopSection.appGroup)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            Divider()
            footer
        }
        .frame(width: collapsed ? 64 : 244)
        .background(Color(.secondarySystemBackground).ignoresSafeArea(edges: .bottom))
        .onAppear(perform: loadDeviceItems)
        .onReceive(account.vaultChanged) { loadDeviceItems() }
        .onReceive(account.accountsChanged) { loadDeviceItems() }
        .sheet(isPresented: $addingAccount) {
            LoginView(welcome: false) {}.environmentObject(account).environmentObject(settings)
        }
        .sheet(isPresented: $managingAccounts) {
            NavigationView { AccountsView(closable: true) }
                .environmentObject(model).environmentObject(account).environmentObject(sessions).environmentObject(settings)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image("Logo")
                    .resizable()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
                if !collapsed {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: "Termoak").font(.subheadline.weight(.semibold))
                        Text(verbatim: "v\(version)").font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            AccountSwitcher(onAdd: { addingAccount = true },
                            onManage: { managingAccounts = true },
                            onVaults: { section = .vaults },
                            expanded: !collapsed)
                .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            if !collapsed && account.showsVaults {
                VaultPicker(hasDeviceItems: deviceItems) { section = .vaults }
            }
        }
        .padding(.horizontal, collapsed ? 8 : 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: Sections

    @ViewBuilder private func group(_ title: String, _ items: [DesktopSection]) -> some View {
        if collapsed {
            Divider().padding(.vertical, 8)
        } else {
            Text(verbatim: title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.leading, 10)
                .padding(.top, 14)
                .padding(.bottom, 4)
        }
        ForEach(items) { s in item(s) }
    }

    private func item(_ s: DesktopSection) -> some View {
        let selected = section == s
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button { section = s } label: {
            HStack(spacing: 12) {
                Image(systemName: s.icon)
                    .font(.system(size: 17))
                    .frame(width: 24)
                    .overlay(alignment: .topTrailing) {
                        if collapsed, let dot = badgeDot(s) {
                            Circle().fill(dot).frame(width: 7, height: 7).offset(x: 4, y: -2)
                        }
                    }
                if !collapsed {
                    Text(verbatim: s.title).font(.body).lineLimit(1)
                    Spacer(minLength: 4)
                    trailing(s)
                }
            }
            .foregroundColor(selected ? .accentColor : .primary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: collapsed ? .center : .leading)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.clear, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(Text(verbatim: s.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Approvals waiting next to AI; a green dot with how many sessions run
    /// on the server next to Server sessions.
    @ViewBuilder private func trailing(_ s: DesktopSection) -> some View {
        switch s {
        case .ai where account.pendingApprovals > 0:
            Text(verbatim: "\(account.pendingApprovals)")
                .font(.caption2.weight(.bold))
                .foregroundColor(.black)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Brand.amber, in: Capsule())
                .accessibilityLabel(Text("desktop.ai.approvals \(account.pendingApprovals)"))
        case .serverSessions where !sessions.onServer.isEmpty:
            HStack(spacing: 4) {
                Circle().fill(Brand.green).frame(width: 7, height: 7)
                Text(verbatim: "\(sessions.onServer.count)").font(.caption).foregroundColor(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("hosts.server_sessions \(sessions.onServer.count)"))
        default:
            EmptyView()
        }
    }

    private func badgeDot(_ s: DesktopSection) -> Color? {
        switch s {
        case .ai: return account.pendingApprovals > 0 ? Brand.amber : nil
        case .serverSessions: return sessions.onServer.isEmpty ? nil : Brand.green
        default: return nil
        }
    }

    // MARK: Footer

    /// The account's state (synced, live, signed out...); it opens Settings.
    private var footer: some View {
        Button { section = .settings } label: {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                if !collapsed {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: account.current?.email ?? String(localized: "desktop.account.no_server"))
                            .font(.caption.weight(.medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        statusText.font(.caption2).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        guard account.loggedIn == true else { return account.current == nil ? Color.secondary : Brand.amber }
        return account.live ? Brand.green : Brand.amber
    }

    @ViewBuilder private var statusText: some View {
        if let current = account.current {
            if current.status != .active {
                AccountStatusText(info: current)
            } else if account.syncing {
                Text("common.syncing").foregroundColor(.secondary)
            } else {
                Text(LocalizedStringKey(account.live ? "nav.account.synced_live" : "nav.account.synced")).foregroundColor(.secondary)
            }
        } else {
            Text("accounts.device_only").foregroundColor(.secondary)
        }
    }

    private func loadDeviceItems() {
        let device = ItemFilter(accountIds: [], vaultIds: nil, includeDevice: true)
        deviceItems = !account.scoped.isEmpty && !((try? model.core.listHosts(filter: device)) ?? []).isEmpty
    }
}

/// The vault shown (like the vault chips of the phone): All, each vault,
/// This device, and Vaults to manage them.
private struct VaultPicker: View {
    let hasDeviceItems: Bool
    let onManage: () -> Void
    @EnvironmentObject private var account: Accounts

    var body: some View {
        Menu {
            Section {
                option(String(localized: "vaults.filter.all"), selected: account.vaultFilter == .all) {
                    account.vaultFilter = .all
                }
                ForEach(account.scopedVaults, id: \.key) { v in
                    option(title(v), selected: account.vaultFilter == .vault(accountId: v.accountId, vaultId: v.id)) {
                        account.vaultFilter = .vault(accountId: v.accountId, vaultId: v.id)
                    }
                }
                if hasDeviceItems {
                    option(String(localized: "accounts.this_device"), selected: account.vaultFilter == .device) {
                        account.vaultFilter = .device
                    }
                }
            }
            Button(action: onManage) { Label("vaults.title", systemImage: "lock.shield") }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundColor(tint)
                Text(verbatim: currentTitle).font(.caption.weight(.medium)).foregroundColor(.primary).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .accessibilityLabel("vaults.title")
        .accessibilityValue(Text(verbatim: currentTitle))
    }

    private func option(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected {
                Label(text, systemImage: "checkmark")
            } else {
                Text(verbatim: text)
            }
        }
    }

    private func title(_ v: VaultInfo) -> String {
        account.showsAccountBadges ? "\(v.displayName) · \(account.account(v.accountId)?.email ?? "")" : v.displayName
    }

    private var chosen: VaultInfo? {
        if case .vault(let a, let v) = account.vaultFilter { return account.vault(a, v) }
        return nil
    }

    private var currentTitle: String {
        switch account.vaultFilter {
        case .all: return String(localized: "desktop.vaults.all")
        case .device: return String(localized: "accounts.this_device")
        case .vault: return chosen.map(title) ?? String(localized: "desktop.vaults.all")
        }
    }

    private var symbol: String {
        switch account.vaultFilter {
        case .all: return "square.grid.2x2"
        case .device: return "iphone"
        case .vault: return chosen.map { vaultSymbol($0.icon, kind: $0.kind) } ?? "square.grid.2x2"
        }
    }

    private var tint: Color {
        switch account.vaultFilter {
        case .all: return Brand.blue
        case .device: return .secondary
        case .vault: return vaultColor(chosen)
        }
    }
}
