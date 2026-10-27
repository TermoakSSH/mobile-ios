import TermoakKit
import SwiftUI

/// Vault → Encryption (0.7 phase 5c). Off: who gets the key now with their
/// fingerprints (Admins), what changes, the private networks warning (§9.3),
/// turn on. On: key version, your state, rotate when someone lost access,
/// members waiting with their fingerprints and the key-changed warning
/// (Confirm), turn off with the typed name.
struct VaultE2eeView: View {
    let accountId: String
    let vaultId: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @ObservedObject private var book = E2eeBook.shared
    @State private var state: E2eeVaultState?
    @State private var pending: [E2eeMember] = []
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var message: String?
    @State private var turningOff = false
    @State private var typed = ""
    @State private var settingUp = false
    @State private var unlocking = false

    private var vault: VaultInfo? { account.vaults.first { $0.id == vaultId && $0.accountId == accountId } }
    private var handle: AccountHandle? { try? model.core.account(accountId: accountId) }
    private var me: String? { account.account(accountId)?.userId }
    private var networks: Int {
        (try? model.core.listNetworks(filter: ItemFilter(accountIds: [accountId], vaultIds: [vaultId], includeDevice: false)).count) ?? 0
    }

    var body: some View {
        Form {
            if let v = vault {
                let st = book.status[accountId]
                let keyState = E2eeRules.keyState(v.e2eeFlags, setUp: st?.setUp ?? false, unlocked: st?.unlocked ?? false)
                if let message { Text(verbatim: message).foregroundColor(Brand.green) }
                if let e = v.e2ee {
                    Section {
                        E2eeBadge(badge: .e2ee)
                        Text("vault_e2ee.enabled")
                        Text("vault_e2ee.key_version \(String(e.keyVersion))").font(.caption).foregroundColor(.secondary)
                        stateText(keyState, fingerprint: st?.key?.fingerprint ?? "")
                        actionFor(keyState)
                    } header: { Text("vaults.tab.encryption") }
                    if e.rekeyNeeded {
                        Section {
                            Label("vault_e2ee.rekey_needed", systemImage: "exclamationmark.triangle").foregroundColor(Brand.amber)
                            if keyState == .holder { Button("vault_e2ee.rotate") { rotate() }.disabled(busy) }
                        }
                    }
                    if keyState == .holder && !pending.isEmpty {
                        Section {
                            Text("vault_e2ee.pending_hint").font(.caption).foregroundColor(.secondary)
                            ForEach(pending, id: \.userId) { m in
                                HStack {
                                    memberText(m, isMe: false)
                                    Spacer()
                                    Button("vault_e2ee.confirm") { confirm(m) }.disabled(busy).buttonStyle(.borderless)
                                }
                            }
                        } header: { Text("vault_e2ee.pending_title") }
                    }
                    consequences(on: true)
                    networksWarning
                    if keyState == .holder && !e.rekeyNeeded { Button("vault_e2ee.rotate") { rotate() }.disabled(busy) }
                    if v.role == .manager && keyState == .holder {
                        Button("vault_e2ee.turn_off", role: .destructive) { turningOff = true }.disabled(busy)
                    }
                } else {
                    Section { Text("vault_e2ee.off_intro").font(.footnote) }
                    if v.role != .manager {
                        Text("vault_e2ee.managers_only").foregroundColor(.secondary)
                    } else if keyState == .setUpFirst || !(st?.setUp ?? false) {
                        Text("vault_e2ee.setup_first").foregroundColor(Brand.amber)
                        Button("e2ee.setup.button") { settingUp = true }
                    } else if !(st?.unlocked ?? false) {
                        Text("vault_e2ee.unlock_first").foregroundColor(Brand.amber)
                        Button("e2ee.unlock.button") { unlocking = true }
                    } else {
                        consequences(on: false)
                        networksWarning
                        if let state {
                            Section {
                                Text("vault_e2ee.recipients_hint").font(.caption).foregroundColor(.secondary)
                                ForEach(state.recipients, id: \.userId) { m in
                                    let isMe = m.userId == me
                                    Toggle(isOn: Binding(get: { isMe || selected.contains(m.userId) }, set: { on in if on { selected.insert(m.userId) } else { selected.remove(m.userId) } })) {
                                        memberText(m, isMe: isMe)
                                    }
                                    .disabled(isMe)
                                }
                                if !state.withoutKey.isEmpty { Text("vault_e2ee.without_key \(state.withoutKey.count)").font(.caption).foregroundColor(.secondary) }
                                if state.items > 0 { Text("vault_e2ee.items \(Int(state.items))").font(.caption).foregroundColor(.secondary) }
                            } header: { Text("vault_e2ee.recipients_title") }
                            Button("vault_e2ee.turn_on") { turnOn() }.disabled(busy).accessibilityIdentifier("e2ee-turn-on")
                        } else {
                            ProgressView()
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(Text("vaults.tab.encryption"))
        .task(id: "\(vault?.e2ee?.keyVersion ?? 0)/\(book.unlocked(accountId))") { await load() }
        .sheet(isPresented: $settingUp) { PhraseFlowView(accountId: accountId, kind: .setup) { _ in settingUp = false }.environmentObject(model) }
        .sheet(isPresented: $unlocking) { UnlockView(accountId: accountId) { unlocking = false }.environmentObject(model).environmentObject(account) }
        .alert(Text("vault_e2ee.off_title"), isPresented: $turningOff) {
            TextField(vault?.name ?? "", text: $typed)
            Button("vault_e2ee.turn_off", role: .destructive) {
                guard typed.trimmingCharacters(in: .whitespaces) == vault?.name else { message = String(localized: "vault_e2ee.off_mismatch"); return }
                act { try await $0.e2eeDisableVault(vaultId: vaultId); return String(localized: "vault_e2ee.disabled") }
            }
            Button("common.cancel", role: .cancel) {}
        } message: { Text("vault_e2ee.off_message") }
    }

    @ViewBuilder private func stateText(_ k: E2eeRules.KeyState, fingerprint: String) -> some View {
        switch k {
        case .noKeyRole: Text("vault_e2ee.no_key_role").font(.caption)
        case .setUpFirst: Text("vault_e2ee.setup_to_get_key").font(.caption)
        case .waiting: Text("vault_e2ee.waiting_for_key \(fingerprint)").font(.caption)
        case .unlockFirst: Text("vault_e2ee.unlock_first").font(.caption)
        default: EmptyView()
        }
    }

    @ViewBuilder private func actionFor(_ k: E2eeRules.KeyState) -> some View {
        switch k {
        case .setUpFirst: Button("e2ee.setup.button") { settingUp = true }
        case .unlockFirst: Button("e2ee.unlock.button") { unlocking = true }
        default: EmptyView()
        }
    }

    private func memberText(_ m: E2eeMember, isMe: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: isMe ? String(localized: "vault_e2ee.you \(m.email)") : (m.name.isEmpty ? m.email : m.name))
            if !isMe && !m.name.isEmpty { Text(verbatim: m.email).font(.caption).foregroundColor(.secondary) }
            Text(verbatim: m.fingerprint).font(.caption.monospaced())
            if m.keyChanged { Text("vault_e2ee.key_changed").font(.caption).foregroundColor(Brand.red) }
        }
    }

    private func consequences(on: Bool) -> some View {
        Section {
            ForEach(["vault_e2ee.consequence.reveal", "vault_e2ee.consequence.server_sessions", "vault_e2ee.consequence.jit", "vault_e2ee.consequence.ai",
                     "vault_e2ee.consequence.moves", "vault_e2ee.consequence.certificates", "vault_e2ee.consequence.metadata"], id: \.self) { k in
                Text(LocalizedStringKey(k)).font(.caption)
            }
        } header: { Text(on ? "vault_e2ee.on_consequences_title" : "vault_e2ee.consequences_title") }
    }

    @ViewBuilder private var networksWarning: some View {
        let n = networks
        if n > 0 { Label("vault_e2ee.networks_warning \(n)", systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(Brand.amber) }
    }

    private func load() async {
        guard let h = handle, let v = vault else { return }
        let unlocked = book.unlocked(accountId)
        if v.e2ee == nil && v.role == .manager && unlocked {
            state = try? await h.e2eeVaultState(vaultId: vaultId)
            selected = Set(state?.recipients.map(\.userId) ?? [])
        }
        if let e = v.e2ee, e.hasWrap, unlocked, e.pendingMembers > 0 {
            pending = (try? await h.e2eePendingMembers(vaultId: vaultId)) ?? []
        } else {
            pending = []
        }
    }

    private func turnOn() {
        let include = Array(selected.union(me.map { [$0] } ?? []))
        act { _ = try await $0.e2eeEnableVault(vaultId: vaultId, include: include); return String(localized: "vault_e2ee.enabled") }
    }

    private func rotate() {
        act { String(localized: "vault_e2ee.rotated \(String(try await $0.e2eeRotateVault(vaultId: vaultId)))") }
    }

    private func confirm(_ m: E2eeMember) {
        act { String(localized: "vault_e2ee.confirmed \(Int(try await $0.e2eeAddMembers(vaultId: vaultId, userIds: [m.userId])))") }
    }

    private func act(_ f: @escaping (AccountHandle) async throws -> String?) {
        guard let h = handle else { return }
        busy = true
        Task {
            defer { busy = false }
            do { message = try await f(h) } catch { message = userMessage(error) }
            if let report = try? await h.syncNow() { _ = report }
            account.reload()
            account.vaultChanged.send()
            await load()
        }
    }
}
