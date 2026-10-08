import TermoakKit
import SwiftUI
import UniformTypeIdentifiers

/// Import hosts, like the desktop's import dialog: a file picked in Files
/// (or pasted text) from Termoak (JSON), a CSV, Termius, PuTTY (.reg),
/// MobaXterm, SecureCRT, ZOC or an OpenSSH config. The format is detected;
/// the preview lists each host with what will happen to it (new, already
/// there, repeated), a CSV's columns can be chosen, a Termoak export's
/// secrets opened with its passphrase, and everything goes into This
/// device or a vault, under a group if you want.
struct ImportView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @StateObject private var flow = ImportFlow()
    @State private var picking = false
    @State private var pasted = ""
    @FocusState private var typing: Bool

    var body: some View {
        NavigationView {
            Form { content }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if !flow.finished {
                            Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) { confirmButton }
                }
                .disabled(flow.busy && !flow.loaded)
        }
        .navigationViewStyle(.stack)
        .onAppear {
            flow.core = model.core
            flow.place = account.defaultPlace
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in read(result) }
        .alert("common.error", isPresented: Binding(get: { flow.error != nil }, set: { if !$0 { flow.error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: { Text(flow.error ?? "") }
    }

    private var title: String {
        if flow.finished { return String(localized: "import.done.title") }
        guard flow.loaded else { return String(localized: "import.title") }
        return String(localized: "import.from \(flow.format.title)")
    }

    @ViewBuilder private var confirmButton: some View {
        if flow.finished {
            Button("common.done") { dismiss() }
        } else if flow.loaded {
            Button(String(localized: "import.run \(flow.importCount)")) { run() }
                .disabled(flow.importCount == 0 || flow.busy || flow.needsAddressColumn)
        } else {
            Button("import.read") { readPasted() }
                .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder private var content: some View {
        if flow.finished {
            ImportDoneSections(flow: flow)
        } else if flow.loaded {
            loadedSections
        } else {
            sourceSections
        }
    }

    // MARK: Choosing what to import

    @ViewBuilder private var sourceSections: some View {
        Section {
            Button { picking = true } label: { Label("import.choose_file", systemImage: "folder") }
            if flow.busy { ProgressView() }
        } footer: {
            Text("import.formats")
        }
        Section {
            pasteEditor
        } header: {
            Text("import.paste")
        } footer: {
            Text("import.paste.footer")
        }
    }

    private var pasteEditor: some View {
        ZStack(alignment: .topLeading) {
            if pasted.isEmpty {
                Text(verbatim: "Host web\n  HostName 203.0.113.10\n  User deploy")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $pasted)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 140, maxHeight: 260)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($typing)
                .accessibilityLabel(Text("import.paste"))
        }
    }

    // MARK: The preview

    @ViewBuilder private var loadedSections: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: flow.isSshConfig ? "doc.text" : "doc")
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: flow.format.title).font(.body.weight(.medium))
                    if !flow.fileName.isEmpty {
                        Text(verbatim: flow.fileName).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if flow.busy { ProgressView() }
            }
            Button { flow.reset() } label: { Label("import.choose_other", systemImage: "arrow.uturn.backward") }
        }
        if flow.needsPassphrase || flow.unlocked {
            ImportPassphraseSection(flow: flow)
        }
        if let mapping = flow.mapping, let preview = flow.preview {
            ImportColumnsSection(flow: flow, mapping: mapping, preview: preview)
        }
        ImportTargetSection(flow: flow)
        if flow.isSshConfig {
            if let report = flow.sshReport { SshConfigPreviewSections(report: report) }
        } else {
            ImportHostsSections(flow: flow)
        }
    }

    // MARK: Actions

    private func read(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            Task { await flow.load(data, fileName: url.lastPathComponent) }
        } catch {
            flow.error = String(localized: "import.read_failed")
        }
    }

    private func readPasted() {
        typing = false
        let text = pasted
        Task { await flow.load(Data(text.utf8), fileName: "") }
    }

    private func run() {
        Task {
            guard await flow.run() else { return }
            account.sync()
            account.vaultChanged.send()
        }
    }
}

/// A Termoak export with passwords and keys sealed by a passphrase.
private struct ImportPassphraseSection: View {
    @ObservedObject var flow: ImportFlow
    @State private var passphrase = ""
    @State private var wrong = false

    var body: some View {
        Section {
            if flow.unlocked {
                Label("import.secrets_unlocked", systemImage: "lock.open")
                    .foregroundColor(Brand.green)
            } else {
                SecureField("import.passphrase", text: $passphrase)
                    .textContentType(.password)
                    .onSubmit(unlock)
                Button("import.unlock", action: unlock)
                    .disabled(passphrase.isEmpty || flow.busy)
            }
        } footer: {
            if wrong {
                Text("import.wrong_passphrase").foregroundColor(.red)
            } else if !flow.unlocked {
                Text("import.secrets_locked")
            }
        }
    }

