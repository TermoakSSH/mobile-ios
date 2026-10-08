import TermoakKit
import SwiftTerm
import SwiftUI

// App shortcuts of a hardware keyboard, listed by name when ⌘ is held on an
// iPad. They are invisible buttons with `.keyboardShortcut`; they only use ⌘
// (and Ctrl+Tab to change tabs), so Ctrl and Option stay for the terminal.
// A screen covered by a sheet turns its own off (`enabled`): SwiftUI keeps
// the shortcuts of the presenting screen active.

/// Invisible button that only carries a keyboard shortcut.
struct ShortcutButton: View {
    let title: String
    let key: KeyEquivalent
    var modifiers: EventModifiers = .command
    let action: () -> Void

    var body: some View {
        Button(title, action: action).keyboardShortcut(key, modifiers: modifiers)
    }
}

/// Holds shortcut buttons out of sight.
struct ShortcutLayer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack { content }
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Terminal

/// Shortcuts of the terminal screen: ⌘T / ⌘K connect to a host in a new
/// tab, ⌘W closes the tab, ⌘⇧] / ⌘⇧[ and Ctrl+Tab / Ctrl+⇧Tab change tabs,
/// ⌘1…⌘9 pick one, ⌘F finds, ⌘+ / ⌘- / ⌘0 zoom, ⌘. sends Esc, ⌘↩ turns
/// a `# request` into a command and ⌘, opens Settings. In the desktop layout (`onHome`) also ⌃⌘H for the Home
/// tab (⌘H and ⌘⇧H are the system's) and Ctrl+⇧PgUp / Ctrl+⇧PgDn to move
/// the tab.
struct TerminalShortcuts: View {
    let session: TerminalSession
    let enabled: Bool
    let onQuickConnect: () -> Void
    let onFind: () -> Void
    let onSettings: () -> Void
    var onHome: (() -> Void)? = nil
    /// ⌘/: the list of shortcuts.
    var onShortcuts: (() -> Void)? = nil
    @EnvironmentObject private var sessions: Sessions
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        if enabled {
            ShortcutLayer {
                tabShortcuts
                TabSwitchShortcuts()
                otherShortcuts
                if let onHome { desktopShortcuts(onHome) }
            }
        }
    }

    @ViewBuilder private var tabShortcuts: some View {
        ShortcutButton(title: String(localized: "shortcut.new_terminal"), key: "t", action: onQuickConnect)
        ShortcutButton(title: String(localized: "shortcut.quick_connect"), key: "k", action: onQuickConnect)
        ShortcutButton(title: String(localized: "shortcut.close_tab"), key: "w") { sessions.close(session.id) }
    }

    @ViewBuilder private func desktopShortcuts(_ onHome: @escaping () -> Void) -> some View {
        ShortcutButton(title: String(localized: "desktop.home"), key: "h", modifiers: [.command, .control], action: onHome)
        ShortcutButton(title: String(localized: "desktop.tab.move_left"), key: .pageUp, modifiers: [.control, .shift]) {
            sessions.moveTab(session.id, by: -1)
        }
        ShortcutButton(title: String(localized: "desktop.tab.move_right"), key: .pageDown, modifiers: [.control, .shift]) {
            sessions.moveTab(session.id, by: 1)
        }
    }

    @ViewBuilder private var otherShortcuts: some View {
        ShortcutButton(title: String(localized: "shortcut.find"), key: "f", action: onFind)
        ShortcutButton(title: String(localized: "shortcut.zoom_in"), key: "=") { settings.changeFontSize(1) }
        ShortcutButton(title: String(localized: "shortcut.zoom_in"), key: "+") { settings.changeFontSize(1) }
        ShortcutButton(title: String(localized: "shortcut.zoom_out"), key: "-") { settings.changeFontSize(-1) }
        ShortcutButton(title: String(localized: "shortcut.zoom_reset"), key: "0") {
            settings.fontSize = AppSettings.defaultFontSize
        }
        ShortcutButton(title: String(localized: "shortcut.send_escape"), key: ".") {
            // Only while typing in the terminal (not in the copilot's box).
            if session.view.isFirstResponder { session.input(Data([0x1B])) }
        }
        ShortcutButton(title: String(localized: "shortcut.settings"), key: ",", action: onSettings)
        // `# request` at the prompt → the AI's command, typed (not run).
        ShortcutButton(title: String(localized: "shortcut.ai_command"), key: .return) {
            if session.view.isFirstResponder { session.assist.askForLine() }
        }
        if let onShortcuts {
            ShortcutButton(title: String(localized: "shortcuts.title"), key: "/", action: onShortcuts)
        }
    }

}

