import Foundation

// The keyboard layout is stored in UserDefaults as JSON (`AppSettings.keyboard`).
// The raw values and coding keys below keep the names it was first saved
// with, so existing layouts keep loading: do not change them.

/// Keys the phone keyboard does not have.
enum SpecialKey: String, Codable, CaseIterable, Hashable {
    case esc, tab, shiftTab, enter = "intro", backspace = "retroceso", ins, del = "supr"
    case home = "inicio", end = "fin", pageUp = "rePag", pageDown = "avPag"
    case up = "arriba", down = "abajo", left = "izquierda", right = "derecha"
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    /// Short name (the one used in the combinations of custom keys).
    var name: String {
        switch self {
        case .esc: return "esc"
        case .tab: return "tab"
        case .shiftTab: return "shift+tab"
        case .enter: return "enter"
        case .backspace: return "bksp"
        case .ins: return "ins"
        case .del: return "del"
        case .home: return "home"
        case .end: return "end"
        case .pageUp: return "pgup"
        case .pageDown: return "pgdn"
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        default: return rawValue
        }
    }

    var isArrow: Bool { [.up, .down, .left, .right].contains(self) }

    /// Sequence that is sent. `ctrl`/`alt` (from the bar) and `shift` (a
    /// hardware keyboard) change the arrows and editing keys like xterm does
    /// (`ESC [ 1 ; m X`, `ESC [ n ; m ~`); `appCursor` is the application
    /// cursor mode (vim, less...).
    func bytes(ctrl: Bool, alt: Bool, shift: Bool = false, appCursor: Bool) -> [UInt8] {
        let mod = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
        func csi(_ s: String) -> [UInt8] { Array("\u{1b}[\(s)".utf8) }
        /// Arrows, home and end: `ESC [ X`, `ESC O X` or `ESC [ 1 ; m X`.
        func cursor(_ letter: Character) -> [UInt8] {
            if mod > 1 { return csi("1;\(mod)\(letter)") }
            return Array((appCursor ? "\u{1b}O\(letter)" : "\u{1b}[\(letter)").utf8)
        }
        /// Tilde keys: `ESC [ n ~` or `ESC [ n ; m ~`.
        func tilde(_ n: Int) -> [UInt8] { csi(mod > 1 ? "\(n);\(mod)~" : "\(n)~") }
        /// F1–F4: `ESC O P` or `ESC [ 1 ; m P`.
        func ss3(_ letter: Character) -> [UInt8] {
            mod > 1 ? csi("1;\(mod)\(letter)") : Array("\u{1b}O\(letter)".utf8)
        }
        let altPrefix: [UInt8] = alt ? [0x1b] : []
        switch self {
        case .esc: return [0x1b]
        case .tab: return altPrefix + [0x09]
        case .shiftTab: return csi("Z")
        case .enter: return altPrefix + [0x0d]
        case .backspace: return altPrefix + [ctrl ? 0x08 : 0x7f]
        case .ins: return tilde(2)
        case .del: return tilde(3)
        case .pageUp: return tilde(5)
        case .pageDown: return tilde(6)
        case .home: return cursor("H")
        case .end: return cursor("F")
        case .up: return cursor("A")
        case .down: return cursor("B")
        case .right: return cursor("C")
        case .left: return cursor("D")
        case .f1: return ss3("P")
        case .f2: return ss3("Q")
        case .f3: return ss3("R")
        case .f4: return ss3("S")
        case .f5: return tilde(15)
        case .f6: return tilde(17)
        case .f7: return tilde(18)
        case .f8: return tilde(19)
        case .f9: return tilde(20)
        case .f10: return tilde(21)
        case .f11: return tilde(23)
        case .f12: return tilde(24)
        }
    }
}

/// One part of what a key sends.
enum KeyStep: Codable, Hashable {
    case text(String)
    case special(SpecialKey)
    /// Ctrl + a character (`ctrl+b` = 0x02).
    case ctrl(String)
    case alt(String)

    enum CodingKeys: String, CodingKey {
        case text = "texto", special = "especial", ctrl, alt
    }

    func bytes(ctrl modCtrl: Bool, alt modAlt: Bool, appCursor: Bool) -> [UInt8] {
        switch self {
        case .special(let e):
            return e.bytes(ctrl: modCtrl, alt: modAlt, appCursor: appCursor)
        case .ctrl(let c):
            return (modAlt ? [0x1b] : []) + controlByte(c)
        case .alt(let c):
            return [0x1b] + (modCtrl ? controlByte(c) : Array(c.utf8))
        case .text(let t):
            // The bar modifiers apply to the first character.
            guard (modCtrl || modAlt), let first = t.first else { return Array(t.utf8) }
            let rest = Array(t.dropFirst().utf8)
            let base = modCtrl ? controlByte(String(first)) : Array(String(first).utf8)
            return (modAlt ? [0x1b] : []) + base + rest
        }
    }
}

