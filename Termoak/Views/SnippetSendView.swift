import TermoakKit
import SwiftUI

/// Where a snippet is sent to from the snippets list.
enum SnippetTarget: Hashable {
    /// Hosts (or whole groups) picked here: a terminal to each one.
    case servers
    /// The terminals already open.
    case openTerminals
}

struct SnippetSendItem: Identifiable {
    let id = UUID()
    let snippet: Snippet
    let target: SnippetTarget
}

/// Runs (or pastes) a snippet on several servers at once: pick hosts or a
/// group, a terminal opens to each one and the snippet goes as soon as it is
/// connected; then a summary of how it went. It can also go to every
/// terminal that is already open.
struct SnippetSendView: View {
    let snippet: Snippet
    var initialTarget: SnippetTarget = .servers

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var sessions: Sessions
    @Environment(\.dismiss) private var dismiss

    @State private var target: SnippetTarget = .servers
    @State private var run = true
    @State private var values: [String: String] = [:]
    @State private var hosts: [SshHost] = []
    @State private var groups: [HostGroup] = []
    @State private var chosenHosts: Set<String> = []
    @State private var chosenOpen: Set<UUID> = []
    @State private var query = ""
    @State private var batch: SnippetBatch?
    @State private var loaded = false

    private var variables: [String] { snippetVariables(script: snippet.script) }

    var body: some View {
        NavigationView {
            Group {
                if let batch {
                    SnippetBatchSummary(batch: batch) { showTerminals() }
                } else {
                    form
                }
            }
            .navigationTitle(snippet.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if batch == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(sendTitle) { send() }
                            .disabled(chosenCount == 0)
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
                }
            }
        }
        .onAppear(perform: load)
    }

    // MARK: Form

    private var form: some View {
        Form {
            Section {
                Text(verbatim: snippet.script)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(8)
            } header: {
                Text("snippets.send.command")
            }
            if !variables.isEmpty {
                Section("snippets.send.variables") {
                    ForEach(variables, id: \.self) { name in
                        TextField(name, text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }
            Section {
                Picker("snippets.send.mode", selection: $run) {
                    Text("common.run").tag(true)
                    Text("common.paste").tag(false)
                }
                .pickerStyle(.segmented)
                Picker("snippets.send.target", selection: $target) {
                    Text("snippets.send.target.servers").tag(SnippetTarget.servers)
                    Text("snippets.send.target.open").tag(SnippetTarget.openTerminals)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(run ? String(localized: "snippets.send.mode.run_footer") : String(localized: "snippets.send.mode.paste_footer"))
            }
            if target == .servers {
                serverSections
            } else {
                openSection
            }
        }
        .searchable(text: $query, prompt: Text("hosts.search.prompt"))
    }

    @ViewBuilder private var serverSections: some View {
        if !groups.isEmpty && !searching {
            Section("hosts.groups") {
                ForEach(groups, id: \.id) { g in
                    let ids = hostIds(in: g)
                    let picked = ids.filter { chosenHosts.contains($0) }.count
                    Button { toggleGroup(ids) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill").foregroundColor(hexColor(g.color) ?? .accentColor)
                            Text(g.name).foregroundColor(.primary)
                            Spacer()
                            Text(verbatim: "\(picked)/\(ids.count)").font(.footnote).foregroundColor(.secondary)
                            check(!ids.isEmpty && picked == ids.count)
                        }
                    }
                    .disabled(ids.isEmpty)
                }
            }
        }
        Section {
            if hosts.isEmpty && loaded {
                Text("snippets.send.no_hosts").foregroundColor(.secondary)
            }
            ForEach(filteredHosts, id: \.id) { h in
                Button { toggle(h.id) } label: {
                    HStack(spacing: 12) {
                        HostIcon(host: h, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.label.isEmpty ? h.address : h.label).foregroundColor(.primary).lineLimit(1)
                            Text(h.address).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        check(chosenHosts.contains(h.id))
                    }
                }
            }
        } header: {
            HStack {
                Text("nav.hosts")
                Spacer()
                if !filteredHosts.isEmpty {
                    Button(allFilteredChosen ? String(localized: "hosts.select.none") : String(localized: "hosts.select.all")) {
                        let ids = filteredHosts.map(\.id)
                        if allFilteredChosen { chosenHosts.subtract(ids) } else { chosenHosts.formUnion(ids) }
                    }
                    .font(.footnote)
                    .textCase(nil)
                }
            }
        } footer: {
            Text("snippets.send.servers.footer")
        }
    }

    private var openSection: some View {
        Section {
            if sessions.open.isEmpty {
                Text("snippets.send.no_open").foregroundColor(.secondary)
            }
            ForEach(sessions.open) { s in
                let ready = canTake(s)
                Button { toggleOpen(s.id) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: s.persistent ? "icloud" : "terminal")
                            .foregroundColor(.secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title ?? s.label).foregroundColor(.primary).lineLimit(1)
                            if !ready {
                                Text("snippets.send.status.not_connected").font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        check(chosenOpen.contains(s.id))
                    }
                }
                .disabled(!ready)
            }
        } footer: {
            Text("snippets.send.open.footer")
        }
    }

    private func check(_ on: Bool) -> some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .foregroundColor(on ? .accentColor : .secondary)
            .font(.title3)
            .accessibilityLabel(on ? Text("common.on") : Text("common.off"))
    }

    // MARK: Data

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var filteredHosts: [SshHost] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return hosts }
        return hosts.filter { h in
            [h.label, h.address, h.settings.username ?? "", h.tags.joined(separator: " ")].contains { $0.lowercased().contains(q) }
        }
    }

    private var allFilteredChosen: Bool {
        !filteredHosts.isEmpty && filteredHosts.allSatisfy { chosenHosts.contains($0.id) }
    }

    private var chosenCount: Int {
        switch target {
        case .servers: return hosts.filter { chosenHosts.contains($0.id) }.count
        case .openTerminals: return sessions.open.filter { chosenOpen.contains($0.id) && canTake($0) }.count
        }
    }

    private var sendTitle: String {
        run ? String(localized: "snippets.send.run_count \(chosenCount)")
            : String(localized: "snippets.send.paste_count \(chosenCount)")
    }

    /// An open terminal that can take the snippet now.
    private func canTake(_ s: TerminalSession) -> Bool {
        !s.asleep && s.state == .connected && s.canWrite
    }

    /// The hosts of a group and of the groups inside it.
    private func hostIds(in g: HostGroup) -> [String] {
        var ids = Set([g.id])
        var grew = true
        while grew {
            let more = groups.filter { g in g.parentId.map { ids.contains($0) } == true && !ids.contains(g.id) }.map(\.id)
            grew = !more.isEmpty
            ids.formUnion(more)
        }
        return hosts.filter { h in h.groupId.map { ids.contains($0) } == true }.map(\.id)
    }

    private func toggle(_ id: String) {
        if chosenHosts.contains(id) { chosenHosts.remove(id) } else { chosenHosts.insert(id) }
    }

    private func toggleGroup(_ ids: [String]) {
        if ids.allSatisfy({ chosenHosts.contains($0) }) { chosenHosts.subtract(ids) } else { chosenHosts.formUnion(ids) }
    }

    private func toggleOpen(_ id: UUID) {
        if chosenOpen.contains(id) { chosenOpen.remove(id) } else { chosenOpen.insert(id) }
    }

    private func load() {
        guard !loaded else { return }
        hosts = ((try? model.core.listHosts()) ?? []).sorted { a, b in
            if a.favorite != b.favorite { return a.favorite }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
        groups = ((try? model.core.listGroups()) ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        target = initialTarget
        chosenOpen = Set(sessions.open.filter(canTake).map(\.id))
        loaded = true
    }

    private func send() {
        let text = variables.isEmpty ? snippet.script
            : ((try? renderSnippet(script: snippet.script, values: values)) ?? snippet.script)
        switch target {
        case .servers:
            let chosen = hosts.filter { chosenHosts.contains($0.id) }
            guard !chosen.isEmpty else { return }
            batch = SnippetBatch(text: text, run: run, terminals: sessions.openInBackground(chosen))
        case .openTerminals:
            let chosen = sessions.open.filter { chosenOpen.contains($0.id) && canTake($0) }
            guard !chosen.isEmpty else { return }
            batch = SnippetBatch(text: text, run: run, terminals: chosen)
        }
    }

    /// Closes and shows the terminals (side by side on an iPad).
    private func showTerminals() {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !sessions.open.isEmpty { sessions.showing = true }
        }
    }
}

