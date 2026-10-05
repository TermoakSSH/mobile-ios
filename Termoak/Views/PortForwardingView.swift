import TermoakKit
import SwiftUI

/// Every saved tunnel, grouped by host (Termius's "Port forwarding"): start
/// and stop them here, and tap one to manage the tunnels of its host.
struct PortForwardingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var tunnels: Tunnels
    @EnvironmentObject private var sessions: Sessions
    @State private var forwards: [PortForward] = []
    @State private var hosts: [SshHost] = []
    /// Host whose tunnels are being managed (the sheet of the host).
    @State private var managing: SshHost?
    @State private var choosingHost = false
    /// Host chosen for a new tunnel: its sheet opens when the picker closes.
    @State private var picked: SshHost?

    /// This screen answers the tunnels' prompts and errors unless a host's
    /// sheet (or the terminal, with its own sheet) is in front.
    private var inFront: Bool { managing == nil && !sessions.showing }

    private var sections: [HostForwards] {
        hosts.compactMap { (h: SshHost) -> HostForwards? in
            let list = forwards.filter { $0.hostId == h.id }
            return list.isEmpty ? nil : HostForwards(host: h, forwards: list)
        }
    }

    var body: some View {
        List {
            if sections.isEmpty {
                Section {
                    EmptyState(
                        icon: "arrow.left.arrow.right",
                        title: String(localized: "tunnels.empty.title"),
                        text: String(localized: "tunnels.empty.text"),
                        action: hosts.isEmpty ? nil : String(localized: "tunnels.new")
                    ) { choosingHost = true }
                    .listRowBackground(Color.clear)
                }
            }
            ForEach(sections) { s in
                Section {
                    ForEach(s.forwards, id: \.id) { f in
                        ForwardRow(forward: f) { managing = s.host }
                    }
                } header: {
                    HStack(spacing: 8) {
                        HostIcon(host: s.host, size: 20)
                        Text(verbatim: s.host.label.isEmpty ? s.host.address : s.host.label)
                    }
                }
            }
            if !sections.isEmpty {
                Section {
                    EmptyView()
                } footer: {
                    Text("tunnels.footer")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("nav.port_forwarding")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { choosingHost = true } label: { Image(systemName: "plus") }
                    .disabled(hosts.isEmpty)
                    .accessibilityLabel("tunnels.new")
            }
        }
        .sheet(isPresented: $choosingHost, onDismiss: {
            if let h = picked {
                picked = nil
                managing = h
            }
        }) {
            HostPicker(hosts: hosts) { picked = $0 }
        }
        .sheet(item: Binding(get: { managing.map(SelectedHost.init) }, set: { managing = $0?.host }), onDismiss: load) { e in
            TunnelsView(host: e.host)
        }
        // A tunnel started from this list may need a password or to trust the
        // server (while a host's sheet is open, the sheet asks).
        .sheet(item: inFront ? $tunnels.prompt : Binding<AuthPrompt?>.constant(nil)) { p in
            AuthPromptView(prompt: p) { tunnels.prompt = nil }.interactiveDismissDisabled()
        }
        .alert("common.error", isPresented: Binding(get: { inFront && tunnels.error != nil },
                                                     set: { if !$0 { tunnels.error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: { Text(tunnels.error ?? "") }
        .onAppear(perform: load)
    }

    private func load() {
        forwards = ((try? model.core.listForwards(hostId: nil)) ?? [])
            .sorted { forwardName($0).localizedCaseInsensitiveCompare(forwardName($1)) == .orderedAscending }
        hosts = ((try? model.core.listHosts()) ?? [])
            .sorted { hostName($0).localizedCaseInsensitiveCompare(hostName($1)) == .orderedAscending }
    }
}

private struct HostForwards: Identifiable {
    let host: SshHost
    let forwards: [PortForward]
    var id: String { host.id }
}

private func hostName(_ h: SshHost) -> String {
    h.label.isEmpty ? h.address : h.label
}

private func forwardName(_ f: PortForward) -> String {
    f.label.isEmpty ? forwardSummary(f, port: nil) : f.label
}

/// `L 127.0.0.1:8080 → db:5432` (with the real port if a free one was requested).
private func forwardSummary(_ f: PortForward, port: UInt32?) -> String {
    let p = port ?? f.bindPort
    let listen = "\(f.bindAddress):\(p == 0 ? "auto" : String(p))"
    let destination = "\(f.destHost ?? "?"):\(f.destPort.map(String.init) ?? "?")"
    switch f.kind {
    case .local: return "L \(listen) → \(destination)"
    case .remote: return String(localized: "tunnels.summary.remote \(listen) \(destination)")
    case .dynamic: return "D SOCKS \(listen)"
    }
}

/// A tunnel with its switch; tapping it opens its host's tunnels.
private struct ForwardRow: View {
    let forward: PortForward
    let onManage: () -> Void
    @EnvironmentObject private var tunnels: Tunnels

    var body: some View {
        let active = tunnels.activeForward(forward)
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(active != nil ? Brand.green : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: forwardName(forward)).font(.body.weight(.medium)).lineLimit(1)
                Text(verbatim: forwardSummary(forward, port: active?.boundPort()))
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { active != nil },
                set: { on in Task { if on { await tunnels.start(forward) } else { await tunnels.stop(forward) } } }
            ))
            .labelsHidden()
            .accessibilityLabel(forwardName(forward))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onManage)
    }

    private var icon: String {
        switch forward.kind {
        case .local: return "arrow.right.circle"
        case .remote: return "arrow.left.circle"
        case .dynamic: return "globe"
        }
    }
}

/// Which host a new tunnel goes through.
private struct HostPicker: View {
    let hosts: [SshHost]
    let onPick: (SshHost) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List(hosts, id: \.id) { h in
                Button {
                    onPick(h)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        HostIcon(host: h, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: hostName(h)).foregroundColor(.primary)
                            Text(verbatim: h.address).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("port_forwarding.choose_host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
    }
}
