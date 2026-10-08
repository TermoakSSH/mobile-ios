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
