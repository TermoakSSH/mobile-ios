import TermoakKit
import SwiftUI
import UniformTypeIdentifiers

// End-to-end encryption of the account (0.7 phase 5c, docs-next/
// E2EE-SSO-AUDIT.md §11): Settings → Security, the recovery phrase shown
// once and confirmed, unlocking this device, approving another one, the
// passphrase and the reset; linked identities of your teams' SSO.

extension E2eePairingRequest: Identifiable {}

/// A linked identity (`GET /me/sso`).
struct LinkedIdentity: Identifiable, Equatable {
    let teamId: String
    let teamName: String?
    let issuer: String
    let email: String
    let lastLoginAt: Int64?
    var id: String { teamId + issuer }

    static func parse(_ json: String) -> [LinkedIdentity] {
        guard let d = json.data(using: .utf8), let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return a.map {
            LinkedIdentity(teamId: $0["team_id"] as? String ?? "", teamName: $0["team_name"] as? String, issuer: $0["issuer"] as? String ?? "",
                           email: $0["email"] as? String ?? "", lastLoginAt: ($0["last_login_at"] as? NSNumber)?.int64Value)
        }
    }
}

/// Settings → Security: end-to-end encryption (set up, unlock, lock,
/// passphrase, new recovery phrase, replace the key, reset; pairing
/// requests of your other devices), linked identities and your activity.
struct SecurityView: View {
    var accountId: String?
    var pairingId: String?
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @ObservedObject private var book = E2eeBook.shared
    @State private var chosen: String?
    @State private var phrase: PhraseKind?
    @State private var unlocking = false
    @State private var passphrase: Bool?
    @State private var removingPassphrase = false
    @State private var newRecovery = false
    @State private var rotating = false
    @State private var resetting = false
    @State private var reviewing: E2eePairingRequest?
    @State private var identities: [LinkedIdentity]?
    @State private var linkable: [(id: String, name: String)] = []
    @State private var unlinking: LinkedIdentity?
    @State private var linking: String?
    @State private var message: String?

    private var accounts: [AccountInfo] {
        account.list.filter { $0.status == .active && (book.supported($0.id) || book.ssoSupported($0.id) || book.audit($0.id) != nil) }
    }
    private var id: String? {
        let wanted = chosen ?? accountId ?? account.current?.id
        return accounts.first(where: { $0.id == wanted })?.id ?? accounts.first?.id
    }
    private func handle(_ id: String) -> AccountHandle? { try? model.core.account(accountId: id) }

