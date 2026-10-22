import TermoakKit
import SwiftUI
import UniformTypeIdentifiers

// Settings → Accounts → an account → Private networks (0.7, NETWORKS.md
// §8.1), like the web's Account → Networks and the desktop's and Android's
// Networks screens: the WireGuard networks of every vault of an account
// whose server has `features.networks` (never This device), their state in
// the server, the plan's usage, adding or editing one from a .conf (pasted
// or opened) or with a key generated on the server, Test (up + waiting for
// the handshake), bring down, its devices → add a host, delete. Changes go
// through the REST API and reach the local stores by sync.

/// The state of a network as a coloured chip.
struct NetStateChip: View {
    let state: NetState
    var short = true
    var kind: String? = nil

    var body: some View {
        Chip(state.label(short: short, kind: kind), state.color)
            .accessibilityLabel(Text(verbatim: state.label(kind: kind)))
    }
}

extension NetState {
    var color: Color {
        switch self {
        case .up: return Brand.green
        case .waiting, .needsAuth, .needsLogin, .needsApproval, .starting: return Brand.amber
        case .error: return Brand.red
        case .down, .unknown: return .secondary
        }
    }
}

/// "↓ 1.2 MB · ↑ 30 kB", or `nil` without traffic.
func networkTraffic(_ s: NetStatus?) -> String? {
    let rx = s?.rxBytes ?? 0, tx = s?.txBytes ?? 0
    guard rx > 0 || tx > 0 else { return nil }
    return String(localized: "networks.traffic \(Networks.bytes(rx)) \(Networks.bytes(tx))")
}

/// The networks of an account (the one shown, among those whose server has them).
struct NetworksView: View {
    let accountId: String

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @ObservedObject private var book = NetworkBook.shared
    @Environment(\.scenePhase) private var phase

    @State private var networks: [NetworkItem]?
    @State private var loadError: String?
    @State private var usage: (used: Int, max: Int?)?
    @State private var featuresRead = false
    @State private var adding = false
    @State private var notice: String?
    /// A network whose key the server just generated: its public key to add on the other side.
    @State private var keyShown: NetworkItem?
    /// A new tailnet (or a new key) to test once the list read again shows it.
    @State private var autoTest: String?

    private var api: NetworksAPI? { book.api(accountId, core: model.core) }
    private var vaults: [VaultInfo] { account.vaults(of: accountId) }
    private var editorVaults: [VaultInfo] { vaults.filter(\.canWrite) }

    var body: some View {
        Group {
            if !book.isSupported(accountId) {
                if featuresRead {
                    EmptyState(icon: "point.3.connected.trianglepath.dotted", title: String(localized: "networks.unsupported"),
                               text: String(localized: "networks.unsupported_hint"))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                list
            }
        }
        .navigationTitle("networks.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if book.isSupported(accountId) && !editorVaults.isEmpty {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(Text("networks.add"))
                        .accessibilityIdentifier("networks-add")
                }
            }
        }
        .sheet(isPresented: $adding) {
            NetworkFormView(accountId: accountId, editing: nil, vaults: editorVaults, kinds: book.kinds(of: accountId)) { saved, generated, test in
                notice = String(localized: "networks.created \(saved.name)")
                // After the form's sheet has gone.
                if generated { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { keyShown = saved } }
                Task {
                    await afterChange(saved, generated: generated)
                    // Tested once the list (read again) shows it.
                    if test { autoTest = saved.id }
                }
            }
            .environmentObject(model)
        }
        .sheet(item: $keyShown) { n in
            ServerKeyView(network: n, generated: true, canTest: true) { test(n) }
        }
        // A new tailnet or a new key: Test it once the list has it.
        .task(id: autoTest.map { id in id + (networks?.contains { $0.id == id } == true ? "+" : "") }) {
            guard let id = autoTest, let n = networks?.first(where: { $0.id == id }) else { return }
            autoTest = nil
            test(n)
        }
        // The features can be stale: read /info again on entering (§8.1).
        .task {
            await book.refreshFeatures(accountId, core: model.core)
            featuresRead = true
            await load()
        }
        // The states while the screen is open (never brings a network up).
        .task(id: phase == .active ? (networks?.map(\.id).joined(separator: ",") ?? "") : "") {
            guard phase == .active, let api, let ids = networks?.map(\.id), !ids.isEmpty else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { return }
                for id in ids { await book.refreshStatus(api, id, force: true) }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                Text("networks.subtitle").font(.subheadline).foregroundColor(.secondary)
                if let usage { usageRow(usage) }
            }
            if let loadError {
                Section { Text(loadError).foregroundColor(Brand.red) }
            }
            if let notice {
                Section { Text(notice).font(.footnote).foregroundColor(Brand.green) }
            }
            if let networks {
                if networks.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("networks.empty").font(.headline)
                            Text(book.kindSupported(accountId, Networks.tailscale) ? LocalizedStringKey("networks.ts.empty_hint")
                                 : LocalizedStringKey("networks.empty_hint"))
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                        if !editorVaults.isEmpty {
                            Button { adding = true } label: { Label("networks.add", systemImage: "plus") }
                        }
                    }
                } else {
                    Section {
                        ForEach(networks) { n in
                            NavigationLink {
                                NetworkDetailView(accountId: accountId, network: n) { change in
                                    Task { await handle(change) }
                                }
                                .environmentObject(model)
                                .environmentObject(account)
                            } label: {
                                NetworkRow(network: n, vault: vaultName(n.vaultId), available: book.kindSupported(accountId, n.kind))
                            }
                            .accessibilityIdentifier("network-\(n.name)")
                        }
                    }
                }
            } else {
                Section { ProgressView() }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    private func usageRow(_ u: (used: Int, max: Int?)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("networks.usage_label").font(.subheadline.weight(.semibold))
                Spacer()
                if let max = u.max {
                    Text("networks.usage \(u.used) \(max)").foregroundColor(.secondary)
                } else {
                    Text("networks.usage_unlimited \(u.used)").foregroundColor(.secondary)
                }
            }
            if let max = u.max, max > 0 {
                ProgressView(value: Double(min(u.used, max)), total: Double(max))
                    .tint(u.used >= max ? Brand.amber : .accentColor)
            }
            Text(u.max.map { u.used >= $0 } == true ? LocalizedStringKey("networks.usage_full") : LocalizedStringKey("networks.usage_note"))
                .font(.caption).foregroundColor(.secondary)
        }
        .accessibilityIdentifier("networks-usage")
    }

    /// Test from the key sheet (up and wait for the handshake), or of a new tailnet.
    private func test(_ n: NetworkItem) {
        guard let api else { return }
        Task { @MainActor in
            do {
                let st = try await api.test(n.id, kind: n.kind) { book.setStatus(n.id, $0) }
                if n.isTailscale {
                    let (text, ok) = tailnetTestResult(n, st)
                    if ok { notice = text } else { loadError = text }
                    return
                }
                switch Networks.state(st, kind: n.kind) {
                case .up: notice = String(localized: "networks.test.ok \(n.name)")
                case .waiting: notice = String(localized: "networks.test.no_handshake \(n.name)")
                case let other: notice = String(localized: "networks.test.state \(n.name) \(other.label())")
                }
            } catch {
                loadError = networkErrorText(error, network: n)
            }
        }
    }

    private func vaultName(_ id: String?) -> String {
        vaults.first { $0.id == id }?.displayName ?? String(localized: "networks.vault_unknown")
    }

    private func load() async {
        guard let api else { return }
        do {
            let list = try await api.list()
            networks = list
            loadError = nil
            usage = await api.usage()
            for n in list { await book.refreshStatus(api, n.id) }
        } catch {
            loadError = userMessage(error)
            if networks == nil { networks = [] }
        }
    }

    /// After a change the local stores get it by sync (the editors' pickers).
    private func afterChange(_ saved: NetworkItem?, generated: Bool) async {
        account.sync(accountId)
        if let saved, let api { await book.refreshStatus(api, saved.id, force: true) }
        await load()
    }

    private func handle(_ change: NetworkChange) async {
        switch change {
        case .saved(let n): notice = String(localized: "networks.saved \(n.name)")
        case .deleted(let n): notice = String(localized: "networks.delete.done \(n.name)")
        case .hostAdded(let label): notice = String(localized: "networks.host_added \(label)")
        case .hostsAdded(let n): notice = String(localized: "networks.ts.peers.added_all \(n)")
        case .keyGenerated: break
        }
        await afterChange(nil, generated: false)
    }
}

