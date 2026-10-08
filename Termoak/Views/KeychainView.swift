import TermoakKit
import SwiftUI
import UniformTypeIdentifiers

struct KeychainView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @State private var keys: [SshKey] = []
    @State private var generating = false
    @State private var importing = false
    @State private var deleting: SshKey?
    @State private var showing: SshKey?
    @State private var installing: SshKey?
    @State private var notice: String?
    @State private var tab = 0

    var body: some View {
        // Split in parts: as one expression it is too much for the type checker.
        withSheets(list)
            .navigationTitle("nav.keychain")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { generating = true } label: { Label("keychain.menu.generate", systemImage: "key") }
                        Button { importing = true } label: { Label("keychain.menu.import", systemImage: "square.and.arrow.down") }
                    } label: { Image(systemName: "plus") }
                }
            }
            .onAppear(perform: load)
            .onReceive(account.vaultChanged) { load() }
    }

    private var list: some View {
        List {
            Section {
                Picker("", selection: $tab) {
                    Text("keychain.tab.keys \(keys.count)").tag(0)
                    Text("keychain.tab.identities").tag(1)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if tab == 1 {
                IdentityList(keys: keys)
            } else {
                keyRows
            }
        }
    }

    @ViewBuilder private var keyRows: some View {
        if keys.isEmpty {
            EmptyState(
                icon: "key",
                title: String(localized: "keychain.empty.title"),
                text: String(localized: "keychain.empty.text"),
                action: String(localized: "keychain.generate")
            ) { generating = true }
            .listRowBackground(Color.clear)
        }
        ForEach(keys, id: \.key) { k in
            keyRow(k)
                .swipeActions {
                    if !k.isUseOnly { Button("common.delete", role: .destructive) { deleting = k } }
                }
                .contextMenu { keyMenu(k) }
        }
    }

    /// Tapping a key opens its page (details, QR code, install, export).
    private func keyRow(_ k: SshKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showing = k } label: {
                HStack {
                    Image(systemName: "key.fill").foregroundColor(.accentColor)
                    VStack(alignment: .leading) {
                        Text(k.label).font(.headline).foregroundColor(.primary)
                        Text(k.hasPassphrase ? String(localized: "keychain.key.with_passphrase \(k.algorithm)") : k.algorithm)
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    ItemPlaceBadge(accountId: k.accountId, vaultId: k.vaultId, useOnly: k.isUseOnly,
                                   deviceOnly: k.syncMode == .deviceOnly)
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(k.fingerprint).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
            Button { copy(k) } label: { Label("keychain.copy_public", systemImage: "doc.on.doc") }
                .buttonStyle(.borderless).font(.footnote)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func keyMenu(_ k: SshKey) -> some View {
        Button { showing = k } label: { Label("keychain.detail.title", systemImage: "info.circle") }
        Button { copy(k) } label: { Label("keychain.copy_public", systemImage: "doc.on.doc") }
        Button { installing = k } label: { Label("keychain.install.title", systemImage: "server.rack") }
        if !k.isUseOnly {
            Divider()
            Button(role: .destructive) { deleting = k } label: { Label("common.delete", systemImage: "trash") }
        }
    }

    private func withSheets<V: View>(_ view: V) -> some View {
        view
            .sheet(isPresented: $generating, onDismiss: load) { GenerateKeyView().environmentObject(model).environmentObject(account) }
            .sheet(isPresented: $importing, onDismiss: load) { ImportKeyView().environmentObject(model).environmentObject(account) }
            .sheet(item: Binding(get: { showing.map(KeyItem.init) }, set: { showing = $0?.key }), onDismiss: load) { e in
                KeyDetailView(original: e.key).environmentObject(model).environmentObject(account)
            }
            .sheet(item: Binding(get: { installing.map(KeyItem.init) }, set: { installing = $0?.key })) { e in
                InstallKeyView(key: e.key).environmentObject(model).environmentObject(account)
            }
            .confirmationDialog(Text("keychain.delete.title \(deleting?.label ?? "")"),
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("common.delete", role: .destructive) {
                    if let k = deleting {
                        do { try model.core.deleteKey(id: k.id, accountId: k.accountId) } catch { notice = userMessage(error) }
                        load()
                        account.sync()
                    }
                }
            } message: { Text("keychain.delete.message") }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("common.ok", role: .cancel) {}
            }
    }

    private func load() {
        keys = ((try? model.core.listKeys(filter: account.itemFilter)) ?? [])
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private func copy(_ k: SshKey) {
        UIPasteboard.general.string = k.publicKey
        notice = String(localized: "keychain.public_copied")
    }
}

private struct KeyItem: Identifiable {
    let key: SshKey
    var id: String { key.key }
}

/// The key types the engine generates, newest first.
private let keyTypes: [(KeyType, String)] = [
    (.ed25519, "Ed25519"), (.ecdsaP256, "ECDSA P-256"), (.ecdsaP384, "ECDSA P-384"), (.ecdsaP521, "ECDSA P-521"),
    (.rsa4096, "RSA 4096"), (.rsa3072, "RSA 3072"), (.rsa2048, "RSA 2048"),
]

struct GenerateKeyView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type: KeyType = .ed25519
    @State private var comment = ""
    @State private var passphrase = ""
    @State private var storePassphrase = true
    @State private var deviceOnly = true
    @State private var place: ItemPlace = .device
    @State private var busy = false
    @State private var error: String?

    private var label: String { name.isEmpty ? UIDevice.current.name : name }

    var body: some View {
        NavigationView {
            Form {
                TextField(String(localized: "keychain.generate.name \(UIDevice.current.name)"), text: $name)
                Picker("common.type", selection: $type) {
                    ForEach(keyTypes, id: \.1) { t in Text(verbatim: t.1).tag(t.0) }
                }
                TextField(String(localized: "keychain.generate.comment \(label)"), text: $comment)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                passphraseSection
                if account.list.isEmpty {
                    Toggle("common.device_only", isOn: $deviceOnly)
                } else {
                    // A private key stays on this device unless you choose a vault.
                    PlacePicker(place: $place)
                }
                if let error { Text(error).foregroundColor(Brand.red) }
            }
            .navigationTitle("keychain.generate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? String(localized: "keychain.generating") : String(localized: "keychain.generate.action"), action: generate)
                        .disabled(busy)
                }
            }
        }
    }

    private var passphraseSection: some View {
        Section {
            SecureField("keychain.passphrase_optional", text: $passphrase)
            if !passphrase.isEmpty {
                Toggle("keychain.store_passphrase", isOn: $storePassphrase)
            }
        } footer: {
            if !passphrase.isEmpty && !storePassphrase { Text("keychain.store_passphrase.off_hint") }
        }
    }

    private func generate() {
        busy = true
        let label = self.label
        let comment = self.comment.trimmingCharacters(in: .whitespaces)
        Task {
            defer { busy = false }
            do {
                let p = account.list.isEmpty ? ItemPlace.device : place
                let local = account.list.isEmpty ? deviceOnly : p.accountId == nil
                _ = try await model.core.generateKey(
                    label: label, keyType: type, comment: comment.isEmpty ? "\(label) (Termoak)" : comment,
                    passphrase: passphrase.isEmpty ? nil : passphrase, storePassphrase: !passphrase.isEmpty && storePassphrase,
                    syncMode: local ? .deviceOnly : .synced, accountId: p.accountId, vaultId: p.vaultId)
                account.rememberPlace(p)
                account.sync()
                dismiss()
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}

/// Import a private key pasted or read from a file, with a preview of what it
/// is (type, fingerprint, whether it is encrypted) first.
struct ImportKeyView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var privateKey = ""
    @State private var passphrase = ""
    @State private var storePassphrase = true
    @State private var place: ItemPlace = .device
    @State private var picking = false
    @State private var details: KeyDetails?
    @State private var checking = false
    @State private var error: String?

    private var trimmed: String { privateKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationView {
            Form {
                TextField("common.name", text: $name)
                keySection
                passphraseSection
                if let details { previewSection(details) }
                if account.places.count > 1 { PlacePicker(place: $place) }
                if let error { Text(error).foregroundColor(Brand.red) }
            }
            .navigationTitle("keychain.import.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("keychain.import.action", action: importKey).disabled(trimmed.isEmpty)
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { read($0) }
        .onAppear { place = account.defaultPlace }
    }

    private var keySection: some View {
        Section {
            Button { picking = true } label: { Label("import.choose_file", systemImage: "folder") }
            TextEditor(text: $privateKey)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 140)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: privateKey) { _ in details = nil }
        } header: {
            Text("keychain.import.private_key")
        }
    }

    private var passphraseSection: some View {
        Section {
            SecureField("keychain.import.passphrase", text: $passphrase)
                .onChange(of: passphrase) { _ in details = nil }
            if !passphrase.isEmpty {
                Toggle("keychain.store_passphrase", isOn: $storePassphrase)
            }
            Button(action: check) {
                HStack {
                    Label("keychain.import.check", systemImage: "checkmark.shield")
                    Spacer()
                    if checking { ProgressView() }
                }
            }
            .disabled(trimmed.isEmpty || checking)
        } footer: {
            if !passphrase.isEmpty && !storePassphrase { Text("keychain.store_passphrase.off_hint") }
        }
    }

    private func previewSection(_ d: KeyDetails) -> some View {
        Section("keychain.import.preview") {
            HStack {
                Text("common.type")
                Spacer()
                Text(verbatim: d.algorithm).foregroundColor(.secondary)
            }
            Text(verbatim: d.fingerprint).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            if !d.comment.isEmpty { Text(verbatim: d.comment).font(.footnote).foregroundColor(.secondary) }
            if d.encrypted {
                Label("keychain.import.encrypted", systemImage: "lock.fill").font(.footnote).foregroundColor(Brand.amber)
            }
        }
    }

    /// Reads the key without saving it (with the passphrase, if it needs one).
    private func check() {
        checking = true
        error = nil
        let key = trimmed, pass = passphrase.isEmpty ? nil : passphrase
        Task {
            defer { checking = false }
            do {
                details = try await inspectPrivateKey(privateKey: key, passphrase: pass)
                if name.isEmpty, let comment = details?.comment, !comment.isEmpty { name = comment }
            } catch {
                details = nil
                self.error = userMessage(error)
            }
        }
    }

    private func read(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // A private key is small: anything big is not one.
            let data = try Data(contentsOf: url)
            guard data.count <= 64 * 1024, let text = TextFiles.decode(data) else {
                error = String(localized: "keychain.import.not_a_key")
                return
            }
            privateKey = text
            if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
            // After the editor has taken the new text (it clears the preview).
            DispatchQueue.main.async { check() }
        } catch {
            self.error = String(localized: "import.read_failed")
        }
    }

    private func importKey() {
        Task {
            do {
                _ = try await model.core.importKey(
                    label: name.isEmpty ? String(localized: "keychain.import.default_label") : name,
                    privateKey: trimmed,
                    passphrase: passphrase.isEmpty ? nil : passphrase, storePassphrase: !passphrase.isEmpty && storePassphrase,
                    syncMode: account.list.isEmpty ? nil : (place.accountId == nil ? .deviceOnly : .synced),
                    accountId: place.accountId, vaultId: place.vaultId)
                account.rememberPlace(place)
                account.sync()
                dismiss()
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}

/// Snippets: tap to edit; hold or swipe to run one on several servers or
/// in every open terminal.
struct SnippetsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @EnvironmentObject private var sessions: Sessions
    @State private var list: [Snippet] = []
    @State private var editing: SnippetEdit?
    @State private var sending: SnippetSendItem?
    @State private var deleting: Snippet?
    @State private var error: String?

    var body: some View {
        List {
            if list.isEmpty {
                EmptyState(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: String(localized: "snippets.empty.title"),
                    text: String(localized: "snippets.empty.text"),
                    action: String(localized: "snippets.editor.new")
                ) { editing = SnippetEdit(snippet: Snippet(name: "", script: "")) }
                .listRowBackground(Color.clear)
            }
            ForEach(list, id: \.key) { sn in
                Button { if sn.canEdit { editing = SnippetEdit(snippet: sn) } } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(sn.name).font(.headline).foregroundColor(.primary)
                            Spacer()
                            ItemPlaceBadge(accountId: sn.accountId, vaultId: sn.vaultId, useOnly: !sn.canEdit,
                                           deviceOnly: sn.syncMode == .deviceOnly)
                        }
                        if !sn.description.isEmpty { Text(sn.description).font(.caption).foregroundColor(.secondary) }
                        Text(sn.script).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary).lineLimit(3)
                        if !sn.tags.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(Array(sn.tags.prefix(4).enumerated()), id: \.offset) { _, tag in TagChip(text: tag) }
                            }
                        }
                    }
                }
                .swipeActions {
                    if sn.canEdit { Button("common.delete", role: .destructive) { deleting = sn } }
                }
                .swipeActions(edge: .leading) {
                    Button { sending = SnippetSendItem(snippet: sn, target: .servers) } label: {
                        Label("snippets.send.servers", systemImage: "paperplane")
                    }
                    .tint(Brand.blue)
                }
                .contextMenu {
                    Button { sending = SnippetSendItem(snippet: sn, target: .servers) } label: {
                        Label("snippets.send.servers", systemImage: "paperplane")
                    }
                    if !sessions.open.isEmpty {
                        Button { sending = SnippetSendItem(snippet: sn, target: .openTerminals) } label: {
                            Label("snippets.send.open", systemImage: "rectangle.stack")
                        }
                    }
                    if sn.canEdit {
                        Divider()
                        Button { editing = SnippetEdit(snippet: sn) } label: { Label("common.edit", systemImage: "pencil") }
                        Button(role: .destructive) { deleting = sn } label: { Label("common.delete", systemImage: "trash") }
                    }
                }
            }
        }
        .navigationTitle("nav.snippets")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = SnippetEdit(snippet: Snippet(name: "", script: "")) } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editing, onDismiss: load) { e in SnippetEditor(original: e.snippet).environmentObject(model).environmentObject(account) }
        .confirmationDialog(Text("common.delete_named \(deleting?.name ?? "")"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("common.delete", role: .destructive) { if let sn = deleting { delete(sn) } }
        } message: { Text("snippets.delete.message") }
        .alert("common.error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: { Text(error ?? "") }
        .sheet(item: $sending) { e in
            SnippetSendView(snippet: e.snippet, initialTarget: e.target)
                .environmentObject(model)
                .environmentObject(sessions)
        }
        .onAppear(perform: load)
        .onReceive(account.vaultChanged) { load() }
    }

    private func delete(_ sn: Snippet) {
        do { try model.core.deleteSnippet(id: sn.id, accountId: sn.accountId) } catch { self.error = userMessage(error) }
        load()
        account.sync()
    }

    private func load() {
        list = ((try? model.core.listSnippets(filter: account.itemFilter)) ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct SnippetEdit: Identifiable {
    let id = UUID()
    let snippet: Snippet
}

private struct SnippetEditor: View {
    let original: Snippet
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var script = ""
    @State private var summary = ""
    @State private var tags = ""
    @State private var place: ItemPlace = .device
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                TextField("common.name", text: $name)
                if original.id.isEmpty && account.places.count > 1 { PlacePicker(place: $place) }
                Section {
                    TextEditor(text: $script)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: { Text("snippets.editor.command") } footer: { Text("snippets.editor.variables") }
                TextField("snippets.editor.description", text: $summary)
                Section {
                    TextField("snippets.editor.tags", text: $tags)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("snippets.editor.tags_footer")
                }
                if let error { Text(error).foregroundColor(Brand.red) }
            }
            .navigationTitle(original.id.isEmpty ? String(localized: "snippets.editor.new") : String(localized: "snippets.editor.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        var sn = original
                        sn.name = name.trimmingCharacters(in: .whitespaces)
                        sn.script = script
                        sn.description = summary
                        sn.tags = parseTags(tags)
                        if sn.id.isEmpty && !account.list.isEmpty {
                            sn.accountId = place.accountId
                            sn.vaultId = place.vaultId
                            sn.syncMode = place.accountId == nil ? .deviceOnly : .synced
                        }
                        do {
                            _ = try model.core.saveSnippet(snippet: sn)
                            if original.id.isEmpty { account.rememberPlace(place) }
                            account.sync()
                            dismiss()
                        } catch {
                            self.error = userMessage(error)
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || script.isEmpty)
                }
            }
        }
        .onAppear {
            name = original.name
            script = original.script
            summary = original.description
            tags = original.tags.joined(separator: ", ")
            place = account.defaultPlace
        }
    }
}

/// Identities: a username with its password and/or key, to reuse on several hosts.
private struct IdentityList: View {
    let keys: [SshKey]
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @State private var list: [SshIdentity] = []
    @State private var editing: IdentityEdit?
    @State private var deleting: SshIdentity?
    @State private var error: String?

    var body: some View {
        Group {
            if list.isEmpty {
                Text("identities.empty")
                    .foregroundColor(.secondary)
            }
            ForEach(list, id: \.key) { i in
                Button { if !i.isUseOnly { editing = IdentityEdit(identity: i) } } label: {
                    HStack(spacing: 12) {
                        HostTile(name: i.label, os: nil, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.label).foregroundColor(.primary)
                            Text([i.username, i.hasPassword ? String(localized: "identities.has_password") : nil,
                                  keys.first { $0.id == i.keyId && $0.accountId == i.accountId }.map { String(localized: "identities.key \($0.label)") }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer(minLength: 0)
                        ItemPlaceBadge(accountId: i.accountId, vaultId: i.vaultId, useOnly: i.isUseOnly,
                                       deviceOnly: i.syncMode == .deviceOnly)
                    }
                }
                .swipeActions {
                    if !i.isUseOnly {
                        Button("common.delete", role: .destructive) { deleting = i }
                    }
                }
                .contextMenu {
                    if !i.isUseOnly {
                        Button { editing = IdentityEdit(identity: i) } label: { Label("common.edit", systemImage: "pencil") }
                        Button(role: .destructive) { deleting = i } label: { Label("common.delete", systemImage: "trash") }
                    }
                }
            }
            Button { editing = IdentityEdit(identity: SshIdentity(label: "", username: "")) } label: {
                Label("identities.new", systemImage: "plus")
            }
        }
        .sheet(item: $editing, onDismiss: load) { e in
            IdentityEditor(original: e.identity, keys: keys).environmentObject(model).environmentObject(account)
        }
        .confirmationDialog(Text("common.delete_named \(deleting?.label ?? "")"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("common.delete", role: .destructive) { if let i = deleting { delete(i) } }
        } message: { Text("identities.delete.message") }
        .alert("common.error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: { Text(error ?? "") }
        .onAppear(perform: load)
        .onReceive(account.vaultChanged) { load() }
    }

    private func delete(_ i: SshIdentity) {
        do { try model.core.deleteIdentity(id: i.id, accountId: i.accountId) } catch { self.error = userMessage(error) }
        load()
        account.sync()
    }

    private func load() {
        list = ((try? model.core.listIdentities(filter: account.itemFilter)) ?? [])
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
}

private struct IdentityEdit: Identifiable {
    let id = UUID()
    let identity: SshIdentity
}

private struct IdentityEditor: View {
    let original: SshIdentity
    let keys: [SshKey]
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var keyId: String?
    @State private var place: ItemPlace = .device
    /// Forget the saved password (the host asks for it next time).
    @State private var clearPassword = false
    @State private var error: String?

    /// Keys of the identity's vault and of This device.
    private var usableKeys: [SshKey] {
        keys.filter { $0.accountId == nil || ($0.accountId == place.accountId && $0.vaultId == place.vaultId) }
    }

    var body: some View {
        NavigationView {
            Form {
                TextField("common.name", text: $name)
                if original.id.isEmpty && account.places.count > 1 { PlacePicker(place: $place) }
                TextField("common.username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(original.hasPassword ? String(localized: "identities.password_keep")
                            : String(localized: "common.password_optional"), text: $password)
                    .disabled(clearPassword)
                if original.hasPassword {
                    Toggle("identities.clear_password", isOn: $clearPassword)
                }
                Picker("common.key", selection: $keyId) {
                    Text("identities.no_key").tag(String?.none)
                    ForEach(usableKeys, id: \.key) { Text($0.label).tag(Optional($0.id)) }
                }
                if let error { Text(error).foregroundColor(Brand.red) }
            }
            .navigationTitle(original.id.isEmpty ? String(localized: "identities.new") : String(localized: "identities.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        var i = original
                        i.label = name.isEmpty ? username : name
                        i.username = username
                        i.keyId = keyId
                        if i.id.isEmpty && !account.list.isEmpty {
                            i.accountId = place.accountId
                            i.vaultId = place.vaultId
                            i.syncMode = place.accountId == nil ? .deviceOnly : .synced
                        }
                        do {
                            let secret: SecretChange = clearPassword ? .clear : (password.isEmpty ? .keep : .set(value: password))
                            _ = try model.core.saveIdentity(identity: i, password: secret)
                            if original.id.isEmpty { account.rememberPlace(place) }
                            account.sync()
                            dismiss()
                        } catch {
                            self.error = userMessage(error)
                        }
                    }
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear {
            name = original.label
            username = original.username
            keyId = original.keyId
            place = original.id.isEmpty ? account.defaultPlace : account.place(accountId: original.accountId, vaultId: original.vaultId)
        }
    }
}

/// Known hosts: the fingerprints of the servers you trust.
struct KnownHostsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @State private var list: [KnownHost] = []
    @State private var query = ""
    @State private var showing: KnownHost?
    @State private var forgetting: KnownHost?
    @State private var error: String?

    /// Searched by host, port, key type and fingerprint.
    private var filtered: [KnownHost] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter { k in [k.display, k.keyType, k.fingerprint].contains { $0.lowercased().contains(q) } }
    }

    var body: some View {
        withDialogs(content)
            .navigationTitle("nav.known_hosts")
            .onAppear(perform: load)
            .onReceive(account.vaultChanged) { load() }
    }

    private var content: some View {
        List {
            if list.isEmpty {
                EmptyState(
                    icon: "checkmark.shield",
                    title: String(localized: "known_hosts.empty.title"),
                    text: String(localized: "known_hosts.empty.text")
                )
                .listRowBackground(Color.clear)
            }
            ForEach(filtered, id: \.key) { k in row(k) }
        }
        .searchable(text: $query, prompt: Text("known_hosts.search"))
        .overlay {
            if !list.isEmpty && filtered.isEmpty {
                Text("hosts.search.no_results \(query)").foregroundColor(.secondary).padding()
            }
        }
    }

    private func row(_ k: KnownHost) -> some View {
        Button { showing = k } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(verbatim: k.display).font(.headline).foregroundColor(.primary)
                    Spacer()
                    ItemPlaceBadge(accountId: k.accountId, vaultId: k.vaultId, useOnly: false, deviceOnly: false)
                }
                Text(k.keyType).font(.caption).foregroundColor(.secondary)
                Text(k.fingerprint).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            if k.canForget {
                Button("known_hosts.forget", role: .destructive) { forgetting = k }
            }
        }
        .contextMenu {
            Button { UIPasteboard.general.string = k.fingerprint } label: {
                Label("known_hosts.copy_fingerprint", systemImage: "doc.on.doc")
            }
            if k.canForget {
                Button(role: .destructive) { forgetting = k } label: { Label("known_hosts.forget", systemImage: "trash") }
            }
        }
    }

    private func withDialogs<V: View>(_ view: V) -> some View {
        view
            .sheet(item: Binding(get: { showing.map(KnownHostItem.init) }, set: { showing = $0?.host })) { e in
                KnownHostDetail(host: e.host) {
                    showing = nil
                    // One sheet after the other.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { forgetting = e.host }
                }
            }
            .confirmationDialog(Text("known_hosts.forget.title \(forgetting.map(\.display) ?? "")"),
                                isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                                titleVisibility: .visible) {
                Button("known_hosts.forget", role: .destructive) { if let k = forgetting { forget(k) } }
            } message: { Text("known_hosts.forget.message") }
            .alert("common.error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("common.ok", role: .cancel) {}
            } message: { Text(error ?? "") }
    }

    /// Only with access to its vault (not Use only); the engine checks it too.
    private func forget(_ k: KnownHost) {
        guard k.canForget else { return }
        do { try model.core.deleteKnownHost(id: k.id, accountId: k.accountId) } catch { self.error = userMessage(error) }
        load()
        account.sync()
    }

    private func load() {
        list = ((try? model.core.listKnownHosts(filter: account.itemFilter)) ?? []).sorted { $0.host < $1.host }
    }
}

private struct KnownHostItem: Identifiable {
    let host: KnownHost
    var id: String { host.key }
}

/// A known host: its fingerprint, the whole public key and when it was saved.
private struct KnownHostDetail: View {
    let host: KnownHost
    let onForget: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    line("known_hosts.detail.host", host.host)
                    line("common.port", String(host.port))
                    line("common.type", host.keyType)
                    if host.updatedAt > 0 {
                        line("known_hosts.detail.saved", dateFromMillis(host.updatedAt).formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Section("keychain.detail.fingerprint") {
                    Text(verbatim: host.fingerprint).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    Button { UIPasteboard.general.string = host.fingerprint } label: {
                        Label("known_hosts.copy_fingerprint", systemImage: "doc.on.doc")
                    }
                }
                Section("keychain.detail.public_key") {
                    Text(verbatim: host.publicKey).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    Button { UIPasteboard.general.string = host.publicKey } label: {
                        Label("known_hosts.copy_key", systemImage: "doc.on.doc")
                    }
                }
                if host.canForget {
                    Section {
                        Button(role: .destructive, action: onForget) { Label("known_hosts.forget", systemImage: "trash") }
                    }
                }
            }
            .navigationTitle(host.display)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func line(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(verbatim: value).foregroundColor(.secondary).textSelection(.enabled)
        }
    }
}

/// Where an item of the keychain lives: its vault (when several are shown),
/// "This device" (with accounts) and the Use-only lock.
struct ItemPlaceBadge: View {
    let accountId: String?
    let vaultId: String?
    let useOnly: Bool
    let deviceOnly: Bool
    @EnvironmentObject private var account: Accounts

    var body: some View {
        HStack(spacing: 4) {
            if useOnly {
                Image(systemName: "lock.fill").font(.caption).foregroundColor(Brand.amber)
                    .accessibilityLabel(Text("vaults.use_only_badge"))
            }
            if accountId == nil {
                if deviceOnly || !account.scoped.isEmpty {
                    Image(systemName: "iphone").foregroundColor(.secondary)
                        .accessibilityLabel(Text("accounts.this_device"))
                }
            } else if account.showsVaults, let v = account.vault(accountId, vaultId) {
                VaultChip(vault: v)
            }
            if account.showsAccountBadges, let a = account.account(accountId) {
                AccountAvatar(account: a, size: 18)
            }
        }
    }
}
