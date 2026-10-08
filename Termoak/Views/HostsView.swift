import TermoakKit
import SwiftUI
import UniformTypeIdentifiers

/// Hosts in the style of Termius: search, groups as rows above the hosts and
/// each host with its colored avatar. Tapping a host connects; holding it or
/// swiping shows its actions. "Select" picks several to connect to them at
/// once, move them to a group or a vault, or delete them. With `groupId`,
/// the contents of a group. With `shortcuts` (the root of the vault on the
/// phone), the other sections of the vault go as tiles at the top. At the
/// root, the account switcher and the vault chips. With `desktop` (iPad,
/// regular width) it is the desktop app's Hosts view instead: a header with
/// the search and the buttons, group chips and the hosts as cards in a grid,
/// and the host editor in a panel on the right.
struct HostsView: View {
    let groupId: String?
    /// Account of the group (`nil`: This device, or the root).
    var groupAccountId: String? = nil
    var shortcuts = false
    /// The desktop layout's grid (only at the root).
    var desktop = false

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @EnvironmentObject private var sessions: Sessions
    @EnvironmentObject private var settings: AppSettings

    @State private var hosts: [SshHost] = []
    @State private var groups: [HostGroup] = []
    @State private var deviceItems = false
    @State private var counts: [VaultSection: Int] = [:]
    @State private var query = ""
    @State private var editing: HostEdit?
    @State private var filesHost: SshHost?
    @State private var tunnelsHost: SshHost?
    @State private var deleting: SshHost?
    @State private var editedGroup: GroupEdit?
    @State private var deletingGroup: HostGroup?
    @State private var generatingKey = false
    @State private var importingKey = false
    @State private var importingConfig = false
    @State private var transferring: TransferRequest?
    @State private var addingAccount = false
    /// An account to sign in again, or whose email code is pending.
    @State private var resuming: AccountInfo?
    @State private var managingAccounts = false
    @State private var showingVaults = false
    @State private var notice: Notice?
    /// Selecting several hosts (by `SshHost.key`).
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<String> = []
    @State private var deletingSelection = false
    /// Host highlighted with a hardware keyboard (by `SshHost.key`).
    @State private var cursor: String?
    @ObservedObject private var keyboard = HardwareKeyboard.shared
    /// Desktop layout: the chip chosen above the grid.
    @State private var chip: HostChip = .all
    /// Desktop layout: cards per row (for ↑/↓).
    @State private var gridColumns = 1
    @FocusState private var searchFocused: Bool

    private var selecting: Bool { editMode.isEditing }
    private var isRoot: Bool { groupId == nil }

    /// The list selects only while selecting.
    private var selectionBinding: Binding<Set<String>>? {
        selecting ? $selection : nil
    }

    /// The selected hosts, in the order of the list.
    private var selectedHosts: [SshHost] {
        hosts.filter { selection.contains($0.key) }.sorted(by: listOrder)
    }

    private var group: HostGroup? { groups.first { $0.id == groupId && $0.accountId == groupAccountId } }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Groups whose hosts are shown inside them (of the same account).
    private func hasGroup(_ h: SshHost) -> Bool {
        groups.contains { $0.id == h.groupId && $0.accountId == h.accountId }
    }