/// Control byte of Ctrl + character, like a real keyboard.
func controlByte(_ c: String) -> [UInt8] {
    guard let ch = c.lowercased().unicodeScalars.first else { return [] }
    switch ch {
    case "a"..."z": return [UInt8(ch.value - 0x60)]
    case "@", " ", "2": return [0x00]
    case "[", "3": return [0x1b]
    case "\\", "4": return [0x1c]
    case "]", "5": return [0x1d]
    case "^", "6": return [0x1e]
    case "_", "-", "7", "/": return [0x1f]
    case "?", "8": return [0x7f]
    default: return Array(c.utf8)
    }
}

enum KeyModifier: String, Codable, Hashable { case ctrl, alt }

enum KeyAction: Codable, Hashable {
    /// Stays pressed until the next key.
    case modifier(KeyModifier)
    case steps([KeyStep])
    /// Pastes the clipboard.
    case paste

    enum CodingKeys: String, CodingKey {
        case modifier = "modificador", steps = "pasos", paste = "pegar"
    }
}

struct ShortcutKey: Codable, Hashable, Identifiable {
    var id: String
    var label: String
    /// SF Symbols symbol instead of the text.
    var icon: String?
    var action: KeyAction
    /// Repeats while held (arrows, delete).
    var repeats: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, label = "etiqueta", icon = "icono", action = "accion", repeats = "repetir"
    }

    /// Takes two slots in the panel grid.
    var wide: Bool { icon == nil && label.count > 5 }

    /// Text to show (and to read with VoiceOver). The built-in paste key is
    /// shown in the app language; the rest show their label.
    var title: String {
        id == ShortcutKey.paste.id ? String(localized: "common.paste") : label
    }

    static func special(_ e: SpecialKey, _ label: String, icon: String? = nil, repeats: Bool = false) -> ShortcutKey {
        ShortcutKey(id: "esp.\(e.rawValue)", label: label, icon: icon, action: .steps([.special(e)]), repeats: repeats)
    }

    static func text(_ t: String) -> ShortcutKey {
        ShortcutKey(id: "txt.\(t)", label: t, action: .steps([.text(t)]))
    }

    /// Ctrl + letter (`^C`).
    static func control(_ letter: String) -> ShortcutKey {
        ShortcutKey(id: "ctl.\(letter.lowercased())", label: "^\(letter.uppercased())", action: .steps([.ctrl(letter.lowercased())]))
    }

    /// tmux prefix (Ctrl+B) and a key.
    static func tmux(_ t: String) -> ShortcutKey {
        ShortcutKey(id: "tmux.\(t)", label: "ctrl+B, \(t)", action: .steps([.ctrl("b"), .text(t)]))
    }

    static let ctrl = ShortcutKey(id: "mod.ctrl", label: "ctrl", action: .modifier(.ctrl))
    static let alt = ShortcutKey(id: "mod.alt", label: "alt", action: .modifier(.alt))
    static let paste = ShortcutKey(id: "pegar", label: "Paste", icon: "doc.on.clipboard", action: .paste)
}

struct KeyGroup: Codable, Hashable, Identifiable {
    var id: String
    /// Name chosen by the user. Empty for a built-in group that keeps its
    /// default name (shown in the app language, see `title`).
    var name: String
    var keys: [ShortcutKey]
    var visible: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, name = "nombre", keys = "teclas", visible
    }

    /// Id of the group that holds the user's own keys.
    static let customGroupId = "propias"

    /// Catalog keys of the built-in groups' default names, by group id.
    private static let defaultNameKeys: [String: String] = [
        "basicas": "keys.group.basic",
        "flechas": "keys.group.arrows",
        "tmux": "keys.group.tmux",
        "simbolos": "keys.group.symbols",
        "control": "keys.group.control",
        "funciones": "keys.group.functions",
        "propias": "keys.group.custom",
    ]

    /// Default names the built-in groups were saved with by earlier versions
    /// (before the app was translated): they also count as "not renamed".
    private static let legacyDefaultNames: [String: String] = [
        "basicas": "B\u{E1}sicas",
        "flechas": "Flechas y saltos",
        "tmux": "tmux",
        "simbolos": "S\u{ED}mbolos",
        "control": "Control",
        "funciones": "Funciones",
        "propias": "Mis teclas",
    ]

    /// Name to show: the user's name, or the default one in the app language.
    var title: String {
        guard let key = Self.defaultNameKeys[id],
              name.isEmpty || name == Self.legacyDefaultNames[id] else { return name }
        return Bundle.main.localizedString(forKey: key, value: name, table: nil)
    }
}

/// What can be customized: the bar above the keyboard and the groups of the
/// quick access panel.
struct KeyboardLayout: Codable, Equatable {
    var bar: [ShortcutKey]
    var groups: [KeyGroup]

