import TermoakKit
import SwiftUI

// Private networks in the host and group editors, the host lists and the
// terminal bar (NETWORKS.md §8.1).

extension NetworkChoice {
    /// What the picker shows.
    var label: String {
        switch self {
        case .inherit(let group?, _, let name):
            return String(localized: "networks.picker.inherit \(group) \(name ?? String(localized: "networks.missing"))")
        case .inherit:
            return String(localized: "networks.picker.direct")
        case .network(_, let name, let kind):
            return "\(name) · \(Networks.kindLabel(kind))"
        case .missing:
            return String(localized: "networks.missing")
        }
    }
}

/// The "Network" section of a host or group of `accountId`/`vaultId`:
/// empty (`nil`) inherits the group's network (`groupId`: the host's group
/// or the group's parent) or connects directly; then the networks of the
/// same vault; a network that isn't there is kept as "Missing network".
/// Shown for account items whose server has networks, or that already have
/// one (to see and keep it); never on This device. Under it, the chosen
/// network's state in the server.
struct NetworkPickerSection: View {
    let accountId: String?
    let vaultId: String?
    let groupId: String?
    let groups: [HostGroup]
    @Binding var networkId: String?
    /// The host has a proxy: say it is not used with a network.
    var proxySet = false
    /// A group: say its hosts use it.
    var forGroup = false

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var book = NetworkBook.shared
    @State private var networks: [PrivateNetwork] = []

    var body: some View {
        if let accountId, book.isSupported(accountId) || networkId != nil {
            let choices = Networks.choices(current: networkId, groupId: groupId,
                                           groups: NetworkBook.links(groups, account: accountId, vault: vaultId),
                                           sameVault: networks.map { (id: $0.id, name: $0.name, kind: $0.kind) })
            Section {
                Picker("networks.picker.label", selection: $networkId) {
                    ForEach(choices, id: \.self) { c in Text(verbatim: c.label).tag(c.id) }
                }
                .accessibilityIdentifier("network-picker")
            } header: {
                Text("networks.picker.label")
            } footer: {
                Text(verbatim: footer(choices))
            }
            .onAppear(perform: load)
            .onChange(of: vaultId) { _ in load() }
            .task(id: effective(choices)) {
                guard let id = effective(choices), networks.contains(where: { $0.id == id }),
                      let api = book.api(accountId, core: model.core) else { return }
                await book.refreshStatus(api, id)
            }
        }
    }

    private func effective(_ choices: [NetworkChoice]) -> String? {
        if let networkId { return networkId }
        if case .inherit(_, let id, _)? = choices.first { return id }
        return nil
    }

    private func load() {
        guard let accountId else { return }
        let all = (try? model.core.listNetworks(filter: ItemFilter(accountIds: [accountId], vaultIds: nil, includeDevice: false))) ?? []
        networks = all.filter { $0.vaultId == vaultId }
    }

    private func footer(_ choices: [NetworkChoice]) -> String {
        var parts: [String] = []
        let id = effective(choices)
        if let id {
            if let net = networks.first(where: { $0.id == id }) {
                let state = book.state(id, kind: net.kind)
                var line = ""
                if networkId == nil, case .inherit(let group?, _, _)? = choices.first {
                    line += String(localized: "networks.picker.inherited_from \(group)") + " "
                }
                line += "\(Networks.kindLabel(net.kind)) · \(state.label(kind: net.kind))"
                if net.kind == Networks.tailscale, state == .up, let st = book.status(id) {
                    line += " · " + tailnetSummaryText(st, connected: false)
                } else if let at = book.status(id)?.lastHandshakeAt {
                    line += " · " + String(localized: "networks.handshake \(relativeTime(at))")
                }
                parts.append(line + ". " + String(localized: "networks.picker.how"))
                // A host in a tailnet: what its address can be.
                if net.kind == Networks.tailscale && !forGroup { parts.append(String(localized: "networks.ts.address_hint")) }
            } else {
                parts.append(String(localized: "networks.picker.missing_hint"))
            }
            if proxySet { parts.append(String(localized: "networks.picker.proxy_ignored")) }
        } else {
            parts.append(String(localized: "networks.picker.direct_hint"))
        }
        if forGroup && networkId != nil { parts.append(String(localized: "networks.picker.group_hint")) }
        if networks.isEmpty && networkId == nil, let accountId, book.isSupported(accountId) {
            parts.append(String(localized: "networks.picker.no_networks"))
        }
        return parts.joined(separator: "\n")
    }
}

/// The "via Office · 23 ms" chip of a host row or card (nothing for direct hosts).
struct NetworkViaChip: View {
    let host: SshHost
    @ObservedObject private var book = NetworkBook.shared

