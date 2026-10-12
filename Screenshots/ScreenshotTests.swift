import XCTest

/// The App Store screenshots: the app in demo mode (`-TermoakDemo YES`,
/// Termoak/Demo/), which needs no server, sshd or network. Each screen
/// starts from a fresh launch on its scene (`-TermoakDemoScene`); the test
/// finds everything by accessibility identifier, never by its text, so it
/// works in every language. The screenshots are attachments of the result
/// bundle, named `01_hosts`, `02_terminal`…; scripts/screenshots.sh runs this
/// on the simulators and copies them to fastlane/screenshots/.
///
/// Variables (with the TEST_RUNNER_ prefix in `xcodebuild test`):
/// - `SCREENSHOT_LANGUAGE`: the app's language (`en`, `es`).
/// - `SCREENSHOT_LOCALE`: its region (`en_US`, `es_ES`).
final class ScreenshotTests: XCTestCase {
    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUp() {
        super.setUp()
        // A screen that does not show up is reported, and the rest are still taken.
        continueAfterFailure = true
    }

    func testScreenshots() {
        // 01 Hosts: the list (phone) or the desktop layout's grid and sidebar (iPad).
        var app = launch(.hosts)
        waitFor(app, "host-web-1")
        snapshot("01_hosts")

        // 02 A terminal with the key bar: tapping web-1.
        if tap(app, "host-web-1") {
            waitFor(app, "key-bar", or: "terminal-view")
        } else {
            app = launch(.terminal)
            waitFor(app, "key-bar", or: "terminal-view")
        }
        snapshot("02_terminal", settle: 3)

        // 03 Four terminals side by side with broadcast input (iPad), the
        // copilot answering in the terminal (phone).
        if pad {
            app = launch(.split)
            waitFor(app, "broadcast-banner")
            snapshot("03_split", settle: 3)
        } else {
            app = launch(.copilot)
            waitFor(app, "approval-card", timeout: 30)
            snapshot("03_copilot", settle: 2)
        }

        // 04 An AI task waiting for approvals (risk, command, diff).
        app = launch(.ai)
        waitFor(app, "ai-task", timeout: 30)
        snapshot("04_ai", settle: 2)

        // 05 Files over SFTP with transfers under way.
        app = launch(.files)
        waitFor(app, "files-transfers", timeout: 30)
        snapshot("05_files", settle: 3)

        // 06 The host editor (protocol, logo).
        app = launch(.editor)
        waitFor(app, "host-editor")
        snapshot("06_host_editor", settle: 2)

        // 07 The members of a shared vault: Vaults in the sidebar (iPad) or
        // in Profile (phone), then the vault.
        app = launch(.vaults)
        if pad {
            tap(app, "sidebar-vaults")
        } else {
            let profile = app.tabBars.firstMatch.buttons.element(boundBy: 2)
            if profile.waitForExistence(timeout: 15) { profile.tap() } else { XCTFail("no tab bar") }
            tap(app, "settings-vaults")
        }
        tap(app, "vault-ops")
        waitFor(app, "vault-detail")
        snapshot("07_vault_members", settle: 2)

        // 08 The terminal themes (quick panel, Appearance).
        app = launch(.themes)
        waitFor(app, "quick-panel", timeout: 30)
        snapshot("08_themes", settle: 2)
    }

    // MARK: Helpers

    /// The scenes of the app's demo mode (Termoak/Demo/DemoMode.swift).
    private enum Scene: String {
        case hosts, terminal, split, copilot, ai, files, editor, vaults, themes
    }

    /// Opens the app (again) in demo mode on `scene`, in the language of the run.
    @discardableResult
    private func launch(_ scene: Scene) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-TermoakDemo", "YES", "-TermoakDemoScene", scene.rawValue]
        let env = ProcessInfo.processInfo.environment
        if let language = env["SCREENSHOT_LANGUAGE"], !language.isEmpty {
            app.launchArguments += ["-AppleLanguages", "(\(language))"]
        }
        if let locale = env["SCREENSHOT_LOCALE"], !locale.isEmpty {
            app.launchArguments += ["-AppleLocale", locale]
        }
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Waits for the element `id` (or `other`); a failure if neither shows up.
    @discardableResult
    private func waitFor(_ app: XCUIApplication, _ id: String, or other: String? = nil, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element(app, id).exists { return true }
            if let other, element(app, other).exists { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        XCTFail("“\(id)” did not show up")
        return false
    }

    /// Taps the element `id` once it shows up; a failure if it does not.
    @discardableResult
    private func tap(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 15) -> Bool {
        let e = element(app, id)
        guard e.waitForExistence(timeout: timeout) else {
            XCTFail("“\(id)” did not show up to be tapped")
            return false
        }
        e.tap()
        return true
    }

    /// Lets the screen settle and keeps a screenshot named `name`.
    private func snapshot(_ name: String, settle: TimeInterval = 1.5) {
        Thread.sleep(forTimeInterval: settle)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