/// What Test found in a tailnet, and whether it went well.
func tailnetTestResult(_ n: NetworkItem, _ st: NetStatus) -> (String, Bool) {
    switch Networks.state(st, kind: n.kind) {
    case .up: return (String(localized: "networks.ts.test.ok \(n.name) \(tailnetSummaryText(st, connected: false))"), true)
    case .needsLogin: return (String(localized: "networks.ts.test.login \(n.name)"), false)
    case .needsApproval: return (String(localized: "networks.ts.test.approval \(n.name) \(st.nodeName ?? "—")"), false)
    case .starting: return (String(localized: "networks.ts.test.starting \(n.name)"), false)
    case .error:
        let m = st.message ?? ""
        return (String(localized: "networks.ts.test.error \(n.name) \(m.prefix(1).uppercased() + m.dropFirst())"), false)
    case let other: return (String(localized: "networks.test.state \(n.name) \(other.label(kind: n.kind))"), true)
    }
}

/// What a network's page changed (for the list).
enum NetworkChange {
    case saved(NetworkItem)
    case deleted(NetworkItem)
    case hostAdded(String)
    case hostsAdded(Int)
    case keyGenerated
}

/// A network of the list: name, kind and vault, its state, last handshake and traffic.
struct NetworkRow: View {
    let network: NetworkItem
    let vault: String
    /// The server joins networks of its kind (a Tailscale network on a server without it: "Not on this server").
    var available = true
    @ObservedObject private var book = NetworkBook.shared

