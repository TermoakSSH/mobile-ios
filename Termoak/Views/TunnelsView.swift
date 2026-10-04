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
                ToolbarItem(placement: .cancellationAction) { Button("common.close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = TunnelEdit(tunnel: nil) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("tunnels.new")
                }
            }
            .sheet(item: $editing, onDismiss: load) { e in
                TunnelEditor(hostId: host.id, original: e.tunnel)
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
                            try? model.core.deleteForward(id: f.id)
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
        .onTapGesture { editing = TunnelEdit(tunnel: f) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleting = f } label: { Label("common.delete", systemImage: "trash") }
        }
    }

    private func load() {
        list = ((try? model.core.listForwards(hostId: host.id)) ?? [])
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
        let p = port ?? f.bindPort
        let listen = "\(f.bindAddress):\(p == 0 ? "auto" : String(p))"
        let destination = "\(f.destHost ?? "?"):\(f.destPort.map(String.init) ?? "?")"
        switch f.kind {
        case .local: return "L \(listen) → \(destination)"
        case .remote: return String(localized: "tunnels.summary.remote \(listen) \(destination)")
        case .dynamic: return "D SOCKS \(listen)"
        }
    }

    private func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
    }
}

private struct TunnelEdit: Identifiable {
    let id = UUID()
    let tunnel: PortForward?
}

/// Create or edit a saved tunnel.
private struct TunnelEditor: View {
    let hostId: String
    let original: PortForward?
    @EnvironmentObject private var model: AppModel
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
                Section {
                    Toggle("tunnels.editor.auto_start", isOn: $autoStart)
                }
                if let error {
                    Section { Text(error).foregroundColor(Brand.red) }
                }
            }
            .navigationTitle(original == nil ? String(localized: "tunnels.new") : String(localized: "tunnels.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("common.save", action: save) }
            }
            .onAppear(perform: fill)
        }
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
        var f = original ?? PortForward(label: "", hostId: hostId, kind: kind)
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
            self.error = errorMessage(error)
        }
    }
}
