import TermoakKit
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

/// A key: its name and comment (editable), algorithm, fingerprint and public
/// key (copy, share, QR code), install it on a host, and export the private
/// key after unlocking the device.
struct KeyDetailView: View {
    let original: SshKey
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var comment = ""
    @State private var showingQR = false
    @State private var sharing = false
    @State private var installing = false
    @State private var exported: ExportedKey?
    @State private var notice: String?
    @State private var error: String?

    private var editable: Bool { !original.isUseOnly }
    private var changed: Bool { label != original.label || comment != original.comment }

    var body: some View {
        NavigationView {
            Form {
                nameSection
                publicSection
                actionsSection
                if let error {
                    Section { Text(error).foregroundColor(Brand.red) }
                }
            }
            .navigationTitle(original.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save", action: save).disabled(!editable || !changed || label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            label = original.label
            comment = original.comment
        }
        .modifier(KeyDetailSheets(key: original, showingQR: $showingQR, sharing: $sharing, installing: $installing,
                                  exported: $exported, notice: $notice))
    }

    private var nameSection: some View {
        Section {
            TextField("common.name", text: $label).disabled(!editable)
            TextField("keychain.detail.comment", text: $comment)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(!editable)
        } footer: {
            Text("keychain.detail.comment_hint")
        }
    }

    private var publicSection: some View {
        Section("keychain.detail.public_key") {
            detailLine("common.type", original.algorithm)
            VStack(alignment: .leading, spacing: 4) {
                Text("keychain.detail.fingerprint").font(.caption).foregroundColor(.secondary)
                Text(verbatim: original.fingerprint).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            }
            Text(verbatim: original.publicKey)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(6)
            if original.certificate != nil {
                detailLine("keychain.detail.certificate", String(localized: "keychain.detail.certificate_yes"))
            }
            if original.hasPassphrase {
                detailLine("keychain.detail.passphrase", String(localized: "keychain.detail.passphrase_yes"))
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                UIPasteboard.general.string = original.publicKey
                notice = String(localized: "keychain.public_copied")
            } label: { Label("keychain.copy_public", systemImage: "doc.on.doc") }
            Button { sharing = true } label: { Label("keychain.detail.share_public", systemImage: "square.and.arrow.up") }
            Button { showingQR = true } label: { Label("keychain.detail.qr", systemImage: "qrcode") }
            Button { installing = true } label: { Label("keychain.install.title", systemImage: "server.rack") }
            if editable && original.hasPrivateKey {
                Button(action: exportPrivate) { Label("keychain.export.action", systemImage: "key.viewfinder") }
            }
        } footer: {
            if editable && original.hasPrivateKey { Text("keychain.export.footer") }
        }
    }

    private func detailLine(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(verbatim: value).foregroundColor(.secondary)
        }
    }

    private func save() {
        var k = original
        k.label = label.trimmingCharacters(in: .whitespaces)
        k.comment = comment.trimmingCharacters(in: .whitespaces)
        do {
            _ = try model.core.saveKey(key: k, passphrase: .keep)
            account.sync()
            dismiss()
        } catch {
            self.error = userMessage(error)
        }
    }

    /// The private key, only after Face ID / Touch ID or the passcode.
    private func exportPrivate() {
        Task {
            guard await DeviceAuth.unlock(reason: String(localized: "keychain.export.reason")) else { return }
            do {
                guard let pem = try model.core.exportPrivateKey(id: original.id, accountId: original.accountId) else {
                    error = String(localized: "keychain.export.none")
                    return
                }
                exported = ExportedKey(label: original.label, text: pem)
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}

/// The sheets of the key's page (split from its body).
private struct KeyDetailSheets: ViewModifier {
    let key: SshKey
    @Binding var showingQR: Bool
    @Binding var sharing: Bool
    @Binding var installing: Bool
    @Binding var exported: ExportedKey?
    @Binding var notice: String?
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingQR) {
                QRCodeSheet(title: key.label, text: key.publicKey)
            }
            .sheet(isPresented: $sharing) { ActivityView(items: [key.publicKey]) }
            .sheet(isPresented: $installing) {
                InstallKeyView(key: key).environmentObject(model).environmentObject(account)
            }
            .sheet(item: $exported) { e in PrivateKeyView(exported: e) }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("common.ok", role: .cancel) {}
            }
    }
}

/// Unlocking with Face ID / Touch ID or the device passcode.
enum DeviceAuth {
    /// True once the owner confirmed (also on a device without a passcode,
    /// which has nothing to unlock with).
    @MainActor
    static func unlock(reason: String) async -> Bool {
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            return problem?.domain == LAErrorDomain && problem?.code == LAError.Code.passcodeNotSet.rawValue
        }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in c.resume(returning: ok) }
        }
    }
}

struct ExportedKey: Identifiable {
    let id = UUID()
    let label: String
    let text: String
}

/// The exported private key: copy (this device only, cleared after two
/// minutes) or share.
private struct PrivateKeyView: View {
    let exported: ExportedKey
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var sharing = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text(verbatim: exported.text)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                } footer: {
                    Text("keychain.export.warning")
                }
                Section {
                    Button(action: copy) {
                        Label(copied ? LocalizedStringKey("keychain.export.copied") : LocalizedStringKey("keychain.export.copy"),
                              systemImage: "doc.on.doc")
                    }
                    Button { sharing = true } label: { Label("keychain.export.share", systemImage: "square.and.arrow.up") }
                }
            }
            .navigationTitle(exported.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $sharing) { ActivityView(items: [exported.text]) }
    }

    /// Never to other devices (Universal Clipboard), and gone after 2 minutes.
    private func copy() {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: exported.text]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        copied = true
    }
}

