import XCTest

/// Goes through the key bar, the cursor gesture and the quick access panel
/// against a test sshd, and saves screenshots.
///
/// Variables (with the TEST_RUNNER_ prefix in `xcodebuild test`):
/// - `TEST_DIR`: folder with the private key `client` (and where the
///   screenshots are left).
/// - `TEST_HOST`: `address:port:user` of the sshd.
///
/// The app runs in English (`-AppleLanguages (en)`): the labels below are the
/// English texts of Localizable.xcstrings.
final class KeyboardUITests: XCTestCase {
    private var dir: String { ProcessInfo.processInfo.environment["TEST_DIR"] ?? NSTemporaryDirectory() }

    private func saveScreenshot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(device)-\(name).png"))
    }

    /// Opens the app (with settings `arguments`) and connects to the test host.
    private func launchAndConnect(_ arguments: [String] = []) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        let host = try XCTUnwrap(env["TEST_HOST"], "TEST_HOST is missing")
        let app = XCUIApplication()
        app.launchEnvironment["TERMOAK_TEST_HOST"] = host
        app.launchEnvironment["TERMOAK_TEST_KEY"] = try String(contentsOfFile: "\(dir)/client", encoding: .utf8)
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += arguments
        app.launch()

        let noServer = app.buttons["Use without a server, only on this device"]
        if noServer.waitForExistence(timeout: 5) { noServer.tap() }
        let row = app.staticTexts["test"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let trust = app.buttons["Trust"]
        if trust.waitForExistence(timeout: 10) { trust.tap() }

        // Connected, with the keyboard and the bar.
        XCTAssertTrue(app.buttons["ctrl"].firstMatch.waitForExistence(timeout: 15), "the key bar does not appear")
        sleep(2)
        return app
    }

    /// Has the system copy and paste menu appeared?
    private func menuShown(_ app: XCUIApplication) -> Bool {
        ["Select All", "Seleccionar todo"].contains { app.menuItems[$0].exists || app.buttons[$0].exists }
    }

    // The settings arguments use the stored UserDefaults keys and values
    // (`modo_gestos`, `mantener`...), which keep their original names.

    func testBarPanelAndGesture() throws {
        let app = try launchAndConnect(["-modo_gestos", "mantener", "-modo_sugerencias", "cursor"])
        let ctrl = app.buttons["ctrl"].firstMatch
        app.typeText("echo hello\n")
        app.typeText("ls /\n")
        sleep(1)
        saveScreenshot("01-terminal-bar")

        // ↑ from the bar: the shell's last command.
        app.buttons["↑"].firstMatch.tap()
        sleep(1)
        saveScreenshot("02-arrow-up")
        // Ctrl (stays pressed) + c from the keyboard = ^C.
        ctrl.tap()
        saveScreenshot("03-ctrl-pressed")
        app.typeText("c")
        sleep(1)

        // Gesture: holding and dragging to the left moves the cursor.
        app.typeText("echo abcdef")
        sleep(1)
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.35))
        start.press(forDuration: 0.5, thenDragTo: start.withOffset(CGVector(dx: -60, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertFalse(menuShown(app), "the gesture opened the copy menu")
        app.typeText("Z")
        sleep(1)
        saveScreenshot("04-cursor-gesture")
        app.typeText("\n")
        sleep(1)

        // Suggestions: while typing, the history ones show up in the bar.
        app.typeText("ech")
        let suggestion = app.buttons["Suggestion: echo hello"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "the suggestion “echo hello” does not show up")
        saveScreenshot("04b-suggestions")
        suggestion.tap()
        sleep(1)
        saveScreenshot("04c-suggestion-accepted")
        app.typeText("\n")
        sleep(1)

        // Quick access panel (on the tablet it is already in view, on the side).
        if !app.buttons["History"].exists { app.buttons["Quick access panel"].firstMatch.tap() }
        sleep(1)
        saveScreenshot("05-panel-keys")
        app.buttons["History"].tap()
        sleep(1)
        XCTAssertTrue(app.staticTexts["echo hello"].waitForExistence(timeout: 5), "the history does not have “echo hello”")
        // Also what was edited with the cursor in the middle (the gesture).
        XCTAssertTrue(app.staticTexts["echo abcdZef"].exists, "the history does not have “echo abcdZef”")
        saveScreenshot("06-panel-history")
        app.buttons["Snippets"].tap()
        sleep(1)
        saveScreenshot("07-panel-snippets")
        app.buttons["Appearance"].tap()
        sleep(1)
        saveScreenshot("08-panel-appearance")
        app.buttons["Dracula"].tap()
        sleep(1)
        saveScreenshot("09-theme-dracula")
        app.buttons["Keys"].tap()
        app.buttons["Customize"].tap()
        sleep(1)
        saveScreenshot("10-customize")
        app.buttons["Done"].tap()
        sleep(1)

        // Back to the keyboard (on the phone; on the tablet the panel is on the side).
        let keyboard = app.buttons["Back to keyboard"]
        if keyboard.exists {
            keyboard.tap()
            sleep(1)
        }
        saveScreenshot("11-final")
    }

    /// Simple gestures: swiping without holding moves the cursor.
    func testSwipeGesture() throws {
        let app = try launchAndConnect(["-modo_gestos", "deslizar"])
        app.typeText("echo abcdef")
        sleep(1)
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.35))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: -60, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertFalse(menuShown(app), "swiping opened the copy menu")
        app.typeText("Z")
        sleep(1)
        saveScreenshot("20-swipe")
        app.typeText("\n")
        sleep(1)
        // Holding still still opens the copy menu.
        start.press(forDuration: 1.2)
        sleep(1)
        XCTAssertTrue(menuShown(app), "holding still does not open the copy menu")
        saveScreenshot("21-copy-menu")
    }

    /// SFTP: browse, view a file, create and delete a folder (all inside a
    /// test folder in /tmp; the sshd is the real account).
    func testFilesSFTP() throws {
        let base = "/tmp/termoak-sftp-test"
        try? FileManager.default.removeItem(atPath: base)
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try "hello from SFTP\n".write(toFile: "\(base)/hello.txt", atomically: true, encoding: .utf8)
        // If an interaction fails, XCTest stops the test without going through `defer`.
        addTeardownBlock { try? FileManager.default.removeItem(atPath: base) }

        let app = try launchAndConnect()
        menuOption(app, "Files (SFTP)")
        let root = app.buttons["sftp-root"]
        XCTAssertTrue(root.waitForExistence(timeout: 10), "the browser does not open")
        root.tap()
        searchAndOpen(app, "tmp")
        searchAndOpen(app, "termoak-sftp-test")
        XCTAssertTrue(app.buttons["sftp-hello.txt"].waitForExistence(timeout: 10))
        saveScreenshot("30-sftp-folder")

        // View a file (iOS preview).
        app.buttons["sftp-hello.txt"].tap()
        sleep(3)
        saveScreenshot("31-sftp-preview")
        XCTAssertTrue(app.staticTexts["hello from SFTP"].exists || app.textViews.firstMatch.exists, "the preview does not show the file")
        app.buttons["close-preview"].tap()
        sleep(1)

        // New folder, then delete it.
        app.buttons["Actions"].tap()
        app.buttons["New folder"].tap()
        app.textFields["Name"].typeText("sub")
        app.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["sftp-sub"].waitForExistence(timeout: 10), "the folder was not created")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(base)/sub"))
        saveScreenshot("32-sftp-new-folder")
        app.buttons["sftp-sub"].swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        app.sheets.buttons["Delete"].firstMatch.tap()
        sleep(2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/sub"), "the folder was not deleted")
        app.navigationBars.buttons["Close"].firstMatch.tap()
    }

    /// Local tunnel to the sshd itself: from outside the app, the tunnel port
    /// answers with the SSH greeting.
    func testLocalTunnel() throws {
        let app = try launchAndConnect()
        menuOption(app, "Tunnels")
        app.buttons["New tunnel"].tap()
        let fields = app.textFields
        fields["Name (optional)"].tap()
        fields["Name (optional)"].typeText("test sshd")
        fields["Port (empty = any free one)"].tap()
        fields["Port (empty = any free one)"].typeText("18022")
        fields["Port"].tap()
        fields["Port"].typeText("2222")
        app.buttons["Save"].tap()
        let toggle = app.switches["test sshd"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        sleep(2)
        saveScreenshot("33-tunnel-active")
        XCTAssertTrue(sshGreeting(port: 18022).hasPrefix("SSH-2.0"), "the tunnel does not lead to the sshd")
        sleep(2)
        saveScreenshot("34-tunnel-stats")
        toggle.tap()
        sleep(1)
        XCTAssertEqual(sshGreeting(port: 18022), "", "the tunnel is still open after stopping it")
    }

    /// Searches for an entry in the SFTP browser folder and opens it.
    private func searchAndOpen(_ app: XCUIApplication, _ name: String) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the search field is missing")
        field.tap()
        field.typeText(name)
        let row = app.buttons["sftp-\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "“\(name)” does not show up")
        row.tap()
    }

    /// Picks an option of the terminal's “⋯” menu. SwiftUI menu options do not
    /// always give a valid point to tap them: they are tapped by coordinates.
    private func menuOption(_ app: XCUIApplication, _ name: String) {
        app.buttons["terminal-menu"].tap()
        let option = app.buttons[name].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "“\(name)” is not in the menu")
        option.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// First line the server sends on 127.0.0.1:`port` ("" if nothing).
    private func sshGreeting(port: UInt16) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "" }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { return "" }
        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buf, buf.count)
        return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
    }

    /// Gestures with a button: off, one finger does not move the cursor; on, it does.
    func testGesturesWithButton() throws {
        let app = try launchAndConnect(["-modo_gestos", "boton"])
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.35))
        func drag() {
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: -60, dy: 0)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        app.typeText("echo abcdef")
        sleep(1)
        drag()                     // off: scrolls, the cursor does not move
        app.typeText("Y")
        let button = app.buttons["Move the cursor with your finger"].firstMatch
        XCTAssertTrue(button.exists, "the gestures button is missing")
        button.tap()
        sleep(1)
        saveScreenshot("40-gesture-button-on")
        drag()                     // on: two arrows to the left
        app.typeText("Z")
        app.typeText("\n")
        sleep(1)
        app.buttons["Quick access panel"].firstMatch.tap()
        app.buttons["History"].tap()
        // Off it did not move (the Y stays at the end); on it did (the Z goes before).
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'echo abcde' AND label ENDSWITH 'Y' AND label CONTAINS 'Z'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5), "the button does not change what one finger does")
        XCTAssertFalse(app.staticTexts["echo abcdefYZ"].exists, "with the button on the cursor did not move")
        saveScreenshot("41-gesture-button-history")
    }
}