    var body: some View {
        let state = book.state(network.id, kind: network.kind)
        let s = book.status(network.id)
        let noKey = network.isWireguard && !network.hasSecret && !network.secretHidden
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundColor(state == .up && available ? Brand.green : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: network.name).font(.headline).lineLimit(1)
                Text(verbatim: "\(Networks.kindLabel(network.kind)) · \(vault)").font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                let facts: [String] = network.isTailscale ? [
                    state == .up && available ? s.map { tailnetSummaryText($0, connected: false) } : nil,
                    String(localized: "networks.ts.control_line \(Networks.controlServerLabel(network.tailscale?.controlUrl))"),
                    network.secretHidden ? nil
                        : (network.hasSecret ? String(localized: "networks.ts.with_key") : String(localized: "networks.ts.without_key")),
                    available ? networkTraffic(s) : nil,
                ].compactMap { $0 } : [
                    s?.lastHandshakeAt.map { String(localized: "networks.handshake \(relativeTime($0))") }
                        ?? (state == .waiting ? String(localized: "networks.no_handshake") : nil),
                    networkTraffic(s),
                    noKey ? String(localized: "networks.no_key") : nil,
                ].compactMap { $0 }
                if !facts.isEmpty {
                    Text(verbatim: facts.joined(separator: " · ")).font(.caption)
                        .foregroundColor(noKey ? Brand.amber : .secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if available {
                NetStateChip(state: state, kind: network.kind)
            } else {
                Chip(String(localized: "networks.state.cannot_join"), .secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A network's page: its state and actions, the server's key, its
/// configuration, the hosts that use it and its devices.
struct NetworkDetailView: View {
    let accountId: String
    @State var network: NetworkItem
    let onChange: (NetworkChange) -> Void

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @ObservedObject private var book = NetworkBook.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var busy = false
    @State private var message: String?
    @State private var failure: String?
    @State private var editing = false
    /// Tailscale: the key choice the form starts with ("Use another key").
    @State private var editingKeyMode: TsKeyMode?
    /// Tailscale: a login (or approval) followed every 2 s while the page is open.
    @State private var watching = false
    @State private var deleting = false
    @State private var replacing = false
    @State private var keySheet: KeySheet?
    @State private var users = 0

    struct KeySheet: Identifiable {
        let network: NetworkItem
        let generated: Bool
        var id: String { network.id + (generated ? "+" : "") }
    }

    private var api: NetworksAPI? { book.api(accountId, core: model.core) }
    private var editor: Bool { account.vaults(of: accountId).first { $0.id == network.vaultId }?.canWrite == true }
    private var vaultName: String {
        account.vaults(of: accountId).first { $0.id == network.vaultId }?.displayName ?? String(localized: "networks.vault_unknown")
    }
    /// The server joins networks of its kind.
    private var available: Bool { book.kindSupported(accountId, network.kind) }

    var body: some View {
        let state = book.state(network.id, kind: network.kind)
        let s = book.status(network.id)
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: network.name).font(.title3.weight(.semibold))
                        Text("networks.in_vault \(Networks.kindLabel(network.kind)) \(vaultName)").font(.subheadline).foregroundColor(.secondary)
                    }
                    Spacer()
                    if available {
                        NetStateChip(state: state, short: false, kind: network.kind)
                    } else {
                        Chip(String(localized: "networks.state.cannot_join"), .secondary)
                    }
                }
                if !network.description.isEmpty { Text(verbatim: network.description) }
            }
            Section {
                if !available {
                    Text(network.isTailscale ? LocalizedStringKey("networks.ts.unsupported") : LocalizedStringKey("error.unsupported_kind"))
                        .font(.footnote).foregroundColor(Brand.amber)
                } else if network.isTailscale {
                    tailnetState(state, s)
                } else {
                    Text(verbatim: state.hint + (state == .error ? (s?.message.map { " (\($0))" } ?? "") : ""))
                        .font(.footnote).foregroundColor(.secondary)
                    fact("networks.detail.handshake", s?.lastHandshakeAt.map { relativeTime($0) } ?? String(localized: "networks.detail.never"))
                    if let t = networkTraffic(s) { fact("networks.detail.traffic", t) }
                    if let a = s?.nodeAddresses, !a.isEmpty { fact("networks.detail.node_addresses", a.joined(separator: ", ")) }
                    if let n = s?.streams, n > 0 { fact("networks.detail.streams", String(n)) }
                }
                if editor && available {
                    Button(action: test) {
                        HStack {
                            Label("networks.test", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            if busy { ProgressView() }
                        }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("network-test")
                    Button(action: down) { Label("networks.down", systemImage: "power") }
                        .disabled(busy || state == .down)
                }
                if let message { Text(message).font(.footnote).foregroundColor(Brand.green) }
                if let failure { Text(failure).font(.footnote).foregroundColor(Brand.red) }
            } header: {
                Text("networks.detail.state")
            } footer: {
                if editor && available { Text(network.isTailscale ? LocalizedStringKey("networks.ts.test_hint") : LocalizedStringKey("networks.test_hint")) }
            }
            if network.isWireguard { keySection; configurationSection }
            if network.isTailscale { tailnetSettingsSection }
            Section {
                Text(users > 0 ? String(localized: "networks.detail.hosts \(users)") : String(localized: "networks.detail.no_hosts"))
                    .font(.footnote).foregroundColor(.secondary)
                if editor && available {
                    NavigationLink {
                        PeersView(accountId: accountId, network: network, onAdded: { label in onChange(.hostAdded(label)) },
                                  onAddedMany: { n in onChange(.hostsAdded(n)) })
                            .environmentObject(model)
                    } label: {
                        Label(network.isTailscale ? LocalizedStringKey("networks.ts.action.devices") : LocalizedStringKey("networks.peers.show"),
                              systemImage: "desktopcomputer")
                    }
                    .accessibilityIdentifier("network-peers")
                }
            }
            if editor {
                Section {
                    if available {
                        Button { editingKeyMode = nil; editing = true } label: { Label("common.edit", systemImage: "pencil") }
                    }
                    Button(role: .destructive) { deleting = true } label: { Label("common.delete", systemImage: "trash") }
                }
            } else {
                Section { Text("networks.detail.read_only").font(.footnote).foregroundColor(.secondary) }
            }
        }
        .navigationTitle(Text(verbatim: network.name))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { users = hostsUsing() }
        .task {
            if let api { await book.refreshStatus(api, network.id) }
        }
        // A login or an approval started elsewhere: follow it while the page is open.
        .onChange(of: state) { st in
            if (st == .needsLogin || st == .needsApproval) && editor && available { watching = true }
        }
        .onAppear {
            if (state == .needsLogin || state == .needsApproval) && editor && available { watching = true }
        }
        // The login (or approval): the state every 2 s until it is no longer waiting, 5 minutes at most,
        // while the page is open (also while the browser is in front). If it goes idle (down), it stops.
        .task(id: watching) {
            guard watching, let api else { return }
            let id = network.id
            let n = network
            let last = await api.watchLogin(id) { book.setStatus(id, $0) }
            if Task.isCancelled { return }
            if let last, last.state == "up" {
                message = String(localized: "networks.ts.test.ok \(n.name) \(tailnetSummaryText(last, connected: false))")
                failure = nil
            }
            watching = false
        }
        .sheet(isPresented: $editing) {
            NetworkFormView(accountId: accountId, editing: network, vaults: [], kinds: book.kinds(of: accountId),
                            initialKeyMode: editingKeyMode) { saved, generated, testIt in
                network = saved
                onChange(.saved(saved))
                if generated, saved.publicKey != nil {
                    // After the form's sheet has gone.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { keySheet = KeySheet(network: saved, generated: true) }
                }
                // A new key: bring it up to see how it went.
                if testIt { test() }
            }
            .environmentObject(model)
        }
        .sheet(item: $keySheet) { k in
            ServerKeyView(network: k.network, generated: k.generated, canTest: editor) {
                keySheet = nil
                test()
            }
        }
        .confirmationDialog(Text("networks.delete.title \(network.name)"), isPresented: $deleting, titleVisibility: .visible) {
            Button("common.delete", role: .destructive, action: delete)
        } message: {
            Text(verbatim: String(localized: "networks.delete.message")
                 + (network.isTailscale ? " " + String(localized: "networks.ts.delete_note") : "")
                 + (users > 0 ? "\n\n" + String(localized: "networks.delete.hosts \(users)") : ""))
        }
        .confirmationDialog(Text("networks.key.replace_title"), isPresented: $replacing, titleVisibility: .visible) {
            Button("networks.key.replace_ok", role: .destructive) { generateKey(replace: true) }
        } message: {
            Text("networks.key.replace_message")
        }
    }

    private var keySection: some View {
        Section {
            if let key = network.publicKey {
                Text(verbatim: key).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .accessibilityIdentifier("network-public-key")
                Button {
                    UIPasteboard.general.string = key
                    message = String(localized: "networks.key.copied")
                } label: { Label("common.copy", systemImage: "doc.on.doc") }
                Button { keySheet = KeySheet(network: network, generated: false) } label: {
                    Label("networks.key.peer_block", systemImage: "doc.plaintext")
                }
            } else if network.hasSecret || network.secretHidden {
                Text("networks.key.pending").font(.footnote).foregroundColor(.secondary)
            } else {
                Text("networks.key.missing").font(.footnote).foregroundColor(Brand.amber)
            }
            if editor {
                Button {
                    if network.hasSecret { replacing = true } else { generateKey(replace: false) }
                } label: {
                    Label(network.hasSecret ? LocalizedStringKey("networks.key.replace") : LocalizedStringKey("networks.key.generate"),
                          systemImage: "key")
                }
                .disabled(busy)
            }
        } header: {
            Text("networks.key.title")
        } footer: {
            Text("networks.key.private_note")
        }
    }

    /// A tailnet's state: connected (its address, devices, control server,
    /// tailnet, MagicDNS, the server's node), connecting, the login (Editors
    /// open the login page; Use-only members wait for one), the approval, or
    /// the error with "Use another key".
    @ViewBuilder
    private func tailnetState(_ state: NetState, _ s: NetStatus?) -> some View {
        switch state {
        case .up:
            if let s {
                Text(verbatim: tailnetSummaryText(s)).foregroundColor(Brand.green).accessibilityIdentifier("tailnet-summary")
                fact("networks.ts.detail.control", Networks.controlServerLabel(s.controlUrl ?? network.tailscale?.controlUrl))
                if let t = s.tailnet { fact("networks.ts.detail.tailnet", t) }
                if let m = s.magicDnsSuffix { fact("networks.ts.detail.magic_dns", m) }
                let node = [s.nodeName, s.nodeDnsName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }].compactMap { $0 }
                if !node.isEmpty { fact("networks.ts.detail.node", (node.count == 2 && node[0] == node[1] ? [node[0]] : node).joined(separator: " · ")) }
                if !s.nodeAddresses.isEmpty { fact("networks.detail.node_addresses", s.nodeAddresses.joined(separator: ", ")) }
                if let id = s.nodeId { fact("networks.ts.detail.node_id", id) }
                if let e = s.ephemeral {
                    fact("networks.ts.detail.ephemeral", e ? String(localized: "networks.ts.detail.ephemeral_yes") : String(localized: "networks.ts.detail.ephemeral_no"))
                }
                if let t = networkTraffic(s) { fact("networks.detail.traffic", t) }
                if let n = s.streams, n > 0 { fact("networks.detail.streams", String(n)) }
            }
        case .needsLogin:
            VStack(alignment: .leading, spacing: 6) {
                Text("networks.ts.login.title").font(.subheadline.weight(.semibold)).foregroundColor(Brand.amber)
                if editor, let url = s?.authUrl.flatMap(URL.init(string:)) {
                    Text("networks.ts.login.text").font(.footnote)
                    if watching {
                        HStack(spacing: 8) { ProgressView(); Text("networks.ts.login.waiting").font(.footnote).foregroundColor(.secondary) }
                    }
                    Button {
                        openURL(url)
                        watching = true
                    } label: { Label("networks.ts.login.open", systemImage: "arrow.up.forward.app") }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("tailnet-login-open")
                } else {
                    Text("networks.ts.login.use_only").font(.footnote).foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        case .needsApproval:
            VStack(alignment: .leading, spacing: 6) {
                Text("networks.ts.approval.title").font(.subheadline.weight(.semibold)).foregroundColor(Brand.amber)
                Text("networks.ts.approval.text \(s?.nodeName ?? "—")").font(.footnote)
                if watching {
                    HStack(spacing: 8) { ProgressView(); Text("networks.ts.login.waiting").font(.footnote).foregroundColor(.secondary) }
                }
            }
            .padding(.vertical, 4)
        case .error:
            VStack(alignment: .leading, spacing: 6) {
                let m = (s?.message ?? "").trimmingCharacters(in: .whitespaces)
                Text(verbatim: m.isEmpty ? state.hint : m.prefix(1).uppercased() + m.dropFirst()).font(.footnote).foregroundColor(Brand.red)
                if let e = s?.lastError, m.isEmpty || !m.contains(e) {
                    Text("networks.ts.error.details \(e)").font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                }
                if editor {
                    Button { editingKeyMode = .new; editing = true } label: { Label("networks.ts.error.other_key", systemImage: "key") }
                        .accessibilityIdentifier("tailnet-other-key")
                }
            }
            .padding(.vertical, 4)
        default:
            Text(verbatim: state.hint(kind: network.kind)).font(.footnote).foregroundColor(.secondary)
        }
    }

    /// A tailnet's settings.
    private var tailnetSettingsSection: some View {
        let ts = network.tailscale ?? TsConfig()
        return Section {
            fact("networks.ts.detail.control", ts.controlUrl ?? "Tailscale")
            if !network.secretHidden {
                fact("networks.ts.detail.key", network.hasSecret ? String(localized: "networks.ts.detail.with_key")
                     : String(localized: "networks.ts.detail.without_key"))
            }
            fact("networks.ts.form.hostname", ts.hostname ?? String(localized: "networks.ts.form.hostname_auto \(Networks.defaultHostname(network.id))"))
            fact("networks.ts.form.tags", ts.tags.isEmpty ? String(localized: "networks.ts.detail.key_tags") : ts.tags.joined(separator: ", "))
            fact("networks.ts.detail.ephemeral", ts.ephemeral.map { $0 ? String(localized: "networks.ts.detail.ephemeral_yes")
                                                                        : String(localized: "networks.ts.detail.ephemeral_no") }
                 ?? String(localized: "networks.ts.detail.ephemeral_default"))
        } header: {
            Text("networks.detail.configuration")
        }
    }

    private var configurationSection: some View {
        Section {
            fact("networks.detail.addresses", network.addresses.isEmpty ? "—" : network.addresses.joined(separator: ", "))
            if !network.dns.isEmpty { fact("networks.detail.dns", network.dns.joined(separator: ", ")) }
            ForEach(Array(network.peers.enumerated()), id: \.offset) { _, p in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: String(localized: "networks.detail.peer") + " " + String(p.publicKey.prefix(10)) + "…")
                        .font(.subheadline.weight(.semibold))
                    if let e = p.endpoint { fact("networks.detail.endpoint", e) }
                    if !p.allowedIps.isEmpty { fact("networks.detail.allowed_ips", p.allowedIps.joined(separator: ", ")) }
                    if let k = p.keepalive { fact("networks.detail.keepalive", "\(k) s") }
                }
            }
        } header: {
            Text("networks.detail.configuration")
        }
    }

    private func fact(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.footnote).foregroundColor(.secondary)
            Spacer()
            Text(verbatim: value).font(.footnote).multilineTextAlignment(.trailing)
        }
    }

