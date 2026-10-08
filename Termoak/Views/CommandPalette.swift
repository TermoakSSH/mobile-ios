import TermoakKit
import SwiftUI

// MARK: - Quick connect and the command palette

/// An action a screen adds to the palette (go to a section, a new host...).
struct PaletteAction {
    let key: String
    let title: String
    var detail = ""
    let symbol: String
    var keywords: [String] = []
    let run: () -> Void
}

/// ⌘K / ⌘T (and the bolt button): quick connect, extended into a command
/// palette like the desktop's. Type to find a host, an open tab, a session
/// on the server, a snippet (run in the terminal in view) or an action of
/// the app; ↑/↓ choose, Return opens it, Esc closes. The ranking is the
/// engine's (`paletteRank`, fuzzy, the ones chosen lately first) and an
/// address typed (`user@host:port`, `telnet://…`) that no host matches
/// connects to it.
struct QuickConnectView: View {
    /// The chosen host and whether it opens through its server (Strict
    /// Use-only), called once the sheet is closing.
    let onConnect: (SshHost, Bool) -> Void
    /// Actions of the screen that opened it.
    let actions: [PaletteAction]
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hosts: [SshHost] = []
    @State private var items: [PaletteItem] = []
    @State private var highlighted: String?
    @State private var error: String?

    init(onConnect: @escaping (SshHost, Bool) -> Void, actions: [PaletteAction] = []) {
        self.onConnect = onConnect
        self.actions = actions
    }

    private var matches: [PaletteItem] {
        let ranked = paletteRank(query: query, entries: items.map(\.entry), recent: model.settings.paletteRecent)
        return ranked.compactMap { m in Int(m.index) < items.count ? items[Int(m.index)] : nil }
    }

    /// An address typed in the search when no saved host matches it.
    private func quickTarget(_ list: [PaletteItem]) -> QuickTarget? {
        guard !list.contains(where: { $0.entry.kind == .host }) else { return nil }
        return QuickTarget.parse(query)
    }

    private static let quickKey = "quick"

    /// The highlighted row (the first one until ↑/↓ choose another).
    private func current(_ keys: [String]) -> String? {
        if let highlighted, keys.contains(highlighted) { return highlighted }
        return keys.first
    }

