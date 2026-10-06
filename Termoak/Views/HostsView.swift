import TermoakKit
import SwiftUI
import UniformTypeIdentifiers

/// Hosts in the style of Termius: search, groups as rows above the hosts and
/// each host with its colored avatar. Tapping a host connects; holding it or
/// swiping shows its actions. "Select" picks several to connect to them at
/// once, move them to a group or delete them. With `groupId`, the contents
/// of a group. With `shortcuts` (the root of the vault on the phone), the
/// other sections of the vault go as tiles at the top.
struct HostsView: View {
    let groupId: String?
    var shortcuts = false

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Account
    @EnvironmentObject private var sessions: Sessions

    @State private var hosts: [SshHost] = []
    @State private var groups: [HostGroup] = []
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
    @State private var notice: Notice?
    /// Selecting several hosts.
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<String> = []
    @State private var deletingSelection = false

    private var selecting: Bool { editMode.isEditing }

    /// The list selects only while selecting.
    private var selectionBinding: Binding<Set<String>>? {
        selecting ? $selection : nil
    }

    /// The selected hosts, in the order of the list.
    private var selectedHosts: [SshHost] {
        hosts.filter { selection.contains($0.id) }.sorted(by: listOrder)
    }

    private var group: HostGroup? { groups.first { $0.id == groupId } }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var visible: [SshHost] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return hosts.filter { h in
            if searching {
                return [h.label, h.address, h.settings.username ?? "", h.tags.joined(separator: " ")]
                    .contains { $0.lowercased().contains(q) }
            }
            return h.groupId == groupId || (groupId == nil && !groups.contains { $0.id == h.groupId })
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
            g.parentId == groupId || (groupId == nil && g.parentId != nil && !groups.contains { $0.id == g.parentId })
        }
    }

    private func totalIn(_ g: HostGroup) -> Int {
        hosts.filter { $0.groupId == g.id }.count + groups.filter { $0.parentId == g.id }.reduce(0) { $0 + totalIn($1) }
    }

    private var title: String {
        if let group { return group.name }
        return shortcuts ? String(localized: "nav.vault") : String(localized: "nav.hosts")
    }

    var body: some View {
        // Selection only while selecting: otherwise a tap connects (or opens
        // the group), also on an iPad.
        List(selection: selectionBinding) {
            if shortcuts && !searching && !selecting {
                Section { shortcutTiles }
            }
            if groupId == nil && !searching && !selecting && !sessions.onServer.isEmpty {
                Section { serverNotice }
            }
            if hosts.isEmpty && groups.isEmpty && !searching {
                Section { emptyState }
            }
            if !subgroups.isEmpty && !selecting {
                Section("hosts.groups") {
                    ForEach(subgroups, id: \.id) { g in
                        NavigationLink { HostsView(groupId: g.id) } label: { GroupRow(group: g, total: totalIn(g)) }
                            .contextMenu { groupMenu(g) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { deletingGroup = g } label: { Label("hosts.group.delete", systemImage: "trash") }
                                Button { editedGroup = GroupEdit(group: g) } label: { Label("hosts.group.rename", systemImage: "pencil") }
                                    .tint(.orange)
                            }
                    }
                }
            }
            if !visible.isEmpty {
                Section(searching ? String(localized: "hosts.results") : String(localized: "nav.hosts")) {
                    ForEach(visible, id: \.id) { host in
                        HostRow(host: host, selecting: selecting) { connect(host, onServer: false) }
                            .contextMenu { menu(host) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { deleting = host } label: { Label("common.delete", systemImage: "trash") }
                                Button { editing = HostEdit(host: host) } label: { Label("common.edit", systemImage: "pencil") }
                                    .tint(.orange)
                            }
                            .swipeActions(edge: .leading) {
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
        .searchable(text: $query, prompt: Text("hosts.search.prompt"))
        .refreshable {
            if account.loggedIn == true { account.sync() }
            load()
        }
        .navigationTitle(selecting ? selectionTitle : title)
        .toolbar {
            if selecting {
                ToolbarItem(placement: .cancellationAction) {
                    Button(selection.count == visible.count && !visible.isEmpty
                           ? String(localized: "hosts.select.none") : String(localized: "hosts.select.all")) {
                        if selection.count == visible.count { selection = [] } else { selection = Set(visible.map(\.id)) }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { endSelection() }
                }
                ToolbarItemGroup(placement: .bottomBar) { selectionActions }
            } else {
                ToolbarItemGroup(placement: .primaryAction) {
                    if account.syncing {
                        ProgressView()
                    } else if account.loggedIn == true && groupId == nil {
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
        .sheet(item: $editing, onDismiss: load) { e in
            HostEditor(original: e.host, initialGroup: groupId) { saved in
                // After the sheet has gone, the terminal comes up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sessions.openLocal(saved) }
            }
            .environmentObject(model).environmentObject(account)
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
        .fullScreenCover(item: Binding(get: { filesHost.map(SelectedHost.init) }, set: { filesHost = $0?.host })) { e in
            FilesScreen(core: model.core, title: e.host.label.isEmpty ? e.host.address : e.host.label,
                        source: .connect(hostId: e.host.id))
        }
        .sheet(item: Binding(get: { tunnelsHost.map(SelectedHost.init) }, set: { tunnelsHost = $0?.host }), onDismiss: load) { e in
            TunnelsView(host: e.host)
        }
        .fileImporter(isPresented: $importingConfig, allowedContentTypes: [.item]) { result in
            importSshConfig(result)
        }
        .confirmationDialog(Text("hosts.delete.title \(deleting?.label ?? "")"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("common.delete", role: .destructive) { if let h = deleting { delete(h) } }
        } message: { Text("hosts.delete.message") }
        .confirmationDialog(Text("hosts.group.delete.title \(deletingGroup?.name ?? "")"),
                            isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } }),
                            titleVisibility: .visible) {
            Button("hosts.group.delete", role: .destructive) {
                if let g = deletingGroup { try? model.core.deleteGroup(id: g.id); load(); account.sync() }
            }
        } message: { Text("hosts.group.delete.message") }
        .confirmationDialog(Text("hosts.select.delete.title \(selectedHosts.count)"), isPresented: $deletingSelection,
                            titleVisibility: .visible) {
            Button("common.delete", role: .destructive) { deleteSelection() }
        } message: { Text("hosts.delete.message") }
        .alert(notice?.title ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: { Text(notice?.message ?? "") }
        .onAppear {
            load()
            if groupId == nil { account.sync() }
        }
        .onReceive(account.vaultChanged) { load() }
        .task {
            if groupId == nil && account.loggedIn == true { await sessions.refreshServer() }
        }
        .onReceive(account.changes) { kind in
            guard groupId == nil, kind == "session" || kind == "lagged" else { return }
            Task { await sessions.refreshServer() }
        }
    }

    private var selectionTitle: String {
        selection.isEmpty ? String(localized: "hosts.select.title") : String(localized: "hosts.select.count \(selectedHosts.count)")
    }

    /// Bottom bar while selecting: connect to all, move them, delete them.
    @ViewBuilder private var selectionActions: some View {
        let chosen = selectedHosts
        Button { connectSelection() } label: {
            Label(String(localized: "hosts.select.connect \(chosen.count)"), systemImage: "terminal")
                .labelStyle(.titleAndIcon)
        }
        .disabled(chosen.isEmpty)
        Spacer()
        Menu {
            Button { move(chosen, to: nil) } label: { Label("host_editor.no_group", systemImage: "tray") }
            ForEach(groups, id: \.id) { g in
                Button { move(chosen, to: g.id) } label: { Label(g.name, systemImage: "folder") }
            }
        } label: {
            Label("hosts.select.move", systemImage: "folder")
        }
        .disabled(chosen.isEmpty)
        Spacer()
        Button(role: .destructive) { deletingSelection = true } label: {
            Label("common.delete", systemImage: "trash")
        }
        .disabled(chosen.isEmpty)
    }

    private func startSelection(_ host: SshHost?) {
        selection = host.map { Set([$0.id]) } ?? []
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
        if chosen.count == 1 { sessions.openLocal(chosen[0]) } else { sessions.openLocal(chosen) }
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
            for h in selectedHosts { try model.core.deleteHost(id: h.id) }
        } catch {
            show(error)
        }
        endSelection()
        load()
        account.sync()
    }

    /// "+": new host or group, a new key and the imports.
    private var addMenu: some View {
        Menu {
            Button { editing = HostEdit(host: nil) } label: { Label("common.new_host", systemImage: "server.rack") }
            Button { editedGroup = GroupEdit(group: HostGroup(name: "", parentId: groupId)) } label: {
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
                text: account.loggedIn == true
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

    @ViewBuilder private func menu(_ host: SshHost) -> some View {
        Button { connect(host, onServer: false) } label: { Label("common.connect", systemImage: "terminal") }
        if account.loggedIn == true {
            Button { connect(host, onServer: true) } label: { Label("hosts.menu.persistent", systemImage: "icloud") }
        }
        Button { filesHost = host } label: { Label("common.files_sftp", systemImage: "folder") }
        Button { tunnelsHost = host } label: { Label("common.tunnels", systemImage: "arrow.left.arrow.right") }
        Divider()
        Button { editing = HostEdit(host: host) } label: { Label("common.edit", systemImage: "pencil") }
        Button { startSelection(host) } label: { Label("hosts.select", systemImage: "checkmark.circle") }
        Button { toggleFavorite(host) } label: {
            if host.favorite {
                Label("hosts.menu.unfavorite", systemImage: "star.slash")
            } else {
                Label("hosts.menu.favorite", systemImage: "star")
            }
        }
        Button { duplicate(host) } label: { Label("hosts.menu.duplicate", systemImage: "plus.square.on.square") }
        Button { UIPasteboard.general.string = host.address } label: {
            Label("hosts.menu.copy_address", systemImage: "doc.on.doc")
        }
        Divider()
        Button(role: .destructive) { deleting = host } label: { Label("common.delete", systemImage: "trash") }
    }

    @ViewBuilder private func groupMenu(_ g: HostGroup) -> some View {
        Button { editedGroup = GroupEdit(group: g) } label: { Label("hosts.group.rename", systemImage: "pencil") }
        Button(role: .destructive) { deletingGroup = g } label: { Label("hosts.group.delete", systemImage: "trash") }
    }

    private func connect(_ host: SshHost, onServer: Bool) {
        if onServer { sessions.openOnServer(host) } else { sessions.openLocal(host) }
    }

    private func load() {
        do {
            hosts = try model.core.listHosts()
            groups = try model.core.listGroups().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            show(error)
        }
        guard shortcuts else { return }
        let core = model.core
        counts = [
            .keychain: (try? core.listKeys().count) ?? 0,
            .portForwarding: (try? core.listForwards(hostId: nil).count) ?? 0,
            .snippets: (try? core.listSnippets().count) ?? 0,
            .knownHosts: (try? core.listKnownHosts().count) ?? 0,
        ]
    }

    private func show(_ error: Error) {
        notice = Notice(title: String(localized: "common.error"), message: errorMessage(error))
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

    private func duplicate(_ host: SshHost) {
        var h = host
        h.id = ""
        h.label = String(localized: "hosts.copy_label \(host.label)")
        h.favorite = false
        save(h)
    }

    private func delete(_ host: SshHost) {
        do {
            try model.core.deleteHost(id: host.id)
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

struct HostEdit: Identifiable {
    let id = UUID()
    let host: SshHost?
}

private struct GroupEdit: Identifiable {
    let id = UUID()
    let group: HostGroup
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
                Text("hosts.group.count \(total)").font(.subheadline).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A host: avatar, name, "ssh, user" and its tags. Tapping it connects
/// (while selecting, it selects it).
private struct HostRow: View {
    let host: SshHost
    var selecting = false
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
                    Text(host.label.isEmpty ? host.address : host.label)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if host.favorite { Image(systemName: "star.fill").font(.caption2).foregroundColor(Brand.amber) }
                }
                Text(hostSubtitle(host)).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                if !host.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(host.tags.prefix(3).enumerated()), id: \.offset) { _, tag in
                            TagChip(text: tag)
                        }
                        if host.tags.count > 3 { TagChip(text: "+\(host.tags.count - 3)") }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Name of a group (new or existing).
private struct GroupEditor: View {
    let original: HostGroup
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Account
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                TextField("hosts.group.name", text: $name)
                if let error { Text(error).foregroundColor(Brand.red) }
            }
            .navigationTitle(original.id.isEmpty ? String(localized: "hosts.group.new") : String(localized: "hosts.group.rename"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        var g = original
                        g.name = name.trimmingCharacters(in: .whitespaces)
                        do {
                            _ = try model.core.saveGroup(group: g)
                            account.sync()
                            dismiss()
                        } catch {
                            self.error = errorMessage(error)
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { name = original.name }
    }
}

/// Host picked to open a sheet (SFTP, tunnels).
struct SelectedHost: Identifiable {
    let host: SshHost
    var id: String { host.id }
}
