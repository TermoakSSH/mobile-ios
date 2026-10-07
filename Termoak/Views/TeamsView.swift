import TermoakKit
import SwiftUI

/// Your teams on each signed-in account (Teams in the sidebar of the desktop
/// layout): their name, your role and how many people are in them. Teams
/// are created and managed on the web or in the desktop app.
struct TeamsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @State private var teams: [String: [Team]] = [:]
    @State private var errors: [String: String] = [:]
    @State private var loaded = false

    private var accounts: [AccountInfo] {
        account.list.filter { $0.status == .active }
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
            ForEach(accounts, id: \.id) { a in
                Section {
                    let list = teams[a.id] ?? []
                    if let error = errors[a.id] {
                        Text(error).foregroundColor(Brand.red)
                    } else if list.isEmpty && loaded {
                        Text("desktop.teams.none").foregroundColor(.secondary)
                    } else if !loaded {
                        ProgressView()
                    }
                    ForEach(list, id: \.id) { t in TeamRow(team: t) }
                } header: {
                    if accounts.count > 1 { Text(verbatim: a.email) }
                } footer: {
                    if a.id == accounts.last?.id { Text("desktop.teams.footer") }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text("desktop.section.teams"))
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        var found: [String: [Team]] = [:]
        var failed: [String: String] = [:]
        for a in accounts {
            do {
                found[a.id] = try await model.core.teams(of: a.id)
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            } catch {
                failed[a.id] = userMessage(error)
            }
        }
        teams = found
        errors = failed
        loaded = true
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
            if let role = roleTitle {
                Chip(role, Brand.blue)
            }
        }
        .padding(.vertical, 2)
    }

    private var roleTitle: String? {
        switch team.role {
        case .owner: return String(localized: "desktop.teams.role.owner")
        case .admin: return String(localized: "desktop.teams.role.admin")
        case .member: return String(localized: "desktop.teams.role.member")
        default: return nil
        }
    }
}
