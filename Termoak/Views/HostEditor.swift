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

/// Text fields of the editor, in the order Return walks them.
private enum EditorField: Hashable {
    case address, label, tags, username, port, password, keepalive, term, proxyHost, proxyPort
}

/// What is wrong in the form, shown under each field. Missing values only
/// after trying to save; wrong ones as soon as they are typed.
private struct FormProblems {
    var address: String?
    var port: String?
    var keepalive: String?
    var env: String?
    var proxyHost: String?
    var proxyPort: String?

    var isEmpty: Bool { firstField == nil && env == nil }

    /// Some problem is inside the "Advanced" section.
    var inAdvanced: Bool { keepalive != nil || env != nil || proxyHost != nil || proxyPort != nil }

    /// The first field with a problem, to put the cursor there.
    var firstField: EditorField? {
        if address != nil { return .address }
        if port != nil { return .port }
        if proxyHost != nil { return .proxyHost }
        if proxyPort != nil { return .proxyPort }
        if keepalive != nil { return .keepalive }
        return nil
    }
}

/// A TCP port (1–65535).
private func parsePort(_ text: String) -> UInt32? {
    guard let p = UInt32(text.trimmingCharacters(in: .whitespaces)), p > 0, p <= 65535 else { return nil }
    return p
}

/// `KEY=value` lines (blank lines are ignored); the first wrong line on error.
private func parseEnv(_ text: String) -> Result<[String: String], EnvLineError> {
    var env: [String: String] = [:]
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        guard let eq = line.firstIndex(of: "=") else { return .failure(EnvLineError(line: line)) }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else { return .failure(EnvLineError(line: line)) }
        env[key] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
    }
    return .success(env)
}

private struct EnvLineError: Error {
    let line: String
}

/// Comma-separated tags, without empty ones or repetitions.
func parseTags(_ text: String) -> [String] {
    var tags: [String] = []
    for tag in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !tag.isEmpty {
        if !tags.contains(tag) { tags.append(tag) }
    }
    return tags
}

/// `#rrggbb` of a palette color (as the desktop saves it).
func hexString(_ value: UInt32) -> String {
    String(format: "#%06x", value)
}

/// Same color, written in any case and with or without `#`.
func sameColor(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("#") { t.removeFirst() }
        return t
    }
    return clean(a) == clean(b)
}

/// Host editor like the desktop's (and Termius'): the address and its
/// protocol (SSH or Telnet) first, then the label, group, tags, color and
/// logo; the user, port and credential with a "Connect" button; and a
/// collapsible "Advanced" section with jumps, proxy, agent forwarding,
/// keep-alive, startup snippet, environment and terminal theme. Telnet hosts
/// hide what only SSH has (keys, jumps, agent forwarding, keep-alive,
/// startup snippet, environment) and warn that Telnet is not encrypted;
/// switching the protocol moves a default or empty port between 22 and 23.
/// Errors show under their fields. Return goes to the next field and saves
/// on the last one; ⌘↩ saves and connects.
struct HostEditor: View {
    let original: SshHost?
    var initialGroup: String? = nil
    /// Where a new host goes (This device or a vault).
    var initialPlace: ItemPlace? = nil
    /// "Connect": called with the saved host after the editor closes.
    var onConnect: ((SshHost) -> Void)? = nil
    /// In a side panel (iPad, desktop layout) instead of a sheet: closes it.
    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    /// `ssh`, `telnet` or a later version's protocol (kept as it is).
    @State private var hostProtocol = HostProtocol.ssh
    /// Protocol the port field was last adjusted for.
    @State private var portProtocol = HostProtocol.ssh
    @State private var port = ""
    @State private var username = ""
    @State private var method: AuthMethod = .password
    @State private var password = ""
    /// The password typed shows as text (the eye button).
    @State private var revealPassword = false
    @State private var clearPassword = false
    @State private var keyId: String?
    @State private var identityId: String?
    @State private var groupId: String?
    @State private var tags = ""
    @State private var color: String?
    /// Logo id (`nil`: automatic).
    @State private var icon: String?
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
    @State private var agentForwarding = false
    @State private var keepalive = ""
    @State private var term = ""
    @State private var startupSnippetId: String?
    @State private var envText = ""
    @State private var hostTheme: String?
    @State private var recordSessions = false
    @State private var keys: [SshKey] = []
    @State private var identities: [SshIdentity] = []
    @State private var groups: [HostGroup] = []
    @State private var snippets: [Snippet] = []
    @State private var others: [SshHost] = []
    @State private var showAdvanced = false
    /// This device or the vault of the host.
    @State private var place: ItemPlace = .device
    @State private var transferring: TransferRequest?
    /// Tried to save: missing values are errors now.
    @State private var attempted = false
    @State private var deleting = false
    @State private var error: String?
    @FocusState private var focus: EditorField?

