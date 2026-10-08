import TermoakKit
import SwiftUI

/// Your teams on each signed-in account (or one account's: `accountId`):
/// their name, your role and how many people are in them. Each opens its
/// page (members, invitations, roles, rename, delete, leave) and new ones
/// are created on any account, all through that account's `AccountHandle`.
struct TeamsView: View {
    /// Only this account's teams (an account's page); `nil`: every account.
    var accountId: String? = nil

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @State private var teams: [String: [Team]] = [:]
    @State private var errors: [String: String] = [:]
    @State private var loaded = false
    @State private var creating = false
    /// Account the new team goes to.
    @State private var creatingIn: String?
    @State private var newName = ""
    @State private var error: String?

    private var accounts: [AccountInfo] {
        account.list.filter { $0.status == .active && (accountId == nil || $0.id == accountId) }
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
                if accounts.count == 1, let only = accounts.first {
                    Button { startCreating(in: only.id) } label: { Image(systemName: "plus") }
                        .accessibilityLabel(Text("teams.new"))
                } else if accounts.count > 1 {
                    Menu {
                        ForEach(accounts, id: \.id) { a in
                            Button(a.displayLabel) { startCreating(in: a.id) }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
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
                NavigationLink {
                    TeamDetailView(accountId: a.id, team: t, me: a.email) { Task { await load() } }
                } label: { TeamRow(team: t) }
            }
        } header: {
            if account.list.count > 1 { Text(verbatim: a.displayLabel) }
        } footer: {
            if a.id == accounts.last?.id { Text("teams.footer") }
        }
    }

    private func startCreating(in accountId: String) {
        creatingIn = accountId
        newName = ""
        creating = true
    }

    private func load() async {
        var found: [String: [Team]] = [:]
        var failed: [String: String] = [:]
        for a in accounts {
            do {
                let list = try await model.core.account(accountId: a.id).listTeams()
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
        guard !name.isEmpty, let id = creatingIn else { return }
        Task {
            do {
                _ = try await model.core.account(accountId: id).createTeam(name: name)
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
            if let role = team.role {
                Chip(teamRoleTitle(role), Brand.blue)
            }
        }
        .padding(.vertical, 2)
    }
}

extension TeamRole {
    var level: TeamLevel {
        switch self {
        case .member: return .member
        case .admin: return .admin
        case .owner: return .owner
        }
    }

    init(_ level: TeamLevel) {
        switch level {
        case .member: self = .member
        case .admin: self = .admin
        case .owner: self = .owner
        }
    }
}

/// "Owner", "Admin", "Member".
func teamRoleTitle(_ role: TeamRole) -> String {
    switch role {
    case .owner: return String(localized: "desktop.teams.role.owner")
    case .admin: return String(localized: "desktop.teams.role.admin")
    case .member: return String(localized: "desktop.teams.role.member")
    }
}

/// An invitation to sign up just created for a team (to send its link).
private struct CreatedTeamInvite: Identifiable {
    let id = UUID()
    let email: String
    let link: String
    let emailed: Bool
}

/// A team of one account: its members, the invitations waiting to be used
/// and what your role lets you do (the desktop's rules, TeamRules.swift).
/// Adding by email puts someone with an account in it at once; without one
/// it creates an invitation to sign up (emailed when the server can, and a
/// link to send otherwise).
private struct TeamDetailView: View {
    let accountId: String
    let team: Team
    /// Your email (to mark yourself in the list).
    let me: String
    let onChange: () -> Void

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var members: [TeamMember] = []
    @State private var invites: [AccountInvite] = []
    @State private var loading = true
    @State private var email = ""
    @State private var newRole: TeamLevel = .member
    @State private var removing: TeamMember?
    @State private var revoking: AccountInvite?
    @State private var renaming = false
    @State private var newName = ""
    @State private var deleting = false
    @State private var leaving = false
    @State private var created: CreatedTeamInvite?
    @State private var addedNotice: String?
    @State private var busy = false
    @State private var error: String?

    private var rules: TeamRules { TeamRules(mine: team.role?.level) }

    var body: some View {
        List {
            membersSection
            if rules.canAddMembers { addSection }
            if rules.canSeeInvites && !invites.isEmpty { invitesSection }
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
        .modifier(TeamDialogs(name: name, removing: $removing, revoking: $revoking, deleting: $deleting, leaving: $leaving,
                              onRemove: remove, onRevoke: revoke, onDelete: delete, onLeave: leave))
        .sheet(item: $created) { c in TeamInviteSheet(invite: c) }
        .task {
            name = team.name
            await load()
        }
    }

    // MARK: Sections

    private var membersSection: some View {
        Section {
            if loading && members.isEmpty { ProgressView() }
            ForEach(members, id: \.userId) { m in
                memberRow(m)
                    .swipeActions {
                        if rules.canRemove(m.role.level) && m.email != me {
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
            memberMenu(m)
        }
    }

    /// The role as a visible menu (not only a long press) when it can change.
    @ViewBuilder private func memberMenu(_ m: TeamMember) -> some View {
        let roles = rules.roles(for: m.role.level)
        let canRemove = rules.canRemove(m.role.level)
        if m.email != me && (roles.count > 1 || canRemove) {
            Menu {
                ForEach(roles, id: \.self) { r in
                    Button { setRole(m, TeamRole(r)) } label: {
                        if m.role.level == r {
                            Label(teamRoleTitle(TeamRole(r)), systemImage: "checkmark")
                        } else {
                            Text(teamRoleTitle(TeamRole(r)))
                        }
                    }
                }
                if canRemove {
                    Divider()
                    Button(role: .destructive) { removing = m } label: { Label("teams.remove", systemImage: "person.badge.minus") }
                }
            } label: {
                RoleChip(role: m.role, menu: true)
            }
        } else {
            RoleChip(role: m.role, menu: false)
        }
    }

    private var addSection: some View {
        Section {
            TextField("teams.email_placeholder", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Picker("teams.role", selection: $newRole) {
                ForEach(rules.rolesToGrant, id: \.self) { r in Text(teamRoleTitle(TeamRole(r))).tag(r) }
            }
            Button(action: add) {
                HStack {
                    Label("teams.add_member", systemImage: "person.badge.plus")
                    Spacer()
                    if busy { ProgressView() }
                }
            }
            .disabled(busy || !email.contains("@"))
            if let addedNotice {
                Label(addedNotice, systemImage: "checkmark.circle.fill").foregroundColor(Brand.green).font(.footnote)
            }
        } header: {
            Text("teams.add_member")
        } footer: {
            Text("teams.add_member_hint.invite")
        }
    }

    private var invitesSection: some View {
        Section {
            ForEach(invites, id: \.id) { i in
                inviteRow(i)
                    .swipeActions {
                        Button("teams.invites.revoke", role: .destructive) { revoking = i }
                    }
                    .contextMenu {
                        Button(role: .destructive) { revoking = i } label: {
                            Label("teams.invites.revoke", systemImage: "xmark.circle")
                        }
                    }
            }
        } header: {
            Text("teams.invites")
        } footer: {
            Text("teams.invites.footer")
        }
    }

    private func inviteRow(_ i: AccountInvite) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope").foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: i.email ?? String(localized: "teams.invites.anyone")).lineLimit(1)
                if let expires = i.expiresAt {
                    Text("teams.invites.expires \(relativeTime(expires))").font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 8)
            RoleChip(role: i.teamRole ?? .member, menu: false)
        }
    }

    private var actionsSection: some View {
        Section {
            if rules.canRename {
                Button { newName = name; renaming = true } label: { Label("teams.rename", systemImage: "pencil") }
            }
            if rules.canLeave {
                Button(role: .destructive) { leaving = true } label: {
                    Label("teams.leave", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
            if rules.canDelete {
                Button(role: .destructive) { deleting = true } label: { Label("teams.delete", systemImage: "trash") }
            }
        }
    }

    // MARK: Actions

    private func handle() throws -> AccountHandle {
        try model.core.account(accountId: accountId)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let h = try handle()
            members = try await h.listTeamMembers(teamId: team.id)
                .sorted { ($0.name.isEmpty ? $0.email : $0.name).localizedCaseInsensitiveCompare($1.name.isEmpty ? $1.email : $1.name) == .orderedAscending }
            if rules.canSeeInvites {
                invites = ((try? await h.listTeamInvites(teamId: team.id)) ?? [])
                    .filter { !$0.revoked && $0.usedAt == nil }
            }
        } catch {
            self.error = userMessage(error)
        }
    }

    private func add() {
        let mail = email.trimmingCharacters(in: .whitespaces)
        let role = TeamRole(rules.rolesToGrant.contains(newRole) ? newRole : .member)
        addedNotice = nil
        run {
            let result = try await handle().inviteToTeam(teamId: team.id, email: mail, role: role)
            email = ""
            if result.added {
                members = result.members
                addedNotice = String(localized: "teams.added \(mail)")
            } else if let invite = result.invite {
                created = CreatedTeamInvite(email: mail, link: invite.appLink, emailed: result.emailed)
                await load()
            }
            onChange()
        }
    }

    private func setRole(_ m: TeamMember, _ role: TeamRole) {
        guard m.role != role else { return }
        run { members = try await handle().setTeamMemberRole(teamId: team.id, userId: m.userId, role: role) }
    }

    private func remove(_ m: TeamMember) {
        run {
            try await handle().removeTeamMember(teamId: team.id, userId: m.userId)
            await load()
            onChange()
        }
    }

    private func revoke(_ i: AccountInvite) {
        run {
            try await handle().revokeTeamInvite(teamId: team.id, inviteId: i.id)
            invites.removeAll { $0.id == i.id }
        }
    }

    private func rename() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        run {
            name = try await handle().renameTeam(teamId: team.id, name: n).name
            onChange()
        }
    }

    private func delete() {
        run {
            try await handle().deleteTeam(teamId: team.id)
            onChange()
            dismiss()
        }
    }

    private func leave() {
        run {
            try await handle().leaveTeam(teamId: team.id)
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

/// The confirmations of a team's page (kept apart so its body stays small).
private struct TeamDialogs: ViewModifier {
    let name: String
    @Binding var removing: TeamMember?
    @Binding var revoking: AccountInvite?
    @Binding var deleting: Bool
    @Binding var leaving: Bool
    let onRemove: (TeamMember) -> Void
    let onRevoke: (AccountInvite) -> Void
    let onDelete: () -> Void
    let onLeave: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(Text("teams.remove.title \(removing?.email ?? "")"),
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button("teams.remove", role: .destructive) { if let m = removing { onRemove(m) } }
            } message: { Text("teams.remove.message") }
            .confirmationDialog(Text("teams.invites.revoke.title \(revoking?.email ?? String(localized: "teams.invites.anyone"))"),
                                isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                                titleVisibility: .visible) {
                Button("teams.invites.revoke", role: .destructive) { if let i = revoking { onRevoke(i) } }
            } message: { Text("teams.invites.revoke.message") }
            .confirmationDialog(Text("teams.delete.title \(name)"), isPresented: $deleting, titleVisibility: .visible) {
                Button("common.delete", role: .destructive, action: onDelete)
            } message: { Text("teams.delete.message") }
            .confirmationDialog(Text("teams.leave.title \(name)"), isPresented: $leaving, titleVisibility: .visible) {
                Button("teams.leave", role: .destructive, action: onLeave)
            } message: { Text("teams.leave.message") }
    }
}

private struct RoleChip: View {
    let role: TeamRole
    let menu: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text(teamRoleTitle(role))
            if menu { Image(systemName: "chevron.up.chevron.down").font(.caption2) }
        }
        .font(.caption.weight(.medium))
        .foregroundColor(Brand.blue)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Brand.blue.opacity(0.12), in: Capsule())
    }
}

/// The invitation just created for someone without an account: emailed or
/// not, its link to send (copy, share, QR code to scan).
private struct TeamInviteSheet: View {
    let invite: CreatedTeamInvite
    @Environment(\.dismiss) private var dismiss
    @State private var sharing = false
    @State private var showingQr = false
    @State private var copied = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Label(invite.emailed ? String(localized: "teams.invite_created.emailed \(invite.email)")
                                         : String(localized: "teams.invite_created.send \(invite.email)"),
                          systemImage: invite.emailed ? "envelope.badge" : "link")
                } footer: {
                    Text("teams.invite_created.footer")
                }
                Section {
                    Text(verbatim: invite.link)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = invite.link
                        copied = true
                    } label: {
                        Label(copied ? String(localized: "share.link.copied") : String(localized: "share.link.copy"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button { sharing = true } label: { Label("share.menu.share", systemImage: "square.and.arrow.up") }
                    Button { showingQr = true } label: { Label("teams.invite_created.qr", systemImage: "qrcode") }
                }
            }
            .navigationTitle("teams.invite_created.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
            .sheet(isPresented: $sharing) { ActivityView(items: [invite.link]) }
            .sheet(isPresented: $showingQr) {
                QRCodeSheet(title: String(localized: "teams.invite_created.title"), text: invite.link)
            }
        }
        .navigationViewStyle(.stack)
    }
}
