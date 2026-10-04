import TermoakKit
import SwiftUI

struct KeychainView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Account
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
            ForEach(keys, id: \.id) { k in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "key.fill").foregroundColor(.accentColor)
                        VStack(alignment: .leading) {
                            Text(k.label).font(.headline)
                            Text(k.hasPassphrase ? String(localized: "keychain.key.with_passphrase \(k.algorithm)") : k.algorithm)
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if k.syncMode == .deviceOnly {
                            Image(systemName: "iphone").foregroundColor(.secondary)
                        }
                    }
                    Text(k.fingerprint).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
                    Button { copy(k) } label: { Label("keychain.copy_public", systemImage: "doc.on.doc") }
                        .buttonStyle(.borderless).font(.footnote)
                }
                .padding(.vertical, 4)
                .swipeActions { Button("common.delete", role: .destructive) { deleting = k } }
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
                if let k = deleting { try? model.core.deleteKey(id: k.id); load(); account.sync() }
            }
        } message: { Text("keychain.delete.message") }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("common.ok", role: .cancel) {}
        }
        .onAppear(perform: load)
    }

    private func load() {
        keys = ((try? model.core.listKeys()) ?? [])
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private func copy(_ k: SshKey) {
        UIPasteboard.general.string = k.publicKey
        notice = String(localized: "keychain.public_copied")
    }
}

private struct GenerateKeyView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Account
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type: KeyType = .ed25519
    @State private var passphrase = ""
    @State private var deviceOnly = true
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
                Toggle("common.device_only", isOn: $deviceOnly)
                if let error { Text(error).foregroundColor(Brand.red) }
            }
            .navigationTitle("keychain.generate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? String(localized: "keychain.generating") : String(localized: "keychain.generate.action")) {
                        busy = true
                        let label = name.isEmpty ? UIDevice.current.name : name
                        Task {
                            defer { busy = false }
                            do {
                                _ = try await model.core.generateKey(
                                    label: label, keyType: type, comment: "\(label) (Termoak)",
                                    passphrase: passphrase.isEmpty ? nil : passphrase, storePassphrase: !passphrase.isEmpty,
                                    syncMode: deviceOnly ? .deviceOnly : .synced)
                                account.sync()
                                dismiss()
                            } catch {
                                self.error = errorMessage(error)
                            }
                        }
                    }
                    .disabled(busy)
                }
            }
        }
    }
}

private struct ImportKeyView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Account
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var privateKey = ""
    @State private var passphrase = ""
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
                if let error { Text(error).foregroundColor(Brand.red) }
            }
            .navigationTitle("keychain.import.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("keychain.import.action") {
                        Task {
                            do {
                                _ = try await model.core.importKey(
                                    label: name.isEmpty ? String(localized: "keychain.import.default_label") : name,
                                    privateKey: privateKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                    passphrase: passphrase.isEmpty ? nil : passphrase, storePassphrase: !passphrase.isEmpty, syncMode: nil)
                                account.sync()
                                dismiss()
                            } catch {
                                self.error = errorMessage(error)
                            }
                        }
                    }
                    .disabled(privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct SnippetsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Account
    @State private var list: [Snippet] = []
    @State private var editing: SnippetEdit?

    var body: some View {
        List {
            if list.isEmpty {
                EmptyState(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: String(localized: "snippets.empty.title"),
                    text: String(localized: "snippets.empty.text")
                )
                .listRowBackground(Color.clear)
            }
            ForEach(list, id: \.id) { sn in
                Button { editing = SnippetEdit(snippet: sn) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sn.name).font(.headline).foregroundColor(.primary)
                        if !sn.description.isEmpty { Text(sn.description).font(.caption).foregroundColor(.secondary) }
                        Text(sn.script).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary).lineLimit(3)
                    }
                }
                .swipeActions {
                    Button("common.delete", role: .destructive) {
                        try? model.core.deleteSnippet(id: sn.id)
                        load()
                        account.sync()
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
        .onAppear(perform: load)
    }

    private func load() {
        list = ((try? model.core.listSnippets()) ?? [])
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
    @EnvironmentObject private var account: Account
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var script = ""
    @State private var summary = ""
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                TextField("common.name", text: $name)
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
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        var sn = original
                        sn.name = name.trimmingCharacters(in: .whitespaces)
                        sn.script = script
                        sn.description = summary
                        do {
                            _ = try model.core.saveSnippet(snippet: sn)
                            account.sync()
                            dismiss()
                        } catch {
                            self.error = errorMessage(error)
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
        }
    }
}

/// Identities: a username with its password and/or key, to reuse on several hosts.
private struct IdentityList: View {
    let keys: [SshKey]
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Account
    @State private var list: [SshIdentity] = []
    @State private var editing: IdentityEdit?

    var body: some View {
        Group {
            if list.isEmpty {
                Text("identities.empty")
                    .foregroundColor(.secondary)
            }
            ForEach(list, id: \.id) { i in
                Button { editing = IdentityEdit(identity: i) } label: {
                    HStack(spacing: 12) {
                        HostTile(name: i.label, os: nil, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.label).foregroundColor(.primary)
                            Text([i.username, i.hasPassword ? String(localized: "identities.has_password") : nil,
                                  keys.first { $0.id == i.keyId }.map { String(localized: "identities.key \($0.label)") }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button("common.delete", role: .destructive) {
                        try? model.core.deleteIdentity(id: i.id)
                        load()
                        account.sync()
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
    }

    private func load() {
        list = ((try? model.core.listIdentities()) ?? [])
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
    @EnvironmentObject private var account: Account
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var keyId: String?
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                TextField("common.name", text: $name)
                TextField("common.username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(original.hasPassword ? String(localized: "identities.password_keep")
                            : String(localized: "common.password_optional"), text: $password)
                Picker("common.key", selection: $keyId) {
                    Text("identities.no_key").tag(String?.none)
                    ForEach(keys, id: \.id) { Text($0.label).tag(Optional($0.id)) }
                }
                if let error { Text(error).foregroundColor(Brand.red) }
            }
            .navigationTitle(original.id.isEmpty ? String(localized: "identities.new") : String(localized: "identities.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        var i = original
                        i.label = name.isEmpty ? username : name
                        i.username = username
                        i.keyId = keyId
                        do {
                            _ = try model.core.saveIdentity(identity: i, password: password.isEmpty ? .keep : .set(value: password))
                            account.sync()
                            dismiss()
                        } catch {
                            self.error = errorMessage(error)
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
        }
    }
}

/// Known hosts: the fingerprints of the servers you trust.
struct KnownHostsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Account
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
            ForEach(list, id: \.id) { k in
                VStack(alignment: .leading, spacing: 3) {
                    Text(k.port == 22 ? k.host : "\(k.host):\(k.port)").font(.headline)
                    Text(k.keyType).font(.caption).foregroundColor(.secondary)
                    Text(k.fingerprint).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                        .lineLimit(1).textSelection(.enabled)
                }
                .swipeActions {
                    Button("known_hosts.forget", role: .destructive) {
                        try? model.core.deleteKnownHost(id: k.id)
                        load()
                        account.sync()
                    }
                }
            }
        }
        .navigationTitle("nav.known_hosts")
        .onAppear(perform: load)
    }

    private func load() {
        list = ((try? model.core.listKnownHosts()) ?? []).sorted { $0.host < $1.host }
    }
}
