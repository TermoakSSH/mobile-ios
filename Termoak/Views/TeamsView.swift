import TermoakKit
import SwiftUI

/// Your teams on each signed-in account: their name, your role and how many
/// people are in them. Those of the current account open their page
/// (members, add, roles, rename, delete, leave) and new ones can be created
/// there; the engine manages teams of the current account only.
struct TeamsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @State private var teams: [String: [Team]] = [:]
    @State private var errors: [String: String] = [:]
    @State private var loaded = false
    @State private var creating = false
    @State private var newName = ""
    @State private var error: String?

    private var accounts: [AccountInfo] {
        account.list.filter { $0.status == .active }
    }

    /// The account whose teams can be managed here (the current one).
    private var manageable: String? {
        guard let current = account.current, current.status == .active else { return nil }
        return current.id
    }

    var body: some View {
        List {
            if accounts.isEmpty {
                Section {
                    EmptyState(icon: "person.3",
                               title: String(localized: "desktop.teams.empty.title"),
                               text: String(localized: "desktop.teams.sign_in"))
                        .listRowBackground(Color.clear)
                }
            }
            ForEach(accounts, id: \.id) { a in accountSection(a) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text("desktop.section.teams"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if manageable != nil {
                    Button { newName = ""; creating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(Text("teams.new"))
                }
            }
        }
        .textPrompt(Text("teams.new"), isPresented: $creating, text: $newName,
                    placeholder: String(localized: "teams.name_placeholder"), message: Text("teams.new_hint"),
                    confirm: String(localized: "teams.create"), plain: false) { create() }
        .alert("common.error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: { Text(error ?? "") }
        .refreshable { await load() }
        .task { await load() }
    }

    private func accountSection(_ a: AccountInfo) -> some View {
        Section {
            let list = teams[a.id] ?? []
            if let error = errors[a.id] {
                Text(error).foregroundColor(Brand.red)
            } else if list.isEmpty && loaded {
                Text("desktop.teams.none").foregroundColor(.secondary)
            } else if !loaded {
                ProgressView()
            }
            ForEach(list, id: \.id) { t in
                if a.id == manageable {
                    NavigationLink {
                        TeamDetailView(team: t, me: a.email) { Task { await load() } }
                    } label: { TeamRow(team: t) }
                } else {
                    TeamRow(team: t)
                }
            }
        } header: {
            if accounts.count > 1 { Text(verbatim: a.email) }
        } footer: {
            if a.id == accounts.last?.id {
                Text(manageable == nil ? LocalizedStringKey("desktop.teams.footer") : LocalizedStringKey("teams.footer"))
            }
        }
    }

    private func load() async {
        var found: [String: [Team]] = [:]
        var failed: [String: String] = [:]
        for a in accounts {
            do {
                let list = a.id == manageable ? try await model.core.listTeams() : try await model.core.teams(of: a.id)
                found[a.id] = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            } catch {
                failed[a.id] = userMessage(error)
            }
        }
        teams = found
        errors = failed
        loaded = true
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            do {
                _ = try await model.core.createTeam(name: name)
            } catch {
                self.error = userMessage(error)
            }
            await load()
        }
    }
}

private struct TeamRow: View {
    let team: Team

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 15))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(Color.purple, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: team.name).font(.headline).lineLimit(1)
                Text("vaults.members \(Int(team.memberCount))").font(.subheadline).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            if let role = teamRoleTitle(team.role) {
                Chip(role, Brand.blue)
            }
        }
        .padding(.vertical, 2)
    }
}

/// "Owner", "Admin", "Member" (`nil`: a server admin who is not in it).
private func teamRoleTitle(_ role: TeamRole?) -> String? {
    switch role {
    case .owner: return String(localized: "desktop.teams.role.owner")
    case .admin: return String(localized: "desktop.teams.role.admin")
    case .member: return String(localized: "desktop.teams.role.member")
    default: return nil
    }
}

/// A team of the current account: its members and what your role lets you
/// do (admins add and remove members; owners also change roles, rename and
/// delete it). Anyone can leave.
private struct TeamDetailView: View {
    let team: Team
    /// Your email (to mark yourself in the list).
    let me: String
    let onChange: () -> Void

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var members: [TeamMember] = []
    @State private var loading = true
    @State private var email = ""
    @State private var newRole: TeamRole = .member
    @State private var removing: TeamMember?
    @State private var renaming = false
    @State private var newName = ""
    @State private var deleting = false
    @State private var leaving = false
    @State private var busy = false
    @State private var error: String?

    /// Server admins (no role in it) manage it too.
    private var canManage: Bool { team.role != .member }
    private var isOwner: Bool { team.role == .owner || team.role == nil }

