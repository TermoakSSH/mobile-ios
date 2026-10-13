import TermoakKit
import SwiftUI

/// The last section of an account's page (signed-in accounts): "Delete my
/// account…", which opens `DeleteAccountView`.
struct DeleteAccountSection: View {
    let action: () -> Void

    var body: some View {
        Section {
            Button(role: .destructive, action: action) {
                Label("accounts.delete.button", systemImage: "person.crop.circle.badge.xmark")
            }
        } footer: {
            Text("accounts.delete.footer")
        }
    }
}

/// Deletes the account and all its data on its server (`DELETE /api/v1/me`
/// through that account's own handle): what is deleted, the password, the
/// two-step code if the account has it and the confirmation word. Your
/// shared vaults with members are confirmed apart (the server's list of
/// them does not reach the app through the engine's errors, so the warning
/// is general; the same code works again: it is checked after that). Once
/// deleted it
/// says so; `onDeleted` runs right then and the account's page signs out of
/// it on this device when this sheet closes.
struct DeleteAccountView: View {
    let accountId: String
    /// The server deleted the account.
    let onDeleted: () -> Void

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var code = ""
    @State private var typedWord = ""
    /// The account has two-step verification (`GET /api/v1/me`, or the
    /// server asked for the code).
    @State private var needsCode = false
    @State private var deleting = false
    @State private var error: String?
    @State private var confirmingVaults = false
    @State private var deleteSharedVaults = false
    @State private var deleted = false
    @State private var showingDone = false

    private var info: AccountInfo? { account.account(accountId) }

    /// DELETE / BORRAR.
    private var word: String { String(localized: "accounts.delete.confirm_word") }

    private var serverHost: String {
        guard let url = info?.serverUrl else { return "" }
        return URL(string: url)?.host ?? url
    }

    private var canDelete: Bool {
        if deleting || deleted || password.isEmpty { return false }
        if !AccountDeletion.confirmed(typedWord, word: word) { return false }
        if needsCode && code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return true
    }

    var body: some View {
        NavigationView {
            form
                .navigationTitle("accounts.delete.title")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("common.cancel") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                            .disabled(deleting)
                    }
                }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled(deleting || deleted)
        .alert(Text("accounts.delete.done"), isPresented: $showingDone) {
            Button("common.ok") { dismiss() }
        }
        .task { await loadTwoFactor() }
    }

    private var form: some View {
        Form {
            introSection
            credentialsSection
            if needsCode { codeSection }
            confirmSection
            submitSection
        }
        .disabled(deleted)
        .alert(Text("accounts.delete.vaults_title"), isPresented: $confirmingVaults) {
            Button("accounts.delete.vaults_confirm", role: .destructive) {
                deleteSharedVaults = true
                submit()
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("accounts.delete.vaults_text")
        }
    }

    // MARK: Sections

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("accounts.delete.text \(serverHost)")
                    .fixedSize(horizontal: false, vertical: true)
                bullet("accounts.delete.item_data")
                bullet("accounts.delete.item_vaults")
                bullet("accounts.delete.item_sessions")
                bullet("accounts.delete.item_teams")
            }
            .padding(.vertical, 4)
        } header: {
            if account.list.count > 1, let info { Text(verbatim: info.displayLabel) }
        }
    }

    private func bullet(_ key: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "•").foregroundColor(Brand.red)
            Text(key)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var credentialsSection: some View {
        Section {
            SecureField("common.password", text: $password)
                .textContentType(.password)
                .disabled(deleting)
        }
    }

    private var codeSection: some View {
        Section {
            TextField("login.code", text: $code)
                .keyboardType(.asciiCapable)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .disabled(deleting)
        } footer: {
            Text("accounts.delete.code_hint")
        }
    }

    private var confirmSection: some View {
        Section {
            TextField(word, text: $typedWord)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(deleting)
                .onSubmit(submit)
        } header: {
            Text("accounts.delete.confirm_label \(word)")
        }
    }

    private var submitSection: some View {
        Section {
            Button(role: .destructive, action: submit) {
                HStack {
                    Text("accounts.delete.submit")
                    Spacer()
                    if deleting { ProgressView() }
                }
            }
            .disabled(!canDelete)
            if let error {
                Text(error).font(.footnote).foregroundColor(Brand.red)
            }
        }
    }

    // MARK: Actions

    /// Whether to ask for the two-step code from the start.
    private func loadTwoFactor() async {
        guard let handle = try? model.core.account(accountId: accountId),
              let json = try? await handle.apiGet(path: "/api/v1/me") else { return }
        if AccountDeletion.twoFactorEnabled(meJson: json) { needsCode = true }
    }

    private func submit() {
        guard canDelete else { return }
        let body = AccountDeletion.body(password: password, totpCode: needsCode ? code : nil,
                                        deleteSharedVaults: deleteSharedVaults)
        let id = accountId
        deleting = true
        error = nil
        Task { @MainActor in
            do {
                // That account's own handle: never the current account's.
                let handle = try model.core.account(accountId: id)
                _ = try await handle.apiRequest(method: .delete, path: AccountDeletion.path, bodyJson: body)
                deleting = false
                deleted = true
                onDeleted()
                showingDone = true
            } catch {
                deleting = false
                show(error)
            }
        }
    }

    /// The server's refusals, translated; anything else as usual.
    private func show(_ failure: Error) {
        switch problem(of: failure) {
        case .wrongPassword?:
            error = String(localized: "accounts.delete.error.password")
        case .codeRequired?:
            needsCode = true
            error = String(localized: "accounts.delete.error.code_required")
        case .codeInvalid?:
            error = String(localized: "login.code_invalid")
        case .lastAdmin?:
            error = String(localized: "accounts.delete.error.last_admin")
        case .lastTeamOwner(let teams)?:
            if let teams {
                error = String(localized: "accounts.delete.error.last_team_owner.teams \(teams)")
            } else {
                error = String(localized: "accounts.delete.error.last_team_owner")
            }
        case .sharedVaults?:
            if deleteSharedVaults {
                error = userMessage(failure)
            } else {
                confirmingVaults = true
            }
        case .unsupported?:
            error = String(localized: "accounts.delete.error.unsupported")
        case nil:
            error = userMessage(failure)
        }
    }

    private func problem(of failure: Error) -> AccountDeletionProblem? {
        guard let e = failure as? TermoakError else { return nil }
        switch e {
        case .TotpRequired:
            return .codeRequired
        case .TotpInvalid:
            return .codeInvalid
        default:
            // "the server responded 409 (last_admin): …" (404/405: an older
            // server without this endpoint).
            return AccountDeletionProblem.parse(e.message)
        }
    }
}
