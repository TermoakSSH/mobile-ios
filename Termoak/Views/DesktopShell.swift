import TermoakKit
import SwiftUI
import UniformTypeIdentifiers

// The desktop layout: on an iPad with room (regular width: full screen, or a
// big Split View or Stage Manager window) the app looks and works like the
// desktop app. A bar of tabs at the top (Home, one tab per terminal and "+"),
// Home with a sidebar of sections, and the terminals in their tabs with the
// desktop's toolbar. A narrow window (and the phone) keeps the tab bar at the
// bottom and the terminal over everything (`Home`).

/// The sections of the sidebar, like the desktop app's: the vault, the
/// server and the app.
enum DesktopSection: String, CaseIterable, Identifiable {
    case hosts, keychain, snippets, portForwarding, knownHosts
    case ai, serverSessions, teams, vaults
    case settings

    var id: String { rawValue }

    static let vaultGroup: [DesktopSection] = [.hosts, .keychain, .snippets, .portForwarding, .knownHosts]
    static let serverGroup: [DesktopSection] = [.ai, .serverSessions, .teams, .vaults]
    static let appGroup: [DesktopSection] = [.settings]

    /// The vault screen it shows (the same as on the phone).
    var vaultSection: VaultSection? {
        switch self {
        case .hosts: return .hosts
        case .keychain: return .keychain
        case .snippets: return .snippets
        case .portForwarding: return .portForwarding
        case .knownHosts: return .knownHosts
        case .ai, .serverSessions, .teams, .vaults, .settings: return nil
        }
    }

    var title: String {
        switch self {
        case .hosts, .keychain, .snippets, .portForwarding, .knownHosts:
            return vaultSection?.title ?? ""
        case .ai: return String(localized: "desktop.section.ai")
        case .serverSessions: return String(localized: "desktop.section.server_sessions")
        case .teams: return String(localized: "desktop.section.teams")
        case .vaults: return String(localized: "vaults.title")
        case .settings: return String(localized: "shortcut.settings")
        }
    }

    var icon: String {
        switch self {
        case .hosts: return "server.rack"
        case .keychain: return "key"
        case .snippets: return "chevron.left.forwardslash.chevron.right"
        case .portForwarding: return "arrow.left.arrow.right"
        case .knownHosts: return "checkmark.shield"
        case .ai: return "sparkles"
        case .serverSessions: return "icloud"
        case .teams: return "person.3"
        case .vaults: return "lock.shield"
        case .settings: return "gearshape"
        }
    }
}

/// Whether the window gets the desktop layout: an iPad (or a Mac running
/// the iPad app) in a regular-width window.
func usesDesktopLayout(_ sizeClass: UserInterfaceSizeClass?) -> Bool {
    UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
}

/// The window in the desktop layout: the tabs on top, and Home or the
/// terminal of the chosen tab under them.
struct DesktopShell: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @EnvironmentObject private var sessions: Sessions
    @SceneStorage("desktop_section") private var section: DesktopSection = .hosts
    @AppStorage("desktop_sidebar_collapsed") private var sidebarCollapsed = false
    /// "+", ⌘T / ⌘K: connect to a host in a new tab.
    @State private var quickConnect = false

    var body: some View {
        VStack(spacing: 0) {
            DesktopTabBar(onToggleSidebar: toggleSidebar, onQuickConnect: { quickConnect = true })
            Divider()
            ZStack {
                // Home stays under the terminal (as under the full-screen
                // terminal of the phone layout): it keeps its state.
                DesktopHome(section: $section, sidebarCollapsed: sidebarCollapsed)
                    .allowsHitTesting(!sessions.showing)
                    .accessibilityHidden(sessions.showing)
                if sessions.showing {
                    TerminalScreenView(desktop: DesktopTerminalContext(
                        covered: quickConnect,
                        onHome: { sessions.showing = false },
                        onSettings: { show(.settings) },
                        onQuickConnect: { quickConnect = true }
                    ))
                }
            }
        }
        .overlay(alignment: .top) { ShareToasts(notices: sessions.notices) }
        // Off under the terminal (it has its own), the join sheet and quick connect.
        .background(DesktopHomeShortcuts(enabled: !sessions.showing && model.joining == nil && !quickConnect,
                                         onQuickConnect: { quickConnect = true },
                                         onSettings: { show(.settings) },
                                         onToggleSidebar: toggleSidebar))
        .sheet(isPresented: $quickConnect) {
            QuickConnectView { host, strict in
                // After the sheet has gone, the tab opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sessions.connect(host, strict: strict) }
            }
            .environmentObject(model)
            .environmentObject(account)
        }
    }

    /// A section of Home (from a terminal tab too).
    private func show(_ s: DesktopSection) {
        section = s
        sessions.showing = false
    }

    /// ⌃⌘S and the bar's button: shows or hides the sidebar (from a terminal
    /// tab, goes to Home with it shown).
    private func toggleSidebar() {
        if sessions.showing {
            sessions.showing = false
            sidebarCollapsed = false
        } else {
            withAnimation(.easeOut(duration: 0.2)) { sidebarCollapsed.toggle() }
        }
    }
}

// MARK: - Tabs

