import Foundation

// What a key of a hardware keyboard (Magic Keyboard, Smart Keyboard,
// Bluetooth...) sends to the terminal. Pure Swift, without UIKit, so it can
// be tested (UnitTests/HardwareKeysTests.swift); the terminal view turns a
// `UIKey` into a `HardwareKey` and asks `HardwareKeyMap` (TerminalInput.swift).
//
// The sequences are xterm's (what TERM=xterm-256color expects):
// - Ctrl + letter or symbol: the control byte (Ctrl+A = 0x01, Ctrl+[ = Esc,
//   Ctrl+Space = NUL...). On layouts where the symbol is elsewhere (Ctrl+[ on
//   a Spanish keyboard) the physical key of a US layout decides.
// - Option as Meta: Esc + the key. Turned off, Option types the layout's
//   characters (@ # € [ ] { } \ | ~ on a Spanish keyboard) and dead keys.
// - Arrows, Home/End, PgUp/PgDn, Insert/Delete and F1–F12 with modifiers:
//   `ESC [ 1 ; m X` and `ESC [ n ; m ~` (m = 1 + Shift 1 + Alt 2 + Ctrl 4);
//   without modifiers, `ESC O X` in application cursor mode.
// - ⌘. is Esc (for keyboards without that key); other ⌘ combinations are
//   the app's and the system's shortcuts.

/// Modifier keys held down.
struct ModifierKeys: OptionSet, Hashable {
    let rawValue: Int
    static let shift = ModifierKeys(rawValue: 1 << 0)
    static let control = ModifierKeys(rawValue: 1 << 1)
    static let option = ModifierKeys(rawValue: 1 << 2)
    static let command = ModifierKeys(rawValue: 1 << 3)
}

/// A key of a hardware keyboard.
enum HardwareKey: Equatable {
    /// Esc, Tab, Enter, Backspace, arrows, editing and function keys.
    case special(SpecialKey)
    /// A key that types: `typed` is what it types with the modifiers held
    /// (`UIKey.characters`), `unmodified` without them
    /// (`charactersIgnoringModifiers`) and `usKey` what the same physical key
    /// is on a US layout (`nil` if it has no character there).
    case character(typed: String, unmodified: String, usKey: Character?)

    /// The key with HID usage `usage` (`UIKey.keyCode.rawValue`). `nil` for
    /// modifier keys, Caps Lock and keys without a meaning in a terminal
    /// (they go on to the system).
    init?(hidUsage usage: Int, characters: String, charactersIgnoringModifiers: String) {
        if let special = HardwareKey.specialKeys[usage] {
            self = .special(special)
            return
        }
        // Keys the terminal does not use (modifiers, locks, media keys...).
        if HardwareKey.ignored.contains(usage) { return nil }
        let us = HardwareKey.usLayout[usage]
        guard us != nil || !charactersIgnoringModifiers.isEmpty || !characters.isEmpty else { return nil }
        self = .character(typed: characters, unmodified: charactersIgnoringModifiers, usKey: us)
    }

    /// HID usages (USB HID Usage Tables, keyboard page 0x07; the values of
    /// `UIKeyboardHIDUsage`) of the special keys.
    static let specialKeys: [Int: SpecialKey] = [
        0x28: .enter, 0x58: .enter, // Return and the keypad's Enter
        0x29: .esc,
        0x2A: .backspace,
        0x2B: .tab,
        0x3A: .f1, 0x3B: .f2, 0x3C: .f3, 0x3D: .f4, 0x3E: .f5, 0x3F: .f6,
        0x40: .f7, 0x41: .f8, 0x42: .f9, 0x43: .f10, 0x44: .f11, 0x45: .f12,
        0x49: .ins,
        0x4A: .home,
        0x4B: .pageUp,
        0x4C: .del, // forward delete (Fn+Backspace)
        0x4D: .end,
        0x4E: .pageDown,
        0x4F: .right,
        0x50: .left,
        0x51: .down,
        0x52: .up,
    ]

    /// Caps Lock, Print Screen, Scroll Lock, Pause, F13–F24, the media keys
    /// and the modifiers: nothing is sent.
    static let ignored: Set<Int> = Set([0x39, 0x46, 0x47, 0x48, 0x53, 0x65, 0x66])
        .union(0x68...0x73)       // F13–F24
        .union(0x74...0x81)       // Execute, Help, Menu... Mute, Volume
        .union(0xE0...0xE7)       // Ctrl, Shift, Option, ⌘ (left and right)

    /// What each key is on a US layout (for Ctrl + symbol on other layouts).
    static let usLayout: [Int: Character] = {
        var map: [Int: Character] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { map[0x04 + i] = c }
        for (i, c) in "1234567890".enumerated() { map[0x1E + i] = c }
        let symbols: [(Int, Character)] = [
            (0x2C, " "), (0x2D, "-"), (0x2E, "="), (0x2F, "["), (0x30, "]"), (0x31, "\\"),
            (0x32, "\\"), (0x33, ";"), (0x34, "'"), (0x35, "`"), (0x36, ","), (0x37, "."), (0x38, "/"),
        ]
        for (usage, c) in symbols { map[usage] = c }
        return map
    }()
}