    /// Hosts of the account (in the local stores) that go through it.
    private func hostsUsing() -> Int {
        let filter = ItemFilter(accountIds: [accountId], vaultIds: nil, includeDevice: false)
        let hosts = (try? model.core.listHosts(filter: filter)) ?? []
        let groups = (try? model.core.listGroups(filter: filter)) ?? []
        return hosts.filter { h in
            h.vaultId == network.vaultId && Networks.effective(own: h.settings.networkId, groupId: h.groupId,
                groups: NetworkBook.links(groups, account: accountId, vault: h.vaultId)) == network.id
        }.count
    }

    private func test() {
        guard let api else { return }
        let n = network
        busy = true
        message = nil
        failure = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let st = try await api.test(n.id, kind: n.kind) { book.setStatus(n.id, $0) }
                if n.isTailscale {
                    let (text, ok) = tailnetTestResult(n, st)
                    if ok { message = text } else { failure = text }
                    // A login or an approval: follow it while the page is open.
                    if st.state == "needs_auth" && editor { watching = true }
                    return
                }
                switch Networks.state(st, kind: n.kind) {
                case .up: message = String(localized: "networks.test.ok \(n.name)")
                case .waiting: failure = String(localized: "networks.test.no_handshake \(n.name)")
                case .error: failure = String(localized: "networks.test.error \(n.name) \(st.message ?? "")")
                case let other: message = String(localized: "networks.test.state \(n.name) \(other.label())")
                }
            } catch {
                failure = networkErrorText(error, network: n)
            }
        }
    }

    private func down() {
        guard let api else { return }
        let n = network
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await api.down(n.id)
                await book.refreshStatus(api, n.id, force: true)
                message = String(localized: "networks.down.done \(n.name)")
            } catch {
                failure = userMessage(error)
            }
        }
    }

    private func generateKey(replace: Bool) {
        guard let api else { return }
        busy = true
        failure = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let key = try await api.generateKey(network.id, replace: replace)
                network.publicKey = key
                network.hasSecret = true
                keySheet = KeySheet(network: network, generated: true)
                onChange(.keyGenerated)
            } catch {
                failure = userMessage(error)
            }
        }
    }

    private func delete() {
        guard let api else { return }
        let n = network
        Task { @MainActor in
            do {
                try await api.delete(n.id)
                onChange(.deleted(n))
                dismiss()
            } catch {
                failure = userMessage(error)
            }
        }
    }
}

