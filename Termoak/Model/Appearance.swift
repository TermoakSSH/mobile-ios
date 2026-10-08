import CoreText
import SwiftTerm
import SwiftUI
import TermoakKit
import UIKit

/// Terminal colors: background, text, cursor and the 16 ANSI colors
/// (the 8 normal and the 8 bright ones).
struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let background: UInt32
    let foreground: UInt32
    let cursor: UInt32
    let ansi: [UInt32]

    var isLight: Bool { luminance(background) > 0.5 }

    var backgroundColor: SwiftUI.Color { SwiftUI.Color(hex: background) }
    var foregroundColor: SwiftUI.Color { SwiftUI.Color(hex: foreground) }
    /// Bars and panel: slightly lighter (or darker) than the background.
    var barColor: SwiftUI.Color { SwiftUI.Color(hex: blend(background, isLight ? 0x000000 : 0xFFFFFF, 0.06)) }
    var keyUIColor: UIColor { UIColor(hex: blend(background, isLight ? 0x000000 : 0xFFFFFF, 0.12)) }
    var barUIColor: UIColor { UIColor(hex: blend(background, isLight ? 0x000000 : 0xFFFFFF, 0.06)) }
    /// Color of the keys and accents (the theme's green).
    var accent: UInt32 { ansi[2] }

    func apply(to view: TerminalView) {
        view.nativeBackgroundColor = UIColor(hex: background)
        view.nativeForegroundColor = UIColor(hex: foreground)
        view.installColors(ansi.map { c in
            SwiftTerm.Color(red: UInt16((c >> 16) & 0xFF) * 257, green: UInt16((c >> 8) & 0xFF) * 257, blue: UInt16(c & 0xFF) * 257)
        })
        view.caretColor = UIColor(hex: cursor)
        view.layer.backgroundColor = UIColor(hex: background).cgColor
        view.setNeedsDisplay()
    }

    static func byId(_ id: String) -> TerminalTheme { all.first { $0.id == id } ?? all[0] }

    /// Theme of a host's terminal, by the engine's rule (the same in every
    /// app): `dark` and `light` (what the desktop's host editor saves) keep
    /// the app's theme if it is of that kind and otherwise use Termoak's or
    /// Termoak Light; the id of one of these themes uses it; anything else
    /// (or nothing) follows the app.
    static func forHost(_ value: String?, app: TerminalTheme) -> TerminalTheme {
        guard let v = value, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return app }
        return byId(terminalThemeForHost(value: v, appTheme: app.id))
    }

    /// The engine's themes (`terminalThemes()`): the same 15, ids and
    /// palettes as the desktop and Android, in the pickers' order. The ids
    /// are stored in the settings and in hosts.
    static let all: [TerminalTheme] = terminalThemes().map { TerminalTheme($0) }
}

extension TerminalTheme {
    /// A theme of the engine (its colors are ARGB).
    init(_ info: TerminalThemeInfo) {
        let c = info.colors
        self.init(id: info.id, name: info.name, background: c.background & 0xFFFFFF, foreground: c.foreground & 0xFFFFFF,
                  cursor: c.cursor & 0xFFFFFF, ansi: c.ansi.map { $0 & 0xFFFFFF })
    }
}

/// Monospaced fonts: the system ones and the ones bundled with the app
/// (Fonts/, OFL license).
struct TerminalFont: Identifiable, Hashable {
    let id: String
    let name: String
    /// PostScript name; `nil` = the system monospaced font (SF Mono).
    let postScript: String?

    func ui(_ size: Double) -> UIFont {
        if let postScript, let f = UIFont(name: postScript, size: CGFloat(size)) { return f }
        return UIFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }

    static func byId(_ id: String) -> TerminalFont { all.first { $0.id == id } ?? all[0] }

    static let all: [TerminalFont] = [
        TerminalFont(id: "sf-mono", name: "SF Mono", postScript: nil),
        TerminalFont(id: "jetbrains-mono", name: "JetBrains Mono", postScript: "JetBrainsMono-Regular"),
        TerminalFont(id: "source-code-pro", name: "Source Code Pro", postScript: "SourceCodePro-Regular"),
        TerminalFont(id: "fira-code", name: "Fira Code", postScript: "FiraCode-Regular"),
        TerminalFont(id: "menlo", name: "Menlo", postScript: "Menlo-Regular"),
        TerminalFont(id: "courier", name: "Courier New", postScript: "CourierNewPSMT"),
    ]

    /// Registers the bundled fonts (once, at launch).
    static func registerBundled() {
        for name in ["JetBrainsMono", "SourceCodePro", "FiraCode"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

// MARK: - Colors

private func components(_ hex: UInt32) -> (Double, Double, Double) {
    (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
}

private func luminance(_ hex: UInt32) -> Double {
    let (r, g, b) = components(hex)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

/// `a` blended with `b` in the proportion `t` (0 = `a`).
func blend(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
    let (ar, ag, ab) = components(a)
    let (br, bg, bb) = components(b)
    func c(_ x: Double, _ y: Double) -> UInt32 { UInt32(((x + (y - x) * t) * 255).rounded()) }
    return (c(ar, br) << 16) | (c(ag, bg) << 8) | c(ab, bb)
}

extension SwiftUI.Color {
    init(hex: UInt32) {
        let (r, g, b) = components(hex)
        self.init(red: r, green: g, blue: b)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        let (r, g, b) = components(hex)
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
