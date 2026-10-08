import TermoakKit
import SwiftUI

/// Settings → Accounts: every account on this device with its status,
/// server and last sync; add another one.
struct AccountsView: View {
    /// Shown in a sheet (with a Done button).
    var closable = false

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(account.list, id: \.id) { a in
                    NavigationLink { AccountDetailView(accountId: a.id) } label: { AccountRow(info: a) }
                }
                Button { adding = true } label: {
                    Label("accounts.add", systemImage: "person.crop.circle.badge.plus")
                }
            } footer: {
                Text("accounts.footer")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("accounts.title")
        .toolbar {
            if closable {
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
        }
        .sheet(isPresented: $adding) {
            LoginView(welcome: false) {}.environmentObject(account).environmentObject(settings)
        }
        .onAppear { account.reload() }
    }
}

/// An account: avatar, email, server and status.
struct AccountRow: View {
    let info: AccountInfo
    @EnvironmentObject private var account: Accounts

    var body: some View {
        HStack(spacing: 12) {
            AccountAvatar(account: info, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: info.email).font(.headline).lineLimit(1)
                    if info.isCurrent && account.list.count > 1 {
                        Text("accounts.current").font(.caption2.weight(.semibold)).foregroundColor(.accentColor)
                    }
                }
                Text(verbatim: info.official ? officialHost : info.serverName)
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                AccountStatusText(info: info).font(.caption)
            }
            Spacer(minLength: 0)
            if account.syncingIds.contains(info.id) { ProgressView() }
        }
        .padding(.vertical, 2)
    }

    private var officialHost: String {
        officialServerUrl().replacingOccurrences(of: "https://", with: "")
    }
}

/// "Synced 2 minutes ago", "Sign in again to sync"...
struct AccountStatusText: View {
    let info: AccountInfo

    var body: some View {
        switch info.status {
        case .active:
            if let last = info.lastSyncAt {
                Text("settings.synced \(relativeTime(last))").foregroundColor(.secondary)
            } else {
                Text("settings.never_synced").foregroundColor(.secondary)
            }
        case .needsSignIn:
            Text("accounts.status.needs_sign_in").foregroundColor(Brand.amber)
        case .unverified:
            Text("accounts.status.unverified").foregroundColor(Brand.amber)
        case .unknown:
            Text(verbatim: "?").foregroundColor(.secondary)
        }
    }
}

/// One account: status, server, last sync, vaults, sync now, sign out.
struct AccountDetailView: View {
    let accountId: String

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @EnvironmentObject private var sessions: Sessions
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var signingIn = false
    @State private var confirmSignOut = false
    @State private var unsyncedCount: UInt64 = 0
    @State private var confirmUnsynced = false
    @State private var busy = false
    @State private var error: String?

    private var info: AccountInfo? { account.account(accountId) }

    private func syncState(_ info: AccountInfo, failed: Bool) -> String {
        if failed { return String(localized: "nav.account.not_synced") }
        return account.liveIds.contains(info.id) ? String(localized: "nav.account.synced_live") : String(localized: "nav.account.synced")
    }