/// A QR code of a text (a public key, an invitation link) to scan with
/// another device.
struct QRCodeSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                if let code = qrCode(text: text) {
                    QRCodeImage(code: code)
                        .frame(maxWidth: 320, maxHeight: 320)
                        .padding(16)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel(Text("keychain.detail.qr"))
                } else {
                    Text("qr.too_long").foregroundColor(.secondary).multilineTextAlignment(.center)
                }
                Text(verbatim: text)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal)
            }
            .padding()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// The modules of a QR code (dark on white, with the quiet zone around).
struct QRCodeImage: View {
    let code: QrCode

    var body: some View {
        Canvas { context, size in
            let n = Int(code.size)
            guard n > 0 else { return }
            let side = min(size.width, size.height)
            let cell = side / CGFloat(n + 8)
            var path = Path()
            for y in 0..<n {
                for x in 0..<n where code.modules[y * n + x] {
                    path.addRect(CGRect(x: CGFloat(x + 4) * cell, y: CGFloat(y + 4) * cell, width: cell, height: cell))
                }
            }
            context.fill(Path(CGRect(x: 0, y: 0, width: side, height: side)), with: .color(.white))
            context.fill(path, with: .color(.black))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// "Install on a host" (like ssh-copy-id): connects to the host from this
/// device and adds the public key to `~/.ssh/authorized_keys` (nothing if it
/// is already there).
struct InstallKeyView: View {
    let key: SshKey
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var hosts: [SshHost] = []
    @State private var query = ""
    @State private var working: String?
    @State private var result: InstallResult?
    @State private var prompt: AuthPrompt?

    private var filtered: [SshHost] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? hosts : hosts.filter { [$0.label, $0.address].contains { $0.lowercased().contains(q) } }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    if hosts.isEmpty { Text("snippets.send.no_hosts").foregroundColor(.secondary) }
                    ForEach(filtered, id: \.key) { h in row(h) }
                } footer: {
                    Text("keychain.install.footer")
                }
            }
            .searchable(text: $query, prompt: Text("hosts.search.prompt"))
            .navigationTitle("keychain.install.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: load)
        .sheet(item: $prompt) { p in AuthPromptView(prompt: p) { prompt = nil }.interactiveDismissDisabled() }
        .alert(result?.title ?? "", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: { Text(result?.message ?? "") }
    }

    private func row(_ h: SshHost) -> some View {
        Button { install(on: h) } label: {
            HStack(spacing: 12) {
                HostIcon(host: h, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(h.displayName).foregroundColor(.primary).lineLimit(1)
                    Text(hostSubtitle(h)).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if working == h.key { ProgressView() }
            }
        }
        .disabled(working != nil)
    }

    /// SSH hosts this device connects to directly (not Telnet, not Strict
    /// Use-only ones, which only connect through the server).
    private func load() {
        hosts = ((try? model.core.listHosts(filter: account.itemFilter)) ?? [])
            .filter { h in !h.isTelnet && !(h.isUseOnly && account.isStrict(accountId: h.accountId, vaultId: h.vaultId)) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func install(on h: SshHost) {
        working = h.key
        let publicKey = key.publicKey
        Task {
            defer { working = nil }
            let auth = AuthBridge { p in Task { @MainActor in prompt = p } }
            do {
                let session = try await model.core.connect(hostId: h.id, auth: auth, accountId: h.accountId, keyChanged: auth)
                defer { Task.detached { try? await session.disconnect() } }
                let added = try await Self.addKey(publicKey, over: session)
                result = InstallResult(title: added ? String(localized: "keychain.install.done") : String(localized: "keychain.install.already"),
                                       message: String(localized: "keychain.install.where \(h.displayName)"))
            } catch {
                result = InstallResult(title: String(localized: "keychain.install.failed"), message: userMessage(error))
            }
        }
    }

    /// Adds the key to `~/.ssh/authorized_keys` (creating `~/.ssh` with 700
    /// and the file with 600). False if it was already there.
    static func addKey(_ publicKey: String, over session: SshSession) async throws -> Bool {
        let home = try await session.sftpHome()
        let folder = RemotePaths.child(home, AuthorizedKeys.folder)
        let file = RemotePaths.child(home, AuthorizedKeys.file)
        if (try? await session.sftpStat(path: folder)) == nil {
            try await session.sftpMkdir(path: folder, recursive: false)
            try? await session.sftpChmod(path: folder, mode: 0o700)
        }
        let existing: String
        if (try? await session.sftpStat(path: file)) != nil {
            let data = try await session.sftpRead(path: file, maxBytes: TextFiles.maxBytes)
            existing = String(decoding: data, as: UTF8.self)
        } else {
            existing = ""
        }
        if AuthorizedKeys.contains(existing, publicKey: publicKey) { return false }
        try await session.sftpWrite(path: file, data: Data(AuthorizedKeys.appending(existing, publicKey: publicKey).utf8))
        try? await session.sftpChmod(path: file, mode: 0o600)
        return true
    }
}

private struct InstallResult {
    let title: String
    let message: String
}
