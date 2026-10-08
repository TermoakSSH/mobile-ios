import Foundation

// Remote (POSIX) paths, permissions and folder listings of the file browser,
// without the engine's types so the unit tests compile this file on its own
// (like Android's RemotePaths and FileListing).

enum RemotePaths {
    /// Parent folder (`/` for `/` and for a top-level entry).
    static func parent(_ path: String) -> String {
        var p = path
        while p.hasSuffix("/") { p.removeLast() }
        guard !p.isEmpty, let slash = p.lastIndex(of: "/"), slash != p.startIndex else { return "/" }
        return String(p[..<slash])
    }

    /// `name` inside the folder `dir`.
    static func child(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : "\(dir)/\(name)"
    }

    /// A name that can't be used for a new folder or a rename: empty,
    /// `.`/`..`, with `/` or a NUL byte.
    static func invalidName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty || n == "." || n == ".." || n.contains("/") || n.contains("\u{0}")
    }

    /// Permissions as octal text (`644`, `4755`): the 12 permission bits
    /// (setuid, setgid and sticky included), nothing of the file type.
    static func octal(_ mode: UInt32) -> String {
        String(mode & 0o7777, radix: 8)
    }

    /// Octal permissions typed by hand (`755`, `0644`, `4755`); `nil` if it
    /// isn't valid.
    static func parseOctal(_ text: String) -> UInt32? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 4, t.allSatisfy({ ("0"..."7").contains($0) }) else { return nil }
        return UInt32(t, radix: 8)
    }

    /// The mode the permissions editor starts from: the file's 12
    /// permission bits (the special ones are kept), 644 when unknown.
    static func editableMode(_ mode: UInt32?) -> UInt32 {
        (mode ?? 0o644) & 0o7777
    }

    /// A free name for `name` in a folder that already has `taken`:
    /// `a.txt`, `a (1).txt`, `a (2).txt`...
    static func freeName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        // The extension starts at the last dot, unless the name starts with
        // it (".bashrc" has none).
        let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 } ?? name.endIndex
        let base = name[..<dot]
        let ext = name[dot...]
        var i = 1
        while taken.contains("\(base) (\(i))\(ext)") { i += 1 }
        return "\(base) (\(i))\(ext)"
    }

    /// The last part of a picked file's name, never a path, and usable as a
    /// remote name ("file" otherwise).
    static func uploadName(_ name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? ""
        return invalidName(last) ? "file" : last
    }
}

/// How the file browser orders a folder. Raw values are stored in
/// UserDefaults: keep them.
enum FileSort: String, CaseIterable {
    case name, size, date
}

/// An entry of a remote folder, as the listing needs it.
struct FileListingItem: Equatable {
    var name: String
    var dir: Bool
    var size: UInt64
    /// Seconds since 1970.
    var modified: Int64?
}

enum FileListing {
    /// What a folder shows: without hidden files (`.name`) unless
    /// `showHidden`, filtered by `query` (in the name, any case), folders
    /// first and then by `sort` (`descending`: the other way round). Ties go
    /// by name.
    static func arrange<T>(_ entries: [T], item: (T) -> FileListingItem, sort: FileSort, descending: Bool,
                           showHidden: Bool, query: String = "") -> [T] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let kept = entries.map { ($0, item($0)) }.filter { _, i in
            (showHidden || !i.name.hasPrefix(".")) && (q.isEmpty || i.name.lowercased().contains(q))
        }
        return kept.sorted { a, b in
            if a.1.dir != b.1.dir { return a.1.dir }
            let order = compare(a.1, b.1, sort)
            return descending ? order == .orderedDescending : order == .orderedAscending
        }
        .map(\.0)
    }

    private static func compare(_ a: FileListingItem, _ b: FileListingItem, _ sort: FileSort) -> ComparisonResult {
        switch sort {
        case .name: break
        case .size:
            if a.size != b.size { return a.size < b.size ? .orderedAscending : .orderedDescending }
        case .date:
            let x = a.modified ?? Int64.min, y = b.modified ?? Int64.min
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        let byName = a.name.caseInsensitiveCompare(b.name)
        if byName != .orderedSame { return byName }
        return a.name < b.name ? .orderedAscending : (a.name == b.name ? .orderedSame : .orderedDescending)
    }

    /// The order after choosing `by`: the same one again turns it around;
    /// size and date start with the biggest and newest.
    static func nextSort(current: FileSort, descending: Bool, chosen by: FileSort) -> (FileSort, Bool) {
        if by == current { return (by, !descending) }
        return (by, by != .name)
    }
}

/// The transfers of the file browser: at most `limit` run at once, the rest
/// wait their turn in order (like Android's two slots).
struct TransferSlots {
    let limit: Int
    private(set) var running: Set<UUID> = []
    private(set) var waiting: [UUID] = []

    init(limit: Int = 2) {
        self.limit = limit
    }

    /// Queues a transfer; true if it can start now.
    mutating func enqueue(_ id: UUID) -> Bool {
        if running.count < limit && waiting.isEmpty {
            running.insert(id)
            return true
        }
        waiting.append(id)
        return false
    }

    /// A transfer ended (done, failed or cancelled), or a waiting one was
    /// cancelled: the ones that can start now.
    mutating func finish(_ id: UUID) -> [UUID] {
        running.remove(id)
        waiting.removeAll { $0 == id }
        var started: [UUID] = []
        while running.count < limit, !waiting.isEmpty {
            let next = waiting.removeFirst()
            running.insert(next)
            started.append(next)
        }
        return started
    }
}