    var body: some View {
        if let id = book.network(of: host) {
            if let name = book.name(host.accountId, id) {
                let test = book.test(of: host)
                Chip(text(name, id, test), test?.ok == false ? Brand.amber : Brand.blue)
                    .accessibilityIdentifier("via-chip")
            } else {
                Chip(String(localized: "networks.missing"), Brand.red)
            }
        }
    }

    private func text(_ name: String, _ id: String, _ test: HostTest?) -> String {
        if book.isTesting(host) { return String(localized: "networks.via \(name)") + " · …" }
        if let ms = Networks.viaLatency(test: test, networkId: id) {
            return String(localized: "networks.via_latency \(name) \(Int(ms))")
        }
        return String(localized: "networks.via \(name)")
    }
}

/// "Test through Office" in a host's menu: the server tests it through its
/// network (only when asked: never polled).
struct HostNetworkTestMenuItem: View {
    let host: SshHost
    let action: () -> Void
    @ObservedObject private var book = NetworkBook.shared

    var body: some View {
        if let id = book.network(of: host), book.isSupported(host.accountId), !host.isTelnet {
            Button(action: action) {
                Label("networks.test.host \(book.name(host.accountId, id) ?? String(localized: "networks.missing"))",
                      systemImage: "antenna.radiowaves.left.and.right")
            }
        }
    }
}

/// A host test from the server through its network, as the lists run it:
/// the result as a short text, or the fingerprint to trust first.
@MainActor
enum HostNetworkTester {
    enum Outcome {
        case done(String)
        case trust(fingerprint: String?)
    }

    static func run(_ host: SshHost, core: TermoakCore, trust: Bool) async -> Outcome {
        let book = NetworkBook.shared
        guard let api = book.api(host.accountId, core: core) else { return .done(String(localized: "error.not_logged_in")) }
        do {
            let t = try await book.testHost(api, host, trust: trust)
            let name = t.networkName ?? book.network(of: host).flatMap { book.name(host.accountId, $0) } ?? ""
            if t.ok { return .done(String(localized: "networks.test.ok_via \(name) \(Int(t.latencyMs ?? 0))")) }
            if t.errorCode == "host_key_unknown" && !trust { return .trust(fingerprint: t.fingerprint) }
            return .done(String(localized: "networks.test.failed_via \(name) \(hostTestErrorText(t))"))
        } catch {
            return .done(userMessage(error))
        }
    }
}

/// Runs the host tests of a list: shows how it went, and asks to trust an
/// unknown host key before testing again.
struct HostNetworkTests: ViewModifier {
    @Binding var testing: SshHost?
    let flash: (String) -> Void
    @EnvironmentObject private var model: AppModel
    @State private var trustAsk: (host: SshHost, fingerprint: String?)?

    func body(content: Content) -> some View {
        content
            .onChange(of: testing?.key) { _ in
                guard let host = testing else { return }
                run(host, trust: false)
            }
            .alert(Text("networks.test.trust_title"), isPresented: Binding(get: { trustAsk != nil }, set: { if !$0 { trustAsk = nil } })) {
                Button("networks.test.trust") {
                    if let h = trustAsk?.host { run(h, trust: true) }
                    trustAsk = nil
                }
                Button("common.cancel", role: .cancel) { trustAsk = nil }
            } message: {
                Text(verbatim: String(localized: "networks.test.trust_text \(trustAsk?.host.displayName ?? "")")
                     + (trustAsk?.fingerprint.map { "\n\n" + $0 } ?? ""))
            }
    }

    private func run(_ host: SshHost, trust: Bool) {
        let core = model.core
        Task { @MainActor in
            let outcome = await HostNetworkTester.run(host, core: core, trust: trust)
            testing = nil
            switch outcome {
            case .done(let text): flash(text)
            case .trust(let fp): trustAsk = (host, fp)
            }
        }
    }
}

extension View {
    func hostNetworkTests(_ testing: Binding<SshHost?>, flash: @escaping (String) -> Void) -> some View {
        modifier(HostNetworkTests(testing: testing, flash: flash))
    }
}

/// "via Office" in the terminal bar, for a terminal whose host goes
/// through a private network.
struct TerminalNetworkVia: View {
    let hostId: String?
    let accountId: String?
    var color: Color = .secondary
    @EnvironmentObject private var model: AppModel
    @State private var name: String?

    var body: some View {
        Group {
            if let name {
                Text("networks.via \(name)")
                    .font(.caption2)
                    .foregroundColor(color)
                    .lineLimit(1)
                    .accessibilityIdentifier("terminal-via")
            }
        }
        .onAppear { name = NetworkBook.resolve(core: model.core, hostId: hostId, accountId: accountId) }
    }
}
