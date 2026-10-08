import Foundation

// Pure decisions of the screens (the unit tests compile this file on its
// own): which layout a window gets and how the latency is shown.

/// Settings → Appearance → "Layout on wide screens". Raw values are stored
/// in UserDefaults: keep them.
enum WideLayout: String, CaseIterable, Identifiable {
    /// The desktop layout only on an iPad in a regular-width window.
    case automatic
    /// Always the phone's (tab bar at the bottom, terminal over everything).
    case phone
    /// The desktop layout in any regular-width window: also an iPhone Plus
    /// or Pro Max in landscape.
    case desktop

    var id: String { rawValue }

    /// Whether a window gets the desktop layout (tabs on top, sidebar):
    /// `pad` is an iPad (or a Mac running the iPad app), `regularWidth` its
    /// horizontal size class. A narrow window always keeps the phone layout.
    func usesDesktop(pad: Bool, regularWidth: Bool) -> Bool {
        switch self {
        case .automatic: return pad && regularWidth
        case .phone: return false
        case .desktop: return regularWidth
        }
    }
}

/// Latency of a terminal shown in its bar, like the desktop's: measured
/// every `interval` seconds while the terminal is connected and on screen.
enum Latency {
    /// Time between measurements (seconds).
    static let interval: Double = 5
    /// Longest wait for an answer (then the latency is unknown).
    static let timeoutMs: UInt32 = 5000

    enum Level: Equatable {
        /// Not measured yet or no answer (gray).
        case unknown
        /// Below 150 ms (gray).
        case good
        /// Below 400 ms (amber).
        case fair
        /// From 400 ms on (red).
        case poor
    }

    static func level(_ ms: Double?) -> Level {
        guard let ms, ms.isFinite, ms >= 0 else { return .unknown }
        if ms < 150 { return .good }
        if ms < 400 { return .fair }
        return .poor
    }

    /// Text of the badge: `42 ms`, `<1 ms` or `—` while unknown.
    static func text(_ ms: Double?) -> String {
        guard let ms, ms.isFinite, ms >= 0 else { return "—" }
        if ms < 1 { return "<1 ms" }
        return "\(Int(ms)) ms"
    }
}
