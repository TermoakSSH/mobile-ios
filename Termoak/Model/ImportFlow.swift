import TermoakKit
import Foundation

/// A group of the target to import into, or the place's top level.
enum ImportGroupChoice: Hashable {
    case none
    case existing(String)
    /// A new top-level group with the typed name (found if it exists).
    case new
}

/// A group of a place with its path ("Prod / Web"), for the pickers.
struct GroupOption: Identifiable, Hashable {
    let id: String
    let path: String
}

/// The import of a file, step by step: read it (the format is detected),
/// the preview of the engine (`previewImport`, or `importSshConfig` with
/// `dryRun` for an ssh_config), the passphrase of a Termoak export with
/// secrets, the CSV columns, the target, the group, the duplicates and the
/// hosts left out, then `applyImport`.
@MainActor
final class ImportFlow: ObservableObject {
    var core: TermoakCore?

    // The file.
    @Published private(set) var data: Data?
    @Published private(set) var fileName = ""
    @Published private(set) var format: ImportFormat = .auto

    // The engine's preview (not for ssh_config).
    @Published private(set) var preview: ImportPreview?
    @Published private(set) var hosts: [ImportHostPreview] = []
    @Published private(set) var warnings: [ImportWarningInfo] = []
    @Published private(set) var mapping: CsvMapping?
    @Published private(set) var unlocked = false
    /// The preview of an ssh_config (`dryRun`).
    @Published private(set) var sshReport: SshConfigImportReport?

    // Choices.
    @Published var place: ItemPlace = .device
    @Published var group: ImportGroupChoice = .none
    @Published var newGroup = ""
    @Published var policy: ImportDupChoice = .skip
    @Published var excluded: Set<UInt32> = []
    @Published private(set) var groups: [GroupOption] = []

    @Published private(set) var busy = false
    @Published var error: String?
    /// What the import did (the last step).
    @Published private(set) var summary: ImportSummary?
    @Published private(set) var sshDone: SshConfigImportReport?

    /// The passphrase that opened the secrets (to open them again when the
    /// target changes and the preview is read again).
    private var passphrase: String?

    var loaded: Bool { data != nil }
    var isSshConfig: Bool { format == .sshConfig }
    var finished: Bool { summary != nil || sshDone != nil }

    // MARK: What happens

    func dupKind(_ h: ImportHostPreview) -> ImportDupKind {
        switch h.duplicate {
        case .none: return .none
        case .existing(_, let label)?: return .existing(label: label)
        case .inFile?: return .inFile
        }
    }

    func status(_ h: ImportHostPreview) -> ImportRowStatus {
        ImportPlan.status(dupKind(h), policy: policy, included: !excluded.contains(h.index))
    }

    var importCount: Int {
        if isSshConfig { return sshReport?.hostsCreated.count ?? 0 }
        return ImportPlan.importCount(hosts.map(status))
    }

    var duplicateCount: Int { hosts.filter { $0.duplicate != nil }.count }

    var needsPassphrase: Bool { !unlocked && (preview?.needsPassphrase() ?? false) }

    /// A CSV without an address column: nothing can be imported yet.
    var needsAddressColumn: Bool {
        guard let mapping else { return false }
        return !mapping.columns.contains { $0.field == .address }
    }

    func toggle(_ h: ImportHostPreview) {
        if excluded.contains(h.index) { excluded.remove(h.index) } else { excluded.insert(h.index) }
    }

    // MARK: Reading

    /// Reads a file (or pasted text) and shows what it brings.
    func load(_ data: Data, fileName: String) async {
        self.data = data
        self.fileName = fileName
        format = detectImportFormat(data: data, fileName: fileName)
        passphrase = nil
        unlocked = false
        excluded = []
        mapping = nil
        preview = nil
        sshReport = nil
        loadGroups()
        await reread()
    }

    /// Back to choosing a file.
    func reset() {
        data = nil
        preview = nil
        hosts = []
        warnings = []
        mapping = nil
        sshReport = nil
        summary = nil
        sshDone = nil
        passphrase = nil
        unlocked = false
        excluded = []
        format = .auto
    }

    /// The target changed: its groups and its duplicates.
    func placeChanged() async {
        group = .none
        loadGroups()
        guard loaded else { return }
        await reread()
    }

    /// Reads the preview again for the current target, keeping the CSV
    /// columns chosen and the secrets opened.
    func reread() async {
        guard let core, let data else { return }
        error = nil
        if isSshConfig {
            sshPreview()
            return
        }
        busy = true
        defer { busy = false }
        do {
            var p = try await core.previewImport(data: data, fileName: fileName, format: format,
                                                 accountId: place.accountId, vaultId: place.vaultId,
                                                 deviceOnly: place.accountId == nil)
            if let mapping, p.csvMapping() != nil { p = p.withMapping(mapping: mapping) }
            if let passphrase, p.needsPassphrase(), let open = try await Self.unlock(p, passphrase) { p = open }
            show(p)
        } catch {
            preview = nil
            hosts = []
            self.error = userMessage(error)
        }
    }

    private func show(_ p: ImportPreview) {
        preview = p
        hosts = p.hosts()
        warnings = p.warnings()
        mapping = p.csvMapping()
        excluded = excluded.filter { i in hosts.contains { $0.index == i } }
    }

    /// Opens the secrets of a Termoak export (`false`: wrong passphrase).
    func unlock(_ text: String) async -> Bool {
        guard let p = preview else { return false }
        busy = true
        defer { busy = false }
        do {
            guard let open = try await Self.unlock(p, text) else { return false }
            passphrase = text
            unlocked = true
            show(open)
            return true
        } catch {
            self.error = userMessage(error)
            return false
        }
    }

