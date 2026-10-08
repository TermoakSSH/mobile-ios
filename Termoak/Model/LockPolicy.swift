import Foundation

/// When the app lock asks again (Settings → Lock → "Lock after"). Raw values
/// are seconds and are stored in UserDefaults: keep them.
enum LockDelay: Int, CaseIterable, Identifiable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case hour = 3600

    var id: Int { rawValue }
}

/// The app lock's rule, without the system's types for the unit tests.
enum LockPolicy {
    /// Coming back to the foreground: lock if the lock is on and the app was
    /// in the background at least `delay` (always with "immediately").
    static func shouldLock(enabled: Bool, delay: LockDelay, backgroundedAt: Date?, now: Date) -> Bool {
        guard enabled, let since = backgroundedAt else { return false }
        return now.timeIntervalSince(since) >= TimeInterval(delay.rawValue)
    }
}