    var body: some View {
        Form {
            if let info {
                Section {
                    HStack(spacing: 14) {
                        AccountAvatar(account: info, size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: info.email).font(.title3.weight(.semibold)).lineLimit(1)
                            if !info.name.isEmpty {
                                Text(verbatim: info.name).font(.subheadline).foregroundColor(.secondary)
                            }
                            HStack(spacing: 6) {
                                let failed = account.syncErrors[info.id] != nil
                                Circle().fill(account.liveIds.contains(info.id) && !failed ? Brand.green : Brand.amber).frame(width: 7, height: 7)
                                Text(syncState(info, failed: failed))
                                    .font(.caption).foregroundColor(failed ? Brand.amber : .secondary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    HStack {
                        Text("accounts.server")
                        Spacer()
                        Text(verbatim: info.serverUrl).foregroundColor(.secondary).lineLimit(1)
                    }
                    if info.official {
                        Label("accounts.official", systemImage: "checkmark.seal").foregroundColor(.secondary)
                    }
                    if info.insecure {
                        Label("login.server.insecure", systemImage: "exclamationmark.triangle.fill").foregroundColor(Brand.red)
                    }
                    HStack {
                        Text("accounts.status")
                        Spacer()
                        AccountStatusText(info: info)
                    }
                    if let error = account.syncErrors[info.id] {
                        Text(error).font(.footnote).foregroundColor(Brand.red)
                    }
                    if info.status == .active {
                        Button { account.sync(info.id) } label: {
                            HStack {
                                Label("accounts.sync_now", systemImage: "arrow.triangle.2.circlepath")
                                Spacer()
                                if account.syncingIds.contains(info.id) { ProgressView() }
                            }
                        }
                        .disabled(account.syncingIds.contains(info.id))
                    } else {
                        Button { signingIn = true } label: {
                            Label(info.status == .unverified ? String(localized: "accounts.enter_code") : String(localized: "accounts.sign_in_again"),
                                  systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                    if !info.isCurrent || account.scope != .account(info.id) {
                        Button { account.setScope(.account(info.id)) } label: {
                            Label("accounts.show_only", systemImage: "eye")
                        }
                    }
                }

                if info.vaultsSupported {
                    Section {
                        NavigationLink { VaultsView(accountId: info.id) } label: {
                            HStack {
                                Label("vaults.title", systemImage: "lock.shield")
                                Spacer()
                                Text(verbatim: "\(account.vaults(of: info.id).count)").foregroundColor(.secondary)
                            }
                        }
                    }
                } else if info.status == .active {
                    Section {
                        Text("vaults.unsupported").font(.footnote).foregroundColor(.secondary)
                    }
                }

                if let url = URL(string: "\(info.serverUrl)/app/account") {
                    Section {
                        // The engine manages two-step verification of the current account only.
                        if info.isCurrent && info.status == .active {
                            NavigationLink { TwoFactorView() } label: { Label("settings.two_factor", systemImage: "lock.shield") }
                        }
                        Button { openURL(url) } label: { Label("settings.web_account", systemImage: "arrow.up.right.square") }
                    }
                }

                Section {
                    Button(role: .destructive) { askSignOut() } label: {
                        if info.status == .active {
                            Label("accounts.sign_out", systemImage: "rectangle.portrait.and.arrow.right")
                        } else {
                            Label("accounts.remove", systemImage: "trash")
                        }
                    }
                    .disabled(busy)
                } footer: {
                    Text("accounts.sign_out.footer")
                }
                if let error {
                    Section { Text(error).foregroundColor(Brand.red) }
                }
            }
        }
        .navigationTitle(info?.email ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $signingIn) {
            if let info {
                LoginView(welcome: false, resume: info) {}.environmentObject(account).environmentObject(settings)
            }
        }
        .confirmationDialog(Text("accounts.sign_out.title \(info?.email ?? "")"), isPresented: $confirmSignOut,
                            titleVisibility: .visible) {
            Button(info?.status == .active ? String(localized: "accounts.sign_out") : String(localized: "accounts.remove"), role: .destructive) { signOut(discard: false) }
        } message: {
            Text("accounts.sign_out.message")
        }
        .confirmationDialog(Text("accounts.unsynced.title \(Int(unsyncedCount))"), isPresented: $confirmUnsynced,
                            titleVisibility: .visible) {
            if info?.status == .active {
                Button("accounts.unsynced.sync") { syncThenSignOut() }
            }
            Button("accounts.unsynced.discard", role: .destructive) { signOut(discard: true) }
        } message: {
            Text("accounts.unsynced.message")
        }
    }

    private func askSignOut() {
        unsyncedCount = account.unsynced(accountId)
        if unsyncedCount > 0 { confirmUnsynced = true } else { confirmSignOut = true }
    }

    private func syncThenSignOut() {
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await model.core.account(accountId: accountId).syncNow()
                signOut(discard: false)
            } catch {
                self.error = userMessage(error)
            }
        }
    }

    private func signOut(discard: Bool) {
        busy = true
        error = nil
        let id = accountId
        Task {
            defer { busy = false }
            do {
                let report = try await account.signOut(id, discard: discard)
                if report.signedOut {
                    // Its terminals close too (its server sessions stay there).
                    sessions.closeTerminals(ofAccount: id)
                    dismiss()
                } else {
                    unsyncedCount = report.unsynced
                    confirmUnsynced = true
                }
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}
