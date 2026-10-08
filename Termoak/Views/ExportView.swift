import TermoakKit
import SwiftUI

/// Export hosts, like the desktop's: Termoak JSON (hosts, groups, tags,
/// identities, keys' public part and snippets; optionally the passwords
/// and private keys sealed with a passphrase) or CSV (for spreadsheets,
/// never secrets), of This device or a vault, or of one group. The file is
/// shared with the share sheet (Save to Files, AirDrop, Mail...).
struct ExportView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var json = true
    @State private var place: ItemPlace = .device
    @State private var groupId: String?
    @State private var groups: [GroupOption] = []
    @State private var secrets = false
    @State private var pass1 = ""
    @State private var pass2 = ""
    @State private var busy = false
    @State private var error: String?
    @State private var file: ExportedFile?
    @State private var sharing: ExportedFile?

    var body: some View {
        NavigationView {
            Form {
                formatSection
                sourceSection
                if json { secretsSection }
                if let file { resultSection(file) }
            }
            .navigationTitle("export.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(file == nil ? "common.cancel" : "common.done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("export.run", action: export)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            place = account.defaultPlace
            loadGroups()
        }
        .sheet(item: $sharing) { f in
            ActivityView(items: [f.url])
        }
    }

    private var formatSection: some View {
        Section {
            Picker("export.format", selection: $json) {
                Text(verbatim: "Termoak JSON").tag(true)
                Text(verbatim: "CSV").tag(false)
            }
            .pickerStyle(.segmented)
        } footer: {
            Text(json ? "export.intro_json" : "export.intro_csv")
        }
    }

    private var sourceSection: some View {
        Section {
            if places.count > 1 {
                Picker("export.from", selection: $place) {
                    ForEach(places) { p in Text(verbatim: account.placeTitle(p)).tag(p) }
                }
                .onChange(of: place) { _ in
                    groupId = nil
                    loadGroups()
                }
            }
            Picker("import.group", selection: $groupId) {
                Text("export.all_groups").tag(String?.none)
                ForEach(groups) { g in Text(verbatim: g.path).tag(String?.some(g.id)) }
            }
        }
    }

    private var secretsSection: some View {
        Section {
            Toggle("export.include_secrets", isOn: $secrets)
            if secrets {
                SecureField("import.passphrase", text: $pass1).textContentType(.newPassword)
                SecureField("export.passphrase_repeat", text: $pass2).textContentType(.newPassword)
            }
        } footer: {
            if let error {
                Text(verbatim: error).foregroundColor(.red)
            } else if secrets {
                Text("export.passphrase_hint")
            }
        }
    }

    private func resultSection(_ f: ExportedFile) -> some View {
        Section {
            Label(String(localized: "export.done \(f.hosts)"), systemImage: "checkmark.circle.fill")
                .foregroundColor(Brand.green)
            if f.hidden > 0 {
                Text("export.hidden_secrets \(f.hidden)").font(.footnote).foregroundColor(Brand.amber)
            }
            Button { sharing = f } label: { Label("export.share", systemImage: "square.and.arrow.up") }
        }
    }

    /// This device and every vault of the accounts (Use-only vaults too:
    /// their secrets are left out).
    private var places: [ItemPlace] {
        var out: [ItemPlace] = [.device]
        for a in account.list where a.status != .unverified {
            if a.vaultsSupported {
                out += account.vaults(of: a.id).map { ItemPlace(accountId: a.id, vaultId: $0.id) }
            } else {
                out.append(ItemPlace(accountId: a.id, vaultId: nil))
            }
        }
        return out
    }

    private func loadGroups() {
        let filter = ItemFilter(accountIds: place.accountId.map { [$0] } ?? [],
                                vaultIds: place.vaultId.map { [$0] },
                                includeDevice: place.accountId == nil)
        let list = ((try? model.core.listGroups(filter: filter)) ?? []).filter {
            $0.accountId == place.accountId && (place.vaultId == nil || $0.vaultId == place.vaultId)
        }
        groups = ImportFlow.paths(list)
    }

    private func export() {
        let withSecrets = json && secrets
        if withSecrets, let problem = ImportPlan.passphraseProblem(pass1, pass2) {
            error = problem.text
            return
        }
        error = nil
        busy = true
        let scope = ExportScope(accountId: place.accountId, vaultId: place.vaultId,
                                deviceOnly: place.accountId == nil, groupId: groupId)
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        let (core, pass) = (model.core, pass1)
        Task {
            defer { busy = false }
            do {
                let r = try await core.exportHosts(format: json ? .termoakJson : .csv, scope: scope,
                                                   includeSecrets: withSecrets, passphrase: withSecrets ? pass : nil,
                                                   app: "Termoak for iOS \(version)")
                let f = try ExportedFile.write(r, secret: withSecrets)
                file = f
                sharing = f
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}

/// An exported file in the temporary folder, to share.
struct ExportedFile: Identifiable {
    let url: URL
    let hosts: Int
    let hidden: Int
    var id: String { url.path }

    static func write(_ r: ExportResult, secret: Bool) throws -> ExportedFile {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(r.fileName.isEmpty ? "termoak-hosts" : r.fileName)
        try? FileManager.default.removeItem(at: url)
        // Sealed secrets or not, only this app (and whoever it is shared
        // with) reads it.
        try r.data.write(to: url, options: secret ? [.atomic, .completeFileProtection] : [.atomic])
        return ExportedFile(url: url, hosts: Int(r.hosts), hidden: Int(r.hiddenSecrets))
    }
}
