import Foundation

// The app's actions in the command palette (⌘K, quick connect extended like
// the desktop's palette): which ones apply right now, and the keys the
// palette remembers them by. Pure logic (unit-tested).

/// An action of the app that needs no screen of its own.
enum PaletteCommand: String, CaseIterable {
    case home, nextTab, closeTab, addToSplit, focusMode, broadcast
    case zoomIn, zoomOut, zoomReset, toggleTheme

    /// The palette's stable key (`cmd:<name>`, like the desktop's).
    var key: String { "cmd:\(rawValue)" }

    /// What is open and shown now.
    struct State: Equatable {
        var tabs = 0
        var terminalShown = false
        var splitAvailable = false
        var splitActive = false
    }

    /// The actions that do something in this state, in a fixed order.
    static func available(_ s: State) -> [PaletteCommand] {
        allCases.filter { c in
            switch c {
            case .home, .closeTab: return s.terminalShown
            case .nextTab: return s.tabs > 1
            case .addToSplit: return s.splitAvailable && s.tabs >= 2
            case .focusMode, .broadcast: return s.splitActive
            case .zoomIn, .zoomOut, .zoomReset: return s.tabs > 0
            case .toggleTheme: return true
            }
        }
    }

    var title: String {
        switch self {
        case .home: return String(localized: "palette.cmd.home")
        case .nextTab: return String(localized: "shortcut.next_tab")
        case .closeTab: return String(localized: "shortcut.close_tab")
        case .addToSplit: return String(localized: "palette.cmd.add_to_split")
        case .focusMode: return String(localized: "palette.cmd.focus_mode")
        case .broadcast: return String(localized: "palette.cmd.broadcast")
        case .zoomIn: return String(localized: "shortcut.zoom_in")
        case .zoomOut: return String(localized: "shortcut.zoom_out")
        case .zoomReset: return String(localized: "shortcut.zoom_reset")
        case .toggleTheme: return String(localized: "palette.cmd.toggle_theme")
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .nextTab: return "arrow.right.square"
        case .closeTab: return "xmark.square"
        case .addToSplit: return "rectangle.split.2x1"
        case .focusMode: return "rectangle.lefthalf.inset.filled"
        case .broadcast: return "dot.radiowaves.left.and.right"
        case .zoomIn: return "textformat.size.larger"
        case .zoomOut: return "textformat.size.smaller"
        case .zoomReset: return "textformat.size"
        case .toggleTheme: return "circle.lefthalf.filled"
        }
    }

    /// English words it is also found by (whatever the app's language).
    var keywords: [String] {
        switch self {
        case .home: return ["home", "hosts"]
        case .nextTab: return ["next", "tab"]
        case .closeTab: return ["close", "tab"]
        case .addToSplit: return ["split", "pane"]
        case .focusMode: return ["focus", "split"]
        case .broadcast: return ["broadcast", "all panes"]
        case .zoomIn: return ["zoom", "bigger", "font"]
        case .zoomOut: return ["zoom", "smaller", "font"]
        case .zoomReset: return ["zoom", "reset", "font"]
        case .toggleTheme: return ["theme", "appearance", "dark", "light"]
        }
    }
}

enum PaletteKey {
    static func tab(_ id: UUID) -> String { "tab:\(id.uuidString)" }
    static func host(_ key: String) -> String { "host:\(key)" }
    static func session(_ key: String) -> String { "session:\(key)" }
    static func snippet(_ key: String) -> String { "snippet:\(key)" }
    /// Tabs are not remembered among the recent entries (they come and go).
    static func remembered(_ key: String) -> Bool { !key.hasPrefix("tab:") }
}