    /// Takes a moment (a key derivation): off the main thread.
    nonisolated private static func unlock(_ p: ImportPreview, _ text: String) async throws -> ImportPreview? {
        try await Task.detached { try p.unlock(passphrase: text) }.value
    }

    /// Another column mapping of the CSV.
    func setMapping(_ m: CsvMapping) {
        guard let p = preview else { return }
        show(p.withMapping(mapping: m))
    }

    // MARK: Groups

    private func loadGroups() {
        guard let core else { return }
        let filter = ItemFilter(accountIds: place.accountId.map { [$0] } ?? [],
                                vaultIds: place.vaultId.map { [$0] },
                                includeDevice: place.accountId == nil)
        let list = ((try? core.listGroups(filter: filter)) ?? []).filter {
            $0.accountId == place.accountId && (place.accountId == nil || place.vaultId == nil || $0.vaultId == place.vaultId)
        }
        groups = Self.paths(list)
    }

    /// Groups with their paths, sorted.
    static func paths(_ list: [HostGroup]) -> [GroupOption] {
        let byId = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func path(_ g: HostGroup, _ depth: Int = 0) -> String {
            guard depth < 16, let parent = g.parentId.flatMap({ byId[$0] }) else { return g.name }
            return path(parent, depth + 1) + " / " + g.name
        }
        return list.map { GroupOption(id: $0.id, path: path($0)) }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private var groupName: String? {
        switch group {
        case .none: return nil
        case .existing(let id): return groups.first { $0.id == id }?.path
        case .new:
            let n = newGroup.trimmingCharacters(in: .whitespaces)
            return n.isEmpty ? nil : n
        }
    }

    // MARK: ssh_config

    private func sshOptions(dryRun: Bool) -> SshConfigImportOptions {
        SshConfigImportOptions(dryRun: dryRun, group: groupName, deviceOnly: place.accountId == nil,
                               accountId: place.accountId, vaultId: place.vaultId)
    }

    /// The preview of an ssh_config (again after changing the group).
    func sshPreview() {
        guard let core, let data else { return }
        do {
            sshReport = try core.importSshConfig(text: String(decoding: data, as: UTF8.self), options: sshOptions(dryRun: true))
        } catch {
            sshReport = nil
            self.error = userMessage(error)
        }
    }

    // MARK: Import

    /// Saves it. `true` when done (the summary shows).
    func run() async -> Bool {
        guard let core else { return false }
        error = nil
        if isSshConfig {
            guard let data else { return false }
            do {
                sshDone = try core.importSshConfig(text: String(decoding: data, as: UTF8.self), options: sshOptions(dryRun: false))
                return true
            } catch {
                self.error = userMessage(error)
                return false
            }
        }
        guard let preview else { return false }
        busy = true
        defer { busy = false }
        var groupId: String?
        var name: String?
        switch group {
        case .none: break
        case .existing(let id): groupId = id
        case .new: name = groupName
        }
        let options = ImportOptions(accountId: place.accountId, vaultId: place.vaultId,
                                    deviceOnly: place.accountId == nil, groupId: groupId, groupName: name,
                                    duplicatePolicy: policy.engine, excluded: Array(excluded).sorted())
        do {
            summary = try await core.applyImport(preview: preview, options: options)
            return true
        } catch {
            self.error = userMessage(error)
            return false
        }
    }
}

extension ImportDupChoice {
    var engine: DuplicatePolicy {
        switch self {
        case .skip: return .skip
        case .update: return .update
        case .copy: return .copy
        }
    }
}

extension ImportFormat {
    /// The app the file comes from (names are not translated).
    var title: String {
        switch self {
        case .auto: return "?"
        case .termoakJson: return "Termoak JSON"
        case .csv: return "CSV"
        case .sshConfig: return "OpenSSH (ssh_config)"
        case .termius: return "Termius"
        case .putty: return "PuTTY"
        case .mobaXterm: return "MobaXterm"
        case .secureCrt: return "SecureCRT"
        case .zoc: return "ZOC"
        }
    }
}

extension CsvField {
    static let all: [CsvField] = [.label, .address, .port, .user, .group, .tags, .notes, .password, .protocol]

    /// Stable name (ImportPlan's mapping rules use it).
    var key: String {
        switch self {
        case .label: return "label"
        case .address: return "address"
        case .port: return "port"
        case .user: return "user"
        case .group: return "group"
        case .tags: return "tags"
        case .notes: return "notes"
        case .password: return "password"
        case .protocol: return "protocol"
        }
    }

    init?(key: String) {
        guard let f = CsvField.all.first(where: { $0.key == key }) else { return nil }
        self = f
    }

    var title: String {
        switch self {
        case .label: return String(localized: "import.field.label")
        case .address: return String(localized: "import.field.address")
        case .port: return String(localized: "import.field.port")
        case .user: return String(localized: "import.field.user")
        case .group: return String(localized: "import.field.group")
        case .tags: return String(localized: "import.field.tags")
        case .notes: return String(localized: "import.field.notes")
        case .password: return String(localized: "import.field.password")
        case .protocol: return String(localized: "import.field.protocol")
        }
    }
}

extension CsvMapping {
    var pairs: [(field: String, column: Int)] { columns.map { ($0.field.key, Int($0.column)) } }

    /// The mapping after choosing the field of a column (`nil`: none).
    func assigning(_ field: CsvField?, toColumn column: Int) -> CsvMapping {
        let next = ImportPlan.assign(field?.key, toColumn: column, in: pairs)
        return CsvMapping(hasHeader: hasHeader, columns: next.compactMap { p in
            CsvField(key: p.field).map { CsvColumn(field: $0, column: UInt32(p.column)) }
        })
    }
}
