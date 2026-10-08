import TermoakKit
import SwiftUI

/// "View" of a host you can't edit (Use only): what it is and how it
/// connects, without its secrets, and Connect. Like Android's read-only
/// host screen.
struct HostDetailsView: View {
    let host: SshHost
    /// Its vault is Strict: it connects through the server.
    let strict: Bool
    /// Connect (called once the sheet is closing); `true`: on the server.
    let onConnect: (Bool) -> Void
    /// A server session can be opened for it (its account is signed in).
    var canOpenOnServer = false

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String: String] = [:]

    var body: some View {
        NavigationView {
            Form {
                header
                if host.isUseOnly { useOnlySection }
                connectionSection
                organizeSection
                if !host.notes.isEmpty {
                    Section("host_editor.notes") {
                        Text(verbatim: host.notes).font(.body).textSelection(.enabled)
                    }
                }
                actions
            }
            .navigationTitle(host.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: loadNames)
    }

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                HostIcon(host: host, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: host.displayName).font(.headline)
                    Text(verbatim: hostAddressLine(host)).font(.subheadline).foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if host.isTelnet { TelnetBadge() }
            }
            .padding(.vertical, 4)
        }
    }

    /// Use only: you connect, but never see its password or keys (and in a
    /// Strict vault, only through the server).
    private var useOnlySection: some View {
        Section {
            Label {
                Text(strict ? LocalizedStringKey("hosts.use_only.strict") : LocalizedStringKey("hosts.use_only.normal"))
                    .font(.footnote)
            } icon: {
                Image(systemName: "lock.fill").foregroundColor(Brand.amber)
            }
        }
    }

    private var connectionSection: some View {
        Section("host_editor.connection") {
            line("host_editor.protocol", host.isTelnet ? "Telnet" : "SSH")
            line("hosts.details.address", host.address)
            line("hosts.details.port", String(host.effectivePort))
            if let u = host.settings.username, !u.isEmpty { line("hosts.details.username", u) }
            line("host_editor.credentials", credentials)
            if let jumps = host.settings.jumpHostIds, !jumps.isEmpty {
                line("host_editor.jump_chain", jumps.map { names[$0] ?? "?" }.joined(separator: " → "))
            }
        }
    }

    private var organizeSection: some View {
        Section("host_editor.organize") {
            line("host_editor.vault", account.placeTitle(account.place(accountId: host.accountId, vaultId: host.vaultId)))
            line("host_editor.group", host.groupId.flatMap { names[$0] } ?? String(localized: "host_editor.no_group"))
            if !host.tags.isEmpty { line("hosts.details.tags", host.tags.joined(separator: ", ")) }
        }
    }

    @ViewBuilder private var actions: some View {
        Section {
            Button {
                dismiss()
                onConnect(false)
            } label: {
                Label("common.connect", systemImage: "terminal")
            }
            if canOpenOnServer && !strict && !host.isTelnet {
                Button {
                    dismiss()
                    onConnect(true)
                } label: {
                    Label("hosts.menu.persistent", systemImage: "icloud")
                }
            }
        }
    }

    /// The key or identity it uses (by name), or whether it has a password.
    private var credentials: String {
        if let id = host.settings.identityId {
            return String(localized: "hosts.details.identity \(names[id] ?? "?")")
        }
        if let id = host.settings.keyId {
            return String(localized: "hosts.details.key \(names[id] ?? "?")")
        }
        return host.hasPassword || host.secretHidden ? String(localized: "hosts.details.password_saved")
            : String(localized: "hosts.details.asked")
    }

    private func line(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(verbatim: value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    /// Names of the keys, identities, groups and hosts it refers to.
    private func loadNames() {
        let core = model.core
        let f = ItemFilter(accountIds: host.accountId.map { [$0] } ?? [], vaultIds: nil, includeDevice: true)
        var n: [String: String] = [:]
        for k in (try? core.listKeys(filter: f)) ?? [] { n[k.id] = k.label }
        for i in (try? core.listIdentities(filter: f)) ?? [] { n[i.id] = i.label }
        for g in (try? core.listGroups(filter: f)) ?? [] { n[g.id] = g.name }
        for h in (try? core.listHosts(filter: f)) ?? [] { n[h.id] = h.displayName }
        names = n
    }
}
