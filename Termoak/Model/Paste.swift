import Foundation
import SwiftTerm
import UIKit

/// When a paste asks first, and what the confirmation shows (like the
/// desktop's `terminal/paste.rs`).
enum PasteCheck {
    /// Line breaks as `\n` (`\r\n` and a lone `\r` too).
    private static func unixLines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Lines of a paste, not counting a final line break (a copied line
    /// usually ends with one).
    static func lineCount(_ text: String) -> Int {
        var t = Substring(unixLines(text))
        while t.hasSuffix("\n") { t = t.dropLast() }
        return t.isEmpty ? 0 : t.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// Whether pasting `text` asks first: only with the option on, for more
    /// than one line, and when the program has not turned on bracketed paste
    /// (with it, the shell does not run the lines until Enter is pressed).
    static func needsConfirmation(_ text: String, confirm: Bool, bracketed: Bool) -> Bool {
        confirm && !bracketed && lineCount(text) > 1
    }

    /// First lines of a paste for the confirmation, long lines cut.
    static func preview(_ text: String, maxLines: Int) -> String {
        var t = Substring(unixLines(text))
        while t.hasSuffix("\n") { t = t.dropLast() }
        let lines = t.split(separator: "\n", omittingEmptySubsequences: false)
        var out = lines.prefix(maxLines).map { line -> String in
            line.count > 120 ? String(line.prefix(119)) + "…" : String(line)
        }
        if lines.count > maxLines { out.append("…") }
        return out.joined(separator: "\n")
    }
}

/// A paste waiting for the user to confirm it (several lines).
struct PasteRequest: Identifiable {
    let id = UUID()
    let session: TerminalSession
    let text: String
}

/// What is typed in a terminal and also goes to the other panes while
/// broadcasting: keys as they are, pastes and commands as such (each
/// terminal brackets a paste only if its program asked for it).
enum MirroredInput {
    case bytes(Data)
    case paste(String)
    case run(String)
}

/// SwiftTerm's view with its paste (edit menu, ⌘V) going through the
/// session, which may ask before pasting several lines.
final class PasteAwareTerminalView: TerminalView {
    var onPaste: (() -> Void)?

    override func paste(_ sender: Any?) {
        if let onPaste {
            onPaste()
        } else {
            super.paste(sender)
        }
    }
}

/// Set while the terminal interprets output: what it sends back meanwhile
/// (answers to the program's queries) was not typed. Read from the
/// terminal delegate, which SwiftTerm calls on the main thread.
final class FeedFlag: @unchecked Sendable {
    var value = false
}

enum TerminalReport {
    /// Bytes the terminal sends on its own (answers to queries, focus and
    /// mouse reports) rather than keys: they must not be broadcast to the
    /// other panes. Typed keys never look like these.
    static func isReport(_ data: Data) -> Bool {
        let b = [UInt8](data)
        guard b.count >= 3, b[0] == 0x1B else { return false }
        switch b[1] {
        case 0x5D, 0x50, 0x5F, 0x5E:
            // OSC, DCS, APC and PM: answers (colors, capabilities...).
            return true
        case 0x5B:
            // CSI: private markers (`?`, `>`, `=`, `<`) are answers or SGR mouse.
            let third = b[2]
            if third == 0x3F || third == 0x3E || third == 0x3D || third == 0x3C { return true }
            // X10 mouse: ESC [ M and three bytes.
            if third == 0x4D && b.count == 6 { return true }
            guard let final = b.last else { return false }
            let params = b[2..<(b.count - 1)]
            let onlyParams = params.allSatisfy { ($0 >= 0x30 && $0 <= 0x3B) || $0 == 0x24 }
            guard onlyParams else { return false }
            switch final {
            case 0x49, 0x4F:
                // Focus in and out: ESC [ I / ESC [ O.
                return params.isEmpty
            case 0x52:
                // Cursor position: ESC [ row ; col R (with both numbers).
                return params.contains(0x3B) && params.count >= 3
            case 0x63, 0x6E, 0x74:
                // Device attributes, status and window reports.
                return !params.isEmpty || final == 0x63
            case 0x79:
                // Mode report: ESC [ … $ y.
                return params.contains(0x24)
            default:
                return false
            }
        default:
            return false
        }
    }
}
