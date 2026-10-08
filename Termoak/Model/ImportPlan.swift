import Foundation

// Rules of the import and export screens (the desktop's import dialog):
// what happens to each host of a file, the CSV column mapping, the
// warnings' texts and the export passphrase. Pure logic (unit-tested); the
// engine reads and saves (previewImport, applyImport, exportHosts).

/// Why a host of the file is a duplicate (same address, port and user).
enum ImportDupKind: Equatable {
    case none
    /// Of a host already in the target, with its name.
    case existing(label: String)
    /// Of an earlier host of the same file.
    case inFile
}

/// What to do with duplicates (the engine's DuplicatePolicy).
enum ImportDupChoice: String, CaseIterable, Identifiable {
    case skip, update, copy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .skip: return String(localized: "import.dup.skip")
        case .update: return String(localized: "import.dup.update")
        case .copy: return String(localized: "import.dup.copy")
        }
    }
}

/// What happens to a host of the file.
enum ImportRowStatus: Equatable {
    case new
    /// The user unchecked it.
    case unchecked
    case existingSkipped(String)
    case updates(String)
    case copyOf(String)
    case repeatSkipped
    case repeatCopy

    var imports: Bool {
        switch self {
        case .new, .updates, .copyOf, .repeatCopy: return true
        case .unchecked, .existingSkipped, .repeatSkipped: return false
        }
    }

    var isUpdate: Bool { if case .updates = self { return true } else { return false } }

    var text: String {
        switch self {
        case .new: return String(localized: "import.status.new")
        case .unchecked: return String(localized: "import.status.unchecked")
        case .existingSkipped(let name): return String(localized: "import.status.dup_skip \(name)")
        case .updates(let name): return String(localized: "import.status.dup_update \(name)")
        case .copyOf(let name): return String(localized: "import.status.dup_copy \(name)")
        case .repeatSkipped: return String(localized: "import.status.repeat")
        case .repeatCopy: return String(localized: "import.status.repeat_copy")
        }
    }
}

enum ImportPlan {
    /// The engine's plan: unchecked hosts are left out, duplicates follow
    /// the policy (a repeat inside the file is only created with "copy").
    static func status(_ dup: ImportDupKind, policy: ImportDupChoice, included: Bool) -> ImportRowStatus {
        guard included else { return .unchecked }
        switch (dup, policy) {
        case (.none, _): return .new
        case (.existing(let name), .skip): return .existingSkipped(name)
        case (.existing(let name), .update): return .updates(name)
        case (.existing(let name), .copy): return .copyOf(name)
        case (.inFile, .copy): return .repeatCopy
        case (.inFile, _): return .repeatSkipped
        }
    }

    /// How many hosts the Import button imports.
    static func importCount(_ statuses: [ImportRowStatus]) -> Int {
        statuses.filter(\.imports).count
    }

    // MARK: CSV columns

    /// The field a column feeds (`nil`: none), from the mapping's pairs.
    static func field(ofColumn column: Int, in mapping: [(field: String, column: Int)]) -> String? {
        mapping.first { $0.column == column }?.field
    }

    /// The mapping after giving `column` the field `field` (`nil`: none): a
    /// field feeds one column at most, and a column one field.
    static func assign(_ field: String?, toColumn column: Int,
                       in mapping: [(field: String, column: Int)]) -> [(field: String, column: Int)] {
        var out = mapping.filter { $0.column != column && $0.field != field }
        if let field { out.append((field, column)) }
        return out.sorted { $0.column < $1.column }
    }

    /// Without an address column nothing can be imported.
    static func hasAddress(_ mapping: [(field: String, column: Int)]) -> Bool {
        mapping.contains { $0.field == "address" }
    }

    /// The example value of a column: the first data row of the sample (the
    /// sample starts with the header row when there is one).
    static func example(column: Int, sample: [[String]], hasHeader: Bool) -> String? {
        let rows = hasHeader ? Array(sample.dropFirst()) : sample
        for row in rows where column < row.count {
            let v = row[column].trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
        return nil
    }

    // MARK: Warnings

    /// A warning of the engine in the app's language, by its stable code
    /// (the English text when the code is new).
    static func warningText(code: String, params: [String: String], fallback: String) -> String {
        let name = params["name"] ?? "", line = params["line"] ?? "", path = params["path"] ?? ""
        let proto = params["protocol"] ?? "", port = params["port"] ?? "", error = params["error"] ?? ""
        switch code {
        case "not_ssh": return String(localized: "import.warn.not_ssh \(name) \(proto)")
        case "no_address": return String(localized: "import.warn.no_address \(name)")
        case "no_address_line": return String(localized: "import.warn.no_address_line \(line)")
        case "bad_port": return String(localized: "import.warn.bad_port \(line) \(port)")
        case "proxy_unsupported": return String(localized: "import.warn.proxy_unsupported \(name)")
        case "key_file": return String(localized: "import.warn.key_file \(name) \(path) \(error)")
        case "key_without_private": return String(localized: "import.warn.key_without_private \(name)")
        default: return fallback
        }
    }

    // MARK: Export

    enum PassphraseProblem: Equatable {
        case short, mismatch
        var text: String {
            switch self {
            case .short: return String(localized: "export.passphrase_short")
            case .mismatch: return String(localized: "export.passphrase_mismatch")
            }
        }
    }

    /// An export with secrets needs a passphrase of 8 characters or more,
    /// typed twice the same.
    static func passphraseProblem(_ first: String, _ second: String) -> PassphraseProblem? {
        if first.count < 8 { return .short }
        if first != second { return .mismatch }
        return nil
    }
}