/// The terminal's state that changes what a key sends.
struct KeyEncodingOptions: Equatable {
    /// Application cursor mode (DECCKM): arrows, Home and End as `ESC O X`.
    var applicationCursor = false
    /// Option sends Esc + the key (Meta) instead of typing characters.
    var optionAsMeta = true
    /// Ctrl or Alt of the key bar, waiting for the next key.
    var stickyControl = false
    var stickyAlt = false
}

/// What to do with a key.
enum HardwareKeyResult: Equatable {
    /// Send these bytes (and repeat them while the key is held).
    case send([UInt8])
    /// Leave it to the text system: plain and shifted characters, dead keys
    /// (´ ` ^ ¨), ñ, the characters of Option when it is not Meta, Enter
    /// and Backspace without modifiers, and the ⌘ shortcuts.
    case system
    /// An app shortcut (Ctrl+Tab): nothing is typed.
    case ignore
    /// Shift+PgUp / Shift+PgDn: the terminal's own scrollback, like xterm.
    case scrollPage(up: Bool)
}

enum HardwareKeyMap {
    static let esc: UInt8 = 0x1B

    static func result(for key: HardwareKey, modifiers: ModifierKeys,
                       options: KeyEncodingOptions = KeyEncodingOptions()) -> HardwareKeyResult {
        if modifiers.contains(.command) {
            // ⌘. is Esc on keyboards without it (the iPad's Magic Keyboard).
            if case .character(_, let unmodified, let us) = key, unmodified == "." || (unmodified.isEmpty && us == ".") {
                return .send([esc])
            }
            return .system
        }
        switch key {
        case .special(let special):
            return specialKey(special, modifiers: modifiers, options: options)
        case let .character(typed, unmodified, us):
            return character(typed: typed, unmodified: unmodified, usKey: us, modifiers: modifiers, options: options)
        }
    }

    // MARK: Special keys

    private static func specialKey(_ key: SpecialKey, modifiers: ModifierKeys, options: KeyEncodingOptions) -> HardwareKeyResult {
        let shift = modifiers.contains(.shift)
        let ctrl = modifiers.contains(.control) || options.stickyControl
        // Option has no characters to type on these keys: it is always Alt.
        let alt = modifiers.contains(.option) || options.stickyAlt
        let altPrefix: [UInt8] = alt ? [esc] : []
        switch key {
        case .esc:
            return .send(altPrefix + [esc])
        case .tab, .shiftTab:
            // Ctrl+Tab and Ctrl+Shift+Tab change tabs (app shortcuts).
            if modifiers.contains(.control) { return .ignore }
            if shift || key == .shiftTab { return .send(Array("\u{1b}[Z".utf8)) }
            return .send(altPrefix + [0x09])
        case .enter:
            if !ctrl && !alt { return shift ? .send([0x0D]) : .system }
            return .send(altPrefix + [0x0D])
        case .backspace:
            if !ctrl && !alt { return .system }
            return .send(altPrefix + [ctrl ? 0x08 : 0x7F])
        case .pageUp, .pageDown:
            if shift && !ctrl && !alt { return .scrollPage(up: key == .pageUp) }
        case .left, .right:
            // Option+←/→ alone jumps a word (Meta-b / Meta-f), as before and
            // as bash, zsh, fish and emacs expect by default.
            if modifiers.contains(.option) && !shift && !ctrl && !options.stickyAlt {
                return .send([esc, key == .left ? 0x62 : 0x66])
            }
        default:
            break
        }
        return .send(key.bytes(ctrl: ctrl, alt: alt, shift: shift, appCursor: options.applicationCursor))
    }

    // MARK: Characters

    private static func character(typed: String, unmodified: String, usKey: Character?,
                                  modifiers: ModifierKeys, options: KeyEncodingOptions) -> HardwareKeyResult {
        let shift = modifiers.contains(.shift)
        let option = modifiers.contains(.option)
        let meta = option && options.optionAsMeta
        if modifiers.contains(.control) {
            // Ctrl+Option+x with Option as Meta: Esc + Ctrl+x.
            let prefix: [UInt8] = meta || options.stickyAlt ? [esc] : []
            if let code = controlCode(unmodified) ?? usKey.flatMap({ controlCode(String($0)) }) {
                return .send(prefix + [code])
            }
            // No control byte (Ctrl+1, Ctrl+ñ...): the key itself, like xterm.
            let base = unmodified.isEmpty ? typed : unmodified
            return base.isEmpty ? .system : .send(prefix + Array(applyShift(base, shift).utf8))
        }
        if meta {
            let base = unmodified.isEmpty ? usKey.map(String.init) ?? "" : unmodified
            guard !base.isEmpty else { return .system }
            return .send([esc] + Array(applyShift(base, shift).utf8))
        }
        // Plain, Shift, Option typing characters, dead keys: the text system
        // (it also applies the key bar's Ctrl and Alt).
        return .system
    }

