import TermoakKit
import SwiftUI

private enum AuthMethod: CaseIterable, Identifiable {
    case password, key, identity
    var id: Self { self }

    var title: String {
        switch self {
        case .password: return String(localized: "common.password")
        case .key: return String(localized: "host_editor.method.key")
        case .identity: return String(localized: "common.identity")
        }
    }
}

/// Host editor in blocks, like Termius's.
struct HostEditor: View {
    let original: SshHost?
    var initialGroup: String? = nil

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Account
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    @State private var port = ""
    @State private var username = ""
    @State private var method: AuthMethod = .password
    @State private var password = ""
    @State private var clearPassword = false
    @State private var keyId: String?
    @State private var identityId: String?
    @State private var groupId: String?
    @State private var tags = ""
    @State private var notes = ""
    @State private var favorite = false
    @State private var deviceOnly = false
    @State private var jumps: [String] = []
    @State private var proxyKind: ProxyKind?
    @State private var proxyHost = ""
    @State private var proxyPort = ""
    @State private var proxyUsername = ""
    @State private var proxyPassword = ""
    @State private var hadProxyPassword = false
    @State private var clearProxyPassword = false
    @State private var keys: [SshKey] = []
    @State private var identities: [SshIdentity] = []
    @State private var groups: [HostGroup] = []
    @State private var others: [SshHost] = []
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                // Header that looks like the host will in the list.
                Section {
                    HStack(spacing: 14) {
                        HostTile(name: name.isEmpty ? (address.isEmpty ? "?" : address) : name, os: original?.os, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name.isEmpty ? (address.isEmpty ? String(localized: "common.new_host") : address) : name)
                                .font(.title3.weight(.semibold))
                            Text(verbatim: username.isEmpty ? "ssh" : "ssh, \(username)").foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("host_editor.general") {
                    TextField("host_editor.address", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("host_editor.label", text: $name)
                    Picker("host_editor.group", selection: $groupId) {
                        Text("host_editor.no_group").tag(String?.none)
                        ForEach(groups, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextField("host_editor.tags", text: $tags).textInputAutocapitalization(.never)
                }

                Section {
                    TextField("host_editor.port", text: $port).keyboardType(.numberPad)
                } header: { Text(verbatim: "SSH") }

                Section {
                    TextField("common.username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("host_editor.method", selection: $method) {
                        ForEach(AuthMethod.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch method {
                    case .password:
                        SecureField(original?.hasPassword == true && !clearPassword
                                    ? String(localized: "common.password_saved") : String(localized: "common.password_optional"),
                                    text: $password)
                        if original?.hasPassword == true && !clearPassword && password.isEmpty {
                            Button("host_editor.clear_password", role: .destructive) { clearPassword = true }
                        }
                    case .key:
                        if keys.isEmpty {
                            Text("host_editor.no_keys").foregroundColor(.secondary)
                        } else {
                            Picker("common.key", selection: $keyId) {
                                Text("common.choose").tag(String?.none)
                                ForEach(keys, id: \.id) { Text(verbatim: "\($0.label) · \($0.algorithm)").tag(Optional($0.id)) }
                            }
                        }
                    case .identity:
                        if identities.isEmpty {
                            Text("host_editor.no_identities").foregroundColor(.secondary)
                        } else {
                            Picker("common.identity", selection: $identityId) {
                                Text("common.choose").tag(String?.none)
                                ForEach(identities, id: \.id) { Text(verbatim: "\($0.label) (\($0.username))").tag(Optional($0.id)) }
                            }
                        }
                    }
                } header: { Text("host_editor.credentials") }

                Section {
                    ForEach(Array(jumps.enumerated()), id: \.offset) { i, id in
                        HStack {
                            Text(verbatim: "\(i + 1).").foregroundColor(.secondary)
                            VStack(alignment: .leading) {
                                Text(others.first { $0.id == id }?.label ?? String(localized: "host_editor.deleted_host"))
                                if let h = others.first(where: { $0.id == id }) {
                                    Text(h.address).font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { jumps.remove(atOffsets: $0) }
                    .onMove { jumps.move(fromOffsets: $0, toOffset: $1) }
                    let candidates = others.filter { !jumps.contains($0.id) }
                    if !candidates.isEmpty {
                        Menu {
                            ForEach(candidates, id: \.id) { h in Button(h.label) { jumps.append(h.id) } }
                        } label: { Label("host_editor.add_jump", systemImage: "plus") }
                    }
                } header: { Text("host_editor.jump_chain") } footer: {
                    Text(jumps.isEmpty ? String(localized: "host_editor.jump_chain.footer_empty")
                         : String(localized: "host_editor.jump_chain.footer"))
                }

                Section {
                    Picker("common.type", selection: $proxyKind) {
                        Text("host_editor.no_proxy").tag(ProxyKind?.none)
                        Text(verbatim: "SOCKS5").tag(Optional(ProxyKind.socks5))
                        Text(verbatim: "SOCKS4").tag(Optional(ProxyKind.socks4))
                        Text(verbatim: "HTTP (CONNECT)").tag(Optional(ProxyKind.http))
                    }
                    if proxyKind != nil {
                        TextField("host_editor.proxy_address", text: $proxyHost)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField(proxyKind == .http ? String(localized: "host_editor.proxy_port_http")
                                  : String(localized: "host_editor.proxy_port_socks"), text: $proxyPort)
                            .keyboardType(.numberPad)
                        TextField("host_editor.username_optional", text: $proxyUsername)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField(hadProxyPassword && !clearProxyPassword
                                    ? String(localized: "common.password_saved") : String(localized: "common.password_optional"),
                                    text: $proxyPassword)
                        if hadProxyPassword && !clearProxyPassword && proxyPassword.isEmpty {
                            Button("host_editor.clear_proxy_password", role: .destructive) { clearProxyPassword = true }
                        }
                    }
                } header: { Text(verbatim: "Proxy") } footer: {
                    Text("host_editor.proxy.footer")
                }

                Section("host_editor.options") {
                    Toggle("host_editor.favorite", isOn: $favorite)
                    Toggle("common.device_only", isOn: $deviceOnly)
                    TextField("host_editor.notes", text: $notes)
                }
            }
            .navigationTitle(original == nil ? String(localized: "common.new_host") : String(localized: "host_editor.edit_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save", action: save).disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("host_editor.save_failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("common.ok", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .onAppear(perform: load)
    }

    private func load() {
        keys = (try? model.core.listKeys()) ?? []
        identities = (try? model.core.listIdentities()) ?? []
        groups = (try? model.core.listGroups()) ?? []
        others = ((try? model.core.listHosts()) ?? []).filter { $0.id != original?.id }
        groupId = initialGroup
        guard let h = original else { return }
        name = h.label
        address = h.address
        port = h.settings.port.map(String.init) ?? ""
        username = h.settings.username ?? ""
        keyId = h.settings.keyId
        identityId = h.settings.identityId
        method = identityId != nil ? .identity : (keyId != nil ? .key : .password)
        groupId = h.groupId
        tags = h.tags.joined(separator: ", ")
        notes = h.notes
        favorite = h.favorite
        deviceOnly = h.syncMode == .deviceOnly
        jumps = h.settings.jumpHostIds ?? []
        if let p = h.settings.proxy {
            proxyKind = p.kind
            proxyHost = p.host
            proxyPort = String(p.port)
            proxyUsername = p.username ?? ""
        }
        hadProxyPassword = (try? model.core.hostHasProxyPassword(id: h.id)) ?? false
    }

    private func save() {
        let addr = address.trimmingCharacters(in: .whitespaces)
        var host = original ?? SshHost(label: "", address: "")
        let label = name.trimmingCharacters(in: .whitespaces)
        host.label = label.isEmpty ? addr : label
        host.address = addr
        host.groupId = groupId
        host.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        host.notes = notes
        host.favorite = favorite
        host.syncMode = deviceOnly ? .deviceOnly : .synced
        host.settings.port = UInt32(port)
        host.settings.username = username.isEmpty ? nil : username
        host.settings.keyId = method == .key ? keyId : nil
        host.settings.identityId = method == .identity ? identityId : nil
        host.settings.jumpHostIds = jumps.isEmpty ? nil : jumps
        if let kind = proxyKind {
            guard !proxyHost.trimmingCharacters(in: .whitespaces).isEmpty, let p = UInt32(proxyPort), p > 0 else {
                error = String(localized: "host_editor.proxy_incomplete")
                return
            }
            host.settings.proxy = HostProxy(kind: kind, host: proxyHost.trimmingCharacters(in: .whitespaces), port: p,
                                            username: proxyUsername.isEmpty ? nil : proxyUsername)
        } else {
            host.settings.proxy = nil
        }

        let secret: SecretChange
        if method != .password {
            secret = original?.hasPassword == true ? .clear : .keep
        } else if !password.isEmpty {
            secret = .set(value: password)
        } else if clearPassword {
            secret = .clear
        } else {
            secret = .keep
        }
        let proxySecret: SecretChange
        if proxyKind == nil {
            proxySecret = hadProxyPassword ? .clear : .keep
        } else if !proxyPassword.isEmpty {
            proxySecret = .set(value: proxyPassword)
        } else if clearProxyPassword {
            proxySecret = .clear
        } else {
            proxySecret = .keep
        }
        do {
            let saved = try model.core.saveHost(host: host, password: secret)
            try model.core.setHostProxyPassword(id: saved.id, password: proxySecret)
            account.sync()
            dismiss()
        } catch {
            self.error = errorMessage(error)
        }
    }
}
