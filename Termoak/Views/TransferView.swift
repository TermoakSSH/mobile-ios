import TermoakKit
import SwiftUI

/// Items to move or copy to another vault (all from the same place).
struct TransferRequest: Identifiable {
    let id = UUID()
    let items: [ItemRef]
    /// Names to show, by item id.
    let names: [String]
    let from: ItemPlace
    let mode: TransferMode

    init(hosts: [SshHost], from: ItemPlace, mode: TransferMode) {
        items = hosts.map { ItemRef(accountId: $0.accountId, id: $0.id) }
        names = hosts.map(\.displayName)
        self.from = from
        self.mode = mode
    }

    init(items: [ItemRef], names: [String], from: ItemPlace, mode: TransferMode) {
        self.items = items
        self.names = names
        self.from = from
        self.mode = mode
    }
}

/// "Move to…" / "Copy to…": choose the vault (or This device, or another
/// account), see what else goes with the items (a key the host uses...)
/// and confirm. The plan comes from the engine (`dryRun`).
struct TransferView: View {
    let request: TransferRequest
    /// Done (after moving or copying).
    var onDone: (() -> Void)? = nil

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss

    @State private var target: ItemPlace?
    @State private var plan: TransferResult?
    @State private var planning = false
    @State private var running = false
    @State private var error: String?
    @State private var names: [String: String] = [:]

    private var moving: Bool { request.mode == .move }

    private var targets: [ItemPlace] {
        account.places.filter { $0 != request.from }
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    ForEach(Array(request.names.prefix(6).enumerated()), id: \.offset) { _, name in
                        Label(name, systemImage: "server.rack")
                    }
                    if request.names.count > 6 {
                        Text("transfer.more \(request.names.count - 6)").foregroundColor(.secondary)
                    }
                } header: {
                    Text(verbatim: String(localized: "transfer.from \(account.placeTitle(request.from))"))
                }

                Section {
                    if targets.isEmpty {
                        Text("transfer.no_targets").foregroundColor(.secondary)
                    }
                    ForEach(targets) { p in
                        Button { choose(p) } label: {
                            HStack {
                                Image(systemName: p.accountId == nil ? "iphone" : "lock.shield")
                                    .foregroundColor(p.accountId == nil ? .secondary : vaultColor(account.vault(p.accountId, p.vaultId)))
                                    .frame(width: 24)
                                Text(verbatim: account.placeTitle(p)).foregroundColor(.primary)
                                Spacer()
                                if target == p { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                            }
                        }
                    }
                } header: {
                    Text("transfer.to")
                } footer: {
                    if moving { Text("transfer.move.footer") } else { Text("transfer.copy.footer") }
                }

                if target != nil {
                    Section("transfer.plan") {
                        if planning {
                            HStack { ProgressView(); Text("transfer.planning").foregroundColor(.secondary) }
                        } else if let plan {
                            let lines = summary(plan)
                            if lines.isEmpty {
                                Text("transfer.plan.nothing").foregroundColor(.secondary)
                            }
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Label(line.text, systemImage: line.icon)
                                    .foregroundColor(line.warning ? Brand.amber : .primary)
                            }
                        }
                    }
                }

                if let error {
                    Section { Text(error).foregroundColor(Brand.red) }
                }
            }
            .navigationTitle(moving ? String(localized: "transfer.move_to") : String(localized: "transfer.copy_to"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(moving ? String(localized: "transfer.move") : String(localized: "transfer.copy")) { run() }
                        .disabled(target == nil || plan == nil || planning || running)
                }
            }
            .disabled(running)
            .overlay { if running { ProgressView() } }
        }
        .onAppear(perform: loadNames)
    }

    private func choose(_ p: ItemPlace) {
        target = p
        plan = nil
        error = nil
        planning = true
        let core = model.core
        let r = request
        Task {
            defer { planning = false }
            do {
                let result = try await core.transfer(items: r.items, targetAccount: p.accountId, targetVault: p.vaultId,
                                                     mode: r.mode, dryRun: true)
                if target == p { plan = result }
            } catch {
                if target == p { self.error = userMessage(error) }
            }
        }
    }

    private func run() {
        guard let p = target else { return }
        running = true
        error = nil
        let core = model.core
        let r = request
        Task {
            defer { running = false }
            do {
                _ = try await core.transfer(items: r.items, targetAccount: p.accountId, targetVault: p.vaultId,
                                            mode: r.mode, dryRun: false)
                account.rememberPlace(p)
                account.reload()
                account.vaultChanged.send()
                account.sync()
                dismiss()
                onDone?()
            } catch {
                self.error = userMessage(error)
            }
        }
    }

    // ----- Plan -----

    private struct Line {
        let text: String
        let icon: String
        var warning = false
    }

    private func summary(_ r: TransferResult) -> [Line] {
        var out: [Line] = []
        for m in r.moved {
            out.append(Line(text: String(localized: "transfer.plan.moved \(kindTitle(m.kind)) \(name(m.id))"), icon: "arrow.right"))
        }
        for c in r.copied {
            out.append(Line(text: String(localized: "transfer.plan.copied \(kindTitle(c.kind)) \(name(c.fromId))"), icon: "plus.square.on.square"))
        }
        for c in r.reused {
            out.append(Line(text: String(localized: "transfer.plan.reused \(kindTitle(c.kind)) \(name(c.fromId))"), icon: "link"))
        }
        for d in r.detached {
            out.append(Line(text: String(localized: "transfer.plan.detached \(kindTitle(d.kind)) \(name(d.id))"),
                            icon: "scissors", warning: true))
        }
        for w in r.warnings {
            out.append(Line(text: String(localized: "transfer.plan.warning \(name(w.id)) \(w.code)"),
                            icon: "exclamationmark.triangle", warning: true))
        }
        return out
    }

    private func name(_ id: String) -> String {
        names[id] ?? String(id.prefix(8))
    }

    private func kindTitle(_ kind: String) -> String {
        switch kind {
        case "host": return String(localized: "transfer.kind.host")
        case "group": return String(localized: "transfer.kind.group")
        case "identity": return String(localized: "transfer.kind.identity")
        case "key": return String(localized: "transfer.kind.key")
        case "snippet": return String(localized: "transfer.kind.snippet")
        case "forward": return String(localized: "transfer.kind.forward")
        case "known_host": return String(localized: "transfer.kind.known_host")
        case "memory": return String(localized: "transfer.kind.memory")
        default: return kind
        }
    }

    /// Names of everything that may show up in the plan.
    private func loadNames() {
        let core = model.core
        let f = ItemFilter(accountIds: nil, vaultIds: nil, includeDevice: true)
        var n: [String: String] = [:]
        for h in (try? core.listHosts(filter: f)) ?? [] { n[h.id] = h.displayName }
        for g in (try? core.listGroups(filter: f)) ?? [] { n[g.id] = g.name }
        for k in (try? core.listKeys(filter: f)) ?? [] { n[k.id] = k.label }
        for i in (try? core.listIdentities(filter: f)) ?? [] { n[i.id] = i.label }
        for s in (try? core.listSnippets(filter: f)) ?? [] { n[s.id] = s.name }
        for t in (try? core.listForwards(hostId: nil, filter: f)) ?? [] { n[t.id] = t.label }
        for k in (try? core.listKnownHosts(filter: f)) ?? [] { n[k.id] = k.host }
        names = n
    }
}
