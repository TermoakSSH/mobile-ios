import TermoakKit
import SwiftUI

/// The software in the app and its licenses: Termoak itself (AGPL), its
/// engine, SwiftTerm and the bundled fonts (their full OFL texts come with
/// the app).
struct LicensesView: View {
    private struct Component: Identifiable {
        let name: String
        let license: String
        let url: String
        /// A license file in the app bundle (name without `.txt`).
        var file: String? = nil
        var id: String { name }
    }

    private let components: [Component] = [
        Component(name: "Termoak for iOS", license: "GNU AGPL v3", url: "https://github.com/TermoakSSH/mobile-ios"),
        Component(name: "Termoak core", license: "GNU AGPL v3", url: "https://github.com/TermoakSSH/core"),
        Component(name: "SwiftTerm", license: "MIT", url: "https://github.com/migueldeicaza/SwiftTerm"),
        Component(name: "JetBrains Mono", license: "SIL OFL 1.1", url: "https://github.com/JetBrains/JetBrainsMono",
                  file: "OFL-jetbrainsmono"),
        Component(name: "Fira Code", license: "SIL OFL 1.1", url: "https://github.com/tonsky/FiraCode", file: "OFL-firacode"),
        Component(name: "Source Code Pro", license: "SIL OFL 1.1", url: "https://github.com/adobe-fonts/source-code-pro",
                  file: "OFL-sourcecodepro"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(components) { c in row(c) }
            } footer: {
                Text("about.licenses.footer")
            }
        }
        .navigationTitle("about.licenses")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func row(_ c: Component) -> some View {
        if let file = c.file, let text = Self.bundled(file) {
            NavigationLink { LicenseText(title: c.name, text: text) } label: { label(c) }
        } else if let url = URL(string: c.url) {
            Link(destination: url) { label(c) }
        }
    }

    private func label(_ c: Component) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: c.name).foregroundColor(.primary)
            Text(verbatim: c.license).font(.caption).foregroundColor(.secondary)
        }
    }

    private static func bundled(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

private struct LicenseText: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// How this device appears in your accounts (Devices on the web): chosen
/// by you, else the system's name (just "iPhone" or "iPad" since iOS 16).
enum DeviceName {
    static let key = "device_name"

    /// The name chosen in Settings, if any.
    static var chosen: String? {
        let n = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? nil : n
    }

    static var current: String { chosen ?? UIDevice.current.name }

    /// Saves it and tells the engine (accounts signed in from now on show
    /// it). Empty: back to the system's name.
    static func set(_ name: String, core: TermoakCore) throws {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        UserDefaults.standard.set(n, forKey: key)
        try core.setDeviceName(name: n.isEmpty ? UIDevice.current.name : n)
    }
}
