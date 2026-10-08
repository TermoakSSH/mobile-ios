import Foundation

/// Notices that can arrive twice (from an open terminal and from the
/// server's events): only the first one within `window` seconds counts.
/// Without the app's types, for the unit tests.
struct NoticeDeduper {
    let window: TimeInterval
    private var seen: [String: Date] = [:]

    init(window: TimeInterval) {
        self.window = window
    }

    /// True the first time `key` shows up within the window (and remembers it).
    mutating func isNew(_ key: String, at now: Date) -> Bool {
        seen = seen.filter { now.timeIntervalSince($0.value) < max(window, 60) }
        if let last = seen[key], now.timeIntervalSince(last) < window { return false }
        seen[key] = now
        return true
    }
}
