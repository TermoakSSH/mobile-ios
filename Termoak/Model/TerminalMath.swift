import Foundation

// Small decisions of the terminal screen (pinch, links, tab names), without
// UIKit or the engine's types so the unit tests compile this file on its own.

/// Pinch to change the text size (like Android).
enum FontPinch {
    /// The size for a pinch of `scale` that started at `start`: whole
    /// points, within `minimum…maximum`. A pinch of less than 8 % keeps the
    /// size, so two fingers that move together (scrolling, moving the cursor)
    /// don't change it.
    static func size(start: Double, scale: Double, minimum: Double, maximum: Double) -> Double {
        guard scale > 0, abs(scale - 1) >= 0.08 else { return start }
        return min(maximum, max(minimum, (start * scale).rounded()))
    }
}

/// Links in the terminal's text, to open them with a tap.
enum TerminalLinks {
    /// Characters that end a link (spaces and quotes; brackets only if they
    /// are not part of it).
    private static let stops: Set<Character> = [" ", "\t", "\"", "'", "<", ">", "`", "|", "\u{0}"]

    /// The `http`/`https` link under `column` of a row of text (one
    /// character per column), `nil` if there is none. Trailing punctuation
    /// (`.`, `,`, `)` without its `(`…) is not part of it.
    static func link(in text: String, at column: Int) -> String? {
        let chars = Array(text)
        guard column >= 0, column < chars.count, !stops.contains(chars[column]) else { return nil }
        var start = column
        while start > 0, !stops.contains(chars[start - 1]) { start -= 1 }
        var end = column
        while end + 1 < chars.count, !stops.contains(chars[end + 1]) { end += 1 }
        let word = String(chars[start...end])
        // The link can start in the middle of the word ("url=https://…").
        guard let scheme = word.range(of: "https://", options: .caseInsensitive) ?? word.range(of: "http://", options: .caseInsensitive)
        else { return nil }
        let schemeStart = start + word.distance(from: word.startIndex, to: scheme.lowerBound)
        guard column >= schemeStart else { return nil }
        var link = String(chars[schemeStart...end])
        link = trimmed(link)
        // The tap is on what was trimmed away.
        guard column < schemeStart + link.count, let url = URL(string: link), let host = url.host, !host.isEmpty else { return nil }
        return link
    }

    /// Without the punctuation that usually follows a link in a sentence.
    private static func trimmed(_ link: String) -> String {
        var s = link
        while let last = s.last {
            if ".,;:!?".contains(last) {
                s.removeLast()
            } else if last == ")" && s.filter({ $0 == "(" }).count < s.filter({ $0 == ")" }).count {
                s.removeLast()
            } else if last == "]" && s.filter({ $0 == "[" }).count < s.filter({ $0 == "]" }).count {
                s.removeLast()
            } else {
                break
            }
        }
        return s
    }
}

/// The name of a tab.
enum TabTitle {
    /// The name given by hand (empty or only spaces: none), else the
    /// program's title, else the host's name.
    static func display(custom: String?, title: String?, label: String) -> String {
        if let custom = custom?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty { return custom }
        if let title, !title.isEmpty { return title }
        return label
    }
}

/// Reconnecting the terminals of this device that the system cut while the
/// app was away.
enum AutoReconnect {
    /// After this long away, a terminal that still looks connected is
    /// checked (a keep-alive) before trusting it.
    static let checkAfter: TimeInterval = 20
    /// For this long after coming back, a terminal that was connected and
    /// drops reconnects by itself (the system tells late).
    static let window: TimeInterval = 15
}
