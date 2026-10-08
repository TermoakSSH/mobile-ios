import TermoakKit
import SwiftUI

/// Tunnels (port forwarding) of a host: the saved ones, starting and
/// stopping them, and their live statistics.
struct TunnelsView: View {
    let host: SshHost
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tunnels: Tunnels
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var list: [PortForward] = []
    @State private var editing: TunnelEdit?
    @State private var deleting: PortForward?

    var body: some View {
        NavigationView {
            List {
                if list.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("tunnels.empty.title").font(.headline)
                            Text("tunnels.empty.text")
                                .font(.callout).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }
                if !unsaved.isEmpty {
                    Section {
                        ForEach(unsaved) { t in adHocRow(t) }
                    } header: {
                        Text("tunnels.adhoc.header")
                    }
                }
                Section {
                    ForEach(list, id: \.id) { f in row(f) }
                } footer: {
                    if !list.isEmpty {
                        Text("tunnels.footer")
                    }
                }
            }
            .navigationTitle(Text("tunnels.title \(host.label.isEmpty ? host.address : host.label)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { editing = TunnelEdit(tunnel: nil) } label: { Label("tunnels.new", systemImage: "plus") }
                        Button { editing = TunnelEdit(tunnel: nil, startOnly: true) } label: {
                            Label("tunnels.adhoc.new", systemImage: "bolt")
                        }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("tunnels.new")
                }
            }
            .sheet(item: $editing, onDismiss: load) { e in
                TunnelEditor(host: host, original: e.tunnel, startOnly: e.startOnly).environmentObject(tunnels)
            }
            .sheet(item: $tunnels.prompt) { p in
                AuthPromptView(prompt: p) { tunnels.prompt = nil }.interactiveDismissDisabled()
            }
            .confirmationDialog(Text("tunnels.delete.title \(deleting.map(name) ?? "")"),
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("common.delete", role: .destructive) {
                    if let f = deleting {
                        Task {
                            await tunnels.stop(f)
                            try? model.core.deleteForward(id: f.id, accountId: f.accountId)
                            load()
                        }
                    }
                }
            }
            .alert("common.error", isPresented: Binding(get: { tunnels.error != nil }, set: { if !$0 { tunnels.error = nil } })) {
                Button("common.ok", role: .cancel) {}
            } message: { Text(tunnels.error ?? "") }
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: load)
    }

    private func row(_ f: PortForward) -> some View {
        let active = tunnels.activeForward(f)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: icon(f.kind))
                    .foregroundColor(active != nil ? Brand.green : .secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name(f)).font(.body.weight(.medium)).lineLimit(1)
                    Text(summary(f, port: active?.boundPort())).font(.caption.monospaced()).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { active != nil },
                    set: { on in Task { if on { await tunnels.start(f) } else { await tunnels.stop(f) } } }
                ))
                .labelsHidden()
                .accessibilityLabel(name(f))
            }
            if let active, let st = tunnels.stats[f.id] {
                HStack(spacing: 12) {
                    Label("tunnels.stats.connections \(Int(st.activeConnections)) \(Int(st.totalConnections))", systemImage: "link")
                    Label(bytes(st.bytesIn), systemImage: "arrow.down")
                    Label(bytes(st.bytesOut), systemImage: "arrow.up")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                if f.kind == .local, let url = URL(string: "http://127.0.0.1:\(active.boundPort())") {
                    Button { openURL(url) } label: { Label("tunnels.open_browser", systemImage: "safari") }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { if f.canEdit { editing = TunnelEdit(tunnel: f) } }
        .swipeActions(edge: .trailing) {
            if f.canEdit {
                Button(role: .destructive) { deleting = f } label: { Label("common.delete", systemImage: "trash") }
            }
        }
    }

    /// Unsaved tunnels of this host that are running.
    private var unsaved: [AdHocTunnel] { tunnels.adHoc.filter { $0.hostId == host.id } }

    /// An unsaved tunnel: what it does, its statistics and Stop.
    private func adHocRow(_ t: AdHocTunnel) -> some View {
        let active = tunnels.running[t.id]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: icon(t.kind)).foregroundColor(Brand.green).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.label.isEmpty ? String(localized: "tunnels.adhoc.unnamed") : t.label)
                        .font(.body.weight(.medium)).lineLimit(1)
                    Text(adHocSummary(t, port: active?.boundPort())).font(.caption.monospaced()).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Button { Task { await tunnels.stopAdHoc(t) } } label: { Text("tunnels.adhoc.stop") }
                    .buttonStyle(.bordered)
            }
            if let active, let st = tunnels.stats[t.id] {
                HStack(spacing: 12) {
                    Label("tunnels.stats.connections \(Int(st.activeConnections)) \(Int(st.totalConnections))", systemImage: "link")
                    Label(bytes(st.bytesIn), systemImage: "arrow.down")
                    Label(bytes(st.bytesOut), systemImage: "arrow.up")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                if t.kind == .local, let url = URL(string: "http://127.0.0.1:\(active.boundPort())") {
                    Button { openURL(url) } label: { Label("tunnels.open_browser", systemImage: "safari") }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func adHocSummary(_ t: AdHocTunnel, port: UInt32?) -> String {
        tunnelSummary(kind: t.kind, bindAddress: t.bindAddress, bindPort: port ?? t.bindPort, destHost: t.destHost, destPort: t.destPort)
    }

    private func load() {
        // The host's account and This device (a This-device host may have
        // older tunnels in an account).
        let filter = ItemFilter(accountIds: host.accountId.map { [$0] }, vaultIds: nil, includeDevice: true)
        list = ((try? model.core.listForwards(hostId: host.id, filter: filter)) ?? [])
            .sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
    }

    private func name(_ f: PortForward) -> String {
        f.label.isEmpty ? summary(f, port: nil) : f.label
    }

    private func icon(_ k: ForwardKind) -> String {
        switch k {
        case .local: return "arrow.right.circle"
        case .remote: return "arrow.left.circle"
        case .dynamic: return "globe"
        }
    }

    /// `L 127.0.0.1:8080 → db:5432` (with the real port if a free one was requested).
    private func summary(_ f: PortForward, port: UInt32?) -> String {
        tunnelSummary(kind: f.kind, bindAddress: f.bindAddress, bindPort: port ?? f.bindPort, destHost: f.destHost, destPort: f.destPort)
    }

    private func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
    }
}

/// `L 127.0.0.1:8080 → db:5432` (`auto` for a free port not known yet).
func tunnelSummary(kind: ForwardKind, bindAddress: String, bindPort: UInt32, destHost: String?, destPort: UInt32?) -> String {
    let listen = "\(bindAddress):\(bindPort == 0 ? "auto" : String(bindPort))"
    let destination = "\(destHost ?? "?"):\(destPort.map(String.init) ?? "?")"
    switch kind {
    case .local: return "L \(listen) → \(destination)"
    case .remote: return String(localized: "tunnels.summary.remote \(listen) \(destination)")
    case .dynamic: return "D SOCKS \(listen)"
    }
}

private struct TunnelEdit: Identifiable {
    let id = UUID()
    let tunnel: PortForward?
    /// Start it without saving it.
    var startOnly = false
}

/// Create or edit a saved tunnel.
private struct TunnelEditor: View {
    let host: SshHost
    let original: PortForward?
    /// Start it now without saving it (it goes away when stopped).
    var startOnly = false
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tunnels: Tunnels
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: ForwardKind = .local
    @State private var listenAddress = "127.0.0.1"
    @State private var port = ""
    @State private var destination = "localhost"
    @State private var destinationPort = ""
    @State private var autoStart = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("tunnels.editor.name", text: $name)
                    Picker("common.type", selection: $kind) {
                        Text("tunnels.kind.local").tag(ForwardKind.local)
                        Text("tunnels.kind.remote").tag(ForwardKind.remote)
                        Text(verbatim: "SOCKS").tag(ForwardKind.dynamic)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(explanation)
                }
                Section(kind == .remote ? String(localized: "tunnels.editor.listen_server")
                        : String(localized: "tunnels.editor.listen_device")) {
                    TextField("tunnels.editor.address", text: $listenAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("tunnels.editor.port_free", text: $port).keyboardType(.numberPad)
                }
                if kind != .dynamic {
                    Section(kind == .remote ? String(localized: "tunnels.editor.destination_device")
                            : String(localized: "tunnels.editor.destination_server")) {
                        TextField("tunnels.editor.host", text: $destination)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        TextField("common.port", text: $destinationPort).keyboardType(.numberPad)
                    }
                }
                if startOnly {
                    Section { Text("tunnels.adhoc.explanation").font(.footnote).foregroundColor(.secondary) }
                } else {
                    Section {
                        Toggle("tunnels.editor.auto_start", isOn: $autoStart)
                    }
                }
                if let error {
                    Section { Text(error).foregroundColor(Brand.red) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(startOnly ? String(localized: "tunnels.adhoc.start") : String(localized: "common.save"), action: save)
                }
            }
            .onAppear(perform: fill)
        }
    }

    private var title: String {
        if startOnly { return String(localized: "tunnels.adhoc.new") }
        return original == nil ? String(localized: "tunnels.new") : String(localized: "tunnels.edit")
    }

    private var explanation: String {
        switch kind {
        case .local: return String(localized: "tunnels.kind.local.explanation")
        case .remote: return String(localized: "tunnels.kind.remote.explanation")
        case .dynamic: return String(localized: "tunnels.kind.dynamic.explanation")
        }
    }

    private func fill() {
        guard let f = original else { return }
        name = f.label
        kind = f.kind
        listenAddress = f.bindAddress
        port = f.bindPort == 0 ? "" : String(f.bindPort)
        destination = f.destHost ?? "localhost"
        destinationPort = f.destPort.map(String.init) ?? ""
        autoStart = f.autoStart
    }

    private func save() {
        func number(_ t: String) -> UInt32?? {
            let t = t.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return .some(nil) }
            guard let n = UInt32(t), (1...65535).contains(n) else { return nil }
            return .some(n)
        }
        guard let p = number(port) else { error = String(localized: "tunnels.error.listen_port"); return }
        var dp: UInt32?
        if kind != .dynamic {
            guard let d = number(destinationPort), let d else { error = String(localized: "tunnels.error.destination_port"); return }
            dp = d
        }
        let address = listenAddress.trimmingCharacters(in: .whitespaces).isEmpty ? "127.0.0.1" : listenAddress.trimmingCharacters(in: .whitespaces)
        let target = kind == .dynamic ? nil : (destination.trimmingCharacters(in: .whitespaces).isEmpty ? "localhost" : destination.trimmingCharacters(in: .whitespaces))
        if startOnly {
            let label = name.trimmingCharacters(in: .whitespaces)
            let (k, bindPort) = (kind, p ?? 0)
            dismiss()
            Task {
                await tunnels.startAdHoc(host: host, label: label, kind: k, bindAddress: address, bindPort: bindPort,
                                         destHost: target, destPort: dp)
            }
            return
        }
        // A new tunnel goes where its host is.
        var f = original ?? PortForward(label: "", hostId: host.id, kind: kind, accountId: host.accountId, vaultId: host.vaultId)
        f.label = name.trimmingCharacters(in: .whitespaces)
        f.kind = kind
        f.bindAddress = listenAddress.trimmingCharacters(in: .whitespaces).isEmpty ? "127.0.0.1" : listenAddress.trimmingCharacters(in: .whitespaces)
        f.bindPort = p ?? 0
        f.destHost = kind == .dynamic ? nil : (destination.trimmingCharacters(in: .whitespaces).isEmpty ? "localhost" : destination.trimmingCharacters(in: .whitespaces))
        f.destPort = dp
        f.autoStart = autoStart
        do {
            _ = try model.core.saveForward(forward: f)
            dismiss()
        } catch {
            self.error = userMessage(error)
        }
    }
}
