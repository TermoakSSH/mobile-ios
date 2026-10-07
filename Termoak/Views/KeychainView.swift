import TermoakKit
import SwiftUI

struct KeychainView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @State private var keys: [SshKey] = []
    @State private var generating = false
    @State private var importing = false
    @State private var deleting: SshKey?
    @State private var notice: String?
    @State private var tab = 0

    var body: some View {
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "key.fill").foregroundColor(.accentColor)
                        VStack(alignment: .leading) {
                            Text(k.label).font(.headline)
                            Text(k.hasPassphrase ? String(localized: "keychain.key.with_passphrase \(k.algorithm)") : k.algorithm)
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        ItemPlaceBadge(accountId: k.accountId, vaultId: k.vaultId, useOnly: k.isUseOnly,
                                       deviceOnly: k.syncMode == .deviceOnly)
                    }
                    Text(k.fingerprint).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
                    Button { copy(k) } label: { Label("keychain.copy_public", systemImage: "doc.on.doc") }
                        .buttonStyle(.borderless).font(.footnote)
                }
                .padding(.vertical, 4)
                .swipeActions {
                    if !k.isUseOnly { Button("common.delete", role: .destructive) { deleting = k } }
                }
            }
            }
        }
        .navigationTitle("nav.keychain")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { generating = true } label: { Label("keychain.menu.generate", systemImage: "key") }
                    Button { importing = true } label: { Label("keychain.menu.import", systemImage: "square.and.arrow.down") }
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $generating, onDismiss: load) { GenerateKeyView().environmentObject(model).environmentObject(account) }
        .sheet(isPresented: $importing, onDismiss: load) { ImportKeyView().environmentObject(model).environmentObject(account) }
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
        .onAppear(perform: load)
        .onReceive(account.vaultChanged) { load() }
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

struct GenerateKeyView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type: KeyType = .ed25519
    @State private var passphrase = ""
    @State private var deviceOnly = true
    @State private var place: ItemPlace = .device
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                TextField(String(localized: "keychain.generate.name \(UIDevice.current.name)"), text: $name)
                Picker("common.type", selection: $type) {
                    Text(verbatim: "Ed25519").tag(KeyType.ed25519)
                    Text(verbatim: "ECDSA").tag(KeyType.ecdsaP256)
                    Text(verbatim: "RSA 4096").tag(KeyType.rsa4096)
                }
                .pickerStyle(.segmented)
                SecureField("keychain.passphrase_optional", text: $passphrase)
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
                    Button(busy ? String(localized: "keychain.generating") : String(localized: "keychain.generate.action")) {
                        busy = true
                        let label = name.isEmpty ? UIDevice.current.name : name
                        Task {
                            defer { busy = false }
                            do {
                                let p = account.list.isEmpty ? ItemPlace.device : place
                                let local = account.list.isEmpty ? deviceOnly : p.accountId == nil
                                _ = try await model.core.generateKey(
                                    label: label, keyType: type, comment: "\(label) (Termoak)",
                                    passphrase: passphrase.isEmpty ? nil : passphrase, storePassphrase: !passphrase.isEmpty,
                                    syncMode: local ? .deviceOnly : .synced, accountId: p.accountId, vaultId: p.vaultId)
                                account.rememberPlace(p)
                                account.sync()
                                dismiss()
                            } catch {
                                self.error = userMessage(error)
                            }
                        }
                    }
                    .disabled(busy)
                }
            }
        }
    }
}

struct ImportKeyView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var privateKey = ""
    @State private var passphrase = ""
    @State private var place: ItemPlace = .device
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                TextField("common.name", text: $name)
                Section("keychain.import.private_key") {
                    TextEditor(text: $privateKey)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 140)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                SecureField("keychain.import.passphrase", text: $passphrase)
                if account.places.count > 1 { PlacePicker(place: $place) }
                if let error { Text(error).foregroundColor(Brand.red) }
            }
            .navigationTitle("keychain.import.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("keychain.import.action") {
                        Task {
                            do {
                                _ = try await model.core.importKey(
                                    label: name.isEmpty ? String(localized: "keychain.import.default_label") : name,
                                    privateKey: privateKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                    passphrase: passphrase.isEmpty ? nil : passphrase, storePassphrase: !passphrase.isEmpty,
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
                    .disabled(privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { place = account.defaultPlace }
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
                    }
                }
                .swipeActions {
                    if sn.canEdit { Button("common.delete", role: .destructive) { delete(sn) } }
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
                        Button(role: .destructive) { delete(sn) } label: { Label("common.delete", systemImage: "trash") }
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
        .sheet(item: $sending) { e in
            SnippetSendView(snippet: e.snippet, initialTarget: e.target)
                .environmentObject(model)
                .environmentObject(sessions)
        }
        .onAppear(perform: load)
        .onReceive(account.vaultChanged) { load() }
    }

    private func delete(_ sn: Snippet) {
        try? model.core.deleteSnippet(id: sn.id, accountId: sn.accountId)
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
                        Button("common.delete", role: .destructive) {
                            try? model.core.deleteIdentity(id: i.id, accountId: i.accountId)
                            load()
                            account.sync()
                        }
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
        .onAppear(perform: load)
        .onReceive(account.vaultChanged) { load() }
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
                            _ = try model.core.saveIdentity(identity: i, password: password.isEmpty ? .keep : .set(value: password))
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

    var body: some View {
        List {
            if list.isEmpty {
                EmptyState(
                    icon: "checkmark.shield",
                    title: String(localized: "known_hosts.empty.title"),
                    text: String(localized: "known_hosts.empty.text")
                )
                .listRowBackground(Color.clear)
            }
            ForEach(list, id: \.key) { k in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(k.port == 22 ? k.host : "\(k.host):\(k.port)").font(.headline)
                        Spacer()
                        ItemPlaceBadge(accountId: k.accountId, vaultId: k.vaultId, useOnly: false, deviceOnly: false)
                    }
                    Text(k.keyType).font(.caption).foregroundColor(.secondary)
                    Text(k.fingerprint).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                        .lineLimit(1).textSelection(.enabled)
                }
                .swipeActions {
                    Button("known_hosts.forget", role: .destructive) {
                        try? model.core.deleteKnownHost(id: k.id, accountId: k.accountId)
                        load()
                        account.sync()
                    }
                }
            }
        }
        .navigationTitle("nav.known_hosts")
        .onAppear(perform: load)
        .onReceive(account.vaultChanged) { load() }
    }

    private func load() {
        list = ((try? model.core.listKnownHosts(filter: account.itemFilter)) ?? []).sorted { $0.host < $1.host }
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
