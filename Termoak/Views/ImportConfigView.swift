import TermoakKit
import SwiftUI
import UniformTypeIdentifiers

/// Imports hosts from an OpenSSH config (`~/.ssh/config`): pasted or picked
/// in Files, into a group and only on this device if you want, with a
/// preview of what will be created first (like Android).
struct ImportConfigView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var group = ""
    @State private var deviceOnly = false
    @State private var preview: SshConfigImportReport?
    @State private var picking = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var typing: Bool

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Import is offered once there is text, unless the preview found nothing new.
    private var canImport: Bool { hasText && !busy && preview.map { !$0.hostsCreated.isEmpty } != false }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Button { picking = true } label: { Label("import.choose_file", systemImage: "folder") }
                    configEditor
                } header: {
                    Text("import.config")
                } footer: {
                    Text("import.intro")
                }
                optionsSection
                actionsSection
                if let preview { ImportPreview(report: preview) }
            }
            .navigationTitle("import.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("import.run") { run(dryRun: false) }.disabled(!canImport)
                }
            }
        }
        .navigationViewStyle(.stack)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in read(result) }
        .alert("common.error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private var configEditor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(verbatim: "Host web\n  HostName 203.0.113.10\n  User deploy")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 140, maxHeight: 260)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($typing)
                .onChange(of: text) { _ in preview = nil }
                .accessibilityLabel(Text("import.config"))
        }
    }

    private var optionsSection: some View {
        Section {
            TextField("import.group", text: $group)
                .onChange(of: group) { _ in preview = nil }
            if !account.list.isEmpty {
                Toggle(isOn: $deviceOnly) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("common.device_only")
                        Text("import.device_only_hint").font(.caption).foregroundColor(.secondary)
                    }
                }
                .onChange(of: deviceOnly) { _ in preview = nil }
            }
        } footer: {
            Text("import.group_hint")
        }
    }

    private var actionsSection: some View {
        Section {
            Button { run(dryRun: true) } label: {
                HStack {
                    Label("import.preview", systemImage: "eye")
                    Spacer()
                    if busy { ProgressView() }
                }
            }
            .disabled(!hasText || busy)
        }
    }

    private func options(dryRun: Bool) -> SshConfigImportOptions {
        let g = group.trimmingCharacters(in: .whitespaces)
        return SshConfigImportOptions(dryRun: dryRun, group: g.isEmpty ? nil : g, deviceOnly: deviceOnly)
    }

    private func run(dryRun: Bool) {
        typing = false
        busy = true
        defer { busy = false }
        do {
            let report = try model.core.importSshConfig(text: text, options: options(dryRun: dryRun))
            if dryRun {
                preview = report
                return
            }
            account.sync()
            account.post(String(localized: "vault.import.done"),
                         String(localized: "import.done \(report.hostsCreated.count)"))
            dismiss()
        } catch {
            self.error = userMessage(error)
        }
    }

    private func read(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            text = try String(contentsOf: url, encoding: .utf8)
            preview = nil
        } catch {
            self.error = String(localized: "import.read_failed")
        }
    }
}

/// What an import would do: how many hosts, jump hosts, keys and tunnels,
/// and the hosts it creates, skips and warns about.
private struct ImportPreview: View {
    let report: SshConfigImportReport

    var body: some View {
        Section("import.preview") {
            if report.hostsCreated.isEmpty {
                Text("import.nothing").foregroundColor(.secondary)
            }
            counts
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

    private var counts: some View {
        VStack(alignment: .leading, spacing: 6) {
            count(String(localized: "import.count.hosts \(report.hostsCreated.count)"), Brand.green, report.hostsCreated.count)
            count(String(localized: "import.count.jumps \(report.jumpHostsCreated.count)"), .accentColor, report.jumpHostsCreated.count)
            count(String(localized: "import.count.keys \(report.keysImported.count)"), .accentColor, report.keysImported.count)
            count(String(localized: "import.count.tunnels \(Int(report.forwardsCreated))"), .accentColor, Int(report.forwardsCreated))
            count(String(localized: "import.count.skipped \(report.hostsSkipped.count)"), Brand.amber, report.hostsSkipped.count)
            count(String(localized: "import.count.warnings \(report.warnings.count)"), Brand.amber, report.warnings.count)
        }
    }

    @ViewBuilder private func count(_ text: String, _ color: Color, _ n: Int) -> some View {
        if n > 0 {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(verbatim: text).font(.subheadline)
            }
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