    /// Shift on a letter that the system gave without it.
    private static func applyShift(_ s: String, _ shift: Bool) -> String {
        guard shift, s.count == 1, s.lowercased() == s, s.uppercased() != s else { return s }
        return s.uppercased()
    }

    /// Control byte of Ctrl + character (`nil` if it has none), like xterm:
    /// letters, `@ [ \ ] ^ _ ? Space` and the digits 2–8 of the VT220.
    static func controlCode(_ s: String) -> UInt8? {
        guard s.unicodeScalars.count == 1, let ch = s.lowercased().unicodeScalars.first else { return nil }
        switch ch {
        case "a"..."z": return UInt8(ch.value - 0x60)
        case "@", " ", "2": return 0x00
        case "[", "3": return 0x1B
        case "\\", "4": return 0x1C
        case "]", "5": return 0x1D
        case "^", "6": return 0x1E
        case "_", "-", "7", "/": return 0x1F
        case "?", "8": return 0x7F
        default: return nil
        }
    }
}

// MARK: - Lists

/// Keys that move around a list (hosts, files) outside the terminal.
enum NavKey: Equatable {
    case up, down, left, right, enter, space, delete, escape, home, end, pageUp, pageDown
    /// The context-menu key of PC keyboards (Application or Menu).
    case menu
    /// F10 (Shift+F10 opens the menu on Windows and Linux).
    case f10

    init?(hidUsage usage: Int) {
        switch usage {
        case 0x52: self = .up
        case 0x51: self = .down
        case 0x50: self = .left
        case 0x4F: self = .right
        case 0x28, 0x58: self = .enter
        case 0x2C: self = .space
        case 0x2A, 0x4C: self = .delete
        case 0x29: self = .escape
        case 0x4A: self = .home
        case 0x4D: self = .end
        case 0x4B: self = .pageUp
        case 0x4E: self = .pageDown
        case 0x65, 0x76: self = .menu
        case 0x43: self = .f10
        default: return nil
        }
    }
}

/// The item highlighted after `key` (↑/↓, Home/End, PgUp/PgDn by 10) in
/// `items`; with none highlighted, ↓ starts at the first and ↑ at the last.
func moveHighlight<ID: Equatable>(_ current: ID?, in items: [ID], _ key: NavKey) -> ID? {
    guard !items.isEmpty else { return nil }
    let i = current.flatMap { items.firstIndex(of: $0) }
    let last = items.count - 1
    switch key {
    case .up: return items[i.map { max(0, $0 - 1) } ?? last]
    case .down: return items[i.map { min(last, $0 + 1) } ?? 0]
    case .pageUp: return items[i.map { max(0, $0 - 10) } ?? 0]
    case .pageDown: return items[i.map { min(last, $0 + 10) } ?? last]
    case .home: return items[0]
    case .end: return items[last]
    default: return current.flatMap { items.contains($0) ? $0 : nil }
    }
}

/// The item highlighted after `key` in a grid of cards split in sections
/// (the hosts of each group), `columns` cards per row: ←/→ go to the
/// previous or next card, ↑/↓ to the card above or below (into the
/// previous or next section in the same column; ↓ from a row with nothing
/// under it goes to the last card of the section). Home/End and PgUp/PgDn
/// as in a list. With none highlighted, ↓/→ start at the first card and
/// ↑/← at the last.
func moveInGrid<ID: Equatable>(_ current: ID?, in sections: [[ID]], columns: Int, _ key: NavKey) -> ID? {
    let rows = sections.filter { !$0.isEmpty }
    let flat = rows.flatMap { $0 }
    guard !flat.isEmpty else { return nil }
    let c = max(1, columns)
    guard let current, let s = rows.firstIndex(where: { $0.contains(current) }),
          let i = rows[s].firstIndex(of: current) else {
        switch key {
        case .down, .right: return flat.first
        case .up, .left: return flat.last
        default: return moveHighlight(nil, in: flat, key)
        }
    }
    let section = rows[s]
    switch key {
    case .left, .right:
        let at = flat.firstIndex(of: current) ?? 0
        return flat[max(0, min(flat.count - 1, at + (key == .left ? -1 : 1)))]
    case .down:
        if i + c < section.count { return section[i + c] }
        // A row below that is shorter than this column.
        if i / c < (section.count - 1) / c { return section[section.count - 1] }
        guard s + 1 < rows.count else { return current }
        let next = rows[s + 1]
        return next[min(i % c, next.count - 1)]
    case .up:
        if i - c >= 0 { return section[i - c] }
        guard s > 0 else { return current }
        let previous = rows[s - 1]
        let lastRow = (previous.count - 1) / c * c
        return previous[min(lastRow + i % c, previous.count - 1)]
    default:
        return moveHighlight(current, in: flat, key)
    }
}
