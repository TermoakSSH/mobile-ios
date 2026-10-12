import Foundation
import TermoakKit

// Demo mode, for the App Store screenshots (scripts/screenshots.sh and the
// TermoakScreenshots UI test). It is compiled in every build but only turns
// on with the launch argument `-TermoakDemo YES`, which only Xcode or
// `xcodebuild test` can pass: the app then opens an engine on an empty
// temporary folder (never the vault, never the Keychain) and `DemoCore`
// answers the accounts, vaults, hosts, AI, server sessions, terminals and
// SFTP with the made-up data of DemoData.swift, without any network.
// `-TermoakDemoScene <scene>` sets the screen it starts on (DemoDirector).

/// The screens the demo can start on.
enum DemoScene: String {
    /// The hosts (the start screen).
    case hosts
    /// A terminal to web-1.
    case terminal
    /// Four terminals side by side with broadcast input (iPad).
    case split
    /// A terminal with the copilot answering (iPhone).
    case copilot
    /// An AI task waiting for approvals.
    case ai
    /// SFTP with transfers.
    case files
    /// The editor of web-1.
    case editor
    /// The vaults (the UI test goes on to a shared vault's members).
    case vaults
    /// A terminal with the themes of the quick panel.
    case themes
}

enum DemoMode {
    /// `-TermoakDemo YES` was passed at launch.
    static let isOn: Bool = argument("-TermoakDemo").map { ["yes", "1", "true"].contains($0.lowercased()) } ?? false

    /// `-TermoakDemoScene <scene>` (the hosts if missing or unknown).
    static let scene: DemoScene = argument("-TermoakDemoScene").flatMap(DemoScene.init(rawValue:)) ?? .hosts

    /// The demo's texts follow the app's language (English or Spanish).
    static var spanish: Bool {
        (Bundle.main.preferredLocalizations.first ?? "en").lowercased().hasPrefix("es")
    }

    /// What a call the demo does not imitate throws.
    static let unavailable = TermoakError.Invalid(message: "Not available in the demo")

    private static func argument(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// The settings the demo starts with, over whatever this device saved
    /// (the volatile argument domain: nothing is written; launch arguments
    /// still win). Called before the settings are read.
    static func prepare() {
        guard isOn else { return }
        let values: [String: Any] = [
            "account_aliases": DemoData.aliases,
            "host_status_checks": true,
            "accounts_device_only": false,
            "desktop_sidebar_collapsed": false,
            "key_bar_hardware_keyboard": true,
            "notifications_asked": true,
            "tema": "oscuro",
            "wide_layout": "automatic",
            "hide_emails": false,
            "ai_fix_chip": true,
            // The quick panel next to the terminal (iPad), but not in the
            // split view; on its Appearance tab for the themes.
            "panel_lateral": scene != .split,
            "pestana_panel": scene == .themes ? "apariencia" : "teclas",
            "tema_terminal": scene == .themes ? "dracula" : "termoak",
        ]
        let d = UserDefaults.standard
        d.register(defaults: values)
        let given = d.volatileDomain(forName: UserDefaults.argumentDomain)
        d.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        d.setVolatileDomain(values.merging(given) { _, launch in launch }, forName: UserDefaults.argumentDomain)
    }

    /// The engine of the demo: a new vault in a temporary folder with a
    /// throwaway key, and the demo's answers on top.
    static func makeCore() throws -> TermoakCore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("termoak-demo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try DemoCore(dataDir: dir.path, vaultKeyB64: generateVaultKey())
    }
}

/// English or Spanish text of the demo data.
func demoText(_ en: String, _ es: String) -> String {
    DemoMode.spanish ? es : en
}