    var body: some View {
        NavigationView {
            Form {
                header
                general
                organize
                ssh
                if onConnect != nil { connectButton }
                options
                advancedToggle
                if showAdvanced { advanced }
                if original != nil {
                    Section {
                        Button("host_editor.delete", role: .destructive) { deleting = true }
                    }
                }
            }
            .navigationTitle(original == nil ? String(localized: "common.new_host") : String(localized: "host_editor.edit_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { close() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") { save(connect: false) }
                        .keyboardShortcut("s", modifiers: .command)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("common.done") { focus = nil }
                }
            }
            .alert("host_editor.save_failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("common.ok", role: .cancel) {}
            } message: { Text(error ?? "") }
            .confirmationDialog(Text("hosts.delete.title \(original?.label ?? "")"), isPresented: $deleting,
                                titleVisibility: .visible) {
                Button("common.delete", role: .destructive, action: delete)
            } message: { Text("hosts.delete.message") }
            .sheet(item: $transferring) { r in
                TransferView(request: r) {
                    // Moved: this copy of the host is no longer where it was.
                    close()
                }
                .environmentObject(model).environmentObject(account)
            }
        }
        // Also in a side panel of a regular-width window (no columns there).
        .navigationViewStyle(.stack)
        .onAppear(perform: load)
        .onChange(of: place) { _ in loadReferences() }
        .onChange(of: hostProtocol, perform: protocolChanged)
    }

    private var telnet: Bool { HostProtocol.isTelnet(hostProtocol) }

    /// The port follows (22 ↔ 23 when it is the default or empty) and a key
    /// gives way to the password (Telnet has no keys).
    private func protocolChanged(to: String) {
        guard to != portProtocol else { return }
        port = HostProtocol.portAfterSwitch(from: portProtocol, to: to, text: port)
        portProtocol = to
        if HostProtocol.isTelnet(to) && method == .key { method = .password }
    }

    /// Closes the sheet, or the side panel.
    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    // MARK: Sections

    /// How the host will look in the list.
    private var header: some View {
        Section {
            HStack(spacing: 14) {
                HostIcon(label: displayName, os: original?.os, color: color, icon: icon, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name.isEmpty ? (address.isEmpty ? String(localized: "common.new_host") : address) : name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    let kind = telnet ? "telnet" : "ssh"
                    Text(verbatim: username.isEmpty ? kind : "\(kind), \(username)").foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        let a = address.trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? "?" : a
    }

    private var general: some View {
        let p = problems
        return Section {
            HStack(spacing: 8) {
                TextField("host_editor.address", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.weight(.medium))
                    .focused($focus, equals: .address)
                    .submitLabel(.next)
                    .onSubmit {
                        splitAddress()
                        focus = .label
                    }
                protocolPicker
            }
            if let e = p.address { errorRow(e) }
            if telnet {
                Label {
                    Text("host_editor.telnet_warning")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.footnote)
                .foregroundColor(Brand.amber)
            }
            TextField("host_editor.label", text: $name)
                .focused($focus, equals: .label)
                .submitLabel(.next)
                .onSubmit { focus = .username }
        } header: {
            Text("host_editor.general")
        } footer: {
            Text("host_editor.address.footer")
        }
    }

    /// SSH or Telnet, next to the address (a later version's protocol is
    /// kept and shown as it is).
    private var protocolPicker: some View {
        Picker("host_editor.protocol", selection: $hostProtocol) {
            Text(verbatim: "SSH").tag(HostProtocol.ssh)
            Text(verbatim: "Telnet").tag(HostProtocol.telnet)
            if hostProtocol != HostProtocol.ssh && hostProtocol != HostProtocol.telnet {
                Text(verbatim: hostProtocol.uppercased()).tag(hostProtocol)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(Text("host_editor.protocol"))
    }

    private var organize: some View {
        Section("host_editor.organize") {
            vaultRow
            Picker("host_editor.group", selection: $groupId) {
                Text("host_editor.no_group").tag(String?.none)
                ForEach(groups, id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }
            TextField("host_editor.tags", text: $tags)
                .textInputAutocapitalization(.never)
                .focused($focus, equals: .tags)
                .submitLabel(.next)
                .onSubmit { focus = .username }
            colorRow
            logoRow
        }
    }

    /// The logo: Automatic (the detected system's, else the initial), a
    /// system's or a generic one, chosen in its own screen.
    private var logoRow: some View {
        NavigationLink {
            LogoPicker(icon: $icon, label: displayName, os: original?.os, color: color)
        } label: {
            HStack(spacing: 10) {
                Text("host_editor.logo")
                Spacer()
                Text(verbatim: logoSummary).foregroundColor(.secondary).lineLimit(1)
                HostIcon(label: displayName, os: original?.os, color: color, icon: icon, size: 26)
            }
        }
    }

    private var logoSummary: String {
        if let icon {
            return HostLogo.byId(icon)?.title ?? icon
        }
        if let detected = original?.os.flatMap(HostLogo.forOs) {
            return String(localized: "host_editor.logo_automatic_with \(detected.title)")
        }
        return String(localized: "host_editor.logo_automatic")
    }

    /// The vault: chosen for a new host (when there is more than one place);
    /// for an existing one it is shown with "Move to…".
    @ViewBuilder private var vaultRow: some View {
        if let original {
            if !account.list.isEmpty {
                HStack {
                    Text("host_editor.vault")
                    Spacer()
                    Text(verbatim: account.placeTitle(place)).foregroundColor(.secondary).lineLimit(1)
                }
                Button {
                    transferring = TransferRequest(hosts: [original], from: place, mode: .move)
                } label: {
                    Label("transfer.move_to", systemImage: "arrow.right.square")
                }
            }
        } else if account.places.count > 1 {
            PlacePicker(place: $place)
        }
    }

    /// Automatic (the system's or a color from the name) or one of the palette.
    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("host_editor.color")
            // Wraps on narrow screens.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 30, maximum: 40), spacing: 8)], alignment: .leading, spacing: 8) {
                Button { color = nil } label: {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .frame(width: 24, height: 24)
                        .overlay(Image(systemName: "wand.and.stars").font(.system(size: 10)).foregroundColor(.secondary))
                        .padding(3)
                        .overlay(Circle().stroke(color == nil ? Color.accentColor : .clear, lineWidth: 2))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("host_editor.color.auto")
                .accessibilityAddTraits(color == nil ? .isSelected : [])
                ForEach(Array(hostPalette.enumerated()), id: \.offset) { i, value in
                    let hex = hexString(value)
                    let selected = sameColor(color, hex)
                    Button { color = hex } label: {
                        Circle()
                            .fill(Color(hex: value))
                            .frame(width: 24, height: 24)
                            .padding(3)
                            .overlay(Circle().stroke(selected ? Color.primary : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("host_editor.color.option \(i + 1)"))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var ssh: some View {
        let p = problems
        return Section {
            TextField("host_editor.username", text: $username, prompt: fromGroup(inherited.username))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textContentType(.username)
                .focused($focus, equals: .username)
                .submitLabel(.next)
                .onSubmit { focus = .port }
            TextField("host_editor.port", text: $port, prompt: fromGroup(inherited.port.map(String.init)))
                .keyboardType(.numberPad)
                .focused($focus, equals: .port)
                .onSubmit {
                    if method == .password { focus = .password } else { save(connect: false) }
                }
            if let e = p.port { errorRow(e) }
            Picker("host_editor.method", selection: $method) {
                // Telnet has no keys: only the password or an identity's
                // username and password.
                ForEach(AuthMethod.allCases.filter { !telnet || $0 != .key }) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            switch method {
            case .password:
                passwordRow
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
            if let hint = inheritedCredential {
                Text(hint).font(.footnote).foregroundColor(.secondary)
            }
        } header: {
            Text(verbatim: telnet ? "Telnet" : "SSH")
        } footer: {
            if telnet {
                Text("host_editor.telnet_login_hint")
            } else {
                Text("host_editor.credentials.footer")
            }
        }
    }

    /// The password, hidden or shown with the eye button.
    private var passwordRow: some View {
        HStack {
            Group {
                if revealPassword {
                    TextField(passwordPrompt, text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField(passwordPrompt, text: $password)
                }
            }
            .textContentType(.password)
            .focused($focus, equals: .password)
            .submitLabel(.done)
            .onSubmit { save(connect: false) }
            Button { revealPassword.toggle() } label: {
                Image(systemName: revealPassword ? "eye.slash" : "eye").foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(revealPassword ? Text("host_editor.hide_password") : Text("host_editor.show_password"))
        }
    }

    private var passwordPrompt: String {
        original?.hasPassword == true && !clearPassword
            ? String(localized: "common.password_saved") : String(localized: "common.password_optional")
    }

    private var connectButton: some View {
        Section {
            Button { save(connect: true) } label: {
                Label("host_editor.save_connect", systemImage: "terminal")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private var options: some View {
        Section("host_editor.options") {
            Toggle("host_editor.favorite", isOn: $favorite)
            // With accounts, This device is one of the places above.
            if account.list.isEmpty {
                Toggle("common.device_only", isOn: $deviceOnly)
            }
            notesEditor
        }
    }

    /// Several lines of notes (a placeholder while empty).
    private var notesEditor: some View {
        ZStack(alignment: .topLeading) {
            if notes.isEmpty {
                Text("host_editor.notes")
                    .foregroundColor(Color(.placeholderText))
                    .padding(.top, 8)
                    .padding(.leading, 4)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $notes)
                .frame(minHeight: 72, maxHeight: 180)
                .accessibilityLabel(Text("host_editor.notes"))
        }
    }

    private var advancedToggle: some View {
        Section {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showAdvanced.toggle() }
            } label: {
                HStack {
                    Label("host_editor.advanced", systemImage: "slider.horizontal.3")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .foregroundColor(.primary)
            .accessibilityValue(showAdvanced ? Text("common.on") : Text("common.off"))
        } footer: {
            if !showAdvanced { Text("host_editor.advanced.footer") }
        }
    }

    /// Hosts to jump through first, in order.
    private var jumpSection: some View {
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
            // A Telnet host is not an SSH server to jump through.
            let candidates = others.filter { !jumps.contains($0.id) && !$0.isTelnet }
            if !candidates.isEmpty {
                Menu {
                    ForEach(candidates, id: \.id) { h in Button(h.label) { jumps.append(h.id) } }
                } label: { Label("host_editor.add_jump", systemImage: "plus") }
            }
        } header: { Text("host_editor.jump_chain") } footer: {
            Text(jumps.isEmpty ? String(localized: "host_editor.jump_chain.footer_empty")
                 : String(localized: "host_editor.jump_chain.footer"))
        }
    }

    @ViewBuilder private var advanced: some View {
        let p = problems
        // A Telnet host cannot go through jump hosts.
        if !telnet { jumpSection }

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
                    .focused($focus, equals: .proxyHost)
                    .submitLabel(.next)
                    .onSubmit { focus = .proxyPort }
                if let e = p.proxyHost { errorRow(e) }
                TextField(proxyKind == .http ? String(localized: "host_editor.proxy_port_http")
                          : String(localized: "host_editor.proxy_port_socks"), text: $proxyPort)
                    .keyboardType(.numberPad)
                    .focused($focus, equals: .proxyPort)
                if let e = p.proxyPort { errorRow(e) }
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

        Section {
            // SSH only: agent forwarding and keep-alive.
            if !telnet {
                Toggle("host_editor.agent_forwarding", isOn: $agentForwarding)
                HStack {
                    Text("host_editor.keepalive")
                    Spacer()
                    TextField(text: $keepalive, prompt: Text(verbatim: inherited.keepaliveSecs.map(String.init) ?? "30")) {
                        Text("host_editor.keepalive")
                    }
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90)
                        .focused($focus, equals: .keepalive)
                        .onSubmit { save(connect: false) }
                }
                if let e = p.keepalive { errorRow(e) }
            }
            HStack {
                Text("host_editor.term")
                Spacer()
                TextField(text: $term, prompt: Text(verbatim: inherited.term ?? "xterm-256color")) { Text("host_editor.term") }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .focused($focus, equals: .term)
                    .submitLabel(.done)
                    .onSubmit { save(connect: false) }
            }
            Toggle("host_editor.record_sessions", isOn: $recordSessions)
        } header: {
            Text("host_editor.connection")
        } footer: {
            Text("host_editor.connection.footer")
        }

        // SSH only: the startup snippet and the environment.
        if !telnet { sshSessionSections(p) }

        Section {
            Picker("host_editor.theme", selection: $hostTheme) {
                Text("host_editor.theme.follow").tag(String?.none)
                Text("host_editor.theme.dark").tag(Optional("dark"))
                Text("host_editor.theme.light").tag(Optional("light"))
                ForEach(TerminalTheme.all) { t in Text(t.name).tag(Optional(t.id)) }
                // A theme of another version of the app is kept.
                if let v = hostTheme, v != "dark", v != "light", !TerminalTheme.all.contains(where: { $0.id == v }) {
                    Text(verbatim: v).tag(Optional(v))
                }
            }
        } footer: {
            Text("host_editor.theme.footer")
        }
    }

    /// The startup snippet and the environment (SSH only).
    @ViewBuilder private func sshSessionSections(_ p: FormProblems) -> some View {
        Section {
            Picker("host_editor.startup_snippet", selection: $startupSnippetId) {
                Text("common.none").tag(String?.none)
                ForEach(snippets, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                // A snippet that is no longer there stays chosen until changed.
                if let id = startupSnippetId, !snippets.contains(where: { $0.id == id }) {
                    Text("host_editor.deleted_snippet").tag(Optional(id))
                }
            }
        } footer: {
            Text("host_editor.startup_snippet.footer")
        }

        Section {
            TextEditor(text: $envText)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(minHeight: 80)
            if let e = p.env { errorRow(e) }
        } header: {
            Text("host_editor.env")
        } footer: {
            Text("host_editor.env.footer")
        }
    }

    private func errorRow(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
        }
        .font(.footnote)
        .foregroundColor(Brand.red)
    }

    // MARK: Checking

    private var problems: FormProblems {
        var p = FormProblems()
        let addr = address.trimmingCharacters(in: .whitespaces)
        if addr.isEmpty {
            if attempted { p.address = String(localized: "host_editor.error.address") }
        } else if addr.contains(where: { $0.isWhitespace }) {
            p.address = String(localized: "host_editor.error.address_spaces")
        }
        if !port.trimmingCharacters(in: .whitespaces).isEmpty && parsePort(port) == nil {
            p.port = String(localized: "host_editor.error.port")
        }
        // Hidden for Telnet hosts: not checked then (and kept as they were).
        let k = keepalive.trimmingCharacters(in: .whitespaces)
        if !telnet && !k.isEmpty && UInt32(k) == nil {
            p.keepalive = String(localized: "host_editor.error.keepalive")
        }
        if !telnet, case .failure(let e) = parseEnv(envText) {
            p.env = String(localized: "host_editor.error.env \(e.line)")
        }
        if proxyKind != nil {
            if proxyHost.trimmingCharacters(in: .whitespaces).isEmpty {
                if attempted { p.proxyHost = String(localized: "host_editor.error.proxy_address") }
            }
            let pp = proxyPort.trimmingCharacters(in: .whitespaces)
            if (attempted || !pp.isEmpty) && parsePort(pp) == nil {
                p.proxyPort = String(localized: "host_editor.error.proxy_port")
            }
        }
        return p
    }

    /// `user@host` and `host:port` typed in the address fill the user and
    /// the port (if they are empty).
    private func splitAddress() {
        var addr = address.trimmingCharacters(in: .whitespaces)
        // `telnet://` or `ssh://` in front chooses the protocol.
        for (scheme, proto) in [("telnet://", HostProtocol.telnet), ("ssh://", HostProtocol.ssh)]
            where addr.lowercased().hasPrefix(scheme) {
            addr = String(addr.dropFirst(scheme.count))
            while addr.hasSuffix("/") { addr.removeLast() }
            if hostProtocol != proto { hostProtocol = proto }
        }
        if let at = addr.lastIndex(of: "@") {
            let user = String(addr[..<at])
            let rest = String(addr[addr.index(after: at)...])
            if !user.isEmpty, !rest.isEmpty, username.trimmingCharacters(in: .whitespaces).isEmpty {
                username = user
                addr = rest
            }
        }
        // Only one colon: an IPv6 address has several.
        let parts = addr.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let p = parsePort(String(parts[1])), !parts[0].isEmpty,
           port.trimmingCharacters(in: .whitespaces).isEmpty {
            port = String(p)
            addr = String(parts[0])
        }
        if addr != address.trimmingCharacters(in: .whitespaces) { address = addr }
    }

    // MARK: Values from the group

    /// What the host gets from its group and the ones above it (shown as
    /// hints; the host's own values win).
    private var inherited: HostSettings {
        HostSettings.inherited(groupId: groupId, groups: groups)
    }

    /// "From the group: deploy" in an empty field.
    private func fromGroup(_ value: String?) -> Text? {
        value.map { Text("host_editor.from_group \($0)") }
    }

    /// The group's identity or key, when the host doesn't choose its own.
    private var inheritedCredential: String? {
        guard keyId == nil, identityId == nil, password.isEmpty, original?.hasPassword != true else { return nil }
        let s = inherited
        if let i = s.identityId, let identity = identities.first(where: { $0.id == i }) {
            return String(localized: "host_editor.from_group_identity \(identity.label)")
        }
        if let k = s.keyId, let key = keys.first(where: { $0.id == k }) {
            return String(localized: "host_editor.from_group_key \(key.label)")
        }
        return nil
    }

    // MARK: Loading and saving

    /// Keys, identities, groups, snippets and jump hosts the host can use:
    /// those of its own vault and those of This device (references never
    /// leave a vault).
    private func loadReferences() {
        let p = place
        let filter = ItemFilter(accountIds: p.accountId.map { [$0] } ?? [], vaultIds: nil, includeDevice: true)
        func usable(_ accountId: String?, _ vaultId: String?) -> Bool {
            accountId == nil || (accountId == p.accountId && vaultId == p.vaultId)
        }
        keys = ((try? model.core.listKeys(filter: filter)) ?? []).filter { usable($0.accountId, $0.vaultId) }
        identities = ((try? model.core.listIdentities(filter: filter)) ?? []).filter { usable($0.accountId, $0.vaultId) }
        // A group is in the same place as its hosts.
        groups = ((try? model.core.listGroups(filter: filter)) ?? [])
            .filter { $0.accountId == p.accountId && $0.vaultId == p.vaultId }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        snippets = ((try? model.core.listSnippets(filter: filter)) ?? [])
            .filter { usable($0.accountId, $0.vaultId) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        others = ((try? model.core.listHosts(filter: filter)) ?? [])
            .filter { usable($0.accountId, $0.vaultId) && !($0.id == original?.id && $0.accountId == original?.accountId) }
        if let g = groupId, !groups.contains(where: { $0.id == g }) { groupId = nil }
    }

    private func load() {
        if let h = original {
            place = account.place(accountId: h.accountId, vaultId: h.vaultId)
        } else {
            place = initialPlace ?? account.defaultPlace
        }
        groupId = initialGroup
        loadReferences()
        guard let h = original else {
            // A new host: straight to the address.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focus = .address }
            return
        }
        name = h.label
        address = h.address
        hostProtocol = h.protocol
        portProtocol = h.protocol
        icon = h.icon
        port = h.settings.port.map(String.init) ?? ""
        username = h.settings.username ?? ""
        keyId = h.settings.keyId
        identityId = h.settings.identityId
        method = identityId != nil ? .identity : (keyId != nil ? .key : .password)
        groupId = h.groupId
        tags = h.tags.joined(separator: ", ")
        color = h.color
        notes = h.notes
        favorite = h.favorite
        deviceOnly = h.syncMode == .deviceOnly
        let s = h.settings
        jumps = s.jumpHostIds ?? []
        if let p = s.proxy {
            proxyKind = p.kind
            proxyHost = p.host
            proxyPort = String(p.port)
            proxyUsername = p.username ?? ""
        }
        agentForwarding = s.agentForwarding ?? false
        keepalive = s.keepaliveSecs.map(String.init) ?? ""
        term = s.term ?? ""
        startupSnippetId = s.startupSnippetId
        envText = s.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        hostTheme = s.theme
        recordSessions = s.recordSessions ?? false
        hadProxyPassword = (try? model.core.hostHasProxyPassword(id: h.id, accountId: h.accountId)) ?? false
        // It starts open if the host uses anything in it.
        showAdvanced = !jumps.isEmpty || s.proxy != nil || agentForwarding || s.keepaliveSecs != nil
            || s.startupSnippetId != nil || !s.env.isEmpty || recordSessions
            || !(s.term ?? "").trimmingCharacters(in: .whitespaces).isEmpty || s.theme != nil
    }

    private func save(connect: Bool) {
        attempted = true
        splitAddress()
        let p = problems
        let parsedEnv = try? parseEnv(envText).get()
        guard p.isEmpty, let env = parsedEnv ?? (telnet ? original?.settings.env ?? [:] : nil) else {
            if p.inAdvanced { showAdvanced = true }
            focus = p.firstField
            return
        }
        let addr = address.trimmingCharacters(in: .whitespaces)
        var host = original ?? SshHost(label: "", address: "")
        let label = name.trimmingCharacters(in: .whitespaces)
        host.label = label.isEmpty ? addr : label
        host.address = addr
        host.groupId = groupId
        host.tags = parseTags(tags)
        host.color = color
        host.notes = notes
        host.favorite = favorite
        host.protocol = hostProtocol
        host.icon = icon
        if account.list.isEmpty {
            host.syncMode = deviceOnly ? .deviceOnly : .synced
        } else if original == nil {
            // A new host goes where it was chosen; This-device items never
            // leave the device.
            host.accountId = place.accountId
            host.vaultId = place.vaultId
            host.syncMode = place.accountId == nil ? .deviceOnly : .synced
        }
        var s = host.settings
        s.port = parsePort(port)
        let user = username.trimmingCharacters(in: .whitespaces)
        s.username = user.isEmpty ? nil : user
        s.keyId = method == .key ? keyId : nil
        s.identityId = method == .identity ? identityId : nil
        // Telnet cannot go through jump hosts or forward the agent.
        s.jumpHostIds = jumps.isEmpty || telnet ? nil : jumps
        s.agentForwarding = agentForwarding && !telnet ? true : nil
        let k = keepalive.trimmingCharacters(in: .whitespaces)
        s.keepaliveSecs = k.isEmpty ? nil : UInt32(k)
        let t = term.trimmingCharacters(in: .whitespaces)
        s.term = t.isEmpty ? nil : t
        s.startupSnippetId = startupSnippetId
        s.env = env
        s.theme = hostTheme
        s.recordSessions = recordSessions ? true : nil
        if let kind = proxyKind, let pp = parsePort(proxyPort) {
            let ph = proxyHost.trimmingCharacters(in: .whitespaces)
            let pu = proxyUsername.trimmingCharacters(in: .whitespaces)
            s.proxy = HostProxy(kind: kind, host: ph, port: pp, username: pu.isEmpty ? nil : pu)
        } else {
            s.proxy = nil
        }
        host.settings = s

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
            try model.core.setHostProxyPassword(id: saved.id, password: proxySecret, accountId: saved.accountId)
            if original == nil { account.rememberPlace(place) }
            account.sync()
            close()
            if connect { onConnect?(saved) }
        } catch {
            self.error = userMessage(error)
        }
    }

    private func delete() {
        guard let h = original else { return }
        do {
            try model.core.deleteHost(id: h.id, accountId: h.accountId)
            account.sync()
            close()
        } catch {
            self.error = userMessage(error)
        }
    }
}

/// The logo of a host, like the desktop's picker: Automatic (the detected
/// system's logo, else the initial), the systems' logos and generic icons.
private struct LogoPicker: View {
    @Binding var icon: String?
    /// For the Automatic preview.
    let label: String
    let os: String?
    let color: String?

    var body: some View {
        List {
            Section {
                Button { icon = nil } label: {
                    HStack(spacing: 12) {
                        HostIcon(label: label, os: os, color: color, icon: nil, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("host_editor.logo_automatic").foregroundColor(.primary)
                            Text("host_editor.logo_automatic_hint").font(.caption).foregroundColor(.secondary)
                        }
                        Spacer(minLength: 0)
                        if icon == nil { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(icon == nil ? .isSelected : [])
                // A logo of a later version of the app is kept until changed.
                if let icon, HostLogo.byId(icon) == nil {
                    HStack {
                        Text(verbatim: icon)
                        Spacer()
                        Image(systemName: "checkmark").foregroundColor(.accentColor)
                    }
                }
            }
            Section("host_editor.logo.systems") { grid(HostLogo.systems) }
            Section("host_editor.logo.generic") { grid(HostLogo.generics) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("host_editor.logo")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func grid(_ logos: [HostLogo]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 110), spacing: 8)], spacing: 12) {
            ForEach(logos) { logo in
                let selected = icon.flatMap(HostLogo.byId)?.id == logo.id
                Button { icon = logo.id } label: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(logo.swiftUIColor)
                            .frame(width: 44, height: 44)
                            .overlay(LogoGlyph(logo: logo, size: 24).foregroundColor(.white))
                            .padding(3)
                            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                        Text(verbatim: logo.title)
                            .font(.caption2)
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(verbatim: logo.title))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }
}