    var body: some View {
        Form {
            if let id {
                if accounts.count > 1 {
                    Picker("settings.account", selection: Binding(get: { id }, set: { chosen = $0 })) {
                        ForEach(accounts, id: \.id) { Text(verbatim: $0.email).tag($0.id) }
                    }
                }
                if let message { Text(verbatim: message).font(.footnote).foregroundColor(Brand.green) }
                if book.supported(id) {
                    e2eeSection(id)
                } else {
                    Section("e2ee.title") { Text("settings.security.no_e2ee").foregroundColor(.secondary) }
                }
                if book.ssoSupported(id) { identitiesSection(id) }
                if book.audit(id) != nil {
                    Section("settings.page.activity") {
                        NavigationLink { AuditView(accountId: id, scope: .me, scopeId: nil, name: nil) } label: {
                            Label("audit.account_title", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }
            } else {
                Text("settings.security.signed_out_hint").foregroundColor(.secondary)
            }
        }
        .navigationTitle(Text("settings.page.security"))
        .task(id: id) {
            guard let id else { return }
            await book.refresh(id)
            await loadIdentities(id)
            if let pairingId, let p = book.pairings[id]?.first(where: { $0.id == pairingId }) { reviewing = p }
        }
        .sheet(item: $phrase) { kind in
            if let id { PhraseFlowView(accountId: id, kind: kind) { done in phrase = nil; if done { message = NSLocalizedString(kind.doneKey, comment: "") } }.environmentObject(model) }
        }
        .sheet(isPresented: $unlocking) { if let id { UnlockView(accountId: id) { unlocking = false }.environmentObject(model).environmentObject(account) } }
        .sheet(item: Binding(get: { passphrase.map { PassphraseMode(change: $0) } }, set: { passphrase = $0?.change })) { mode in
            if let id { PassphraseSheet(accountId: id, change: mode.change) { passphrase = nil }.environmentObject(model) }
        }
        .sheet(item: $reviewing) { p in
            if let id { PairingSheet(accountId: id, request: p) { reviewing = nil }.environmentObject(model) }
        }
        .sheet(isPresented: $resetting) { if let id { ResetSheet(accountId: id) { resetting = false }.environmentObject(model).environmentObject(account) } }
        .alert(Text("e2ee.passphrase.remove_title"), isPresented: $removingPassphrase) {
            Button("e2ee.passphrase.remove", role: .destructive) { act { _ = try await $0.e2eeRemovePassphrase(); return String(localized: "e2ee.passphrase.removed") } }
            Button("common.cancel", role: .cancel) {}
        } message: { Text("e2ee.passphrase.remove_message") }
        .alert(Text("e2ee.recovery.new_title"), isPresented: $newRecovery) {
            Button("e2ee.recovery.new_confirm") { gated { phrase = .newRecovery } }
            Button("common.cancel", role: .cancel) {}
        } message: { Text("e2ee.recovery.new_message") }
        .alert(Text("e2ee.rotate.title"), isPresented: $rotating) {
            Button("e2ee.rotate.confirm", role: .destructive) { gated { phrase = .rotate } }
            Button("common.cancel", role: .cancel) {}
        } message: { Text("e2ee.rotate.message") }
        .alert(Text("sso.unlink_title"), isPresented: Binding(get: { unlinking != nil }, set: { if !$0 { unlinking = nil } })) {
            Button("sso.unlink", role: .destructive) {
                guard let i = unlinking, let id else { return }
                act {
                    _ = try await $0.apiRequest(method: .delete, path: "/api/v1/me/sso/\(i.teamId)", bodyJson: nil)
                    await loadIdentities(id)
                    return String(localized: "sso.unlinked")
                }
            }
            Button("common.cancel", role: .cancel) {}
        } message: { Text("sso.unlink_message \(unlinking?.teamName ?? unlinking?.issuer ?? "")") }
    }

    // MARK: E2EE

    @ViewBuilder
    private func e2eeSection(_ id: String) -> some View {
        Section {
            Text("e2ee.intro").font(.footnote)
            Text("e2ee.intro_secrets_only").font(.footnote).foregroundColor(.secondary)
            if let st = book.status[id] {
                if !st.setUp {
                    Button { phrase = .setup } label: { Label("e2ee.setup.button", systemImage: "lock.shield") }
                        .accessibilityIdentifier("e2ee-setup")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("e2ee.fingerprint").font(.caption).foregroundColor(.secondary)
                        Text(verbatim: st.key?.fingerprint ?? "").font(.callout.monospaced()).textSelection(.enabled)
                        Text(st.unlocked ? LocalizedStringKey("e2ee.state.unlocked") : LocalizedStringKey("e2ee.state.locked"))
                            .font(.caption.weight(.semibold)).foregroundColor(st.unlocked ? Brand.green : Brand.amber)
                        Text(st.unlocked ? LocalizedStringKey("e2ee.state.unlocked_hint") : LocalizedStringKey("e2ee.state.locked_hint"))
                            .font(.caption).foregroundColor(.secondary)
                        Text(methodsKey(st)).font(.caption).foregroundColor(.secondary)
                        if st.lockedSecrets > 0 { Text("e2ee.locked_secrets \(Int(st.lockedSecrets))").font(.caption).foregroundColor(Brand.amber) }
                        if let w = book.waiting[id], w > 0 { Text("e2ee.notice.waiting \(Int(w))").font(.caption).foregroundColor(Brand.amber) }
                    }
                }
            } else {
                ProgressView()
            }
        } header: { Text("e2ee.title") }
        if let list = book.pairings[id], !list.isEmpty {
            Section("e2ee.pairing.waiting_title") {
                ForEach(list, id: \.id) { p in
                    Button { reviewing = p } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: p.deviceName)
                            Text("e2ee.pairing.expires \(E2eeRules.pairingLeft(expiresAt: p.expiresAt, now: nowMs()))").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        if let st = book.status[id], st.setUp {
            Section("settings.page.security") {
                if !st.unlocked {
                    Button { unlocking = true } label: { Label("e2ee.unlock.button", systemImage: "lock.open") }.accessibilityIdentifier("e2ee-unlock")
                } else {
                    Button { act { try await $0.e2eeLock(); return String(localized: "e2ee.locked_toast") } } label: { Label("e2ee.lock", systemImage: "lock") }
                    Button { passphrase = st.hasPassphrase } label: {
                        Label(st.hasPassphrase ? LocalizedStringKey("e2ee.passphrase.change") : LocalizedStringKey("e2ee.passphrase.set"), systemImage: "key")
                    }
                    if st.hasPassphrase {
                        Button { removingPassphrase = true } label: { Label("e2ee.passphrase.remove", systemImage: "key.slash") }
                    }
                    Button { newRecovery = true } label: { Label("e2ee.recovery.new", systemImage: "list.number") }
                    Button { rotating = true } label: { Label("e2ee.rotate.button", systemImage: "arrow.triangle.2.circlepath") }
                }
                Button(role: .destructive) { gated { resetting = true } } label: { Label("e2ee.reset.button", systemImage: "exclamationmark.arrow.circlepath") }
            }
        }
    }

    private func methodsKey(_ st: E2eeStatus) -> LocalizedStringKey {
        switch (st.hasPassphrase, st.hasRecoveryKey) {
        case (true, true): return "e2ee.methods.both"
        case (true, false): return "e2ee.methods.passphrase"
        case (false, true): return "e2ee.methods.recovery"
        default: return "e2ee.methods.none"
        }
    }

    // MARK: Identities

    @ViewBuilder
    private func identitiesSection(_ id: String) -> some View {
        Section {
            Text("sso.identities.hint").font(.footnote).foregroundColor(.secondary)
            if let identities {
                if identities.isEmpty { Text("sso.identities.none").foregroundColor(.secondary) }
                ForEach(identities) { i in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(verbatim: i.teamName ?? i.issuer)
                            Text(verbatim: i.email + " · " + (i.lastLoginAt.map { String(localized: "sso.identities.last_login \(i.issuer) \(AccessTexts.dateTime($0))") } ?? i.issuer))
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("sso.unlink") { unlinking = i }.foregroundColor(Brand.red)
                    }
                }
            } else {
                ProgressView()
            }
            ForEach(linkable, id: \.id) { t in
                Button { link(id, t.id) } label: {
                    if linking == t.id { ProgressView() } else { Label("sso.link_with \(t.name)", systemImage: "link") }
                }
                .disabled(linking != nil)
            }
        } header: { Text("sso.identities.title") }
    }

    private func loadIdentities(_ id: String) async {
        guard book.ssoSupported(id), let h = handle(id) else { return }
        let list = LinkedIdentity.parse((try? await h.apiRequest(method: .get, path: "/api/v1/me/sso", bodyJson: nil)) ?? "[]")
        identities = list
        var out: [(id: String, name: String)] = []
        for t in (try? await h.listTeams()) ?? [] where !list.contains(where: { $0.teamId == t.id }) {
            if let s = try? await h.teamSso(teamId: t.id), s.enabled { out.append((t.id, t.name)) }
        }
        linkable = out
    }

    /// POST /me/sso/link with this app's PKCE, then the provider in ASWebAuthenticationSession; the server links it when it comes back.
    private func link(_ id: String, _ teamId: String) {
        guard let h = handle(id) else { return }
        linking = teamId
        Task {
            defer { linking = nil }
            do {
                let state = SsoRules.token()
                let body = SsoRules.linkBody(teamId: teamId, state: state, verifier: SsoRules.token(), deviceName: UIDevice.current.name)
                let v = try await h.apiRequest(method: .post, path: "/api/v1/me/sso/link", bodyJson: body)
                guard let d = v.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let url = (o["authorize_url"] as? String).flatMap(URL.init(string:)) else { return }
                let back = try await SsoBrowser.open(url)
                switch SsoRules.linkResult(back.absoluteString, state: state) {
                case .linked: message = String(localized: "sso.linked")
                case .failed(let code): message = E2eeTexts.error(code) ?? String(localized: "error.sso_failed")
                }
                await loadIdentities(id)
            } catch SsoBrowserError.cancelled {
            } catch {
                message = userMessage(error)
            }
        }
    }

    // MARK: Helpers

    private func act(_ f: @escaping (AccountHandle) async throws -> String?) {
        guard let id, let h = handle(id) else { return }
        Task {
            do {
                message = try await f(h)
            } catch {
                message = userMessage(error)
            }
            await book.refresh(id)
            account.sync(id)
        }
    }

    /// New phrase, replace the key and reset ask for Face ID / Touch ID or the passcode first.
    private func gated(_ then: @escaping () -> Void) {
        Task { if await DeviceAuth.unlock(reason: String(localized: "e2ee.auth_reason")) { then() } }
    }
}

private struct PassphraseMode: Identifiable {
    let change: Bool
    var id: Bool { change }
}

// MARK: - The phrase

/// What made the phrase.
enum PhraseKind: String, Identifiable {
    case setup, newRecovery, rotate
    var id: String { rawValue }
    var titleKey: LocalizedStringKey {
        switch self {
        case .setup: return "e2ee.setup.title"
        case .newRecovery: return "e2ee.recovery.new_title"
        case .rotate: return "e2ee.rotate.title"
        }
    }
    /// Localization key of what to say when done.
    var doneKey: String {
        switch self {
        case .setup: return "e2ee.setup.done"
        case .newRecovery: return "e2ee.recovery.new_done"
        case .rotate: return "e2ee.rotate.done"
        }
    }
}

/// The 24 words in two numbered columns.
struct PhraseGrid: View {
    let phrase: String
    var body: some View {
        let words = E2eeRules.numberedWords(phrase)
        let half = (words.count + 1) / 2
        HStack(alignment: .top, spacing: 24) {
            ForEach([Array(words.prefix(half)), Array(words.dropFirst(half))], id: \.first?.0) { col in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(col, id: \.0) { n, w in
                        HStack(spacing: 10) {
                            Text(verbatim: "\(n)").foregroundColor(.secondary).frame(width: 26, alignment: .trailing)
                            Text(verbatim: w)
                        }
                        .font(.body.monospaced())
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
        .accessibilityIdentifier("phrase-grid")
    }
}

/// A plain text file for "Save…" (the Files app).
struct PhraseDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = "" }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

/// Set up, new recovery phrase, replace the key: the optional passphrase,
/// the 24 words shown once (copy for this device only, save to Files,
/// print; hidden while the app is not in front or the screen is being
/// recorded or mirrored, so the app switcher's snapshot never has it), then
/// three of them typed again. The engine publishes the key when it makes
/// it, as on the desktop: closing before confirming warns that the phrase
/// is not shown again.
struct PhraseFlowView: View {
    let accountId: String
    let kind: PhraseKind
    let onClose: (Bool) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var step = 0
    @State private var phrase: String?
    @State private var p1 = ""
    @State private var p2 = ""
    @State private var busy = false
    @State private var error: String?
    @State private var stored = false
    @State private var positions = E2eeRules.confirmPositions(UInt64.random(in: 1...UInt64.max))
    @State private var typed = ["", "", ""]
    @State private var wrong = false
    @State private var closing = false
    @State private var saving = false
    @State private var captured = UIScreen.main.isCaptured
    @State private var copied = false

    private var hidden: Bool { scenePhase != .active || captured }

    var body: some View {
        NavigationView {
            Form {
                if step == 0 && kind != .newRecovery {
                    Section {
                        Text(kind == .rotate ? LocalizedStringKey("e2ee.rotate.message") : LocalizedStringKey("e2ee.setup.message")).font(.footnote)
                        PassphraseFields(p1: $p1, p2: $p2, label: "e2ee.passphrase.optional")
                        if let error { Text(verbatim: error).foregroundColor(Brand.red) }
                        Button { create() } label: {
                            if busy { ProgressView() } else { Text(kind == .rotate ? LocalizedStringKey("e2ee.rotate.confirm") : LocalizedStringKey("e2ee.setup.create")) }
                        }
                        .disabled(busy || !E2eeRules.passphraseOk(p1, p2, required: false))
                    }
                } else if let phrase {
                    if step <= 1 {
                        Section {
                            Text("e2ee.recovery.show_message").font(.footnote)
                            if hidden {
                                Label("e2ee.recovery.hidden", systemImage: "eye.slash").foregroundColor(.secondary)
                            } else {
                                PhraseGrid(phrase: phrase)
                            }
                            Button {
                                UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: phrase]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                                copied = true
                            } label: { Label("common.copy", systemImage: "doc.on.doc") }
                            if copied { Text("e2ee.recovery.copied").font(.caption).foregroundColor(Brand.green) }
                            Button { saving = true } label: { Label("e2ee.recovery.save", systemImage: "square.and.arrow.down") }
                            Button { printPhrase(phrase) } label: { Label("e2ee.recovery.print", systemImage: "printer") }
                            Text("e2ee.recovery.keep_hint").font(.caption).foregroundColor(.secondary)
                            Toggle("e2ee.recovery.stored", isOn: $stored)
                            Button("login.custom.continue") { step = 2; wrong = false }.disabled(!stored)
                        }
                    } else {
                        Section {
                            Text("e2ee.confirm.message").font(.footnote)
                            ForEach(0..<3, id: \.self) { i in
                                TextField(String(localized: "e2ee.confirm.word \(String(positions[i] + 1))"), text: $typed[i])
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                            }
                            if wrong { Text("e2ee.confirm.wrong").foregroundColor(Brand.red) }
                            Button("e2ee.confirm.back") { step = 1 }
                            Button("e2ee.confirm.done") { finish(phrase) }.disabled(typed.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                        }
                    }
                } else if let error {
                    Text(verbatim: error).foregroundColor(Brand.red)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(Text(kind.titleKey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close") { if phrase != nil { closing = true } else { onClose(false) } } }
            }
            .alert(Text("e2ee.confirm.close_title"), isPresented: $closing) {
                Button("e2ee.confirm.close_anyway", role: .destructive) { phrase = nil; onClose(true) }
                Button("e2ee.confirm.back", role: .cancel) {}
            } message: { Text("e2ee.confirm.close_message") }
            .fileExporter(isPresented: $saving, document: PhraseDocument(text: document()), contentType: .plainText, defaultFilename: "termoak-recovery-phrase.txt") { _ in }
        }
        .interactiveDismissDisabled()
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in captured = UIScreen.main.isCaptured }
        .task {
            guard kind == .newRecovery, phrase == nil else { return }
            do {
                phrase = try await handle()?.e2eeNewRecoveryKey()
                step = 1
            } catch {
                self.error = userMessage(error)
            }
        }
    }

    private func handle() -> AccountHandle? { try? model.core.account(accountId: accountId) }

    private func create() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let pass = p1.isEmpty ? nil : p1
                let r = kind == .rotate ? try await handle()?.e2eeRotateUserKey(passphrase: pass) : try await handle()?.e2eeSetup(passphrase: pass)
                phrase = r?.recoveryKey
                p1 = ""; p2 = ""
                step = 1
                await E2eeBook.shared.refresh(accountId)
                model.account.sync(accountId)
            } catch {
                self.error = userMessage(error)
            }
        }
    }

    private func finish(_ phrase: String) {
        guard E2eeRules.confirmMatches(phrase, positions, typed) else { wrong = true; return }
        self.phrase = nil
        onClose(true)
    }

    private func labels() -> (String, String, String, String) {
        let a = model.account.account(accountId)
        let date = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }()
        return (String(localized: "e2ee.recovery.doc.title"), String(localized: "e2ee.recovery.doc.account \(a?.email ?? "") \(a?.serverUrl ?? "")"),
                String(localized: "e2ee.recovery.doc.date \(date)"), String(localized: "e2ee.recovery.doc.keep"))
    }

    private func document() -> String {
        guard let phrase else { return "" }
        let l = labels()
        return E2eeRules.document(phrase, title: l.0, account: l.1, date: l.2, keep: l.3)
    }

    private func printPhrase(_ phrase: String) {
        let l = labels()
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = l.0
        info.outputType = .general
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = UIMarkupTextPrintFormatter(markupText: E2eeRules.printPage(phrase, title: l.0, account: l.1, date: l.2, keep: l.3))
        _ = controller.present(animated: true, completionHandler: nil)
    }
}

/// The passphrase twice, with its strength.
struct PassphraseFields: View {
    @Binding var p1: String
    @Binding var p2: String
    var label: LocalizedStringKey

    var body: some View {
        SecureField(label, text: $p1).textContentType(.newPassword)
        if !p1.isEmpty {
            let s = E2eeRules.strength(p1)
            Text(strengthKey(s)).font(.caption).foregroundColor(s >= .good ? Brand.green : (s == .fair ? Brand.amber : Brand.red))
            SecureField("e2ee.passphrase.repeat", text: $p2).textContentType(.newPassword)
            if !p2.isEmpty && p2 != p1 { Text("e2ee.passphrase.mismatch").font(.caption).foregroundColor(Brand.red) }
        }
        Text("e2ee.passphrase.hint").font(.caption).foregroundColor(.secondary)
    }

    private func strengthKey(_ s: E2eeRules.Strength) -> LocalizedStringKey {
        switch s {
        case .tooShort: return "e2ee.passphrase.strength.too_short"
        case .weak: return "e2ee.passphrase.strength.weak"
        case .fair: return "e2ee.passphrase.strength.fair"
        case .good: return "e2ee.passphrase.strength.good"
        case .strong: return "e2ee.passphrase.strength.strong"
        }
    }
}

// MARK: - Unlock

/// Unlock end-to-end encryption on this device: the E2EE passphrase, the
/// recovery phrase (live feedback from the core and word suggestions), or
/// another device of yours (a six-digit code to compare there; this one
/// asks every 3 seconds).
struct UnlockView: View {
    let accountId: String
    let onDone: () -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @State private var way = 0
    @State private var passphrase = ""
    @State private var recovery = ""
    @State private var busy = false
    @State private var error: String?
    @State private var pairing: E2eePairingStart?
    @State private var now = nowMs()

    private var st: E2eeStatus? { E2eeBook.shared.status[accountId] }

    var body: some View {
        NavigationView {
            Form {
                Picker("e2ee.unlock.title", selection: $way) {
                    if st?.hasPassphrase ?? true { Text("e2ee.unlock.way_passphrase").tag(0) }
                    if st?.hasRecoveryKey ?? true { Text("e2ee.unlock.way_recovery").tag(1) }
                    Text("e2ee.unlock.way_device").tag(2)
                }
                .pickerStyle(.segmented)
                switch way {
                case 0:
                    Section {
                        Text("e2ee.unlock.passphrase_message").font(.footnote)
                        SecureField("e2ee.passphrase.placeholder", text: $passphrase)
                        Button("e2ee.unlock.button") { unlock() }.disabled(busy || passphrase.isEmpty)
                    }
                case 1:
                    Section {
                        Text("e2ee.unlock.recovery_message").font(.footnote)
                        TextEditor(text: $recovery)
                            .font(.body.monospaced()).frame(minHeight: 120)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("recovery-phrase")
                        let suggestions = E2eeRules.suggestions(recovery, wordlist: RecoveryWords.list)
                        if !suggestions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(suggestions, id: \.self) { w in
                                        Button(w) { recovery = E2eeRules.complete(recovery, w) }.buttonStyle(.bordered).font(.callout.monospaced())
                                    }
                                }
                            }
                        }
                        let fb = RecoveryWords.feedback(recovery)
                        if let t = E2eeTexts.feedbackText(fb) {
                            Text(verbatim: t).font(.caption).foregroundColor(fb == .valid ? Brand.green : (fb.isProblem ? Brand.red : .secondary))
                        }
                        Button("e2ee.unlock.button") { unlock() }.disabled(busy || fb != .valid)
                    }
                default:
                    Section {
                        Text("e2ee.unlock.device_message").font(.footnote)
                        if let p = pairing {
                            Text("e2ee.unlock.device_code").font(.caption).foregroundColor(.secondary)
                            Text(verbatim: E2eeRules.spacedCode(p.code)).font(.system(size: 40, weight: .semibold, design: .monospaced))
                                .frame(maxWidth: .infinity).accessibilityIdentifier("pairing-code")
                            HStack {
                                ProgressView()
                                Text("e2ee.unlock.device_waiting").font(.caption)
                                Text("e2ee.pairing.expires \(E2eeRules.pairingLeft(expiresAt: p.expiresAt, now: now))").font(.caption).foregroundColor(.secondary)
                            }
                        } else {
                            Button("e2ee.unlock.device_start") { startPairing() }.disabled(busy)
                        }
                    }
                }
                if let error { Text(verbatim: error).foregroundColor(Brand.red) }
            }
            .navigationTitle(Text("e2ee.unlock.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { onDone() } } }
            .onAppear { if !(st?.hasPassphrase ?? true) { way = (st?.hasRecoveryKey ?? true) ? 1 : 2 } }
            .task(id: pairing?.id) { await waitForApproval() }
        }
    }

    private func handle() -> AccountHandle? { try? model.core.account(accountId: accountId) }

    private func unlocked(_ n: UInt64) async {
        await E2eeBook.shared.refresh(accountId)
        account.sync(accountId)
        account.post(String(localized: "e2ee.title"), String(localized: "e2ee.unlock.done \(Int(n))"))
        onDone()
    }

    private func unlock() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                guard let h = handle() else { return }
                let n = way == 0 ? try await h.e2eeUnlockWithPassphrase(passphrase: passphrase) : try await h.e2eeUnlockWithRecoveryKey(recoveryKey: recovery)
                passphrase = ""
                recovery = ""
                await unlocked(n)
            } catch {
                self.error = userMessage(error)
            }
        }
    }

    private func startPairing() {
        busy = true
        Task {
            defer { busy = false }
            do { pairing = try await handle()?.e2eePairingStart() } catch { self.error = userMessage(error) }
        }
    }

    private func waitForApproval() async {
        guard let p = pairing, let h = handle() else { return }
        while !Task.isCancelled {
            now = nowMs()
            if now > p.expiresAt {
                error = String(localized: "error.e2ee_pairing_closed")
                pairing = nil
                return
            }
            do {
                if let n = try await h.e2eePairingFinish(pairingId: p.id) {
                    pairing = nil
                    await unlocked(n)
                    return
                }
            } catch {
                self.error = userMessage(error)
                pairing = nil
                return
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}

extension E2eeRules.Feedback {
    var isProblem: Bool { if case .problem = self { return true } else { return false } }
}

// MARK: - Pairing, passphrase, reset

/// "Unlock another device?": the same six-digit code as on that device, Approve or Deny.
struct PairingSheet: View {
    let accountId: String
    let request: E2eePairingRequest
    let onDone: () -> Void
    @EnvironmentObject private var model: AppModel
    @State private var busy = false
    @State private var error: String?
    @State private var now = nowMs()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            Form {
                Text("e2ee.pairing.message \(request.deviceName)")
                Text(verbatim: E2eeRules.spacedCode(request.code)).font(.system(size: 40, weight: .semibold, design: .monospaced)).frame(maxWidth: .infinity)
                Text("e2ee.pairing.compare").font(.footnote)
                Text("e2ee.pairing.expires \(E2eeRules.pairingLeft(expiresAt: request.expiresAt, now: now))").font(.caption).foregroundColor(.secondary)
                if let error { Text(verbatim: error).foregroundColor(Brand.red) }
                Button("e2ee.pairing.approve") { decide(true) }.disabled(busy)
                Button("e2ee.pairing.deny", role: .destructive) { decide(false) }.disabled(busy)
            }
            .navigationTitle(Text("e2ee.pairing.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { onDone() } } }
        }
        .onReceive(tick) { _ in now = nowMs(); if now > request.expiresAt { onDone() } }
    }

    private func decide(_ approve: Bool) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await (try? model.core.account(accountId: accountId))?.e2eePairingDecide(pairingId: request.id, approve: approve)
                E2eeBook.shared.decided(accountId, request.id)
                onDone()
            } catch {
                self.error = userMessage(error)
            }
            await E2eeBook.shared.refresh(accountId)
        }
    }
}

