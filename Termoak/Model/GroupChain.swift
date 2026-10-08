import Foundation

/// A host's groups from the nearest one up (like the engine's
/// `effective_settings`: a group's defaults apply to the hosts inside it and
/// its subgroups, the nearest group winning). Without the engine's types, for
/// the unit tests.
enum GroupChain {
    /// The engine's limit of nested groups.
    static let maxDepth = 16

    /// `start` and its parents, nearest first; stops at a missing group, a
    /// loop or the depth limit. `parent`: a group's parent (`.some(nil)`
    /// for a top-level group, `nil` for a group that doesn't exist).
    static func ids(from start: String?, parent: (String) -> String??) -> [String] {
        var out: [String] = []
        var next = start
        while let id = next, !out.contains(id), out.count < maxDepth {
            guard let p = parent(id) else { break }
            out.append(id)
            next = p
        }
        return out
    }
}