    private var visible: [SshHost] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return hosts.filter { h in
            if searching {
                return [h.label, h.address, h.settings.username ?? "", h.tags.joined(separator: " ")]
                    .contains { $0.lowercased().contains(q) }
            }
            if let groupId { return h.groupId == groupId && h.accountId == groupAccountId }
            return !hasGroup(h)
        }
        .sorted(by: listOrder)
    }

    /// Favorites first, then by name.
    private func listOrder(_ a: SshHost, _ b: SshHost) -> Bool {
        if a.favorite != b.favorite { return a.favorite }
        return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
    }

    private var subgroups: [HostGroup] {
        guard !searching else { return [] }
        return groups.filter { g in
            if let groupId { return g.parentId == groupId && g.accountId == groupAccountId }
            return g.parentId == nil || !groups.contains { $0.id == g.parentId && $0.accountId == g.accountId }
        }
    }

    private func totalIn(_ g: HostGroup) -> Int {
        hosts.filter { $0.groupId == g.id && $0.accountId == g.accountId }.count
            + groups.filter { $0.parentId == g.id && $0.accountId == g.accountId }.reduce(0) { $0 + totalIn($1) }
    }

    /// With several accounts at the root, the hosts go in a section per
    /// account (This device first).
    private var sections: [HostSection] {
        let list = visible
        guard isRoot, account.showsAccountBadges, !searching else {
            return list.isEmpty ? [] : [HostSection(id: "all", title: searching ? String(localized: "hosts.results") : String(localized: "nav.hosts"), hosts: list)]
        }
        var out: [HostSection] = []
        let device = list.filter { $0.accountId == nil }
        if !device.isEmpty {
            out.append(HostSection(id: "device", title: String(localized: "accounts.this_device"), hosts: device))
        }
        for a in account.list {
            let mine = list.filter { $0.accountId == a.id }
            if !mine.isEmpty { out.append(HostSection(id: a.id, title: a.email, hosts: mine)) }
        }
        return out
    }

    private var title: String {
        if let group { return group.name }
        return shortcuts ? String(localized: "nav.vault") : String(localized: "nav.hosts")
    }

    var body: some View {
        // Split in parts: as one expression it is too much for the type checker.
        withDialogs(withSheets(withToolbar(content)))
        .onAppear {
            load()
            if isRoot { account.sync() }
        }
        .onReceive(account.vaultChanged) { load() }
        .onChange(of: account.vaultFilter) { _ in load() }
        .task {
            if isRoot { await sessions.refreshServer(accounts: activeAccounts) }
        }
        .onReceive(account.changes) { kind in
            guard isRoot, kind == "session" || kind == "lagged" else { return }
            Task { await sessions.refreshServer(accounts: activeAccounts) }
        }
    }

    // The toolbar in a .toolbar closure (not a @ToolbarContentBuilder property:
    // its if/else needs iOS 16 there).
    private func withToolbar<V: View>(_ view: V) -> some View {
        view.toolbar {
                if selecting {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(selectAllTitle) { toggleSelectAll() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.done") { endSelection() }
                    }
                    ToolbarItemGroup(placement: .bottomBar) { selectionActions }
                } else {
                    if isRoot {
                        ToolbarItem(placement: .navigationBarLeading) {
                            AccountSwitcher(onAdd: { addingAccount = true },
                                            onManage: { managingAccounts = true },
                                            onVaults: { showingVaults = true })
                        }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        if account.syncing {
                            ProgressView()
                        } else if account.list.contains(where: { $0.status == .active }) && isRoot {
                            Button { account.sync() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                                .accessibilityLabel("settings.sync")
                        }
                        if !hosts.isEmpty {
                            Button { startSelection(nil) } label: { Image(systemName: "checkmark.circle") }
                                .accessibilityLabel("hosts.select")
                        }
                        addMenu
                    }
                }
        }
    }

    private func withSheets<V: View>(_ view: V) -> some View {
        view
        // In the desktop layout the editor is a panel on the right.
        .sheet(item: Binding(get: { desktop ? nil : editing }, set: { editing = $0 }), onDismiss: load) { e in
            HostEditor(original: e.host, initialGroup: groupId, initialPlace: newPlace) { saved in
                // After the sheet has gone, the terminal comes up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { connect(saved, onServer: false) }
            }
            .environmentObject(model).environmentObject(account).environmentObject(sessions)
        }
        .sheet(item: $editedGroup, onDismiss: load) { e in
            GroupEditor(original: e.group).environmentObject(model).environmentObject(account)
        }
        .sheet(isPresented: $generatingKey, onDismiss: load) {
            GenerateKeyView().environmentObject(model).environmentObject(account)
        }
        .sheet(isPresented: $importingKey, onDismiss: load) {
            ImportKeyView().environmentObject(model).environmentObject(account)
        }
        .sheet(item: $transferring, onDismiss: load) { r in
            TransferView(request: r).environmentObject(model).environmentObject(account)
        }
        .sheet(isPresented: $addingAccount) {
            LoginView(welcome: false) {}.environmentObject(account).environmentObject(settings)
        }
        .sheet(item: Binding(get: { resuming.map(ResumeItem.init) }, set: { resuming = $0?.account })) { r in
            LoginView(welcome: false, resume: r.account) {}.environmentObject(account).environmentObject(settings)
        }
        .sheet(isPresented: $managingAccounts) {
            NavigationView { AccountsView(closable: true) }
                .environmentObject(model).environmentObject(account).environmentObject(sessions).environmentObject(settings)
        }
        .sheet(isPresented: $showingVaults, onDismiss: load) {
            NavigationView { VaultsView(closable: true) }
                .environmentObject(model).environmentObject(account)
        }
        .fullScreenCover(item: Binding(get: { filesHost.map(SelectedHost.init) }, set: { filesHost = $0?.host })) { e in
            FilesScreen(core: model.core, title: e.host.displayName,
                        source: filesSource(e.host))
        }
        .sheet(item: Binding(get: { tunnelsHost.map(SelectedHost.init) }, set: { tunnelsHost = $0?.host }), onDismiss: load) { e in
            TunnelsView(host: e.host)
        }
        .fileImporter(isPresented: $importingConfig, allowedContentTypes: [.item]) { result in
            importSshConfig(result)
        }
    }

    private func withDialogs<V: View>(_ view: V) -> some View {
        view
        .confirmationDialog(Text("hosts.delete.title \(deleting?.label ?? "")"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("common.delete", role: .destructive) { if let h = deleting { delete(h) } }
        } message: { Text(deleteMessage(deleting.map { [$0] } ?? [])) }
        .confirmationDialog(Text("hosts.group.delete.title \(deletingGroup?.name ?? "")"),
                            isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } }),
                            titleVisibility: .visible) {
            Button("hosts.group.delete", role: .destructive) {
                if let g = deletingGroup {
                    do { try model.core.deleteGroup(id: g.id, accountId: g.accountId) } catch { show(error) }
                    load()
                    account.sync()
                }
            }
        } message: { Text("hosts.group.delete.message") }
        .confirmationDialog(Text("hosts.select.delete.title \(selectedHosts.count)"), isPresented: $deletingSelection,
                            titleVisibility: .visible) {
            Button("common.delete", role: .destructive) { deleteSelection() }
        } message: { Text(deleteMessage(selectedHosts)) }
        .alert(notice?.title ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: { Text(notice?.message ?? "") }
    }

    @ViewBuilder private var content: some View {
        if desktop {
            desktopContent
        } else {
            ScrollViewReader { proxy in
                hostList.onChange(of: cursor) { key in
                    if let key { withAnimation { proxy.scrollTo(key) } }
                }
            }
        }
    }

    private var hostList: some View {
        // Selection only while selecting: otherwise a tap connects (or opens
        // the group), also on an iPad.
        List(selection: selectionBinding) {
            if shortcuts && !searching && !selecting {
                Section { shortcutTiles }
            }
            if isRoot && !searching && !selecting && account.showsVaults {
                Section {
                    VaultFilterBar(hasDeviceItems: deviceItems)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }
            if isRoot && !searching && !selecting {
                if let pending = account.scoped.first(where: { $0.status == .needsSignIn || $0.status == .unverified }) {
                    Section { signInAgainBanner(pending) }
                }
                if !sessions.onServer.isEmpty {
                    Section { serverNotice }
                }
            }
            if hosts.isEmpty && groups.isEmpty && !searching {
                Section { emptyState }
            }
            if !subgroups.isEmpty && !selecting {
                Section("hosts.groups") {
                    ForEach(subgroups, id: \.key) { g in
                        NavigationLink { HostsView(groupId: g.id, groupAccountId: g.accountId) } label: {
                            GroupRow(group: g, total: totalIn(g), account: account.showsAccountBadges ? account.account(g.accountId) : nil,
                                     vault: account.showsVaults ? account.vault(g.accountId, g.vaultId) : nil)
                        }
                        .contextMenu { groupMenu(g) }
                        .swipeActions(edge: .trailing) {
                            if g.canEdit {
                                Button(role: .destructive) { deletingGroup = g } label: { Label("hosts.group.delete", systemImage: "trash") }
                                Button { editedGroup = GroupEdit(group: g) } label: { Label("hosts.group.rename", systemImage: "pencil") }
                                    .tint(.orange)
                            }
                        }
                    }
                }
            }
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.hosts, id: \.key) { host in
                        HostRow(host: host, selecting: selecting,
                                account: account.showsAccountBadges ? account.account(host.accountId) : nil,
                                vault: account.showsVaults ? account.vault(host.accountId, host.vaultId) : nil,
                                showVault: account.showsVaults || (host.accountId == nil && !account.scoped.isEmpty)) {
                            connect(host, onServer: false)
                        }
                        .contextMenu { menu(host) }
                        .listRowBackground(keyboardHighlight(cursor == host.key))
                        .id(host.key)
                        .swipeActions(edge: .trailing) {
                            if host.canEdit {
                                Button(role: .destructive) { deleting = host } label: { Label("common.delete", systemImage: "trash") }
                                Button { editing = HostEdit(host: host) } label: { Label("common.edit", systemImage: "pencil") }
                                    .tint(.orange)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if host.canEdit {
                                Button { toggleFavorite(host) } label: {
                                    if host.favorite {
                                        Label("hosts.menu.unfavorite", systemImage: "star.slash")
                                    } else {
                                        Label("hosts.menu.favorite", systemImage: "star")
                                    }
                                }
                                .tint(Brand.amber)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, $editMode)
        .overlay {
            if searching && visible.isEmpty {
                Text("hosts.search.no_results \(query)")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .background(HostsKeyboard(active: keysActive, newHost: newHostShortcut, find: nil, onKey: handleKey))
        .searchable(text: $query, prompt: Text("hosts.search.prompt"))
        .refreshable {
            account.sync()
            load()
        }
        .navigationTitle(selecting ? selectionTitle : title)
    }

    // MARK: Hardware keyboard

    /// Something covers the list (a sheet, an alert, the terminal...).
    private var covered: Bool {
        // One element at a time (a long || chain is slow to type-check).
        let shown: [Bool] = [
            sessions.showing, editing != nil, editedGroup != nil, generatingKey, importingKey, importingConfig,
            transferring != nil, addingAccount, resuming != nil, managingAccounts, showingVaults,
            filesHost != nil, tunnelsHost != nil, deleting != nil, deletingGroup != nil, deletingSelection, notice != nil,
        ]
        return shown.contains(true)
    }

    /// ↑/↓ and Return work in the list (in the grid, also when the search
    /// field lets go of the keyboard).
    private var keysActive: Bool { keyboard.connected && !covered && !selecting && !(desktop && searchFocused) }

    /// ⌘N: a new host (at the root of the vault).
    private var newHostShortcut: (() -> Void)? {
        guard isRoot, !covered else { return nil }
        return { editing = HostEdit(host: nil) }
    }

    /// ↑/↓ choose a host, Return (or Space) connects, Delete deletes it after
    /// asking, Esc lets go of it.
    private func handleKey(_ key: NavKey, _ modifiers: ModifierKeys) -> Bool {
        let grid = desktop ? gridSections : []
        let list = desktop ? grid.flatMap(\.hosts) : sections.flatMap(\.hosts)
        let host = list.first { $0.key == cursor }
        switch key {
        case .up, .down, .left, .right, .home, .end, .pageUp, .pageDown:
            // The grid moves in two dimensions; the list only up and down.
            if desktop {
                cursor = moveInGrid(cursor, in: grid.map { $0.hosts.map(\.key) }, columns: gridColumns, key)
                return true
            }
            guard key != .left && key != .right else { return false }
            cursor = moveHighlight(cursor, in: list.map(\.key), key)
            return true
        case .enter, .space:
            guard let host else { return false }
            connect(host, onServer: false)
            return true
        case .delete:
            guard let host, host.canEdit else { return false }
            deleting = host
            return true
        case .escape:
            guard cursor != nil else { return false }
            cursor = nil
            return true
        default:
            return false
        }
    }

    private var selectAllTitle: String {
        let list = selectable
        return !list.isEmpty && selection.count == list.count
            ? String(localized: "hosts.select.none") : String(localized: "hosts.select.all")
    }

    private func toggleSelectAll() {
        let list = selectable
        if selection.count == list.count { selection = [] } else { selection = Set(list.map(\.key)) }
    }

    /// The hosts on screen (in the grid, those of every group shown).
    private var selectable: [SshHost] {
        desktop ? gridSections.flatMap(\.hosts) : visible
    }

    private var activeAccounts: [String] {
        account.list.filter { $0.status == .active }.map(\.id)
    }

    /// Where a new host or group goes: the open group's place, or the
    /// default one.
    private var newPlace: ItemPlace {
        if let group = targetGroup { return account.place(accountId: group.accountId, vaultId: group.vaultId) }
        return account.defaultPlace
    }

    /// Where new hosts and groups go: the open group, or the group chosen
    /// in the chips of the grid.
    private var targetGroup: HostGroup? {
        if desktop, case .group(let key) = chip { return groups.first { $0.key == key } }
        return group
    }

    private var selectionTitle: String {
        selection.isEmpty ? String(localized: "hosts.select.title") : String(localized: "hosts.select.count \(selectedHosts.count)")
    }

    /// The selected hosts all come from the same place (needed to move or
    /// copy them together).
    private var selectionPlace: ItemPlace? {
        let chosen = selectedHosts
        guard let first = chosen.first else { return nil }
        let p = account.place(accountId: first.accountId, vaultId: first.vaultId)
        return chosen.allSatisfy({ account.place(accountId: $0.accountId, vaultId: $0.vaultId) == p }) ? p : nil
    }

    /// Bottom bar while selecting: connect to all, move them, delete them.
    @ViewBuilder private var selectionActions: some View {
        let chosen = selectedHosts
        let editable = chosen.allSatisfy(\.canEdit)
        let sameAccount = Set(chosen.map { $0.accountId ?? "" }).count == 1
        Button { connectSelection() } label: {
            Label(String(localized: "hosts.select.connect \(chosen.count)"), systemImage: "terminal")
                .labelStyle(.titleAndIcon)
        }
        .disabled(chosen.isEmpty)
        Spacer()
        Menu {
            if sameAccount && editable {
                let accountId = chosen.first?.accountId
                Section {
                    Button { move(chosen, to: nil) } label: { Label("host_editor.no_group", systemImage: "tray") }
                    ForEach(groups.filter { $0.accountId == accountId && $0.vaultId == chosen.first?.vaultId }, id: \.key) { g in
                        Button { move(chosen, to: g.id) } label: { Label(g.name, systemImage: "folder") }
                    }
                }
            }
            if !account.list.isEmpty, let place = selectionPlace {
                Section {
                    if editable {
                        Button { transferring = TransferRequest(hosts: chosen, from: place, mode: .move) } label: {
                            Label("transfer.move_to", systemImage: "arrow.right.square")
                        }
                    }
                    if chosen.allSatisfy({ !$0.isUseOnly }) {
                        Button { transferring = TransferRequest(hosts: chosen, from: place, mode: .copy) } label: {
                            Label("transfer.copy_to", systemImage: "plus.square.on.square")
                        }
                    }
                }
            }
        } label: {
            Label("hosts.select.move", systemImage: "folder")
        }
        .disabled(chosen.isEmpty || (!editable && selectionPlace == nil))
        Spacer()
        Button(role: .destructive) { deletingSelection = true } label: {
            Label("common.delete", systemImage: "trash")
        }
        .disabled(chosen.isEmpty || !editable)
    }

    private func startSelection(_ host: SshHost?) {
        selection = host.map { Set([$0.key]) } ?? []
        withAnimation { editMode = .active }
    }

    private func endSelection() {
        withAnimation { editMode = .inactive }
        selection = []
    }

    /// A terminal to each selected host (side by side on an iPad).
    private func connectSelection() {
        let chosen = selectedHosts
        guard !chosen.isEmpty else { return }
        endSelection()
        if chosen.count == 1 {
            connect(chosen[0], onServer: false)
        } else {
            // Strict Use-only hosts open through their server.
            let strict = chosen.filter { isStrict($0) }
            sessions.openLocal(chosen.filter { !isStrict($0) })
            strict.forEach { sessions.openOnServer($0) }
        }
    }

    private func move(_ chosen: [SshHost], to group: String?) {
        do {
            for var h in chosen where h.groupId != group {
                h.groupId = group
                _ = try model.core.saveHost(host: h, password: .keep)
            }
        } catch {
            show(error)
        }
        endSelection()
        load()
        account.sync()
    }

    private func deleteSelection() {
        do {
            for h in selectedHosts { try model.core.deleteHost(id: h.id, accountId: h.accountId) }
        } catch {
            show(error)
        }
        endSelection()
        load()
        account.sync()
    }

    /// Deleting a host of a shared vault deletes it for everyone in it.
    private func deleteMessage(_ chosen: [SshHost]) -> String {
        let shared = chosen.contains { h in
            guard let v = account.vault(h.accountId, h.vaultId) else { return false }
            return v.kind != .personal
        }
        return shared ? String(localized: "hosts.delete.message_shared") : String(localized: "hosts.delete.message")
    }

    /// "+": new host or group, a new key and the imports.
    private var addMenu: some View {
        Menu {
            Button { editing = HostEdit(host: nil) } label: { Label("common.new_host", systemImage: "server.rack") }
            Button(action: newGroup) {
                Label("hosts.group.new", systemImage: "folder.badge.plus")
            }
            Divider()
            Button { generatingKey = true } label: { Label("vault.new_key", systemImage: "key") }
            Menu {
                Button { importingConfig = true } label: { Label("vault.import.ssh_config", systemImage: "doc.text") }
                Button { importingKey = true } label: { Label("keychain.import.title", systemImage: "doc.on.clipboard") }
            } label: {
                Label("vault.import", systemImage: "square.and.arrow.down")
            }
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("vault.add")
    }

    private func newGroup() {
        let p = newPlace
        editedGroup = GroupEdit(group: HostGroup(name: "", parentId: desktop ? targetGroup?.id : groupId,
                                                 accountId: p.accountId, vaultId: p.vaultId))
    }

    /// Keychain, port forwarding, snippets and known hosts, with how many
    /// there are of each.
    private var shortcutTiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(VaultSection.shortcuts) { s in
                NavigationLink { s.screen } label: { VaultTile(section: s, count: counts[s]) }
                    .buttonStyle(.plain)
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        .listRowBackground(Color.clear)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            EmptyState(
                icon: "server.rack",
                title: account.syncing ? String(localized: "common.syncing") : String(localized: "hosts.empty.title"),
                text: !account.scoped.isEmpty
                    ? String(localized: "hosts.empty.text_synced")
                    : String(localized: "hosts.empty.text_local"),
                action: String(localized: "common.new_host")
            ) { editing = HostEdit(host: nil) }
            Button { importingConfig = true } label: {
                Label("hosts.empty.import", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .padding(.top, -16)
            .padding(.bottom, 20)
        }
        .listRowBackground(Color.clear)
    }

    /// "Sign in again to sync" for an account whose session ended (its
    /// items stay usable offline), or "Enter the email code".
    private func signInAgainBanner(_ a: AccountInfo) -> some View {
        Button { resuming = a } label: {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundColor(Brand.amber)
                    .frame(width: 30, height: 30)
                    .background(Brand.amber.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.status == .unverified ? String(localized: "accounts.enter_code") : String(localized: "accounts.sign_in_again"))
                        .font(.subheadline.weight(.medium)).foregroundColor(.primary)
                    Text(verbatim: a.email).font(.caption).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// "☁ N sessions running on the server", with a button to go to them.
    private var serverNotice: some View {
        let n = sessions.onServer.count
        return Button { sessions.openRunningSessions() } label: {
            HStack(spacing: 12) {
                Image(systemName: "icloud")
                    .foregroundColor(.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("hosts.server_sessions \(n)")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                Spacer(minLength: 0)
                Text("common.open").font(.subheadline.weight(.semibold)).foregroundColor(.accentColor)
            }
        }
    }

    /// A server session can be opened for this host: its account is signed
    /// in (This-device hosts use the current account).
    private func canOpenOnServer(_ host: SshHost) -> Bool {
        if let a = account.account(host.accountId) { return a.status == .active }
        return account.loggedIn == true
    }

    @ViewBuilder private func menu(_ host: SshHost) -> some View {
        Button { connect(host, onServer: false) } label: { Label("common.connect", systemImage: "terminal") }
        if desktop && !sessions.open.isEmpty {
            Button { connectInSplit(host) } label: { Label("hosts.menu.connect_split", systemImage: "rectangle.split.2x1") }
        }
        // Telnet hosts: no server sessions, SFTP or tunnels (SSH only).
        if canOpenOnServer(host) && !host.isTelnet {
            Button { connect(host, onServer: true) } label: { Label("hosts.menu.persistent", systemImage: "icloud") }
        }
        if !host.isTelnet {
            Button { filesHost = host } label: { Label("common.files_sftp", systemImage: "folder") }
        }
        if !isStrict(host) && !host.isTelnet {
            Button { tunnelsHost = host } label: { Label("common.tunnels", systemImage: "arrow.left.arrow.right") }
        }
        Divider()
        if host.canEdit {
            Button { editing = HostEdit(host: host) } label: { Label("common.edit", systemImage: "pencil") }
        }
        Button { startSelection(host) } label: { Label("hosts.select", systemImage: "checkmark.circle") }
        if host.canEdit {
            Button { toggleFavorite(host) } label: {
                if host.favorite {
                    Label("hosts.menu.unfavorite", systemImage: "star.slash")
                } else {
                    Label("hosts.menu.favorite", systemImage: "star")
                }
            }
            Button { duplicate(host) } label: { Label("hosts.menu.duplicate", systemImage: "plus.square.on.square") }
        }
        Button { UIPasteboard.general.string = host.address } label: {
            Label("hosts.menu.copy_address", systemImage: "doc.on.doc")
        }
        if desktop && host.canEdit { moveToGroupMenu(host) }
        if !account.list.isEmpty {
            let place = account.place(accountId: host.accountId, vaultId: host.vaultId)
            Menu {
                if host.canEdit {
                    Button { transferring = TransferRequest(hosts: [host], from: place, mode: .move) } label: {
                        Label("transfer.move_to", systemImage: "arrow.right.square")
                    }
                }
                if !host.isUseOnly {
                    Button { transferring = TransferRequest(hosts: [host], from: place, mode: .copy) } label: {
                        Label("transfer.copy_to", systemImage: "plus.square.on.square")
                    }
                }
            } label: {
                Label("transfer.menu", systemImage: "lock.shield")
            }
        }
        if host.canEdit {
            Divider()
            Button(role: .destructive) { deleting = host } label: { Label("common.delete", systemImage: "trash") }
        }
    }

    @ViewBuilder private func groupMenu(_ g: HostGroup) -> some View {
        if g.canEdit {
            Button { editedGroup = GroupEdit(group: g) } label: { Label("hosts.group.rename", systemImage: "pencil") }
            Button(role: .destructive) { deletingGroup = g } label: { Label("hosts.group.delete", systemImage: "trash") }
        }
    }

    private func isStrict(_ host: SshHost) -> Bool {
        host.isUseOnly && account.isStrict(accountId: host.accountId, vaultId: host.vaultId)
    }

    /// Desktop layout: the groups of the host's vault, the current one checked.
    private func moveToGroupMenu(_ host: SshHost) -> some View {
        let options = groups.filter { $0.accountId == host.accountId && $0.vaultId == host.vaultId }
        return Menu {
            Button { move([host], to: nil) } label: {
                if !hasGroup(host) {
                    Label("host_editor.no_group", systemImage: "checkmark")
                } else {
                    Text("host_editor.no_group")
                }
            }
            ForEach(options, id: \.key) { g in
                Button { move([host], to: g.id) } label: {
                    if host.groupId == g.id {
                        Label(g.name, systemImage: "checkmark")
                    } else {
                        Text(verbatim: g.name)
                    }
                }
            }
        } label: {
            Label("hosts.select.move", systemImage: "folder")
        }
    }

    /// Desktop layout: the terminal opens next to the one on screen.
    private func connectInSplit(_ host: SshHost) {
        sessions.splitOnNextOpen = true
        connect(host, onServer: false)
    }

    private func connect(_ host: SshHost, onServer: Bool) {
        if onServer {
            sessions.openOnServer(host)
        } else {
            sessions.connect(host, strict: isStrict(host))
        }
    }

    /// Files over SFTP: from the phone, or from the server for Strict
    /// Use-only hosts.
    private func filesSource(_ host: SshHost) -> FileBrowser.Source {
        isStrict(host) ? .server(hostId: host.id, accountId: host.accountId) : .connect(hostId: host.id, accountId: host.accountId)
    }

    private func load() {
        do {
            hosts = try model.core.listHosts(filter: account.hostFilter)
            groups = try model.core.listGroups(filter: account.hostFilter)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            show(error)
        }
        if case .group(let key) = chip, !groups.contains(where: { $0.key == key }) { chip = .all }
        guard isRoot else { return }
        let core = model.core
        let device = ItemFilter(accountIds: [], vaultIds: nil, includeDevice: true)
        deviceItems = !account.scoped.isEmpty && !((try? core.listHosts(filter: device)) ?? []).isEmpty
        guard shortcuts else { return }
        let f = account.itemFilter
        counts = [
            .keychain: (try? core.listKeys(filter: f).count) ?? 0,
            .portForwarding: (try? core.listForwards(hostId: nil, filter: f).count) ?? 0,
            .snippets: (try? core.listSnippets(filter: f).count) ?? 0,
            .knownHosts: (try? core.listKnownHosts(filter: f).count) ?? 0,
        ]
    }

    private func show(_ error: Error) {
        notice = Notice(title: String(localized: "common.error"), message: userMessage(error))
    }

    private func save(_ host: SshHost) {
        do {
            _ = try model.core.saveHost(host: host, password: .keep)
            load()
            account.sync()
        } catch {
            show(error)
        }
    }

    private func toggleFavorite(_ host: SshHost) {
        var h = host
        h.favorite.toggle()
        save(h)
    }

    /// A copy next to it (same account and vault; the password stays with
    /// the original).
    private func duplicate(_ host: SshHost) {
        var h = host
        h.id = ""
        h.label = String(localized: "hosts.copy_label \(host.label)")
        h.favorite = false
        save(h)
    }

    private func delete(_ host: SshHost) {
        do {
            try model.core.deleteHost(id: host.id, accountId: host.accountId)
            load()
            account.sync()
        } catch {
            show(error)
        }
    }

    /// Imports the hosts of an `ssh_config` picked in Files.
    private func importSshConfig(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            let report = try model.core.importSshConfig(text: text, options: SshConfigImportOptions())
            load()
            account.sync()
            let details = report.hostsSkipped.map { "\($0.alias): \($0.reason)" } + report.warnings
            notice = Notice(
                title: String(localized: "vault.import.done"),
                message: ([String(localized: "vault.import.result \(report.hostsCreated.count) \(report.hostsSkipped.count)")] + details)
                    .joined(separator: "\n")
            )
        } catch {
            show(error)
        }
    }
}

// MARK: - Desktop layout

private extension HostsView {
    /// The grid, and the host editor on its right while it is open (over
    /// the whole grid when the window is narrow).
    var desktopContent: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let beside = width >= 720
            let panel = beside ? min(420, width * 0.45) : width
            ZStack(alignment: .trailing) {
                hostGrid
                    .padding(.trailing, beside && editing != nil ? panel : 0)
                if let e = editing {
                    HStack(spacing: 0) {
                        Divider()
                        HostEditor(original: e.host, initialGroup: targetGroup?.id ?? groupId, initialPlace: newPlace,
                                   onConnect: { saved in connect(saved, onServer: false) },
                                   onClose: {
                                       editing = nil
                                       load()
                                   })
                    }
                    .frame(width: panel)
                    .id(e.id)
                    .transition(.move(edge: .trailing))
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: editing?.id)
        .background(HostsKeyboard(active: keysActive, newHost: newHostShortcut,
                                  find: covered ? nil : { searchFocused = true }, onKey: handleKey))
    }

    var hostGrid: some View {
        GeometryReader { geo in
            let width = geo.size.width
            // Cards of at least 270 points, 12 apart, 20 from the edges.
            let columns = max(1, Int((width - 40 + 12) / (270 + 12)))
            VStack(spacing: 0) {
                gridHeader(narrow: width < 760)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        gridBody(columns: columns).padding(20)
                    }
                    .onChange(of: cursor) { key in
                        if let key { withAnimation { proxy.scrollTo(key) } }
                    }
                }
                if selecting {
                    Divider()
                    HStack { selectionActions }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
            }
            .onAppear { gridColumns = columns }
            .onChange(of: columns) { gridColumns = $0 }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    /// Title and count, the search and the buttons, and the group chips.
    func gridHeader(narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selecting ? selectionTitle : String(localized: "nav.hosts"))
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                    Text("desktop.hosts.subtitle \(hosts.count)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if !narrow { searchField.frame(maxWidth: 280) }
                headerButtons(narrow: narrow)
            }
            if narrow { searchField }
            if !searching && !selecting && !hosts.isEmpty { chipBar }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    var searchField: some View {
        // Return goes to the first result (Return again connects).
        DesktopSearchField(prompt: String(localized: "desktop.hosts.search"), text: $query, focused: $searchFocused) {
            cursor = gridSections.first?.hosts.first?.key
            searchFocused = false
        }
    }

    @ViewBuilder func headerButtons(narrow: Bool) -> some View {
        if selecting {
            Button { toggleSelectAll() } label: { HeaderButtonLabel(title: selectAllTitle, symbol: "checklist") }
                .buttonStyle(.plain)
            Button { endSelection() } label: { HeaderButtonLabel(title: String(localized: "common.done"), symbol: "checkmark", prominent: true) }
                .buttonStyle(.plain)
        } else {
            if account.syncing {
                ProgressView().frame(width: 34, height: 34)
            } else if account.list.contains(where: { $0.status == .active }) {
                Button { account.sync() } label: {
                    HeaderButtonLabel(title: String(localized: "settings.sync"), symbol: "arrow.triangle.2.circlepath", iconOnly: true)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            }
            if !hosts.isEmpty {
                Button { startSelection(nil) } label: {
                    HeaderButtonLabel(title: String(localized: "hosts.select"), symbol: "checkmark.circle", iconOnly: true)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            }
            Menu {
                Button { importingConfig = true } label: { Label("vault.import.ssh_config", systemImage: "doc.text") }
                Button { importingKey = true } label: { Label("keychain.import.title", systemImage: "doc.on.clipboard") }
                Divider()
                Button { generatingKey = true } label: { Label("vault.new_key", systemImage: "key") }
            } label: {
                HeaderButtonLabel(title: String(localized: "vault.import"), symbol: "square.and.arrow.down", iconOnly: narrow)
            }
            .hoverEffect(.highlight)
            Button(action: newGroup) {
                HeaderButtonLabel(title: String(localized: "desktop.hosts.group"), symbol: "folder.badge.plus", iconOnly: narrow)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            Button { editing = HostEdit(host: nil) } label: {
                HeaderButtonLabel(title: String(localized: "common.new_host"), symbol: "plus", prominent: true)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
        }
    }

    /// All, Favorites, each group and No group, with how many hosts.
    var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                FilterChip(title: String(localized: "vaults.filter.all"), count: hosts.count, selected: chip == .all) { chip = .all }
                let favorites = hosts.filter(\.favorite).count
                if favorites > 0 {
                    FilterChip(title: String(localized: "desktop.hosts.favorites"), count: favorites, symbol: "star",
                               selected: chip == .favorites) { chip = .favorites }
                }
                ForEach(groupTree) { node in
                    FilterChip(title: node.title, count: totalIn(node.group), symbol: "folder",
                               tint: hexColor(node.group.color) ?? .accentColor,
                               selected: chip == .group(node.group.key)) { chip = .group(node.group.key) }
                }
                let loose = hosts.filter { !hasGroup($0) }.count
                if !groups.isEmpty && loose > 0 {
                    FilterChip(title: String(localized: "host_editor.no_group"), count: loose, selected: chip == .noGroup) { chip = .noGroup }
                }
            }
        }
    }

    func gridBody(columns: Int) -> some View {
        let layout = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns)
        return LazyVStack(alignment: .leading, spacing: 22) {
            if !searching && !selecting { gridNotices }
            if hosts.isEmpty && groups.isEmpty && !searching { emptyState }
            if searching && visible.isEmpty {
                Text("hosts.search.no_results \(query)")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
            ForEach(gridSections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    gridSectionHeader(section)
                    if section.hosts.isEmpty {
                        Text("desktop.hosts.group_empty").font(.subheadline).foregroundColor(.secondary)
                    } else {
                        LazyVGrid(columns: layout, alignment: .leading, spacing: 12) {
                            ForEach(section.hosts, id: \.key) { host in
                                hostCard(host).id(host.key)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder func gridSectionHeader(_ section: HostGridSection) -> some View {
        if let g = section.group {
            GridGroupHeader(title: section.title, count: section.hosts.count, color: hexColor(g.color) ?? .accentColor,
                            account: account.showsAccountBadges ? account.account(g.accountId) : nil,
                            vault: account.showsVaults ? account.vault(g.accountId, g.vaultId) : nil,
                            showsMenu: g.canEdit) {
                groupMenu(g)
            }
        } else if !section.title.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: section.symbol).foregroundColor(.secondary)
                Text(verbatim: section.title).font(.headline)
                Text("hosts.group.count \(section.hosts.count)").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    func hostCard(_ host: SshHost) -> some View {
        HostCard(host: host, highlighted: cursor == host.key, selecting: selecting, selected: selection.contains(host.key),
                 account: account.showsAccountBadges ? account.account(host.accountId) : nil,
                 vault: account.showsVaults ? account.vault(host.accountId, host.vaultId) : nil,
                 showVault: account.showsVaults || (host.accountId == nil && !account.scoped.isEmpty),
                 onTap: { tapCard(host) }) {
            menu(host)
        }
    }

    /// Connects (and it stays highlighted), or selects while selecting.
    func tapCard(_ host: SshHost) {
        if selecting {
            if selection.contains(host.key) { selection.remove(host.key) } else { selection.insert(host.key) }
        } else {
            cursor = host.key
            connect(host, onServer: false)
        }
    }

    /// "Sign in again" and the running server sessions, as cards.
    @ViewBuilder var gridNotices: some View {
        let card = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if let pending = account.scoped.first(where: { $0.status == .needsSignIn || $0.status == .unverified }) {
            signInAgainBanner(pending)
                .buttonStyle(.plain)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: card)
        }
        if !sessions.onServer.isEmpty {
            serverNotice
                .buttonStyle(.plain)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: card)
        }
    }

    /// The sections of the grid: the results of the search, the favorites,
    /// or each group (in tree order) and the hosts without one.
    var gridSections: [HostGridSection] {
        if searching {
            let list = visible
            return list.isEmpty ? [] : [HostGridSection(id: "results", title: String(localized: "hosts.results"),
                                                       symbol: "magnifyingglass", group: nil, hosts: list)]
        }
        let all = hosts.sorted(by: listOrder)
        if chip == .favorites {
            let favorites = all.filter(\.favorite)
            return favorites.isEmpty ? [] : [HostGridSection(id: "favorites", title: String(localized: "desktop.hosts.favorites"),
                                                            symbol: "star", group: nil, hosts: favorites)]
        }
        var out: [HostGridSection] = []
        if chip != .noGroup {
            var nodes = groupTree
            if case .group(let key) = chip {
                let inside = groupAndDescendants(key)
                nodes = nodes.filter { inside.contains($0.group.key) }
            }
            for node in nodes {
                let g = node.group
                let mine = all.filter { $0.groupId == g.id && $0.accountId == g.accountId }
                // An empty group shows only when it is the chosen one.
                if !mine.isEmpty || chip == .group(g.key) {
                    out.append(HostGridSection(id: g.key, title: node.title, symbol: "folder", group: g, hosts: mine))
                }
            }
        }
        if chip == .all || chip == .noGroup {
            let loose = all.filter { !hasGroup($0) }
            if !loose.isEmpty {
                // Without any group, no title at all.
                out.append(HostGridSection(id: "no-group", title: groups.isEmpty ? "" : String(localized: "host_editor.no_group"),
                                           symbol: "tray", group: nil, hosts: loose))
            }
        }
        return out
    }

    /// The groups, each one after its parent ("Parent › Child").
    var groupTree: [GroupNode] {
        var out: [GroupNode] = []
        var seen: Set<String> = []
        func visit(_ g: HostGroup, _ prefix: String) {
            guard seen.insert(g.key).inserted else { return }
            let title = prefix.isEmpty ? g.name : "\(prefix) › \(g.name)"
            out.append(GroupNode(group: g, title: title))
            for child in groups where child.parentId == g.id && child.accountId == g.accountId {
                visit(child, title)
            }
        }
        for g in groups where g.parentId == nil || !groups.contains(where: { $0.id == g.parentId && $0.accountId == g.accountId }) {
            visit(g, "")
        }
        return out
    }

    /// A group and the groups inside it (by `HostGroup.key`).
    func groupAndDescendants(_ key: String) -> Set<String> {
        guard let root = groups.first(where: { $0.key == key }) else { return [] }
        var out: Set<String> = [root.key]
        var pending = [root]
        while let g = pending.popLast() {
            for child in groups where child.parentId == g.id && child.accountId == g.accountId && !out.contains(child.key) {
                out.insert(child.key)
                pending.append(child)
            }
        }
        return out
    }
}

/// The chip chosen above the hosts grid.
private enum HostChip: Hashable {
    case all, favorites, noGroup
    /// A group (by `HostGroup.key`) and the ones inside it.
    case group(String)
}

/// A group of cards in the grid.
private struct HostGridSection: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let group: HostGroup?
    let hosts: [SshHost]
}

/// A group with its path, in tree order.
private struct GroupNode: Identifiable {
    let group: HostGroup
    let title: String
    var id: String { group.key }
}

struct HostEdit: Identifiable {
    let id = UUID()
    let host: SshHost?
}

private struct GroupEdit: Identifiable {
    let id = UUID()
    let group: HostGroup
}

/// An account to sign in again (sheet).
private struct ResumeItem: Identifiable {
    let account: AccountInfo
    var id: String { account.id }
}

/// Hosts of one account (or all of them) in the list.
private struct HostSection: Identifiable {
    let id: String
    let title: String
    let hosts: [SshHost]
}

/// Title and text of an alert.
private struct Notice {
    let title: String
    let message: String
}

/// A section of the vault as a tile (like the lists of Reminders).
private struct VaultTile: View {
    let section: VaultSection
    let count: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: section.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(section.tint, in: Circle())
                Spacer(minLength: 0)
                if let count {
                    Text(verbatim: "\(count)").font(.title2.weight(.bold)).foregroundColor(.primary)
                }
            }
            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A group: folder, name and how many hosts it has.
private struct GroupRow: View {
    let group: HostGroup
    let total: Int
    var account: AccountInfo? = nil
    var vault: VaultInfo? = nil

    var body: some View {
        let tint = hexColor(group.color) ?? Color.accentColor
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 18))
                .foregroundColor(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text("hosts.group.count \(total)").font(.subheadline).foregroundColor(.secondary)
                    if let vault { VaultChip(vault: vault) }
                }
            }
            Spacer(minLength: 0)
            if let account { AccountAvatar(account: account, size: 20) }
        }
        .padding(.vertical, 2)
    }
}

/// A host: avatar, name, "ssh, user", its vault and its tags. Tapping it
/// connects (while selecting, it selects it).
private struct HostRow: View {
    let host: SshHost
    var selecting = false
    /// Several accounts on screen: the host's account.
    var account: AccountInfo? = nil
    /// Several vaults on screen: the host's vault.
    var vault: VaultInfo? = nil
    /// Show the vault chip (or "This device").
    var showVault = false
    let onConnect: () -> Void

    var body: some View {
        if selecting {
            content
        } else {
            Button(action: onConnect) { content }
                .buttonStyle(.plain)
        }
    }

    private var content: some View {
        HStack(spacing: 14) {
            HostIcon(host: host, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(host.displayName)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if host.favorite { Image(systemName: "star.fill").font(.caption2).foregroundColor(Brand.amber) }
                    if host.isUseOnly {
                        Image(systemName: "lock.fill").font(.caption2).foregroundColor(Brand.amber)
                            .accessibilityLabel(Text("vaults.use_only_badge"))
                    }
                    if host.isTelnet { TelnetBadge() }
                }
                Text(hostSubtitle(host)).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                if !host.tags.isEmpty || showVault || host.isUseOnly {
                    HStack(spacing: 4) {
                        if showVault && (vault != nil || host.accountId == nil) { VaultChip(vault: vault) }
                        if host.isUseOnly { UseOnlyBadge() }
                        ForEach(Array(host.tags.prefix(3).enumerated()), id: \.offset) { _, tag in
                            TagChip(text: tag)
                        }
                        if host.tags.count > 3 { TagChip(text: "+\(host.tags.count - 3)") }
                    }
                }
            }
            Spacer(minLength: 0)
            if let account { AccountAvatar(account: account, size: 20) }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Name of a group (new or existing).
private struct GroupEditor: View {
    let original: HostGroup
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var place: ItemPlace = .device
    @State private var error: String?

    /// A new top-level group: choose its vault.
    private var choosesPlace: Bool {
        original.id.isEmpty && original.parentId == nil && account.places.count > 1
    }

    var body: some View {
        NavigationView {
            Form {
                TextField("hosts.group.name", text: $name)
                if choosesPlace { PlacePicker(place: $place) }
                if let error { Text(error).foregroundColor(Brand.red) }
            }
            .navigationTitle(original.id.isEmpty ? String(localized: "hosts.group.new") : String(localized: "hosts.group.rename"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        var g = original
                        g.name = name.trimmingCharacters(in: .whitespaces)
                        if choosesPlace {
                            g.accountId = place.accountId
                            g.vaultId = place.vaultId
                            g.syncMode = place.accountId == nil && !account.list.isEmpty ? .deviceOnly : nil
                        }
                        do {
                            _ = try model.core.saveGroup(group: g)
                            if choosesPlace { account.rememberPlace(place) }
                            account.sync()
                            dismiss()
                        } catch {
                            self.error = userMessage(error)
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear {
            name = original.name
            place = account.place(accountId: original.accountId, vaultId: original.vaultId)
        }
    }
}

/// Host picked to open a sheet (SFTP, tunnels).
struct SelectedHost: Identifiable {
    let host: SshHost
    var id: String { host.key }
}

/// Hardware keyboard in the hosts list: the keys of `KeyCatcher` (not while
/// searching: it is inside `.searchable`) and ⌘N.
private struct HostsKeyboard: View {
    let active: Bool
    let newHost: (() -> Void)?
    /// ⌘F: to the search field (desktop layout).
    let find: (() -> Void)?
    let onKey: (NavKey, ModifierKeys) -> Bool
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        ZStack {
            KeyCatcher(active: active && !isSearching, onKey: onKey)
                .frame(width: 0, height: 0)
            if let newHost {
                ShortcutLayer {
                    ShortcutButton(title: String(localized: "common.new_host"), key: "n", action: newHost)
                    if let find {
                        ShortcutButton(title: String(localized: "shortcut.find"), key: "f", action: find)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}