    enum CodingKeys: String, CodingKey {
        case bar = "barra", groups = "grupos"
    }

    /// All the keys (to add them to the bar).
    var all: [ShortcutKey] {
        var seen = Set<String>()
        return (groups.flatMap(\.keys) + bar).filter { seen.insert($0.id).inserted }
    }

    static let standard: KeyboardLayout = {
        let arrows: [ShortcutKey] = [
            .special(.left, "←", icon: "arrow.left", repeats: true),
            .special(.right, "→", icon: "arrow.right", repeats: true),
            .special(.up, "↑", icon: "arrow.up", repeats: true),
            .special(.down, "↓", icon: "arrow.down", repeats: true),
        ]
        let enter = ShortcutKey.special(.enter, "enter", icon: "return")
        let esc = ShortcutKey.special(.esc, "esc")
        let tab = ShortcutKey.special(.tab, "tab")
        // Empty names: the built-in groups show their name in the app language.
        return KeyboardLayout(
            bar: [.paste, enter, esc, .ctrl, .alt, tab] + arrows + [.control("c"), .text("|"), .text("/"), .text("-"), .text("~")],
            groups: [
                KeyGroup(id: "basicas", name: "",
                         keys: [.paste, enter, esc, tab, .ctrl, .alt, .special(.shiftTab, "shift+tab"),
                                .special(.backspace, "bksp", icon: "delete.left", repeats: true),
                                .special(.ins, "ins"), .special(.del, "del")]),
                KeyGroup(id: "flechas", name: "",
                         keys: arrows + [.special(.home, "home"), .special(.pageUp, "pgUp"), .special(.pageDown, "pgDn"), .special(.end, "end")]),
                KeyGroup(id: "tmux", name: "",
                         keys: ["c", "n", "p", "d", "%", "\"", "o", "x", "z", "["].map(ShortcutKey.tmux)),
                KeyGroup(id: "simbolos", name: "",
                         keys: ["|", "\\", "/", "?", "~", "@", "$", "#", ":", ";", "!", "%", "&", "*", "=", "`",
                                "'", "\"", "-", "_", "+", "^", "<", ">", "(", ")", "{", "}", "[", "]"].map(ShortcutKey.text)),
                KeyGroup(id: "control", name: "",
                         keys: ["c", "d", "z", "l", "r", "a", "e", "u", "w", "k", "s", "q"].map(ShortcutKey.control)
                             + [ShortcutKey(id: "ctl._", label: "^_", action: .steps([.ctrl("_")]))]),
                KeyGroup(id: "funciones", name: "",
                         keys: [SpecialKey.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12]
                             .map { ShortcutKey.special($0, $0.rawValue.uppercased()) }),
                KeyGroup(id: KeyGroup.customGroupId, name: "", keys: []),
            ]
        )
    }()
}

// MARK: - Custom keys

/// Turns what the user types into steps: parts separated by spaces or commas
/// such as `ctrl+b`, `alt+x`, `^C`, `esc`, `enter`, `up`, `f5`...
/// Returns the error to show if some part is not understood.
func parseCombination(_ text: String) -> Result<[KeyStep], CombinationError> {
    let parts = text
        .replacingOccurrences(of: ",", with: " ")
        .split(separator: " ")
        .map { String($0) }
    var steps: [KeyStep] = []
    for part in parts {
        let p = part.lowercased()
        if let e = SpecialKey.allCases.first(where: { $0.name == p || $0.rawValue.lowercased() == p }) {
            steps.append(.special(e))
        } else if ["return", "intro", "cr"].contains(p) {
            steps.append(.special(.enter))
        } else if ["escape"].contains(p) {
            steps.append(.special(.esc))
        } else if p.hasPrefix("ctrl+"), p.count == 6 {
            steps.append(.ctrl(String(p.last!)))
        } else if p.hasPrefix("alt+"), p.count == 5 {
            steps.append(.alt(String(part.last!)))
        } else if p.hasPrefix("^"), p.count == 2 {
            steps.append(.ctrl(String(p.last!)))
        } else {
            return .failure(CombinationError(part: part))
        }
    }
    return .success(steps)
}

struct CombinationError: Error, Equatable {
    let part: String
    var message: String { String(localized: "keys.combination.error \(part)") }
}

/// Readable text of a key's steps (for the editor lists).
func describe(_ action: KeyAction) -> String {
    switch action {
    case .modifier(let m): return String(localized: "keys.describe.modifier \(m.rawValue)")
    case .paste: return String(localized: "keys.describe.paste")
    case .steps(let steps):
        return steps.map { step -> String in
            switch step {
            case .special(let e): return e.name
            case .ctrl(let c): return "ctrl+\(c)"
            case .alt(let c): return "alt+\(c)"
            case .text(let t): return "“\(t.replacingOccurrences(of: "\r", with: "⏎"))”"
            }
        }.joined(separator: ", ")
    }
}
