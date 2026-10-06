import TermoakKit
import SwiftUI

/// The vaults of an account (or of every account): your personal vault,
/// the ones you created or that were shared with you, and your teams'.
struct VaultsView: View {
    /// `nil`: every account that has vaults.
    var accountId: String? = nil
    /// Shown in a sheet (with a Done button).
    var closable = false

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss

    /// Fresh from the servers (counts and roles); the local copy until then.
    @State private var fresh: [String: [VaultInfo]] = [:]
    @State private var creatingFor: CreateVaultItem?
    @State private var error: String?

    private var accounts: [AccountInfo] {
        account.list.filter { $0.vaultsSupported && (accountId == nil || $0.id == accountId) }
    }

    private func vaults(of a: AccountInfo) -> [VaultInfo] {
        let list = fresh[a.id] ?? account.vaults(of: a.id)
        // Personal first, then by name.
        return list.sorted { x, y in
            if (x.kind == .personal) != (y.kind == .personal) { return x.kind == .personal }
            return x.displayName.localizedCaseInsensitiveCompare(y.displayName) == .orderedAscending
        }
    }

    var body: some View {
        List {
            if accounts.isEmpty {
                Text("vaults.unsupported").foregroundColor(.secondary)
            }
            ForEach(accounts, id: \.id) { a in
                Section {
                    ForEach(vaults(of: a), id: \.key) { v in
                        NavigationLink { VaultDetailView(vault: v) } label: { VaultRow(vault: v) }
                    }
                    if a.status == .active {
                        Button { creatingFor = CreateVaultItem(accountId: a.id) } label: {
                            Label("vaults.new", systemImage: "plus")
                        }
                    }
                } header: {
                    if accounts.count > 1 || accountId == nil && account.list.count > 1 { Text(verbatim: a.email) }
                }
            }
            if let error {
                Section { Text(error).foregroundColor(Brand.red) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("vaults.title")
        .toolbar {
            if closable {
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .onReceive(account.vaultChanged) { Task { await load() } }
        .sheet(item: $creatingFor) { item in
            VaultEditor(accountId: item.accountId, original: nil)
                .environmentObject(model).environmentObject(account)
        }
    }

    private func load() async {
        var out: [String: [VaultInfo]] = [:]
        for a in accounts where a.status == .active {
            do {
                out[a.id] = try await model.core.account(accountId: a.id).listVaults()
            } catch {
                // Offline: the local copy stays.
            }
        }
        fresh = out
    }
}

private struct CreateVaultItem: Identifiable {
    let accountId: String
    var id: String { accountId }
}

/// A vault: icon, name, owner and your role.
struct VaultRow: View {
    let vault: VaultInfo

    var body: some View {
        HStack(spacing: 12) {
            VaultIcon(vault: vault, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: vault.displayName).font(.headline).lineLimit(1)
                    if vault.strict {
                        Image(systemName: "lock.shield.fill").font(.caption).foregroundColor(Brand.amber)
                            .accessibilityLabel(Text("vaults.strict"))
                    }
                }
                Text(verbatim: subtitleText).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(verbatim: vault.role.title)
                .font(.caption2.weight(.semibold))
                .foregroundColor(vault.role == .useOnly ? Brand.amber : .secondary)
        }
        .padding(.vertical, 2)
    }
}

struct VaultIcon: View {
    let vault: VaultInfo
    var size: CGFloat = 38

    var body: some View {
        let tint = vaultColor(vault)
        Image(systemName: vaultSymbol(vault.icon, kind: vault.kind))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - One vault

/// A vault: rename it, its color and icon, its members and their roles,
/// the Strict switch, leaving it or deleting it.
struct VaultDetailView: View {
    @State var vault: VaultInfo

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss

    @State private var members: [VaultMember] = []
    @State private var loadingMembers = false
    @State private var editing = false
    @State private var addingMember = false
    @State private var deleting = false
    @State private var confirmLeave = false
    @State private var removing: VaultMember?
    @State private var busy = false
    @State private var error: String?

    private var handle: AccountHandle? { try? model.core.account(accountId: vault.accountId) }
    private var personal: Bool { vault.kind == .personal }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    VaultIcon(vault: vault, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: vault.displayName).font(.title3.weight(.semibold))
                        Text(verbatim: VaultRow(vault: vault).subtitleText)
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
                if !vault.description.isEmpty {
                    Text(verbatim: vault.description).foregroundColor(.secondary)
                }
                HStack {
                    Text("vaults.your_role")
                    Spacer()
                    Text(verbatim: vault.role.title).foregroundColor(vault.role == .useOnly ? Brand.amber : .secondary)
                }
                if vault.role == .useOnly {
                    Text(vault.strict ? String(localized: "vaults.use_only.strict_hint") : String(localized: "vaults.use_only.hint"))
                        .font(.footnote).foregroundColor(.secondary)
                }
                if vault.canManage {
                    Button { editing = true } label: { Label("vaults.edit", systemImage: "pencil") }
                }
            }

            if !personal {
                if vault.canManage {
                    Section {
                        Toggle(isOn: Binding(get: { vault.strict }, set: { setStrict($0) })) {
                            Label("vaults.strict", systemImage: "lock.shield")
                        }
                        .disabled(busy)
                        if vault.kind == .team {
                            Picker("vaults.team_member_role", selection: Binding(get: { teamRoleChoice }, set: { setTeamRole($0) })) {
                                Text("vaults.role.editor").tag(TeamAccess.editor)
                                Text("vaults.role.use_only").tag(TeamAccess.useOnly)
                                Text("vaults.team_access.none").tag(TeamAccess.none)
                            }
                            .disabled(busy)
                        }
                    } footer: {
                        Text("vaults.strict.footer")
                    }
                } else if vault.strict {
                    Section {
                        Label("vaults.strict", systemImage: "lock.shield.fill").foregroundColor(Brand.amber)
                    } footer: {
                        Text("vaults.strict.footer")
                    }
                }

                Section {
                    if loadingMembers && members.isEmpty {
                        ProgressView()
                    }
                    ForEach(members, id: \.id) { m in
                        MemberRow(member: m)
                            .contextMenu { memberMenu(m) }
                            .swipeActions {
                                if vault.canManage && !m.implicit {
                                    Button("vaults.member.remove", role: .destructive) { removing = m }
                                }
                            }
                    }
                    if vault.canManage {
                        Button { addingMember = true } label: { Label("vaults.member.add", systemImage: "person.badge.plus") }
                    }
                } header: {
                    Text("vaults.members.title")
                } footer: {
                    Text("vaults.roles.footer")
                }
            }

            if let error {
                Section { Text(error).foregroundColor(Brand.red) }
            }

            if !personal {
                Section {
                    if vault.canManage {
                        Button("vaults.delete", role: .destructive) { deleting = true }
                    } else {
                        Button("vaults.leave", role: .destructive) { confirmLeave = true }
                    }
                }
            }
        }
        .navigationTitle(vault.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(isPresented: $editing, onDismiss: { Task { await reload() } }) {
            VaultEditor(accountId: vault.accountId, original: vault)
                .environmentObject(model).environmentObject(account)
        }
        .sheet(isPresented: $addingMember, onDismiss: { Task { await reload() } }) {
            AddVaultMemberView(vault: vault).environmentObject(model)
        }
        .sheet(isPresented: $deleting) {
            DeleteVaultView(vault: vault) { dismiss() }
                .environmentObject(model).environmentObject(account)
        }
        .confirmationDialog(Text("vaults.leave.title \(vault.displayName)"), isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("vaults.leave", role: .destructive) { leave() }
        } message: { Text("vaults.leave.message") }
        .confirmationDialog(Text("vaults.member.remove.title \(removing?.name ?? "")"),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("vaults.member.remove", role: .destructive) { if let m = removing { remove(m) } }
        } message: { Text("vaults.member.remove.message") }
    }

    @ViewBuilder private func memberMenu(_ m: VaultMember) -> some View {
        if vault.canManage && !m.implicit {
            if m.role != .editor {
                Button { setRole(m, .editor) } label: { Label("vaults.role.make_editor", systemImage: "pencil") }
            }
            if m.role != .useOnly {
                Button { setRole(m, .useOnly) } label: { Label("vaults.role.make_use_only", systemImage: "lock") }
            }
            Button(role: .destructive) { removing = m } label: { Label("vaults.member.remove", systemImage: "person.badge.minus") }
        }
    }

    private enum TeamAccess: Hashable { case editor, useOnly, none }

    private var teamRoleChoice: TeamAccess {
        switch vault.teamMemberRole {
        case .some(.useOnly): return .useOnly
        case .some(.editor), .some(.manager): return .editor
        default: return .none
        }
    }

    private func reload() async {
        guard let handle else { return }
        if let list = try? await handle.listVaults(), let v = list.first(where: { $0.id == vault.id }) {
            vault = v
        }
        guard !personal else { return }
        loadingMembers = true
        defer { loadingMembers = false }
        do {
            members = try await handle.vaultMembers(vaultId: vault.id)
        } catch {
            self.error = userMessage(error)
        }
    }

    private func update(_ changes: VaultChanges) {
        guard let handle else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                vault = try await handle.updateVault(vaultId: vault.id, changes: changes)
                account.reload()
                account.vaultChanged.send()
            } catch {
                self.error = userMessage(error)
            }
        }
    }

    private func setStrict(_ on: Bool) {
        update(VaultChanges(strict: on))
    }

    private func setTeamRole(_ a: TeamAccess) {
        switch a {
        case .editor: update(VaultChanges(teamMemberRole: .editor))
        case .useOnly: update(VaultChanges(teamMemberRole: .useOnly))
        case .none: update(VaultChanges(noTeamAccess: true))
        }
    }

    private func setRole(_ m: VaultMember, _ role: VaultRole) {
        guard let handle else { return }
        Task {
            do {
                _ = try await handle.setVaultMemberRole(vaultId: vault.id, memberId: m.id, role: role)
                await reload()
            } catch {
                self.error = userMessage(error)
            }
        }
    }

    private func remove(_ m: VaultMember) {
        guard let handle else { return }
        Task {
            do {
                try await handle.removeVaultMember(vaultId: vault.id, memberId: m.id)
                await reload()
            } catch {
                self.error = userMessage(error)
            }
        }
    }

    private func leave() {
        guard let handle else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await handle.leaveVault(vaultId: vault.id)
                account.reload()
                account.vaultChanged.send()
                dismiss()
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}

extension VaultRow {
    /// "Team Ops · 4 hosts · 3 members".
    var subtitleText: String {
        var parts: [String] = []
        switch vault.kind {
        case .personal: parts.append(String(localized: "vaults.kind.personal"))
        case .team: parts.append(String(localized: "vaults.kind.team \(vault.teamName ?? "")"))
        default:
            if let owner = vault.ownerName, vault.role != .manager {
                parts.append(String(localized: "vaults.kind.shared_by \(owner)"))
            } else {
                parts.append(String(localized: "vaults.kind.shared"))
            }
        }
        parts.append(String(localized: "vaults.hosts \(Int(vault.hostCount))"))
        if vault.kind != .personal {
            parts.append(String(localized: "vaults.members \(Int(vault.memberCount))"))
        }
        return parts.joined(separator: " · ")
    }
}

/// A member: person or team, and their role.
private struct MemberRow: View {
    let member: VaultMember

    var body: some View {
        HStack(spacing: 12) {
            if member.kind == .team {
                Image(systemName: "person.3.fill")
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.purple, in: Circle())
            } else {
                ParticipantAvatar(name: member.name.isEmpty ? (member.email ?? "?") : member.name, size: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: member.name.isEmpty ? (member.email ?? "?") : member.name).lineLimit(1)
                if let email = member.email, !member.name.isEmpty {
                    Text(verbatim: email).font(.caption).foregroundColor(.secondary).lineLimit(1)
                } else if member.kind == .team {
                    Text("vaults.member.team").font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: member.role.title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(member.role == .useOnly ? Brand.amber : .secondary)
                if member.implicit {
                    Text("vaults.member.implicit").font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Create / edit

/// New vault (yours or a team's) or the name, color, icon and Strict switch
/// of an existing one.
struct VaultEditor: View {
    let accountId: String
    let original: VaultInfo?

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var summary = ""
    @State private var color: String?
    @State private var icon: String?
    @State private var strict = false
    /// Owner of a new vault: you (`nil`) or a team you manage.
    @State private var teamId: String?
    @State private var teamRole: VaultRole = .editor
    @State private var teams: [Team] = []
    @State private var busy = false
    @State private var error: String?

    private var personal: Bool { original?.kind == .personal }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("vaults.name", text: $name)
                    if !personal {
                        TextField("vaults.description", text: $summary)
                    }
                }
                if original == nil && !teams.isEmpty {
                    Section {
                        Picker("vaults.owner", selection: $teamId) {
                            Text("vaults.owner.me").tag(String?.none)
                            ForEach(teams, id: \.id) { t in Text(verbatim: t.name).tag(Optional(t.id)) }
                        }
                        if teamId != nil {
                            Picker("vaults.team_member_role", selection: $teamRole) {
                                Text("vaults.role.editor").tag(VaultRole.editor)
                                Text("vaults.role.use_only").tag(VaultRole.useOnly)
                            }
                        }
                    } footer: {
                        Text("vaults.owner.footer")
                    }
                }
                Section("vaults.color") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 30, maximum: 40), spacing: 8)], alignment: .leading, spacing: 8) {
                        Button { color = nil } label: {
                            Circle()
                                .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                                .frame(width: 24, height: 24)
                                .padding(3)
                                .overlay(Circle().stroke(color == nil ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("host_editor.color.auto")
                        ForEach(Array(hostPalette.enumerated()), id: \.offset) { i, value in
                            let hex = String(format: "#%06x", value)
                            Button { color = hex } label: {
                                Circle()
                                    .fill(Color(hex: value))
                                    .frame(width: 24, height: 24)
                                    .padding(3)
                                    .overlay(Circle().stroke(color?.lowercased() == hex ? Color.primary : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("host_editor.color.option \(i + 1)"))
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("vaults.icon") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 52), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(vaultIcons, id: \.name) { item in
                            Button { icon = item.name } label: {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 18))
                                    .frame(width: 40, height: 40)
                                    .foregroundColor(icon == item.name ? .white : .primary)
                                    .background(icon == item.name ? Color.accentColor : Color(.tertiarySystemFill),
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text(verbatim: item.name))
                        }
                    }
                    .padding(.vertical, 4)
                }
                if !personal && original == nil {
                    Section {
                        Toggle("vaults.strict", isOn: $strict)
                    } footer: {
                        Text("vaults.strict.footer")
                    }
                }
                if let error {
                    Section { Text(error).foregroundColor(Brand.red) }
                }
            }
            .navigationTitle(original == nil ? String(localized: "vaults.new") : String(localized: "vaults.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(original == nil ? String(localized: "vaults.create") : String(localized: "common.save")) { save() }
                        .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        if let v = original {
            name = v.kind == .personal ? v.displayName : v.name
            summary = v.description
            color = v.color
            icon = v.icon
            strict = v.strict
            return
        }
        let core = model.core
        let id = accountId
        Task {
            // Teams where you are an owner or admin can own vaults.
            let all = (try? await core.teams(of: id)) ?? []
            teams = all.filter { $0.role == .owner || $0.role == .admin }
        }
    }

    private func save() {
        guard let handle = try? model.core.account(accountId: accountId) else { return }
        busy = true
        error = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        Task {
            defer { busy = false }
            do {
                if let v = original {
                    var changes = VaultChanges()
                    if trimmed != v.name && !(v.kind == .personal && trimmed == v.displayName) { changes.name = trimmed }
                    if v.kind != .personal && summary != v.description { changes.description = summary }
                    if color != v.color {
                        if let color { changes.color = color } else { changes.clearColor = true }
                    }
                    if icon != v.icon {
                        if let icon { changes.icon = icon } else { changes.clearIcon = true }
                    }
                    _ = try await handle.updateVault(vaultId: v.id, changes: changes)
                } else {
                    _ = try await handle.createVault(vault: NewVault(
                        name: trimmed, description: summary.isEmpty ? nil : summary, color: color, icon: icon,
                        teamId: teamId, teamMemberRole: teamId == nil ? nil : teamRole, strict: strict))
                }
                account.reload()
                account.vaultChanged.send()
                dismiss()
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}

// MARK: - Members

/// Share a vault with someone (by email) or with a team, as Editor or
/// Use only.
struct AddVaultMemberView: View {
    let vault: VaultInfo

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var byTeam = false
    @State private var email = ""
    @State private var teamId: String?
    @State private var role: VaultRole = .editor
    @State private var teams: [Team] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("", selection: $byTeam) {
                        Text("vaults.member.by_email").tag(false)
                        Text("vaults.member.by_team").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if byTeam {
                        if teams.isEmpty {
                            Text("vaults.member.no_teams").foregroundColor(.secondary)
                        } else {
                            Picker("vaults.member.team", selection: $teamId) {
                                Text("common.choose").tag(String?.none)
                                ForEach(teams, id: \.id) { t in Text(verbatim: t.name).tag(Optional(t.id)) }
                            }
                        }
                    } else {
                        TextField("login.email", text: $email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                Section {
                    Picker("vaults.member.role", selection: $role) {
                        Text("vaults.role.editor").tag(VaultRole.editor)
                        Text("vaults.role.use_only").tag(VaultRole.useOnly)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("vaults.member.role")
                } footer: {
                    Text(role == .editor ? String(localized: "vaults.role.editor.footer") : String(localized: "vaults.role.use_only.footer"))
                }
                if let error {
                    Section { Text(error).foregroundColor(Brand.red) }
                }
            }
            .navigationTitle("vaults.member.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("vaults.member.add.action") { add() }
                        .disabled(busy || (byTeam ? teamId == nil : !email.contains("@")))
                }
            }
        }
        .task {
            // Teams you belong to.
            teams = (try? await model.core.teams(of: vault.accountId)) ?? []
        }
    }

    private func add() {
        guard let handle = try? model.core.account(accountId: vault.accountId) else { return }
        let target: VaultMemberTarget
        if byTeam, let teamId {
            target = .team(teamId: teamId)
        } else {
            target = .user(email: email.trimmingCharacters(in: .whitespaces))
        }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                _ = try await handle.addVaultMember(vaultId: vault.id, target: target, role: role)
                dismiss()
            } catch TermoakError.NotFound {
                error = String(localized: "vaults.member.not_found")
            } catch TermoakError.Conflict {
                error = String(localized: "vaults.member.exists")
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}

// MARK: - Delete

/// Deleting a vault deletes its items for every member: type its name to
/// confirm.
struct DeleteVaultView: View {
    let vault: VaultInfo
    let onDeleted: () -> Void

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss

    @State private var typed = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text("vaults.delete.message \(vault.name) \(Int(vault.hostCount)) \(Int(vault.memberCount))")
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(vault.name, text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("vaults.delete.footer \(vault.name)")
                }
                if let error {
                    Section { Text(error).foregroundColor(Brand.red) }
                }
                Section {
                    Button(role: .destructive) { delete() } label: {
                        HStack {
                            Text("vaults.delete")
                            Spacer()
                            if busy { ProgressView() }
                        }
                    }
                    .disabled(busy || typed.trimmingCharacters(in: .whitespaces) != vault.name)
                }
            }
            .navigationTitle("vaults.delete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
            }
        }
    }

    private func delete() {
        guard let handle = try? model.core.account(accountId: vault.accountId) else { return }
        busy = true
        error = nil
        let name = typed.trimmingCharacters(in: .whitespaces)
        Task {
            defer { busy = false }
            do {
                try await handle.deleteVault(vaultId: vault.id, confirmName: name)
                account.reload()
                account.vaultChanged.send()
                dismiss()
                onDeleted()
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}