    var body: some View {
        List {
            membersSection
            if canManage { addSection }
            actionsSection
            if let error {
                Section { Text(error).foregroundColor(Brand.red) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(verbatim: name.isEmpty ? team.name : name))
        .navigationBarTitleDisplayMode(.inline)
        .textPrompt(Text("teams.rename"), isPresented: $renaming, text: $newName,
                    placeholder: String(localized: "common.name"), confirm: String(localized: "common.rename"), plain: false) { rename() }
        .confirmationDialog(Text("teams.remove.title \(removing?.email ?? "")"),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("teams.remove", role: .destructive) { if let m = removing { remove(m) } }
        } message: { Text("teams.remove.message") }
        .confirmationDialog(Text("teams.delete.title \(name)"), isPresented: $deleting, titleVisibility: .visible) {
            Button("common.delete", role: .destructive, action: delete)
        } message: { Text("teams.delete.message") }
        .confirmationDialog(Text("teams.leave.title \(name)"), isPresented: $leaving, titleVisibility: .visible) {
            Button("teams.leave", role: .destructive, action: leave)
        } message: { Text("teams.leave.message") }
        .task {
            name = team.name
            await load()
        }
    }

    private var membersSection: some View {
        Section {
            if loading && members.isEmpty { ProgressView() }
            ForEach(members, id: \.userId) { m in
                memberRow(m)
                    .swipeActions {
                        if canManage && m.email != me {
                            Button("teams.remove", role: .destructive) { removing = m }
                        }
                    }
            }
        } header: {
            Text("teams.members")
        }
    }

    private func memberRow(_ m: TeamMember) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: m.name.isEmpty ? m.email : m.name).lineLimit(1)
                Text(verbatim: m.email == me ? "\(m.email) · \(String(localized: "teams.you"))" : m.email)
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if isOwner && m.email != me {
                // The role as a visible menu (not only a long press).
                Menu {
                    ForEach([TeamRole.member, .admin, .owner], id: \.self) { r in
                        Button { setRole(m, r) } label: {
                            if m.role == r {
                                Label(teamRoleTitle(r) ?? "", systemImage: "checkmark")
                            } else {
                                Text(teamRoleTitle(r) ?? "")
                            }
                        }
                    }
                    Divider()
                    Button(role: .destructive) { removing = m } label: { Label("teams.remove", systemImage: "person.badge.minus") }
                } label: {
                    roleChip(m.role, menu: true)
                }
            } else {
                roleChip(m.role, menu: false)
            }
        }
    }

    private func roleChip(_ role: TeamRole, menu: Bool) -> some View {
        HStack(spacing: 3) {
            Text(teamRoleTitle(role) ?? "")
            if menu { Image(systemName: "chevron.up.chevron.down").font(.caption2) }
        }
        .font(.caption.weight(.medium))
        .foregroundColor(Brand.blue)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Brand.blue.opacity(0.12), in: Capsule())
    }

    private var addSection: some View {
        Section {
            TextField("teams.email_placeholder", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if isOwner {
                Picker("teams.role", selection: $newRole) {
                    ForEach([TeamRole.member, .admin, .owner], id: \.self) { r in Text(teamRoleTitle(r) ?? "").tag(r) }
                }
            }
            Button(action: add) {
                HStack {
                    Label("teams.add_member", systemImage: "person.badge.plus")
                    Spacer()
                    if busy { ProgressView() }
                }
            }
            .disabled(busy || !email.contains("@"))
        } header: {
            Text("teams.add_member")
        } footer: {
            Text("teams.add_member_hint")
        }
    }

    private var actionsSection: some View {
        Section {
            if isOwner {
                Button { newName = name; renaming = true } label: { Label("teams.rename", systemImage: "pencil") }
            }
            if team.role != nil {
                Button(role: .destructive) { leaving = true } label: {
                    Label("teams.leave", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
            if isOwner {
                Button(role: .destructive) { deleting = true } label: { Label("teams.delete", systemImage: "trash") }
            }
        }
    }

    // MARK: Actions

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            members = try await model.core.listTeamMembers(teamId: team.id)
                .sorted { ($0.name.isEmpty ? $0.email : $0.name).localizedCaseInsensitiveCompare($1.name.isEmpty ? $1.email : $1.name) == .orderedAscending }
        } catch {
            self.error = userMessage(error)
        }
    }

    private func add() {
        let mail = email.trimmingCharacters(in: .whitespaces)
        let role = isOwner ? newRole : .member
        run {
            members = try await model.core.addTeamMember(teamId: team.id, email: mail, role: role)
            email = ""
            onChange()
        }
    }

    private func setRole(_ m: TeamMember, _ role: TeamRole) {
        guard m.role != role else { return }
        run { members = try await model.core.setTeamMemberRole(teamId: team.id, userId: m.userId, role: role) }
    }

    private func remove(_ m: TeamMember) {
        run {
            try await model.core.removeTeamMember(teamId: team.id, userId: m.userId)
            await load()
            onChange()
        }
    }

    private func rename() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        run {
            name = try await model.core.renameTeam(teamId: team.id, name: n).name
            onChange()
        }
    }

    private func delete() {
        run {
            try await model.core.deleteTeam(teamId: team.id)
            onChange()
            dismiss()
        }
    }

    private func leave() {
        run {
            try await model.core.leaveTeam(teamId: team.id)
            onChange()
            dismiss()
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await action()
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}