/// Set or change the E2EE passphrase (an unlocked device).
struct PassphraseSheet: View {
    let accountId: String
    let change: Bool
    let onDone: () -> Void
    @EnvironmentObject private var model: AppModel
    @State private var p1 = ""
    @State private var p2 = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                PassphraseFields(p1: $p1, p2: $p2, label: "e2ee.passphrase.title")
                if let error { Text(verbatim: error).foregroundColor(Brand.red) }
                Button("common.save") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            try await (try? model.core.account(accountId: accountId))?.e2eeSetPassphrase(passphrase: p1)
                            await E2eeBook.shared.refresh(accountId)
                            onDone()
                        } catch {
                            self.error = userMessage(error)
                        }
                    }
                }
                .disabled(busy || !E2eeRules.passphraseOk(p1, p2, required: true))
            }
            .navigationTitle(Text(change ? "e2ee.passphrase.change" : "e2ee.passphrase.set"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { onDone() } } }
        }
    }
}

/// Everything lost: the vaults nobody else could open first (`e2ee_reset(false)`), then the reset with the typed email.
struct ResetSheet: View {
    let accountId: String
    let onDone: () -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @State private var lost: [String]?
    @State private var typed = ""
    @State private var busy = false
    @State private var error: String?

    private var email: String { account.account(accountId)?.email ?? "" }