    private func unlock() {
        let text = passphrase
        Task {
            wrong = !(await flow.unlock(text))
            if !wrong { passphrase = "" }
        }
    }
}

/// The columns of a CSV: which field each one feeds, with an example.
private struct ImportColumnsSection: View {
    @ObservedObject var flow: ImportFlow
    let mapping: CsvMapping
    let preview: ImportPreview

    var body: some View {
        let names = preview.csvColumns()
        let sample = preview.csvSample(max: 4)
        Section {
            Toggle("import.has_header", isOn: Binding(get: { mapping.hasHeader }, set: { on in
                flow.setMapping(CsvMapping(hasHeader: on, columns: mapping.columns))
            }))
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                column(i, name, example: ImportPlan.example(column: i, sample: sample, hasHeader: mapping.hasHeader))
            }
        } header: {
            Text("import.columns")
        } footer: {
            if flow.needsAddressColumn {
                Text("import.needs_address").foregroundColor(.red)
            }
        }
    }

    private func column(_ i: Int, _ name: String, example: String?) -> some View {
        Picker(selection: Binding(get: { ImportPlan.field(ofColumn: i, in: mapping.pairs) ?? "" }, set: { key in
            flow.setMapping(mapping.assigning(CsvField(key: key), toColumn: i))
        })) {
            Text("import.column_none").tag("")
            ForEach(CsvField.all, id: \.key) { f in Text(f.title).tag(f.key) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                if let example {
                    Text(verbatim: example).font(.caption.monospaced()).foregroundColor(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// Where it goes: This device or a vault, a group and the duplicates.
private struct ImportTargetSection: View {
    @ObservedObject var flow: ImportFlow
    @EnvironmentObject private var account: Accounts

    var body: some View {
        Section {
            if account.places.count > 1 {
                Picker("import.target", selection: $flow.place) {
                    ForEach(account.places) { p in Text(verbatim: account.placeTitle(p)).tag(p) }
                }
                .onChange(of: flow.place) { _ in Task { await flow.placeChanged() } }
            }
            Picker("import.group", selection: $flow.group) {
                Text("import.group.none").tag(ImportGroupChoice.none)
                ForEach(flow.groups) { g in Text(verbatim: g.path).tag(ImportGroupChoice.existing(g.id)) }
                Text("import.group.new").tag(ImportGroupChoice.new)
            }
            .onChange(of: flow.group) { _ in if flow.isSshConfig { flow.sshPreview() } }
            if flow.group == .new {
                TextField("import.group.name", text: $flow.newGroup)
                    .onSubmit { if flow.isSshConfig { flow.sshPreview() } }
            }
            if !flow.isSshConfig && flow.duplicateCount > 0 {
                Picker("import.duplicates", selection: $flow.policy) {
                    ForEach(ImportDupChoice.allCases) { Text($0.title).tag($0) }
                }
            }
        } footer: {
            Text("import.target.footer")
        }
    }
}

/// The hosts of the file (tap one to leave it out), what the file brings
/// besides, and the warnings.
private struct ImportHostsSections: View {
    @ObservedObject var flow: ImportFlow

    var body: some View {
        Section {
            counts
            if flow.hosts.isEmpty && !flow.busy {
                Text("import.nothing").foregroundColor(.secondary)
            }
        }
        if !flow.hosts.isEmpty {
            Section("import.section.file_hosts") {
                ForEach(flow.hosts, id: \.index) { h in row(h) }
            }
        }
        if !flow.warnings.isEmpty {
            Section("import.section.warnings") {
                ForEach(Array(flow.warnings.enumerated()), id: \.offset) { _, w in
                    Text(verbatim: ImportPlan.warningText(code: w.code, params: w.params, fallback: w.message))
                        .font(.footnote)
                }
            }
        }
    }

    @ViewBuilder private var counts: some View {
        let p = flow.preview
        VStack(alignment: .leading, spacing: 6) {
            CountLine(text: String(localized: "import.pill.hosts \(flow.hosts.count)"), color: .accentColor, n: flow.hosts.count)
            CountLine(text: String(localized: "import.pill.dups \(flow.duplicateCount)"), color: Brand.amber, n: flow.duplicateCount)
            CountLine(text: String(localized: "import.pill.groups \(Int(p?.groupCount() ?? 0))"), color: .accentColor, n: Int(p?.groupCount() ?? 0))
            CountLine(text: String(localized: "import.pill.keys \(Int(p?.keyCount() ?? 0))"), color: .accentColor, n: Int(p?.keyCount() ?? 0))
            CountLine(text: String(localized: "import.pill.identities \(Int(p?.identityCount() ?? 0))"), color: .accentColor, n: Int(p?.identityCount() ?? 0))
            CountLine(text: String(localized: "import.pill.snippets \(Int(p?.snippetCount() ?? 0))"), color: .accentColor, n: Int(p?.snippetCount() ?? 0))
            CountLine(text: String(localized: "import.count.warnings \(flow.warnings.count)"), color: Brand.amber, n: flow.warnings.count)
        }
    }

    private func row(_ h: ImportHostPreview) -> some View {
        let status = flow.status(h)
        let included = !flow.excluded.contains(h.index)
        return Button { flow.toggle(h) } label: {
            HStack(spacing: 12) {
                Image(systemName: included ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(included ? .accentColor : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: h.label.isEmpty ? h.address : h.label).foregroundColor(.primary).lineLimit(1)
                        if h.hasPassword { Image(systemName: "key.fill").font(.caption2).foregroundColor(.secondary) }
                    }
                    Text(verbatim: h.group.map { "\(h.target) · \($0)" } ?? h.target)
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    Text(verbatim: status.text)
                        .font(.caption)
                        .foregroundColor(status.imports ? (status.isUpdate ? Brand.amber : Brand.green) : .secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(included ? .isSelected : [])
    }
}

/// "● 3 hosts in the file" (nothing when there are none).
struct CountLine: View {
    let text: String
    let color: Color
    let n: Int

    var body: some View {
        if n > 0 {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(verbatim: text).font(.subheadline)
            }
        }
    }
}

/// What an ssh_config would do: hosts, jump hosts, keys and tunnels, and
/// the hosts it creates, skips and warns about.
private struct SshConfigPreviewSections: View {
    let report: SshConfigImportReport

    var body: some View {
        Section("import.preview") {
            if report.hostsCreated.isEmpty {
                Text("import.nothing").foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                CountLine(text: String(localized: "import.count.hosts \(report.hostsCreated.count)"), color: Brand.green, n: report.hostsCreated.count)
                CountLine(text: String(localized: "import.count.jumps \(report.jumpHostsCreated.count)"), color: .accentColor, n: report.jumpHostsCreated.count)
                CountLine(text: String(localized: "import.count.keys \(report.keysImported.count)"), color: .accentColor, n: report.keysImported.count)
                CountLine(text: String(localized: "import.count.tunnels \(Int(report.forwardsCreated))"), color: .accentColor, n: Int(report.forwardsCreated))
                CountLine(text: String(localized: "import.count.skipped \(report.hostsSkipped.count)"), color: Brand.amber, n: report.hostsSkipped.count)
                CountLine(text: String(localized: "import.count.warnings \(report.warnings.count)"), color: Brand.amber, n: report.warnings.count)
            }
        }
        if !report.hostsCreated.isEmpty {
            lines("import.section.hosts", report.hostsCreated)
        }
        if !report.hostsSkipped.isEmpty {
            lines("import.section.skipped", report.hostsSkipped.map { "\($0.alias): \($0.reason)" })
        }
        if !report.warnings.isEmpty {
            lines("import.section.warnings", report.warnings)
        }
    }

    private func lines(_ title: LocalizedStringKey, _ items: [String]) -> some View {
        Section(title) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line).font(.footnote).textSelection(.enabled)
            }
        }
    }
}

/// What the import did.
private struct ImportDoneSections: View {
    @ObservedObject var flow: ImportFlow

    var body: some View {
        if let s = flow.summary {
            Section {
                Label(String(localized: "import.done.created \(Int(s.created))"), systemImage: "checkmark.circle.fill")
                    .foregroundColor(Brand.green)
                CountLine(text: String(localized: "import.done.updated \(Int(s.updated))"), color: Brand.amber, n: Int(s.updated))
                CountLine(text: String(localized: "import.done.skipped \(Int(s.skipped))"), color: .secondary, n: Int(s.skipped))
                CountLine(text: String(localized: "import.done.groups \(Int(s.groups))"), color: .accentColor, n: Int(s.groups))
                CountLine(text: String(localized: "import.done.keys \(Int(s.keys))"), color: .accentColor, n: Int(s.keys))
                CountLine(text: String(localized: "import.done.keys_reused \(Int(s.keysReused))"), color: .secondary, n: Int(s.keysReused))
                CountLine(text: String(localized: "import.done.identities \(Int(s.identities))"), color: .accentColor, n: Int(s.identities))
                CountLine(text: String(localized: "import.done.snippets \(Int(s.snippets))"), color: .accentColor, n: Int(s.snippets))
            }
            if !s.warnings.isEmpty {
                Section("import.section.warnings") {
                    ForEach(Array(s.warnings.enumerated()), id: \.offset) { _, w in
                        Text(verbatim: ImportPlan.warningText(code: w.code, params: w.params, fallback: w.message))
                            .font(.footnote)
                    }
                }
            }
        } else if let r = flow.sshDone {
            Section {
                Label(String(localized: "import.done \(r.hostsCreated.count)"), systemImage: "checkmark.circle.fill")
                    .foregroundColor(Brand.green)
            }
            SshConfigPreviewSections(report: r)
        }
    }
}