/// ⌘⇧] / ⌘⇧[ and Ctrl+Tab / Ctrl+⇧Tab: the next or previous tab; ⌘1…⌘8 the
/// tab in that place and ⌘9 the last one, with their names. In the terminal,
/// and in the Home tab of the desktop layout.
struct TabSwitchShortcuts: View {
    @EnvironmentObject private var sessions: Sessions

    var body: some View {
        ShortcutButton(title: String(localized: "shortcut.next_tab"), key: "]", modifiers: [.command, .shift]) {
            sessions.showAdjacent(1)
        }
        ShortcutButton(title: String(localized: "shortcut.previous_tab"), key: "[", modifiers: [.command, .shift]) {
            sessions.showAdjacent(-1)
        }
        ShortcutButton(title: String(localized: "shortcut.next_tab"), key: .tab, modifiers: .control) {
            sessions.showAdjacent(1)
        }
        ShortcutButton(title: String(localized: "shortcut.previous_tab"), key: .tab, modifiers: [.control, .shift]) {
            sessions.showAdjacent(-1)
        }
        let tabs = Array(sessions.open.prefix(8).enumerated())
        ForEach(tabs, id: \.element.id) { i, s in
            ShortcutButton(title: s.displayTitle, key: KeyEquivalent(Character("\(i + 1)"))) {
                sessions.showTab(number: i + 1)
            }
        }
        if sessions.open.count >= 9, let last = sessions.open.last {
            ShortcutButton(title: last.displayTitle, key: "9") { sessions.showTab(number: 9) }
        }
    }
}

/// ⌘F: finds text in the terminal (the screen and its history). Return or
/// ⌘G go to the next match, Shift+Return or ⌘⇧G to the previous one, Esc
/// closes it.
struct TerminalFindBar: View {
    @ObservedObject var session: TerminalSession
    let onClose: () -> Void
    @State private var text = ""
    @State private var index = 0
    @State private var total = 0

