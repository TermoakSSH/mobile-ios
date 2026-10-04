import TermoakKit
import SwiftUI

/// Tabs of the quick access panel. The raw values are persisted
/// (`AppSettings.quickPanelTab`), so they keep their original values.
enum QuickPanelTab: String, CaseIterable, Identifiable {
    case keys = "teclas"
    case snippets
    case history = "historial"
    case appearance = "apariencia"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .keys: return "square.grid.2x2"
        case .snippets: return "curlybraces"
        case .history: return "clock.arrow.circlepath"
        case .appearance: return "paintpalette"
        }
    }
    var title: String {
        switch self {
        case .keys: return String(localized: "quick_panel.tab.keys")
        case .snippets: return String(localized: "quick_panel.tab.snippets")
        case .history: return String(localized: "quick_panel.tab.history")
        case .appearance: return String(localized: "quick_panel.tab.appearance")
        }
    }
}

/// Quick access panel: keys, snippets, command history and appearance one
/// tap away. On the phone it takes the place of the keyboard (with the tabs
/// at the bottom and a button to go back to the keyboard); on the tablet it
/// is a side panel (tabs at the top). It opens on the last tab used.
struct QuickPanel: View {
    @ObservedObject var session: TerminalSession
    let side: Bool
    /// Go back to the system keyboard (phone only).
    let onKeyboard: () -> Void
    let onCustomize: () -> Void
    /// Snippet with variables: they have to be asked for before using it.
    let onFill: (Snippet, Bool) -> Void

    @EnvironmentObject private var settings: AppSettings

    private var tab: QuickPanelTab { QuickPanelTab(rawValue: settings.quickPanelTab) ?? .keys }
    private var theme: TerminalTheme { settings.terminalTheme }

    var body: some View {
        VStack(spacing: 0) {
            if side { tabBar.padding(.bottom, 4) }
            Group {
                switch tab {
                case .keys: KeysTab(session: session, onCustomize: onCustomize)
                case .snippets: SnippetsTab(session: session, onFill: onFill)
                case .history: HistoryTab(session: session)
                case .appearance: AppearanceTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !side { tabBar }
        }
        .foregroundColor(theme.foregroundColor)
        .background(theme.barColor)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(QuickPanelTab.allCases) { p in
                Button { settings.quickPanelTab = p.rawValue } label: {
                    Image(systemName: p.icon)
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .foregroundColor(p == tab ? SwiftUI.Color(hex: theme.accent) : theme.foregroundColor.opacity(0.7))
                        .background(p == tab ? SwiftUI.Color(hex: theme.accent).opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .accessibilityLabel(p.title)
            }
            if !side {
                Divider().frame(height: 22).overlay(theme.foregroundColor.opacity(0.2))
                Button(action: onKeyboard) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 52, height: 38)
                        .foregroundColor(theme.foregroundColor.opacity(0.7))
                }
                .accessibilityLabel("quick_panel.back_to_keyboard")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// MARK: - Keys

private struct KeysTab: View {
    @ObservedObject var session: TerminalSession
    let onCustomize: () -> Void
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Button(action: onCustomize) {
                        Label("quick_panel.customize", systemImage: "gearshape")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(settings.terminalTheme.foregroundColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    // On wide screens, two groups per row (like the desktop).
                    let perRow = geo.size.width >= 560 ? 2 : 1
                    let groups = settings.keyboard.groups.filter { $0.visible && !$0.keys.isEmpty }
                    ForEach(Array(stride(from: 0, to: groups.count, by: perRow)), id: \.self) { i in
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(groups[i..<min(i + perRow, groups.count)]) { g in
                                KeyGroupGrid(group: g, session: session)
                            }
                            if perRow == 2 && i + 1 >= groups.count { Spacer().frame(maxWidth: .infinity) }
                        }
                    }
                }
                .padding(10)
            }
        }
    }
}

/// A group in rows of four slots; long keys take two.
private struct KeyGroupGrid: View {
    let group: KeyGroup
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var settings: AppSettings

    private var rows: [[ShortcutKey]] {
        var rows: [[ShortcutKey]] = [[]]
        var slots = 0
        for k in group.keys {
            let n = k.wide ? 2 : 1
            if slots + n > 4 { rows.append([]); slots = 0 }
            rows[rows.count - 1].append(k)
            slots += n
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundColor(settings.terminalTheme.foregroundColor.opacity(0.5))
            GeometryReader { geo in
                let slot = (geo.size.width - 6 * 3) / 4
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 6) {
                            ForEach(row) { k in
                                KeyButton(key: k, active: isActive(k)) { session.press(k) }
                                    .frame(width: k.wide ? slot * 2 + 6 : slot)
                            }
                        }
                    }
                }
            }
            .frame(height: CGFloat(rows.count) * 40 + CGFloat(max(rows.count - 1, 0)) * 6)
        }
        .frame(maxWidth: .infinity)
    }

    private func isActive(_ k: ShortcutKey) -> Bool {
        switch k.action {
        case .modifier(.ctrl): return session.ctrl
        case .modifier(.alt): return session.alt
        default: return false
        }
    }
}

