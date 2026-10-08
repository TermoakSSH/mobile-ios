import TermoakKit
import SwiftUI

/// The AI's memories of an account: facts it keeps between tasks (about you
/// or about a host), saved in its vault and synced. Add, edit and delete.
struct AiMemoriesView: View {
    /// The account (`nil`: the current one).
    let accountId: String?
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @State private var memories: [AiMemory] = []
    @State private var hosts: [SshHost] = []
    @State private var editing: MemoryEdit?
    @State private var deleting: AiMemory?
    @State private var error: String?

    private var owner: String? { accountId ?? account.current?.id }

    var body: some View {
        List {
            Section {
                if memories.isEmpty {
                    Text("ai.memories.empty").foregroundColor(.secondary)
                }
                ForEach(memories, id: \.id) { m in row(m) }
            } footer: {
                Text("ai.memories.footer")
            }
        }
        .navigationTitle("ai.memories")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = MemoryEdit(memory: nil) } label: { Image(systemName: "plus") }
                    .accessibilityLabel(Text("ai.memories.new"))
            }
        }
        .sheet(item: $editing, onDismiss: load) { e in
            MemoryEditor(original: e.memory, accountId: owner, hosts: hosts)
        }
        .confirmationDialog("ai.memories.delete.title", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("common.delete", role: .destructive) { if let m = deleting { delete(m) } }
        } message: { Text(deleting?.content ?? "") }
        .alert("common.error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: { Text(error ?? "") }
        .onAppear(perform: load)
        .onReceive(account.vaultChanged) { load() }
    }

    private func row(_ m: AiMemory) -> some View {
        let editable = m.access != .useOnly
        return Button { if editable { editing = MemoryEdit(memory: m) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.content).foregroundColor(.primary).lineLimit(4)
                if let h = hosts.first(where: { $0.id == m.hostId }) {
                    Label(h.displayName, systemImage: "server.rack").font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .swipeActions {
            if editable { Button("common.delete", role: .destructive) { deleting = m } }
        }
    }

    private func load() {
        guard let owner else {
            memories = []
            return
        }
        let filter = ItemFilter(accountIds: [owner], vaultIds: nil, includeDevice: false)
        memories = ((try? model.core.listMemories(filter: filter)) ?? []).sorted { $0.updatedAt > $1.updatedAt }
        hosts = ((try? model.core.listHosts(filter: filter)) ?? [])
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func delete(_ m: AiMemory) {
        do {
            try model.core.deleteMemory(id: m.id, accountId: m.accountId)
        } catch {
            self.error = userMessage(error)
        }
        load()
        account.sync()
    }
}

private struct MemoryEdit: Identifiable {
    let id = UUID()
    let memory: AiMemory?
}

/// A memory: what the AI should remember, and the host it is about.
private struct MemoryEditor: View {
    let original: AiMemory?
    let accountId: String?
    let hosts: [SshHost]
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var hostId: String?
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextEditor(text: $content).frame(minHeight: 120)
                } footer: {
                    Text("ai.memories.content_hint")
                }
                Picker("ai.memories.host", selection: $hostId) {
                    Text("ai.memories.no_host").tag(String?.none)
                    ForEach(hosts, id: \.id) { h in Text(verbatim: h.displayName).tag(Optional(h.id)) }
                }
                if let error { Text(error).foregroundColor(Brand.red) }
            }
            .navigationTitle(original == nil ? Text("ai.memories.new") : Text("ai.memories.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save", action: save)
                        .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            content = original?.content ?? ""
            hostId = original?.hostId
        }
    }

    private func save() {
        var m = original ?? AiMemory(id: "", content: "", updatedAt: 0, accountId: accountId)
        m.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        m.hostId = hostId
        do {
            _ = try model.core.saveMemory(memory: m)
            account.sync()
            dismiss()
        } catch {
            self.error = userMessage(error)
        }
    }
}
