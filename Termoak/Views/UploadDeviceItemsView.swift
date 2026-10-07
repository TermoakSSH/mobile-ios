import TermoakKit
import SwiftUI

/// After the first account is added: "Upload N items from this device to
/// your Personal vault?". Items marked "This device only" start unchecked.
struct UploadDeviceItemsView: View {
    let accountId: String

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss

    @State private var items: [DeviceItem] = []
    @State private var chosen: Set<String> = []
    @State private var running = false
    @State private var error: String?

    private struct DeviceItem: Identifiable {
        let id: String
        let name: String
        let icon: String
        let deviceOnly: Bool
    }

    private var targetName: String {
        let personal = account.vaults(of: accountId).first { $0.kind == .personal }
        return personal?.displayName ?? account.account(accountId)?.email ?? ""
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text("upload.text \(items.count) \(targetName)")
                        .fixedSize(horizontal: false, vertical: true)
                } footer: {
                    Text("upload.footer")
                }
                Section {
                    ForEach(items) { item in
                        Button { toggle(item.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: chosen.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(chosen.contains(item.id) ? .accentColor : .secondary)
                                Image(systemName: item.icon).foregroundColor(.secondary).frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: item.name).foregroundColor(.primary)
                                    if item.deviceOnly {
                                        Text("common.device_only").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("upload.items")
                        Spacer()
                        Button(chosen.count == items.count ? String(localized: "hosts.select.none") : String(localized: "hosts.select.all")) {
                            chosen = chosen.count == items.count ? [] : Set(items.map(\.id))
                        }
                        .font(.caption)
                    }
                }
                if let error {
                    Section { Text(error).foregroundColor(Brand.red) }
                }
            }
            .navigationTitle("upload.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("upload.not_now") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "upload.action \(chosen.count)")) { upload() }
                        .disabled(chosen.isEmpty || running)
                }
            }
            .disabled(running)
            .overlay { if running { ProgressView() } }
        }
        .onAppear(perform: load)
    }

    private func toggle(_ id: String) {
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
    }

    private func load() {
        let core = model.core
        let f = ItemFilter(accountIds: [], vaultIds: nil, includeDevice: true)
        var out: [DeviceItem] = []
        for h in (try? core.listHosts(filter: f)) ?? [] {
            out.append(DeviceItem(id: h.id, name: h.displayName, icon: "server.rack", deviceOnly: h.syncMode == .deviceOnly))
        }
        for g in (try? core.listGroups(filter: f)) ?? [] {
            out.append(DeviceItem(id: g.id, name: g.name, icon: "folder", deviceOnly: g.syncMode == .deviceOnly))
        }
        for k in (try? core.listKeys(filter: f)) ?? [] {
            out.append(DeviceItem(id: k.id, name: k.label, icon: "key", deviceOnly: k.syncMode == .deviceOnly))
        }
        for i in (try? core.listIdentities(filter: f)) ?? [] {
            out.append(DeviceItem(id: i.id, name: i.label, icon: "person.text.rectangle", deviceOnly: i.syncMode == .deviceOnly))
        }
        for s in (try? core.listSnippets(filter: f)) ?? [] {
            out.append(DeviceItem(id: s.id, name: s.name, icon: "chevron.left.forwardslash.chevron.right", deviceOnly: s.syncMode == .deviceOnly))
        }
        items = out
        chosen = Set(out.filter { !$0.deviceOnly }.map(\.id))
    }

    private func upload() {
        running = true
        error = nil
        let refs = items.filter { chosen.contains($0.id) }.map { ItemRef(accountId: nil, id: $0.id) }
        let core = model.core
        let target = accountId
        Task {
            defer { running = false }
            do {
                // Into the account's personal vault, with what they use.
                _ = try await core.transfer(items: refs, targetAccount: target, targetVault: nil, mode: .move, dryRun: false)
                account.reload()
                account.vaultChanged.send()
                account.sync(target)
                dismiss()
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}