/// The bar of tabs: the sidebar button, Home, a tab per terminal (dragged to
/// change their order) and "+" to connect to a host.
private struct DesktopTabBar: View {
    let onToggleSidebar: () -> Void
    let onQuickConnect: () -> Void
    @EnvironmentObject private var sessions: Sessions
    /// The tab being dragged.
    @State private var dragging: UUID?

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onToggleSidebar) {
                Image(systemName: "sidebar.left")
                    .frame(width: 38, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("desktop.sidebar.toggle")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        homeTab
                        ForEach(Array(sessions.open.enumerated()), id: \.element.id) { i, s in
                            tab(s, index: i)
                        }
                        Button(action: onQuickConnect) {
                            Image(systemName: "plus")
                                .frame(width: 32, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityLabel("shortcut.quick_connect")
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: sessions.activeId) { id in
                    if let id { withAnimation { proxy.scrollTo(id) } }
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 42)
        .background(Color(.secondarySystemBackground).ignoresSafeArea(edges: .top))
    }

    private var homeTab: some View {
        let selected = !sessions.showing
        return Button { sessions.showing = false } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2").font(.caption)
                Text("desktop.home").font(.footnote.weight(selected ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .modifier(TabBackground(selected: selected))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func tab(_ s: TerminalSession, index: Int) -> some View {
        let inPane = sessions.splitActive && sessions.panes.contains(s.id)
        let selected = sessions.showing && (s.id == sessions.current?.id)
        // Next to the terminal on screen (split view), when it is not there.
        let canSplit = sessions.splitAvailable && !inPane && sessions.current.map { $0.id != s.id } == true
            && sessions.panes.count < PaneLayout.maxPanes
        return DesktopTab(session: s, selected: selected, inPane: inPane,
                          canMoveLeft: index > 0, canMoveRight: index < sessions.open.count - 1,
                          onShow: { sessions.show(s.id) },
                          onClose: { sessions.close(s.id) },
                          onMove: { sessions.moveTab(s.id, by: $0) },
                          onSplit: canSplit ? { addToSplit(s) } : nil)
            .id(s.id)
            .onDrag {
                dragging = s.id
                return NSItemProvider(object: s.id.uuidString as NSString)
            }
            .onDrop(of: [UTType.text], delegate: TabDropDelegate(target: s.id, sessions: sessions, dragging: $dragging))
    }

    /// The tab goes next to the terminal on screen.
    private func addToSplit(_ s: TerminalSession) {
        if sessions.addPane(s.id) { sessions.showing = true }
    }
}

/// A terminal's tab: its kind, its state, its name and the close button.
/// The context menu (secondary click or holding it) moves it, puts it in
/// the split view or closes it.
private struct DesktopTab: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let inPane: Bool
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let onShow: () -> Void
    let onClose: () -> Void
    let onMove: (Int) -> Void
    let onSplit: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundColor(.secondary)
            // A server session not attached yet has no state.
            if !session.asleep {
                Circle().fill(stateColor).frame(width: 7, height: 7)
            }
            Text(session.title ?? session.label)
                .font(.footnote.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 180)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("common.close")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .modifier(TabBackground(selected: selected))
        .hoverEffect(.highlight)
        .onTapGesture(perform: onShow)
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onShow)
        .accessibilityAction(named: Text("common.close"), onClose)
    }

    @ViewBuilder private var menu: some View {
        Button(action: onShow) { Label("shortcut.show_tab", systemImage: "terminal") }
        if let onSplit {
            Button(action: onSplit) { Label("desktop.tab.add_to_split", systemImage: "rectangle.split.2x1") }
        }
        if canMoveLeft {
            Button { onMove(-1) } label: { Label("desktop.tab.move_left", systemImage: "arrow.left") }
        }
        if canMoveRight {
            Button { onMove(1) } label: { Label("desktop.tab.move_right", systemImage: "arrow.right") }
        }
        Divider()
        Button(role: .destructive, action: onClose) {
            Label(session.persistent ? String(localized: "terminal.menu.close_tab_persistent") : String(localized: "common.close"),
                  systemImage: "xmark")
        }
    }

    /// Shared with you, on the server, in the split view or a terminal.
    private var icon: String {
        if !session.isOwner { return "person.2" }
        if session.persistent { return "icloud" }
        if inPane { return "rectangle.split.2x1" }
        return "terminal"
    }

    private var stateColor: Color {
        switch session.state {
        case .connected: return Brand.green
        case .connecting: return Brand.amber
        case .closed: return Brand.red
        }
    }
}

/// The look of a tab: the chosen one stands out.
private struct TabBackground: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        content
            .frame(height: 30)
            .background(selected ? Color(.systemBackground) : Color.clear, in: shape)
            .overlay(shape.strokeBorder(selected ? Color(.separator) : Color.clear, lineWidth: 1))
            .contentShape(shape)
    }
}

/// A dragged tab takes the place of the one it goes over.
@MainActor
private struct TabDropDelegate: DropDelegate {
    let target: UUID
    let sessions: Sessions
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let moving = dragging, moving != target,
              let to = sessions.open.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.easeOut(duration: 0.15)) { sessions.moveTab(moving, to: to) }
    }

    /// Only tabs of this bar (not text from other apps).
    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
