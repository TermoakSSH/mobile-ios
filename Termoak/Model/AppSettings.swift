import Foundation
import SwiftUI

/// App appearance. Raw values are stored in UserDefaults: keep them.
enum AppTheme: String, CaseIterable, Identifiable {
    case system = "sistema", dark = "oscuro", light = "claro"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return String(localized: "settings.theme.system")
        case .dark: return String(localized: "settings.theme.dark")
        case .light: return String(localized: "settings.theme.light")
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

/// Where the ways to continue the command being typed are suggested.
/// Raw values are stored in UserDefaults: keep them.
enum SuggestionMode: String, CaseIterable, Identifiable {
    /// Like on the desktop: dimmed text after the cursor and a floating list.
    case cursor
    /// In the key bar, at the start.
    case bar = "barra"
    case off = "desactivadas"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cursor: return String(localized: "settings.suggestions.cursor")
        case .bar: return String(localized: "settings.suggestions.bar")
        case .off: return String(localized: "settings.suggestions.off")
        }
    }
}

/// Preferences of this device (not synced).
/// The UserDefaults keys are kept as they were so existing settings survive.
@MainActor
final class AppSettings: ObservableObject {
    static let minFontSize: Double = 8
    static let maxFontSize: Double = 24
    private let d = UserDefaults.standard

    @Published var fontSize: Double { didSet { d.set(fontSize, forKey: "tamano_letra") } }
    @Published var appTheme: AppTheme { didSet { d.set(appTheme.rawValue, forKey: "tema") } }
    @Published var keepScreenOn: Bool { didSet { d.set(keepScreenOn, forKey: "pantalla_encendida") } }
    /// Terminal colors (`TerminalTheme.id`).
    @Published var terminalThemeId: String { didSet { d.set(terminalThemeId, forKey: "tema_terminal") } }
    /// Terminal font (`TerminalFont.id`).
    @Published var fontId: String { didSet { d.set(fontId, forKey: "fuente_terminal") } }
    /// Bar above the keyboard and groups of the quick access panel.
    @Published var keyboard: KeyboardLayout {
        didSet { if let data = try? JSONEncoder().encode(keyboard) { d.set(data, forKey: "teclado") } }
    }
    /// Quick access panel tab opened last.
    @Published var quickPanelTab: String { didSet { d.set(quickPanelTab, forKey: "pestana_panel") } }
    /// Gestures to move the cursor with a finger.
    @Published var gestureMode: GestureMode { didSet { d.set(gestureMode.rawValue, forKey: "modo_gestos") } }
    /// Command suggestions while typing.
    @Published var suggestionMode: SuggestionMode { didSet { d.set(suggestionMode.rawValue, forKey: "modo_sugerencias") } }
    /// On tablets: side panel in view.
    @Published var sidePanel: Bool { didSet { d.set(sidePanel, forKey: "panel_lateral") } }

    var lastServer: String? {
        get { d.string(forKey: "ultimo_servidor") }
        set { d.set(newValue, forKey: "ultimo_servidor") }
    }
    var lastEmail: String? {
        get { d.string(forKey: "ultimo_email") }
        set { d.set(newValue, forKey: "ultimo_email") }
    }
    /// The user already chose to use the app without a server: do not show the welcome again.
    var noServer: Bool {
        get { d.bool(forKey: "sin_servidor") }
        set { d.set(newValue, forKey: "sin_servidor") }
    }

    init() {
        let size = d.double(forKey: "tamano_letra")
        fontSize = size == 0 ? 13 : size
        appTheme = AppTheme(rawValue: d.string(forKey: "tema") ?? "") ?? .dark
        keepScreenOn = d.object(forKey: "pantalla_encendida") as? Bool ?? true
        terminalThemeId = d.string(forKey: "tema_terminal") ?? TerminalTheme.all[0].id
        fontId = d.string(forKey: "fuente_terminal") ?? TerminalFont.all[0].id
        keyboard = d.data(forKey: "teclado").flatMap { try? JSONDecoder().decode(KeyboardLayout.self, from: $0) } ?? .standard
        quickPanelTab = d.string(forKey: "pestana_panel") ?? "teclas"
        sidePanel = d.object(forKey: "panel_lateral") as? Bool ?? true
        gestureMode = GestureMode(rawValue: d.string(forKey: "modo_gestos") ?? "") ?? .hold
        suggestionMode = SuggestionMode(rawValue: d.string(forKey: "modo_sugerencias") ?? "") ?? .cursor
    }

    var terminalTheme: TerminalTheme { TerminalTheme.byId(terminalThemeId) }
    var terminalFont: TerminalFont { TerminalFont.byId(fontId) }

    func changeFontSize(_ delta: Double) {
        fontSize = min(AppSettings.maxFontSize, max(AppSettings.minFontSize, fontSize + delta))
    }
}

/// Server suggested when logging in.
let defaultServer = "https://termoak.com"