/// How the sending went in each terminal.
private struct SnippetBatchSummary: View {
    @ObservedObject var batch: SnippetBatch
    let onShowTerminals: () -> Void

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    if batch.finished {
                        Image(systemName: batch.sentCount == batch.items.count ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundColor(batch.sentCount == batch.items.count ? Brand.green : Brand.amber)
                    } else {
                        ProgressView()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(batch.run ? String(localized: "snippets.send.summary.run \(batch.sentCount) \(batch.items.count)")
                             : String(localized: "snippets.send.summary.paste \(batch.sentCount) \(batch.items.count)"))
                            .font(.headline)
                        if batch.needsYou {
                            Text("snippets.send.summary.needs_you").font(.footnote).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
                Button(action: onShowTerminals) {
                    Label("snippets.send.show_terminals", systemImage: "terminal")
                }
            }
            Section {
                ForEach(batch.items) { item in
                    HStack(spacing: 12) {
                        icon(item.status).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).lineLimit(1)
                            Text(text(item.status)).font(.caption).foregroundColor(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder private func icon(_ s: SnippetBatch.Status) -> some View {
        switch s {
        case .connecting: ProgressView().scaleEffect(0.7)
        case .waitingForYou: Image(systemName: "key.fill").foregroundColor(Brand.amber)
        case .sent: Image(systemName: "checkmark.circle.fill").foregroundColor(Brand.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundColor(Brand.red)
        case .skipped: Image(systemName: "minus.circle").foregroundColor(.secondary)
        }
    }

    private func text(_ s: SnippetBatch.Status) -> String {
        switch s {
        case .connecting: return String(localized: "terminal.state.connecting")
        case .waitingForYou: return String(localized: "snippets.send.status.waiting")
        case .sent: return batch.run ? String(localized: "snippets.send.status.ran") : String(localized: "snippets.send.status.pasted")
        case .failed(let why): return why
        case .skipped(let why): return why
        }
    }
}