    var body: some View {
        let list = matches
        let target = quickTarget(list)
        let keys = (target == nil ? [] : [Self.quickKey]) + list.map(\.entry.key)
        let chosen = current(keys)
        return NavigationView {
            VStack(spacing: 0) {
                searchField(list, target, keys, chosen)
                rows(list, target, chosen)
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
        .onAppear(perform: load)
        .alert("host_editor.save_failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func searchField(_ list: [PaletteItem], _ target: QuickTarget?, _ keys: [String], _ chosen: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            KeyTextField(placeholder: String(localized: "palette.placeholder"), text: $query,
                         onSubmit: { choose(chosen, list, target) },
                         onEscape: { dismiss() },
                         onArrow: { up in highlighted = moveHighlight(chosen, in: keys, up ? .up : .down) })
                .frame(maxWidth: .infinity, minHeight: 22)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(SwiftUI.Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func rows(_ list: [PaletteItem], _ target: QuickTarget?, _ chosen: String?) -> some View {
        ScrollViewReader { proxy in
            List {
                if let target {
                    Button { quickConnect(target) } label: { quickRow(target, chosen == Self.quickKey) }
                        .buttonStyle(.plain)
                        .listRowBackground(keyboardHighlight(chosen == Self.quickKey))
                        .id(Self.quickKey)
                }
                ForEach(list, id: \.entry.key) { item in
                    Button { perform(item) } label: { PaletteRow(item: item, chosen: item.entry.key == chosen) }
                        .buttonStyle(.plain)
                        .listRowBackground(keyboardHighlight(item.entry.key == chosen))
                        .id(item.entry.key)
                }
            }
            .listStyle(.plain)
            .overlay {
                if list.isEmpty && target == nil {
                    Text(hosts.isEmpty && query.isEmpty ? String(localized: "quick_connect.no_hosts") : String(localized: "palette.no_matches"))
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

    /// "Connect to telnet://router:2323" (saved as a new host first).
    private func quickRow(_ t: QuickTarget, _ chosen: Bool) -> some View {
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
            if chosen { Image(systemName: "return").font(.caption).foregroundColor(.secondary) }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: Entries

    private func load() {
        hosts = (try? model.core.listHosts(filter: account.hostFilter)) ?? []
        let sessions = model.sessions
        var out: [PaletteItem] = sessions.open.map(PaletteItem.tab)
        out += hosts.map(PaletteItem.host)
        out += sessions.onServer.filter { sessions.tab(forSession: $0.session.id) == nil }.map { s in
            PaletteItem.session(s, label: sessionLabel(s))
        }
        if sessions.current != nil {
            let snippets = (try? model.core.listSnippets(filter: account.hostFilter)) ?? []
            out += snippets.map(PaletteItem.snippet)
        }
        let state = PaletteCommand.State(tabs: sessions.open.count, terminalShown: sessions.showing,
                                         splitAvailable: sessions.splitAvailable, splitActive: sessions.splitActive)
        out += PaletteCommand.available(state).map(PaletteItem.command)
        out += actions.enumerated().map { i, a in PaletteItem.action(a, index: i) }
        items = out
    }

    private func sessionLabel(_ s: AccountSession) -> String {
        if !s.session.title.isEmpty { return s.session.title }
        let host = s.session.hostId.flatMap { try? model.core.getHost(id: $0, accountId: s.accountId) }
        return host?.displayName ?? String(localized: "common.session")
    }

    // MARK: Choosing

    private func choose(_ key: String?, _ list: [PaletteItem], _ target: QuickTarget?) {
        if key == Self.quickKey, let target {
            quickConnect(target)
        } else if let item = list.first(where: { $0.entry.key == key }) {
            perform(item)
        }
    }

    private func perform(_ item: PaletteItem) {
        let key = item.entry.key
        if PaletteKey.remembered(key) {
            model.settings.paletteRecent = paletteRemember(recent: model.settings.paletteRecent, key: key)
        }
        if case .host(let h) = item.target {
            connect(h)
            return
        }
        dismiss()
        let sessions = model.sessions
        let settings = model.settings
        let actions = actions
        // After the sheet has gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            switch item.target {
            case .tab(let id): sessions.show(id)
            case .host: break
            case .session(let s, let label):
                sessions.attach(sessionId: s.session.id, label: label, hostId: s.session.hostId, accountId: s.accountId)
            case .snippet(let snippet):
                if let terminal = sessions.current {
                    sessions.show(terminal.id)
                    terminal.run(snippet.script)
                }
            case .command(let c): Self.run(c, sessions, settings)
            case .action(let i): if i < actions.count { actions[i].run() }
            }
        }
    }

    private static func run(_ c: PaletteCommand, _ sessions: Sessions, _ settings: AppSettings) {
        switch c {
        case .home: sessions.showing = false
        case .nextTab: sessions.showAdjacent(1)
        case .closeTab: if let s = sessions.current { sessions.close(s.id) }
        case .addToSplit: _ = sessions.addPane()
        case .focusMode: sessions.toggleFocusMode()
        case .broadcast: sessions.toggleBroadcast()
        case .zoomIn: settings.changeFontSize(1)
        case .zoomOut: settings.changeFontSize(-1)
        case .zoomReset: settings.fontSize = AppSettings.defaultFontSize
        case .toggleTheme: settings.appTheme = settings.appTheme == .light ? .dark : .light
        }
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

/// An entry of the palette and what choosing it does.
struct PaletteItem {
    enum Target {
        case tab(UUID)
        case host(SshHost)
        case session(AccountSession, label: String)
        case snippet(Snippet)
        case command(PaletteCommand)
        /// An action of the screen (its index).
        case action(Int)
    }

    let entry: PaletteEntry
    let symbol: String
    let target: Target
    var host: SshHost?

    @MainActor static func tab(_ s: TerminalSession) -> PaletteItem {
        PaletteItem(entry: PaletteEntry(key: PaletteKey.tab(s.id), kind: .tab, title: s.displayTitle,
                                        detail: String(localized: "palette.kind.tab"), keywords: [s.label]),
                    symbol: "terminal", target: .tab(s.id))
    }

    static func host(_ h: SshHost) -> PaletteItem {
        PaletteItem(entry: PaletteEntry(key: PaletteKey.host(h.key), kind: .host, title: h.displayName,
                                        detail: hostSubtitle(h), keywords: h.tags + [h.address, h.settings.username ?? ""]),
                    symbol: "server.rack", target: .host(h), host: h)
    }

    static func session(_ s: AccountSession, label: String) -> PaletteItem {
        PaletteItem(entry: PaletteEntry(key: PaletteKey.session(s.id), kind: .session, title: label,
                                        detail: String(localized: "palette.kind.session")),
                    symbol: "icloud", target: .session(s, label: label))
    }

    static func snippet(_ s: Snippet) -> PaletteItem {
        let first = s.script.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return PaletteItem(entry: PaletteEntry(key: PaletteKey.snippet(s.key), kind: .snippet, title: s.name,
                                               detail: first, keywords: s.tags),
                           symbol: "chevron.left.forwardslash.chevron.right", target: .snippet(s))
    }

    static func command(_ c: PaletteCommand) -> PaletteItem {
        PaletteItem(entry: PaletteEntry(key: c.key, kind: .command, title: c.title,
                                        detail: String(localized: "palette.kind.command"), keywords: c.keywords),
                    symbol: c.symbol, target: .command(c))
    }

    static func action(_ a: PaletteAction, index: Int) -> PaletteItem {
        PaletteItem(entry: PaletteEntry(key: a.key, kind: .command, title: a.title,
                                        detail: a.detail.isEmpty ? String(localized: "palette.kind.command") : a.detail,
                                        keywords: a.keywords),
                    symbol: a.symbol, target: .action(index))
    }
}

/// A row of the palette: the host's icon (or the kind's), title and detail.
private struct PaletteRow: View {
    let item: PaletteItem
    let chosen: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.entry.title).font(.body.weight(.medium)).foregroundColor(.primary).lineLimit(1)
                if !item.entry.detail.isEmpty {
                    Text(verbatim: item.entry.detail).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if chosen { Image(systemName: "return").font(.caption).foregroundColor(.secondary) }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        if let h = item.host {
            HostIcon(host: h, size: 32)
        } else {
            Image(systemName: item.symbol)
                .font(.system(size: 17))
                .foregroundColor(.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