    var body: some View {
        NavigationView {
            Form {
                Text("e2ee.reset.message").font(.footnote)
                if let lost {
                    if lost.isEmpty { Text("e2ee.reset.no_vaults") } else {
                        Text("e2ee.reset.vaults_lost \(lost.count)").foregroundColor(Brand.red)
                        ForEach(lost, id: \.self) { Text(verbatim: "• " + $0).font(.caption) }
                    }
                } else {
                    ProgressView()
                }
                TextField(String(localized: "e2ee.reset.type_email \(email)"), text: $typed)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                if let error { Text(verbatim: error).foregroundColor(Brand.red) }
                Button("e2ee.reset.confirm", role: .destructive) { reset() }
                    .disabled(busy || lost == nil || typed.trimmingCharacters(in: .whitespaces).lowercased() != email.lowercased())
            }
            .navigationTitle(Text("e2ee.reset.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { onDone() } } }
            .task {
                do {
                    let ids = try await (try? model.core.account(accountId: accountId))?.e2eeReset(confirm: false) ?? []
                    lost = ids.map { id in account.vaults.first(where: { $0.id == id })?.name ?? id }
                } catch {
                    self.error = userMessage(error)
                    lost = []
                }
            }
        }
    }

    private func reset() {
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await (try? model.core.account(accountId: accountId))?.e2eeReset(confirm: true)
                await E2eeBook.shared.refresh(accountId)
                account.sync(accountId)
                account.post(String(localized: "e2ee.title"), String(localized: "e2ee.reset.done"))
                onDone()
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}

// MARK: - Badges

/// "End-to-end encrypted" (· locked) for a vault.
struct E2eeBadge: View {
    let badge: E2eeRules.Badge
    var body: some View {
        switch badge {
        case .none: EmptyView()
        case .e2ee: Text("vault_e2ee.badge").font(.caption2.weight(.semibold)).foregroundColor(Brand.green)
        case .locked: Text("vault_e2ee.badge_locked").font(.caption2.weight(.semibold)).foregroundColor(Brand.amber)
        }
    }
}

// MARK: - Home banners

/// Home's E2EE banners, per account: end-to-end encrypted vaults locked on
/// this device (Unlock), another device asking for the key (Review: the
/// same six-digit code), members waiting for a vault's key this device
/// holds, and a vault you could hold the key of before you set E2EE up.
struct E2eeHomeBanners: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @ObservedObject private var book = E2eeBook.shared
    @State private var unlocking: String?
    @State private var reviewing: PairingAsk?
    @State private var settingUp: String?

    var body: some View {
        ForEach(book.supportedAccounts, id: \.self) { acc in
            if let st = book.status[acc] {
                let vaults = account.vaults(of: acc)
                let mayHold = vaults.filter { $0.e2ee?.mayHoldKey == true }
                if !st.setUp, let v = mayHold.first {
                    banner("e2ee.banner.setup_title \(v.displayName)", "e2ee.banner.setup_detail", "e2ee.setup.button") { settingUp = acc }
                } else if st.setUp {
                    if !st.unlocked && !mayHold.isEmpty {
                        banner("e2ee.banner.locked_title", "e2ee.banner.locked_detail", "e2ee.unlock.button") { unlocking = acc }
                    }
                    ForEach(book.pairings[acc] ?? [], id: \.id) { p in
                        banner("e2ee.banner.pairing_title \(p.deviceName)", "e2ee.banner.pairing_detail", "e2ee.pairing.review") {
                            reviewing = PairingAsk(accountId: acc, request: p)
                        }
                    }
                    ForEach(vaults.filter { E2eeRules.hasPending($0.e2eeFlags, unlocked: st.unlocked) }, id: \.id) { v in
                        NavigationLink { VaultE2eeView(accountId: acc, vaultId: v.id) } label: {
                            bannerText("e2ee.banner.pending_title \(Int(v.e2ee?.pendingMembers ?? 0)) \(v.displayName)", "e2ee.banner.pending_detail")
                        }
                    }
                }
            }
        }
        .sheet(item: Binding(get: { unlocking.map { IdBox(id: $0) } }, set: { unlocking = $0?.id })) { box in
            UnlockView(accountId: box.id) { unlocking = nil }.environmentObject(model).environmentObject(account)
        }
        .sheet(item: Binding(get: { settingUp.map { IdBox(id: $0) } }, set: { settingUp = $0?.id })) { box in
            PhraseFlowView(accountId: box.id, kind: .setup) { _ in settingUp = nil }.environmentObject(model)
        }
        .sheet(item: $reviewing) { a in PairingSheet(accountId: a.accountId, request: a.request) { reviewing = nil }.environmentObject(model) }
    }

    private func banner(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, _ action: LocalizedStringKey, _ run: @escaping () -> Void) -> some View {
        HStack {
            bannerText(title, detail)
            Spacer()
            Button(action, action: run).buttonStyle(.bordered)
        }
        .accessibilityIdentifier("e2ee-banner")
    }

    private func bannerText(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield").foregroundColor(Brand.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

/// An id for `.sheet(item:)`.
struct IdBox: Identifiable {
    let id: String
}
