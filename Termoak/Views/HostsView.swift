import TermoakKit
import SwiftUI

/// Hosts in the style of Termius: search, groups as folders and each host
/// with its colored square. With `groupId`, the contents of a group.
struct HostsView: View {
    let groupId: String?

    var body: some View {
        if groupId == nil {
            NavigationView { HostList(groupId: nil).toolbar { MenuButton() } }
                .navigationViewStyle(.stack)
        } else {
            HostList(groupId: groupId)
        }
    }
}

private struct HostList: View {
    let groupId: String?

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Account
    @EnvironmentObject private var sessions: Sessions

    @State private var hosts: [SshHost] = []
    @State private var groups: [HostGroup] = []
    @State private var query = ""
    @State private var editing: HostEdit?
    @State private var filesHost: SshHost?
    @State private var tunnelsHost: SshHost?
    @State private var deleting: SshHost?
    @State private var editedGroup: GroupEdit?
    @State private var deletingGroup: HostGroup?
    @State private var error: String?

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
        .sorted { a, b in
            if a.favorite != b.favorite { return a.favorite }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
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

    var body: some View {
        List {
            if groupId == nil && !searching && !sessions.onServer.isEmpty {
                Section { serverNotice }
            }
            if !subgroups.isEmpty {
                Section("hosts.groups") {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(subgroups, id: \.id) { g in
                            NavigationLink { HostsView(groupId: g.id) } label: { GroupCard(group: g, total: totalIn(g)) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button { editedGroup = GroupEdit(group: g) } label: { Label("hosts.group.rename", systemImage: "pencil") }
                                    Button(role: .destructive) { deletingGroup = g } label: { Label("hosts.group.delete", systemImage: "trash") }
                                }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            }
            if !visible.isEmpty {
                Section(searching ? String(localized: "hosts.results") : String(localized: "nav.hosts")) {
                    ForEach(visible, id: \.id) { host in
                        HostRow(host: host, onConnect: { connect(host, onServer: false) }) { menu(host) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { deleting = host } label: { Label("common.delete", systemImage: "trash") }
                                Button { editing = HostEdit(host: host) } label: { Label("common.edit", systemImage: "pencil") }
                                    .tint(.orange)
                            }
                            .contextMenu { menu(host) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if hosts.isEmpty && groups.isEmpty {
                EmptyState(
                    icon: "server.rack",
                    title: account.syncing ? String(localized: "common.syncing") : String(localized: "hosts.empty.title"),
                    text: account.loggedIn == true
                        ? String(localized: "hosts.empty.text_synced")
                        : String(localized: "hosts.empty.text_local"),
                    action: String(localized: "common.new_host")
                ) { editing = HostEdit(host: nil) }
            } else if searching && visible.isEmpty {
                Text("hosts.search.no_results \(query)").foregroundColor(.secondary)
            }
        }
        .searchable(text: $query, prompt: Text("hosts.search.prompt"))
        .refreshable {
            if account.loggedIn == true { account.sync() }
            load()
        }
        .navigationTitle(group?.name ?? String(localized: "nav.hosts"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if account.syncing {
                    ProgressView()
                } else if account.loggedIn == true && groupId == nil {
                    Button { account.sync() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                }
                Menu {
                    Button { editing = HostEdit(host: nil) } label: { Label("common.new_host", systemImage: "server.rack") }
                    Button { editedGroup = GroupEdit(group: HostGroup(name: "", parentId: groupId)) } label: {
                        Label("hosts.group.new", systemImage: "folder.badge.plus")
                    }
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editing, onDismiss: load) { e in
            HostEditor(original: e.host, initialGroup: groupId).environmentObject(model).environmentObject(account)
        }
        .sheet(item: $editedGroup, onDismiss: load) { e in
            GroupEditor(original: e.group).environmentObject(model).environmentObject(account)
        }
        .fullScreenCover(item: Binding(get: { filesHost.map(SelectedHost.init) }, set: { filesHost = $0?.host })) { e in
            FilesScreen(core: model.core, title: e.host.label.isEmpty ? e.host.address : e.host.label,
                        source: .connect(hostId: e.host.id))
        }
        .sheet(item: Binding(get: { tunnelsHost.map(SelectedHost.init) }, set: { tunnelsHost = $0?.host })) { e in
            TunnelsView(host: e.host)
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
        .alert("common.error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: { Text(error ?? "") }
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
        Button { tunnelsHost = host } label: { Label("common.tunnels", systemImage: "point.3.connected.trianglepath.dotted") }
        Button { editing = HostEdit(host: host) } label: { Label("common.edit", systemImage: "pencil") }
        Button { toggleFavorite(host) } label: {
            if host.favorite {
                Label("hosts.menu.unfavorite", systemImage: "star.slash")
            } else {
                Label("hosts.menu.favorite", systemImage: "star")
            }
        }
        Button { duplicate(host) } label: { Label("hosts.menu.duplicate", systemImage: "plus.square.on.square") }
        Button(role: .destructive) { deleting = host } label: { Label("common.delete", systemImage: "trash") }
    }

    private func connect(_ host: SshHost, onServer: Bool) {
        if onServer { sessions.openOnServer(host) } else { sessions.openLocal(host) }
    }

    private func load() {
        do {
            hosts = try model.core.listHosts()
            groups = try model.core.listGroups().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func save(_ host: SshHost) {
        do {
            _ = try model.core.saveHost(host: host, password: .keep)
            load()
            account.sync()
        } catch {
            self.error = errorMessage(error)
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
            self.error = errorMessage(error)
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

private struct GroupCard: View {
    let group: HostGroup
    let total: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundColor(.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("hosts.group.count \(total)").font(.caption2).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct HostRow<Actions: View>: View {
    let host: SshHost
    let onConnect: () -> Void
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onConnect) {
                HStack(spacing: 14) {
                    HostTile(name: host.label.isEmpty ? host.address : host.label, os: host.os)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(host.label.isEmpty ? host.address : host.label).font(.headline).lineLimit(1)
                            if host.favorite { Image(systemName: "star.fill").font(.caption2).foregroundColor(Brand.amber) }
                        }
                        Text(hostSubtitle(host)).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu { actions() } label: {
                Image(systemName: "ellipsis").foregroundColor(.secondary).frame(width: 32, height: 32)
            }
        }
        .padding(.vertical, 2)
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