/// The server's public key: copy it, the steps and the `[Peer]` block for the other side.
struct ServerKeyView: View {
    let network: NetworkItem
    let generated: Bool
    let canTest: Bool
    let onTest: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        let key = network.publicKey ?? ""
        let snippet = Networks.peerSnippet(name: network.name, publicKey: key, addresses: network.addresses)
        NavigationView {
            Form {
                Section {
                    Text(verbatim: key).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = key
                        copied = true
                    } label: { Label("networks.key.copy", systemImage: "doc.on.doc") }
                } header: {
                    Text("networks.key.public")
                } footer: {
                    Text("networks.key.description")
                }
                Section {
                    Text(verbatim: "1. " + String(localized: "networks.key.step_peer"))
                    Text(verbatim: "2. " + String(localized: "networks.key.step_allowed \(network.addresses.isEmpty ? "—" : network.addresses.joined(separator: ", "))"))
                    Text(verbatim: "3. " + String(localized: "networks.key.step_test"))
                }
                Section {
                    Text(verbatim: snippet).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = snippet
                        copied = true
                    } label: { Label("common.copy", systemImage: "doc.on.doc") }
                } header: {
                    Text("networks.key.snippet")
                } footer: {
                    Text("networks.key.private_note")
                }
                if canTest {
                    Section {
                        Button { dismiss(); onTest() } label: { Label("networks.test", systemImage: "antenna.radiowaves.left.and.right") }
                    }
                }
                if copied {
                    Text("networks.key.copied").font(.footnote).foregroundColor(Brand.green)
                }
            }
            .navigationTitle(generated ? String(localized: "networks.key.generated_title") : String(localized: "networks.key.title_of \(network.name)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// Devices of a network (`/peers`, it brings it up) with "Add host at …". A
/// tailnet: its devices with "Add host" (by MagicDNS name), "Add a host in"
/// each subnet they route, the ones already added marked and "Add N hosts".
struct PeersView: View {
    let accountId: String
    let network: NetworkItem
    let onAdded: (String) -> Void
    /// "Add N hosts" added that many.
    var onAddedMany: (Int) -> Void = { _ in }

    @EnvironmentObject private var model: AppModel
    @State private var peers: [NetPeer]?
    @State private var hosts: [HostRef] = []
    @State private var error: String?
    @State private var needsLogin = false
    @State private var adding: AddAt?
    @State private var addingAll = false
    @State private var notice: String?

    struct AddAt: Identifiable {
        let address: HostAddress?
        var label: String? = nil
        var id: String { (address?.source ?? "-") + (label ?? "") }
    }

    var body: some View {
        List {
            Section {
                Text(network.isTailscale ? LocalizedStringKey("networks.ts.peers.hint")
                     : network.isWireguard ? LocalizedStringKey("networks.peers.hint_wireguard") : LocalizedStringKey("networks.peers.hint"))
                    .font(.footnote).foregroundColor(.secondary)
            }
            if let error {
                Section {
                    if needsLogin {
                        Text("networks.ts.peers.needs_login").font(.subheadline.weight(.semibold)).foregroundColor(Brand.amber)
                        Text(verbatim: error).font(.footnote)
                    } else {
                        Text(error).foregroundColor(Brand.red)
                    }
                }
            }
            if let notice { Section { Text(verbatim: notice).font(.footnote).foregroundColor(Brand.green) } }
            if let peers {
                if network.isTailscale {
                    tailnetDevices(peers)
                } else {
                    if peers.isEmpty {
                        Section { Text("networks.peers.empty").foregroundColor(.secondary) }
                    }
                    ForEach(peers) { p in
                        Section {
                            HStack {
                                Text(verbatim: p.title).font(.headline).lineLimit(1)
                                Spacer()
                                Chip(p.online == true ? String(localized: "networks.peers.online") : String(localized: "networks.peers.offline"),
                                     p.online == true ? Brand.green : .secondary)
                            }
                            if !p.addresses.isEmpty || p.lastSeen != nil {
                                Text(verbatim: ([p.addresses.joined(separator: ", ")].filter { !$0.isEmpty }
                                                + [p.lastSeen.map { String(localized: "networks.peers.seen \(relativeTime($0))") }].compactMap { $0 })
                                    .joined(separator: " · "))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            ForEach(Networks.hostAddresses(p)) { a in
                                Button { adding = AddAt(address: a) } label: {
                                    Label(a.exact ? String(localized: "networks.peers.add_at \(a.address)")
                                          : String(localized: "networks.peers.add_in \(a.source)"), systemImage: "plus")
                                }
                            }
                        }
                    }
                }
            } else {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("networks.peers.loading").foregroundColor(.secondary)
                    }
                }
            }
            Section {
                Button { adding = AddAt(address: nil) } label: { Label("networks.add_host", systemImage: "plus.circle") }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text("networks.peers.title \(network.name)"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $adding) { a in
            AddNetworkHostView(accountId: accountId, network: network, at: a.address, label: a.label) { label in
                adding = nil
                onAdded(label)
                // A tailnet: the new host marked among its devices.
                if network.isTailscale { Task { await loadHosts() } }
            }
            .environmentObject(model)
        }
    }

    /// The devices of a tailnet: online first, with their MagicDNS name,
    /// addresses, OS, tags and routes; "Add host", "Add a host in <subnet>"
    /// per route (never `/0`), "Added: <host>" and "Add N hosts".
    @ViewBuilder
    private func tailnetDevices(_ peers: [NetPeer]) -> some View {
        if peers.isEmpty {
            Section {
                Text("networks.ts.peers.empty").font(.headline)
                Text("networks.ts.peers.empty_text").font(.footnote).foregroundColor(.secondary)
            }
        } else {
            let fresh = Networks.newDevices(peers, networkId: network.id, hosts: hosts)
            if fresh.count > 1 {
                Section {
                    Button { addAll(fresh) } label: {
                        HStack {
                            Label(String(localized: "networks.ts.peers.add_all \(fresh.count)"), systemImage: "plus.square.on.square")
                            Spacer()
                            if addingAll { ProgressView() }
                        }
                    }
                    .disabled(addingAll)
                    .accessibilityIdentifier("tailnet-add-all")
                } footer: {
                    Text("networks.ts.peers.add_all_hint")
                }
            }
            ForEach(Networks.sortDevices(peers)) { p in
                let host = Networks.importedHost(p, networkId: network.id, hosts: hosts)
                Section {
                    HStack {
                        Text(verbatim: p.name ?? p.bareDnsName ?? p.title).font(.headline).lineLimit(1)
                        Spacer()
                        Chip(p.online == true ? String(localized: "networks.peers.online") : String(localized: "networks.ts.peers.offline"),
                             p.online == true ? Brand.green : .secondary)
                    }
                    let meta = [
                        p.bareDnsName,
                        p.addresses.isEmpty ? nil : p.addresses.joined(separator: ", "),
                        p.os,
                        p.online == true ? nil : p.lastSeen.map { String(localized: "networks.peers.seen \(relativeTime($0))") },
                        p.hostRoutes.isEmpty ? nil : String(localized: "networks.ts.peers.routes \(p.hostRoutes.joined(separator: ", "))"),
                    ].compactMap { $0 }
                    if !meta.isEmpty { Text(verbatim: meta.joined(separator: " · ")).font(.caption).foregroundColor(.secondary) }
                    if !p.tags.isEmpty {
                        Text(verbatim: p.tags.joined(separator: "  ")).font(.caption.monospaced()).foregroundColor(Brand.blue)
                    }
                    if let host {
                        Label(String(localized: "networks.ts.peers.imported \(host.label)"), systemImage: "checkmark.circle.fill")
                            .foregroundColor(Brand.green).font(.footnote)
                    } else if let address = p.deviceAddress {
                        Button { adding = AddAt(address: HostAddress(address: address, exact: true, source: address), label: p.name) } label: {
                            Label("networks.ts.peers.add", systemImage: "plus")
                        }
                        .accessibilityIdentifier("device-add-\(address)")
                    }
                    ForEach(p.hostRoutes, id: \.self) { r in
                        Button {
                            adding = AddAt(address: Networks.hostAddresses(NetPeer(addresses: [r])).first)
                        } label: { Label(String(localized: "networks.peers.add_in \(r)"), systemImage: "plus") }
                    }
                }
            }
            Section { Text("networks.ts.peers.note").font(.footnote).foregroundColor(.secondary) }
        }
    }

    private func load() async {
        guard let api = NetworkBook.shared.api(accountId, core: model.core) else { return }
        do {
            let list = try await api.peers(network.id)
            if network.isTailscale { hosts = await api.hosts(vaultId: network.vaultId) }
            peers = list
        } catch {
            let info = (error as? TermoakError)?.apiError
            needsLogin = network.isTailscale && Networks.needsLogin(code: info?.code, detailsJson: info?.detailsJson)
            self.error = networkErrorText(error, network: network)
            peers = []
        }
    }

    private func loadHosts() async {
        guard let api = NetworkBook.shared.api(accountId, core: model.core) else { return }
        hosts = await api.hosts(vaultId: network.vaultId)
    }

    /// "Add N hosts": each device not added yet, by its MagicDNS name, port 22.
    private func addAll(_ fresh: [NetPeer]) {
        guard let api = NetworkBook.shared.api(accountId, core: model.core) else { return }
        addingAll = true
        Task { @MainActor in
            defer { addingAll = false }
            var added = 0
            var failures: [String] = []
            for p in fresh {
                guard let body = Networks.deviceHostBody(p, network: network) else { continue }
                do {
                    _ = try await api.addHost(body)
                    added += 1
                } catch {
                    failures.append(String(localized: "networks.ts.peers.add_failed \(p.title) \(userMessage(error))"))
                }
            }
            hosts = await api.hosts(vaultId: network.vaultId)
            error = failures.isEmpty ? nil : failures.joined(separator: "\n")
            needsLogin = false
            if added > 0 {
                notice = String(localized: "networks.ts.peers.added_all \(added)")
                onAddedMany(added)
            }
        }
    }
}

/// "Add a host in Office": its address (a device's, or one inside its
/// subnet), name, port and user; `POST /hosts` in the network's vault with
/// the network chosen.
struct AddNetworkHostView: View {
    let accountId: String
    let network: NetworkItem
    let at: HostAddress?
    /// A device's name (a tailnet's "Add host").
    var label: String? = nil
    let onAdded: (String) -> Void

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""
    @State private var labelTouched = false
    @State private var port = "22"
    @State private var username = ""
    @State private var busy = false
    @State private var error: String?

    private var complete: Bool {
        let a = address.trimmingCharacters(in: .whitespaces)
        return !a.isEmpty && !a.hasSuffix(".") && !a.contains(" ") && Int(port).map { (1...65535).contains($0) } == true
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("networks.add_host.address", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: address) { v in if !labelTouched { name = v.trimmingCharacters(in: .whitespaces) } }
                    TextField("common.name", text: $name)
                        .onChange(of: name) { v in if v != address.trimmingCharacters(in: .whitespaces) { labelTouched = true } }
                    TextField("common.username", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("common.port", text: $port).keyboardType(.numberPad)
                } footer: {
                    if let at, !at.exact {
                        Text("networks.add_host.in_subnet \(at.source)")
                    } else if network.isTailscale {
                        Text("networks.ts.address_hint")
                    } else {
                        Text("networks.add_host.hint")
                    }
                }
                if let error { Section { Text(error).foregroundColor(Brand.red) } }
            }
            .navigationTitle(Text("networks.add_host.title \(network.name)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("networks.add_host.ok", action: add).disabled(busy || !complete)
                }
            }
            .onAppear {
                if let at {
                    address = at.address
                    if at.exact { name = at.address }
                }
                if let label, !label.isEmpty {
                    name = label
                    labelTouched = true
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func add() {
        guard let api = NetworkBook.shared.api(accountId, core: model.core) else { return }
        let a = address.trimmingCharacters(in: .whitespaces)
        let l = name.trimmingCharacters(in: .whitespaces)
        let u = username.trimmingCharacters(in: .whitespaces)
        let body = Networks.hostBody(label: l.isEmpty ? a : l, address: a, port: Int(port) ?? 22, username: u.isEmpty ? nil : u, network: network)
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let saved = try await api.addHost(body)
                onAdded(saved.isEmpty ? (l.isEmpty ? a : l) : saved)
                dismiss()
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}

/// The auth key choice of the Tailscale form.
enum TsKeyMode: Hashable {
    /// Creating: optional key. Editing: replace the stored one (or add one).
    case new
    /// Editing a network with a key: keep it (no `secret` in the PUT).
    case keep
    /// Editing a network with a key: remove it (`secret: null`).
    case remove
    /// Editing a network without a key: still none.
    case noKey
}

/// Add or edit a network. Tailscale/Headscale when the server joins it (see
/// `tailscaleSections`); WireGuard: name, vault (new ones), description and the `.conf` (pasted,
/// opened with the Files picker, or from the template), read as it is
/// typed; without a PrivateKey the server generates the key. Editing shows
/// the configuration without keys: the stored key stays unless a PrivateKey
/// line is added or a new key is generated.
struct NetworkFormView: View {
    let accountId: String
    let editing: NetworkItem?
    let vaults: [VaultInfo]
    /// Kinds the server joins (`features.network_kinds`).
    var kinds: [String] = [Networks.wireguard]
    /// Tailscale, editing: the key choice to start with ("Use another key": `.new`).
    var initialKeyMode: TsKeyMode? = nil
    /// Saved (whether the server generated a key, and whether to test it: a new tailnet or a new key).
    let onSaved: (NetworkItem, Bool, Bool) -> Void

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var vaultId: String?
    @State private var conf = ""
    @State private var generateChoice = false
    @State private var picking = false
    @State private var busy = false
    @State private var error: String?
    @State private var loaded = false
    // Tailscale / Headscale.
    @State private var kind = Networks.wireguard
    @State private var headscale = false
    @State private var controlUrl = ""
    @State private var keyMode: TsKeyMode = .new
    @State private var authKey = ""
    @State private var showKey = false
    @State private var hostname = ""
    @State private var tagsText = ""
    @State private var advanced = false
    /// `ephemeral` stays as stored (nil = the default) unless the switch is touched.
    @State private var ephemeralTouched = false
    @State private var ephemeralValue = false

    private var ts0: TsConfig { editing?.tailscale ?? TsConfig() }
    private var tailscaleOffered: Bool { kinds.contains(Networks.tailscale) }
    private var keyModes: [TsKeyMode] {
        guard let editing else { return [.new] }
        return editing.hasSecret ? [.keep, .new, .remove] : [.noKey, .new]
    }
    private var keyWillExist: Bool {
        switch keyMode {
        case .keep: return editing?.hasSecret == true
        case .new: return editing != nil || !authKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .remove, .noKey: return false
        }
    }
    private var ephemeralSet: Bool { ephemeralTouched || ts0.ephemeral != nil }
    private var ephemeralBinding: Binding<Bool> {
        Binding(get: { ephemeralSet ? ephemeralValue : keyWillExist },
                set: { ephemeralTouched = true; ephemeralValue = $0 })
    }

    private var read: Result<WgConf, ConfError>? {
        conf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Networks.check(conf)
    }
    private var parsed: WgConf? { if case .success(let c)? = read { return c } else { return nil } }
    private var hasSecret: Bool { editing?.hasSecret == true }
    private var confKey: Bool { parsed?.privateKey != nil }
    /// Without a PrivateKey the server makes one (unless the stored one stays).
    private var generate: Bool { confKey || hasSecret ? generateChoice : true }

    var body: some View {
        NavigationView {
            Form {
                if let error { Section { Text(error).foregroundColor(Brand.red) } }
                Section {
                    // WireGuard, and Tailscale when the server joins it; ZeroTier in a later version.
                    if editing == nil && tailscaleOffered {
                        Picker("networks.form.kind", selection: $kind) {
                            Text(verbatim: "WireGuard").tag(Networks.wireguard)
                            Text("networks.ts.kind_option").tag(Networks.tailscale)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("network-kind")
                        Text("networks.form.zerotier_soon").font(.footnote).foregroundColor(.secondary)
                    } else {
                        HStack {
                            Text("networks.form.kind")
                            Spacer()
                            Text(verbatim: kind == Networks.tailscale ? String(localized: "networks.ts.kind_option") : "WireGuard")
                                .foregroundColor(.accentColor)
                        }
                        Text(tailscaleOffered || kind == Networks.tailscale ? LocalizedStringKey("networks.form.zerotier_soon")
                             : LocalizedStringKey("networks.form.kind_soon_both"))
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    TextField("networks.form.name", text: $name)
                        .accessibilityIdentifier("network-name")
                    if editing == nil {
                        Picker("networks.form.vault", selection: $vaultId) {
                            ForEach(vaults, id: \.id) { v in Text(verbatim: v.displayName).tag(Optional(v.id)) }
                        }
                    }
                    TextField("networks.form.description", text: $description)
                } footer: {
                    if editing == nil { Text("networks.form.vault_hint") }
                }
                if kind == Networks.tailscale {
                    tailscaleSections
                } else {
                    confSection
                }
            }
            .navigationTitle(editing == nil ? String(localized: "networks.form.new_title") : String(localized: "networks.form.edit_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("common.save", action: save).accessibilityIdentifier("network-save") }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { importConf($0) }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                name = editing?.name ?? ""
                description = editing?.description ?? ""
                vaultId = vaults.first { $0.kind == .personal }?.id ?? vaults.first?.id
                kind = editing?.kind ?? Networks.wireguard
                if let editing, editing.isWireguard { conf = Networks.confText(editing, keyNote: String(localized: "networks.form.conf_key_kept")) }
                let ts = ts0
                headscale = ts.controlUrl != nil
                controlUrl = ts.controlUrl ?? ""
                hostname = ts.hostname ?? ""
                tagsText = ts.tags.joined(separator: ", ")
                advanced = ts.hostname != nil || !ts.tags.isEmpty || ts.ephemeral != nil
                ephemeralValue = ts.ephemeral ?? false
                keyMode = initialKeyMode.flatMap { keyModes.contains($0) ? $0 : nil } ?? keyModes[0]
            }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled(busy)
    }

    /// The Tailscale part: control server (Tailscale, or Headscale with its
    /// URL), the auth key (optional; editing keeps, replaces or removes it)
    /// with where to make it, and Advanced: hostname, tags and "ephemeral"
    /// (the default said under it until it is changed).
    @ViewBuilder
    private var tailscaleSections: some View {
        Section {
            Picker("networks.ts.form.control", selection: $headscale) {
                Text(verbatim: "Tailscale").tag(false)
                Text(verbatim: "Headscale").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("ts-control")
            if headscale {
                TextField("networks.ts.form.control_url", text: $controlUrl, prompt: Text(verbatim: "https://headscale.example.com"))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("ts-control-url")
            }
        } header: {
            Text("networks.ts.form.control")
        } footer: {
            if headscale { Text("networks.ts.form.control_url_hint") }
        }
        Section {
            if keyModes.count > 1 {
                Picker("networks.ts.form.key", selection: $keyMode) {
                    ForEach(keyModes, id: \.self) { m in Text(keyModeLabel(m)).tag(m) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("ts-key-mode")
            }
            if keyMode == .new {
                HStack {
                    Group {
                        if showKey {
                            TextField(editing != nil ? "networks.ts.form.key_new_label" : "networks.ts.form.key_optional", text: $authKey)
                        } else {
                            SecureField(editing != nil ? "networks.ts.form.key_new_label" : "networks.ts.form.key_optional", text: $authKey)
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("ts-auth-key")
                    Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("common.show"))
                }
            }
        } header: {
            Text("networks.ts.form.key")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if keyModes.count > 1 { Text(keyModeHint(keyMode)) }
                if keyMode == .new {
                    Text("networks.ts.form.key_hint")
                    if headscale {
                        Text("networks.ts.form.key_hint_headscale").font(.system(.caption, design: .monospaced))
                    } else {
                        Text("networks.ts.form.key_hint_tailscale")
                    }
                    if editing == nil { Text("networks.ts.form.key_hint_none") }
                }
            }
        }
        Section {
            DisclosureGroup(isExpanded: $advanced) {
                TextField("networks.ts.form.hostname", text: $hostname,
                          prompt: Text("networks.ts.form.hostname_auto \(Networks.defaultHostname(editing?.id))"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("ts-hostname")
                Text("networks.ts.form.hostname_hint \(Networks.defaultHostname(editing?.id))").font(.footnote).foregroundColor(.secondary)
                TextField("networks.ts.form.tags", text: $tagsText, prompt: Text(verbatim: "tag:termoak"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("ts-tags")
                Text("networks.ts.form.tags_hint").font(.footnote).foregroundColor(.secondary)
                Toggle("networks.ts.form.ephemeral", isOn: ephemeralBinding)
                    .accessibilityIdentifier("ts-ephemeral")
                Text(ephemeralSet ? LocalizedStringKey("networks.ts.form.ephemeral_set")
                     : keyWillExist ? LocalizedStringKey("networks.ts.form.ephemeral_default_on")
                     : LocalizedStringKey("networks.ts.form.ephemeral_default_off"))
                    .font(.footnote).foregroundColor(.secondary)
            } label: {
                Text("networks.ts.form.advanced")
            }
        } footer: {
            Text("networks.ts.form.secret_note")
        }
    }

    private func keyModeLabel(_ m: TsKeyMode) -> LocalizedStringKey {
        switch m {
        case .keep: return "networks.ts.form.key_keep"
        case .new: return editing?.hasSecret == true ? "networks.ts.form.key_new" : "networks.ts.form.key_add"
        case .remove: return "networks.ts.form.key_remove"
        case .noKey: return "networks.ts.form.key_none"
        }
    }

    private func keyModeHint(_ m: TsKeyMode) -> LocalizedStringKey {
        switch m {
        case .keep: return "networks.ts.form.key_keep_hint"
        case .new: return "networks.ts.form.key_new_hint"
        case .remove: return "networks.ts.form.key_remove_hint"
        case .noKey: return "networks.ts.form.key_none_hint"
        }
    }

    /// The WireGuard `.conf`.
    private var confSection: some View {
        Section {
            HStack(spacing: 16) {
                Button { picking = true } label: { Label("networks.form.import", systemImage: "folder") }
                    .buttonStyle(.borderless)
                Button {
                    if let s = UIPasteboard.general.string { conf = s }
                } label: { Label("common.paste", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.borderless)
                if editing == nil {
                    Button("networks.form.template") { conf = Networks.confTemplate }
                        .buttonStyle(.borderless)
                }
            }
            TextEditor(text: $conf)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 200)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("network-conf")
            switch read {
            case .failure(let e)?:
                Text(verbatim: e.text).font(.footnote).foregroundColor(Brand.red)
            case .success(let c)?:
                VStack(alignment: .leading, spacing: 4) {
                    Text("networks.form.conf_ok \(c.addresses.joined(separator: ", ")) \(c.peers.count)")
                        .foregroundColor(Brand.green)
                    Text(keyLine)
                    if c.presharedKey != nil && (!generate || editing == nil) { Text("networks.form.psk_from_conf") }
                    if !c.ignored.isEmpty {
                        Text("networks.form.ignored \(c.ignored.joined(separator: ", "))").foregroundColor(.secondary)
                    }
                    if c.peers.allSatisfy({ $0.keepalive == nil }) {
                        Text("networks.form.keepalive_hint").foregroundColor(.secondary)
                    }
                }
                .font(.footnote)
            case nil:
                EmptyView()
            }
            if confKey || hasSecret {
                Toggle(confKey ? LocalizedStringKey("networks.form.generate_instead") : LocalizedStringKey("networks.form.generate_new"),
                       isOn: $generateChoice)
            }
        } header: {
            Text(editing == nil ? LocalizedStringKey("networks.form.conf") : LocalizedStringKey("networks.form.conf_edit"))
        } footer: {
            Text(verbatim: String(localized: "networks.form.conf_hint") + "\n\n" + String(localized: "networks.form.secret_note"))
        }
    }

    private var keyLine: LocalizedStringKey {
        if confKey && !generate { return "networks.form.key_from_conf" }
        if generate && hasSecret { return "networks.form.key_replaced" }
        if generate { return "networks.form.key_generated" }
        return "networks.form.key_kept"
    }

    private func importConf(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard data.count <= Networks.maxConfBytes else {
                error = String(localized: "networks.form.import_too_big")
                return
            }
            guard let text = TextFiles.decode(data) else {
                error = String(localized: "networks.form.import_failed")
                return
            }
            conf = text
            error = nil
            if name.trimmingCharacters(in: .whitespaces).isEmpty { name = url.deletingPathExtension().lastPathComponent }
        } catch {
            self.error = String(localized: "networks.form.import_failed")
        }
    }

    /// Saves a Tailscale network: the core's rules first, then the body
    /// (the whole network as read, `ephemeral` untouched stays as stored,
    /// the key kept, replaced or removed with `secret: null`).
    private func saveTailscale() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            error = String(localized: "networks.form.error_name")
            return
        }
        if editing == nil && vaultId == nil {
            error = String(localized: "networks.form.no_vault")
            return
        }
        let url: String? = headscale ? Networks.cleanControlUrl(controlUrl) : nil
        let tags = Networks.parseTags(tagsText)
        let key = authKey.trimmingCharacters(in: .whitespaces)
        if let p = Networks.tailscaleProblem(controlUrl: url, hostname: hostname, tags: tags, authKey: keyMode == .new ? key : nil)
            ?? (keyMode == .new && editing != nil && key.isEmpty ? TsProblem.keyMissing : nil) {
            error = p.text
            return
        }
        let secret: SecretChange
        if keyMode == .new && !key.isEmpty { secret = .set(key) } else if keyMode == .remove { secret = .clear } else { secret = .keep }
        let h = hostname.trimmingCharacters(in: .whitespaces)
        let ts = TsConfig(controlUrl: url, hostname: h.isEmpty ? nil : h, tags: tags,
                          ephemeral: ephemeralTouched ? ephemeralValue : ts0.ephemeral)
        let body = Networks.tailscaleBody(base: editing?.json, vaultId: editing == nil ? vaultId : nil, name: String(trimmed.prefix(100)),
                                          description: description.trimmingCharacters(in: .whitespaces), ts: ts, secret: secret)
        guard let api = NetworkBook.shared.api(accountId, core: model.core) else {
            error = String(localized: "error.not_logged_in")
            return
        }
        // A new tailnet or a new key: bring it up to see how it went.
        var testIt = editing == nil
        if case .set = secret { testIt = true }
        let editingId = editing?.id
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let saved = editingId != nil ? try await api.update(editingId!, body) : try await api.create(body)
                onSaved(saved, false, testIt)
                dismiss()
            } catch {
                self.error = networkSaveErrorText(error)
            }
        }
    }

    private func save() {
        if kind == Networks.tailscale { return saveTailscale() }
        let c: WgConf
        switch read {
        case nil:
            error = String(localized: "networks.form.error_conf")
            return
        case .failure(let e)?:
            error = e.text
            return
        case .success(let ok)?:
            c = ok
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            error = String(localized: "networks.form.error_name")
            return
        }
        if editing == nil && vaultId == nil {
            error = String(localized: "networks.form.no_vault")
            return
        }
        if c.privateKey == nil && c.presharedKey != nil && hasSecret && !generate {
            error = String(localized: "networks.form.error_psk_needs_key")
            return
        }
        var secret: (privateKey: String?, presharedKey: String?)?
        if let k = c.privateKey, !generate {
            secret = (k, c.presharedKey)
        } else if generate && c.presharedKey != nil && editing == nil {
            // A preshared key alone for a new one (the server's key comes next).
            secret = (nil, c.presharedKey)
        }
        let body = Networks.body(base: editing?.json, vaultId: editing == nil ? vaultId : nil, name: String(trimmed.prefix(100)),
                                 description: description.trimmingCharacters(in: .whitespaces), conf: c, secret: secret)
        guard let api = NetworkBook.shared.api(accountId, core: model.core) else {
            error = String(localized: "error.not_logged_in")
            return
        }
        let generateKey = generate
        let replace = generate && hasSecret
        let editingId = editing?.id
        busy = true
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                var saved: NetworkItem
                if let editingId {
                    saved = try await api.update(editingId, body)
                } else {
                    saved = try await api.create(body)
                }
                var generated = false
                if generateKey {
                    do {
                        saved.publicKey = try await api.generateKey(saved.id, replace: replace)
                        saved.hasSecret = true
                        generated = true
                    } catch {
                        // Saved, without the key: say why (the page offers to generate it again).
                        onSaved(saved, false, false)
                        self.error = String(localized: "networks.saved_without_key \(userMessage(error))")
                        return
                    }
                }
                onSaved(saved, generated, false)
                dismiss()
            } catch {
                self.error = networkSaveErrorText(error)
            }
        }
    }
}