struct KeyButton: View {
    let key: ShortcutKey
    var active = false
    let action: () -> Void
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Button(action: action) {
            Group {
                if let icon = key.icon {
                    Image(systemName: icon).font(.system(size: 15, weight: .medium))
                } else {
                    Text(key.title).font(.system(size: 14, weight: .medium)).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundColor(active ? SwiftUI.Color(hex: settings.terminalTheme.accent) : settings.terminalTheme.foregroundColor.opacity(0.85))
            .background(active ? SwiftUI.Color(hex: settings.terminalTheme.accent).opacity(0.3) : SwiftUI.Color(settings.terminalTheme.keyUIColor),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(key.title)
    }
}

// MARK: - Snippets

private struct SnippetsTab: View {
    @ObservedObject var session: TerminalSession
    let onFill: (Snippet, Bool) -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var list: [Snippet] = []
    @State private var search = ""
    @State private var expanded: Set<String> = []

    /// Internal bucket for snippets without tags (shown with a localized label).
    private static let noFolder = "\u{0}no-folder"

    private var filtered: [Snippet] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter { ($0.name + " " + $0.script + " " + $0.tags.joined(separator: " ")).lowercased().contains(q) }
    }

    /// Folders: the first tag of each snippet.
    private var folders: [(String, [Snippet])] {
        Dictionary(grouping: filtered) { $0.tags.first ?? Self.noFolder }
            .sorted { a, b in
                if a.key == Self.noFolder { return false }
                if b.key == Self.noFolder { return true }
                return a.key.localizedCaseInsensitiveCompare(b.key) == .orderedAscending
            }
    }

    private func folderTitle(_ name: String) -> String {
        name == Self.noFolder ? String(localized: "quick_panel.snippets.no_folder") : name
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $search)
            if list.isEmpty {
                EmptyHint(text: String(localized: "quick_panel.snippets.empty"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !search.isEmpty || folders.count == 1 {
                            ForEach(filtered, id: \.id) { row($0) }
                        } else {
                            ForEach(folders, id: \.0) { name, snippets in
                                Button {
                                    if expanded.contains(name) { expanded.remove(name) } else { expanded.insert(name) }
                                } label: {
                                    HStack {
                                        Image(systemName: "folder").foregroundColor(SwiftUI.Color(hex: settings.terminalTheme.accent))
                                        Text(folderTitle(name)).font(.subheadline.weight(.medium))
                                        Spacer()
                                        Text(verbatim: "\(snippets.count)").font(.caption).opacity(0.6)
                                        Image(systemName: expanded.contains(name) ? "chevron.up" : "chevron.down").font(.caption).opacity(0.6)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if expanded.contains(name) {
                                    ForEach(snippets, id: \.id) { row($0).padding(.leading, 18) }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear {
            list = ((try? model.core.listSnippets()) ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func row(_ sn: Snippet) -> some View {
        HStack(spacing: 10) {
            Button { use(sn, run: false) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sn.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(sn.script).font(.system(.caption, design: .monospaced)).opacity(0.6).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { use(sn, run: true) } label: {
                Image(systemName: "play.fill").font(.caption)
                    .frame(width: 34, height: 30)
                    .foregroundColor(SwiftUI.Color(hex: settings.terminalTheme.accent))
                    .background(SwiftUI.Color(settings.terminalTheme.keyUIColor), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("quick_panel.run \(sn.name)"))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func use(_ sn: Snippet, run: Bool) {
        guard snippetVariables(script: sn.script).isEmpty else {
            onFill(sn, run)
            return
        }
        if run { session.run(sn.script) } else { session.paste(sn.script) }
    }
}

// MARK: - History

private struct HistoryTab: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var commands: [CommandHistoryItem] = []
    @State private var search = ""
    @State private var clearing = false

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $search)
            if commands.isEmpty {
                EmptyHint(text: search.isEmpty
                          ? String(localized: "quick_panel.history.empty")
                          : String(localized: "quick_panel.history.no_match \(search)"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(commands, id: \.command) { c in
                            HStack(spacing: 10) {
                                Button { session.paste(c.command) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "clock").font(.caption).opacity(0.5)
                                        Text(c.command).font(.system(.subheadline, design: .monospaced)).lineLimit(1)
                                        Spacer(minLength: 0)
                                        if c.uses > 1 { Text(verbatim: "×\(c.uses)").font(.caption2).opacity(0.5) }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button { session.run(c.command) } label: {
                                    Image(systemName: "play.fill").font(.caption)
                                        .frame(width: 34, height: 30)
                                        .foregroundColor(SwiftUI.Color(hex: settings.terminalTheme.accent))
                                        .background(SwiftUI.Color(settings.terminalTheme.keyUIColor), in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text("quick_panel.run \(c.command)"))
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                        if search.isEmpty, session.hostId != nil {
                            Button("quick_panel.history.clear", role: .destructive) { clearing = true }
                                .font(.footnote)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: search) { _ in load() }
        .confirmationDialog("quick_panel.history.clear_confirm", isPresented: $clearing, titleVisibility: .visible) {
            Button("common.delete", role: .destructive) {
                try? model.core.clearCommandHistory(hostId: session.hostId)
                load()
            }
        }
    }

    private func load() {
        commands = (try? model.core.commandHistory(hostId: session.hostId, query: search, limit: 200)) ?? []
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Button { settings.changeFontSize(-1) } label: { Image(systemName: "minus").frame(width: 40, height: 36) }
                        .background(SwiftUI.Color(settings.terminalTheme.keyUIColor), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("common.font_smaller")
                    Text(verbatim: "\(Int(settings.fontSize))").font(.body.monospacedDigit()).frame(width: 34)
                    Button { settings.changeFontSize(1) } label: { Image(systemName: "plus").frame(width: 40, height: 36) }
                        .background(SwiftUI.Color(settings.terminalTheme.keyUIColor), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("common.font_larger")
                    Menu {
                        Picker("common.font", selection: $settings.fontId) {
                            ForEach(TerminalFont.all) { f in Text(f.name).tag(f.id) }
                        }
                    } label: {
                        HStack {
                            Text(settings.terminalFont.name).font(SwiftUI.Font(settings.terminalFont.ui(14))).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.caption)
                        }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(SwiftUI.Color(settings.terminalTheme.keyUIColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .buttonStyle(.plain)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 12) {
                    ForEach(TerminalTheme.all) { t in
                        Button { settings.terminalThemeId = t.id } label: { ThemeThumbnail(theme: t, selected: t.id == settings.terminalThemeId) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(10)
        }
    }
}

/// Preview of a theme: the background with a few lines in its colors.
private struct ThemeThumbnail: View {
    let theme: TerminalTheme
    let selected: Bool

    var body: some View {
        VStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 5) {
                line([(theme.ansi[2], 0.45), (theme.foreground, 0.3)])
                line([(theme.ansi[4], 0.25), (theme.foreground, 0.5)])
                line([(theme.ansi[3], 0.35), (theme.ansi[1], 0.2), (theme.foreground, 0.15)])
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(theme.backgroundColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? SwiftUI.Color(hex: theme.accent) : .gray.opacity(0.3), lineWidth: selected ? 2 : 1)
            )
            Text(theme.name).font(.caption2).lineLimit(1).opacity(selected ? 1 : 0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func line(_ pieces: [(UInt32, Double)]) -> some View {
        GeometryReader { geo in
            HStack(spacing: 4) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, p in
                    Capsule().fill(SwiftUI.Color(hex: p.0)).frame(width: geo.size.width * p.1)
                }
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Shared

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").opacity(0.5)
            TextField("common.search", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").opacity(0.5) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(SwiftUI.Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
    }
}

/// Hint shown when a tab has nothing to list (already localized text).
private struct EmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .opacity(0.6)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