    var body: some View {
        let theme = session.theme
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            KeyTextField(placeholder: String(localized: "find.placeholder"), text: $text,
                         onSubmit: { find(forward: true) },
                         onShiftSubmit: { find(forward: false) },
                         onEscape: close)
                .frame(maxWidth: .infinity)
            if !text.isEmpty {
                Text(total == 0 ? String(localized: "find.none") : "\(index)/\(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Button { find(forward: false) } label: {
                Label("find.previous", systemImage: "chevron.up").labelStyle(.iconOnly).frame(width: 30, height: 30)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(text.isEmpty)
            .hoverEffect()
            Button { find(forward: true) } label: {
                Label("find.next", systemImage: "chevron.down").labelStyle(.iconOnly).frame(width: 30, height: 30)
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(text.isEmpty)
            .hoverEffect()
            Button("common.done", action: close)
                .hoverEffect()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.barColor)
        .environment(\.colorScheme, theme.isLight ? .light : .dark)
        .onChange(of: text) { _ in
            session.view.clearSearch()
            find(forward: true)
        }
    }

    private func find(forward: Bool) {
        guard !text.isEmpty else {
            index = 0
            total = 0
            return
        }
        let view = session.view
        if forward { view.findNext(text) } else { view.findPrevious(text) }
        let summary = view.searchMatchSummary(text)
        index = summary.index
        total = summary.total
    }

    private func close() {
        session.view.clearSearch()
        onClose()
        _ = session.view.becomeFirstResponder()
    }
}

// MARK: - Home

/// Shortcuts of the home screen: ⌘K / ⌘T connect to a host, ⌘1–⌘3 the
/// tabs (Vault, Connections, Profile) and ⌘, the settings (Profile).
struct HomeShortcuts: View {
    let enabled: Bool
    let onQuickConnect: () -> Void
    @EnvironmentObject private var router: HomeRouter

    var body: some View {
        if enabled {
            ShortcutLayer {
                ShortcutButton(title: String(localized: "shortcut.quick_connect"), key: "k", action: onQuickConnect)
                ShortcutButton(title: String(localized: "shortcut.new_terminal"), key: "t", action: onQuickConnect)
                ShortcutButton(title: String(localized: "nav.vault"), key: "1") { router.tab = .vault }
                ShortcutButton(title: String(localized: "nav.connections"), key: "2") { router.tab = .connections }
                ShortcutButton(title: String(localized: "nav.profile"), key: "3") { router.tab = .profile }
                ShortcutButton(title: String(localized: "shortcut.settings"), key: ",") { router.tab = .profile }
            }
        }
    }
}

/// Shortcuts of the Home tab of the desktop layout: ⌘K / ⌘T connect to a
/// host, the tab shortcuts of the terminal (⌘1…⌘9, ⌘⇧] / ⌘⇧[, Ctrl+Tab),
/// ⌘, Settings and ⌃⌘S shows or hides the sidebar.
struct DesktopHomeShortcuts: View {
    let enabled: Bool
    let onQuickConnect: () -> Void
    let onSettings: () -> Void
    let onToggleSidebar: () -> Void

    var body: some View {
        if enabled {
            ShortcutLayer {
                ShortcutButton(title: String(localized: "shortcut.quick_connect"), key: "k", action: onQuickConnect)
                ShortcutButton(title: String(localized: "shortcut.new_terminal"), key: "t", action: onQuickConnect)
                TabSwitchShortcuts()
                ShortcutButton(title: String(localized: "shortcut.settings"), key: ",", action: onSettings)
                ShortcutButton(title: String(localized: "desktop.sidebar.toggle"), key: "s", modifiers: [.command, .control],
                               action: onToggleSidebar)
            }
        }
    }
}

// MARK: - Quick connect

/// ⌘K / ⌘T: type to find a host and connect to it (↑/↓ choose, Return
/// connects, Esc closes). The terminal opens in a new tab.
struct QuickConnectView: View {
    /// The chosen host and whether it opens through its server (Strict
    /// Use-only), called once the sheet is closing.
    let onConnect: (SshHost, Bool) -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hosts: [SshHost] = []
    @State private var highlighted: String?
    @State private var error: String?

    /// An address typed in the search (`user@host:port`,
    /// `telnet://[user@]host[:port]`...) when no saved host matches it.
    private var quickTarget: QuickTarget? {
        guard results.isEmpty else { return nil }
        return QuickTarget.parse(query)
    }

    private var results: [SshHost] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? hosts : hosts.filter { h in
            [h.label, h.address, h.settings.username ?? "", h.tags.joined(separator: " ")]
                .contains { $0.lowercased().contains(q) }
        }
        return list.sorted { a, b in
            if a.favorite != b.favorite { return a.favorite }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    /// The highlighted host (the first one until ↑/↓ choose another).
    private var current: String? {
        let keys = results.map(\.key)
        if let highlighted, keys.contains(highlighted) { return highlighted }
        return keys.first
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    KeyTextField(placeholder: String(localized: "quick_connect.prompt"), text: $query,
                                 onSubmit: connectCurrent,
                                 onEscape: { dismiss() },
                                 onArrow: { up in highlighted = moveHighlight(current, in: results.map(\.key), up ? .up : .down) })
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(SwiftUI.Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 16).padding(.vertical, 10)
                list
            }
            .navigationTitle("quick_connect.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { hosts = (try? model.core.listHosts(filter: account.hostFilter)) ?? [] }
        .alert("host_editor.save_failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                if let target = quickTarget {
                    Button { quickConnect(target) } label: { quickRow(target) }
                        .buttonStyle(.plain)
                        .listRowBackground(keyboardHighlight(true))
                }
                ForEach(results, id: \.key) { h in
                    Button { connect(h) } label: { row(h) }
                        .buttonStyle(.plain)
                        .listRowBackground(keyboardHighlight(h.key == current))
                        .id(h.key)
                }
            }
            .listStyle(.plain)
            .overlay {
                if results.isEmpty && quickTarget == nil {
                    Text(hosts.isEmpty ? String(localized: "quick_connect.no_hosts") : String(localized: "hosts.search.no_results \(query)"))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .onChange(of: highlighted) { key in
                if let key { proxy.scrollTo(key) }
            }
        }
    }

    private func row(_ h: SshHost) -> some View {
        HStack(spacing: 12) {
            HostIcon(host: h, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.displayName).font(.body.weight(.medium)).foregroundColor(.primary).lineLimit(1)
                Text(hostSubtitle(h)).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if h.key == current {
                Image(systemName: "return").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// "Connect to telnet://router:2323" (saved as a new host first).
    private func quickRow(_ t: QuickTarget) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(t.isTelnet ? Brand.amber : .accentColor)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("quick_connect.connect_to \(t.display)")
                    .font(.body.weight(.medium)).foregroundColor(.primary).lineLimit(1)
                Text("quick_connect.saved_as_host").font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            if t.isTelnet { TelnetBadge() }
            Spacer(minLength: 0)
            Image(systemName: "return").font(.caption).foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func connectCurrent() {
        if let target = quickTarget {
            quickConnect(target)
            return
        }
        guard let key = current, let h = results.first(where: { $0.key == key }) else { return }
        connect(h)
    }

    /// Connects to a typed address: to the saved host with that address,
    /// protocol, user and port if there is one; otherwise it is saved as a
    /// new host first (so its password, fingerprint and history have a
    /// place), like the desktop's quick connect.
    private func quickConnect(_ t: QuickTarget) {
        do {
            connect(try account.quickConnectHost(t, among: hosts))
        } catch {
            self.error = userMessage(error)
        }
    }

    private func connect(_ h: SshHost) {
        let strict = h.isUseOnly && account.isStrict(accountId: h.accountId, vaultId: h.vaultId)
        dismiss()
        onConnect(h, strict)
    }
}
