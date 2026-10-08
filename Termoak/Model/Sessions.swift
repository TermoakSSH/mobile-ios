import TermoakKit
import Combine
import CoreText
import SwiftTerm
import SwiftUI
import UIKit

enum TerminalState: Equatable {
    case connecting(String)
    case connected
    case closed(String)

    /// Generic text while connecting (before the engine reports any step).
    static var connectingMessage: String { String(localized: "terminal.state.connecting") }
}

/// An open terminal: SSH from the phone or a session that lives on the
/// server. Each one has its SwiftTerm view, which interprets the output, with
/// our key bar above the keyboard and the cursor gestures.
@MainActor
class TerminalSession: NSObject, ObservableObject, Identifiable, TerminalViewDelegate {
    let id = UUID()
    let core: TermoakCore
    let label: String
    let hostId: String?
    /// Account of the host and of the server session (`nil`: This device,
    /// or the current account for sessions opened without a host).
    let accountId: String?
    let view: TerminalView
    let settings: AppSettings
    /// Terminal theme chosen in the host (`dark`, `light`, as the desktop
    /// saves it; `nil`: the app's).
    let hostTheme: String?

    @Published var state: TerminalState = .connecting(TerminalState.connectingMessage) {
        didSet {
            switch state {
            case .connected: if connectedAt == nil { connectedAt = Date() }
            case .connecting, .closed:
                connectedAt = nil
                latency = nil
            }
        }
    }
    /// Last round trip to the host in milliseconds (`nil`: unknown), shown
    /// in the bar while the terminal is on screen (`measureLatency`).
    @Published fileprivate(set) var latency: Double?
    /// When the current connection was made (the time shown in Connections).
    private(set) var connectedAt: Date?
    /// Tab of a server session that was open at launch: it is not attached
    /// until tapped.
    @Published var asleep = false
    @Published var title: String?
    /// Name given to the tab by hand ("Rename"); `nil`: the automatic one.
    @Published var customTitle: String?
    /// The tab's name: the one given by hand, the program's title or the host's name.
    var displayTitle: String { TabTitle.display(custom: customTitle, title: title, label: label) }
    @Published var prompt: AuthPrompt?
    /// Ctrl and Alt of the bar: they stay pressed until the next key.
    @Published private(set) var ctrl = false
    @Published private(set) var alt = false
    /// Pad of the move-the-cursor gesture (long press and drag).
    @Published var cursorPad: CursorPad?
    /// How to continue the line being typed (history, snippets, commands).
    @Published private(set) var suggestions: [CommandSuggestion] = []
    /// Something was typed and the shell has not shown it yet: the dimmed text
    /// after the cursor hides for a moment so it does not jump.
    @Published private(set) var awaitingEcho = false
    /// Where the suggestions are shown (Settings).
    private(set) var suggestionMode: SuggestionMode = .cursor
    /// Cursor gestures (Settings).
    @Published private(set) var gestureMode: GestureMode = .hold
    /// In button mode: one finger moves the cursor (instead of scrolling).
    @Published private(set) var cursorByButton = false

    // ----- Live sharing -----

    /// Your input and resizes reach the terminal: always in a terminal of
    /// this device; in a shared server session only for the owner and for
    /// whoever has the keyboard (the driver). Nothing is sent otherwise.
    @Published var canWrite = true {
        didSet { if canWrite != oldValue { writeAccessChanged() } }
    }
    /// You own the session (you can share it, let people in, hand over the keyboard...).
    @Published var isOwner = true
    /// Your permission: guests with `control` can ask for the keyboard.
    @Published var access: SessionAccess = .owner
    /// People in the session (empty while it is not shared).
    @Published var participants: [SessionParticipant] = []
    /// Participant with the keyboard (`nil`: the owner).
    @Published var driverId: String?
    @Published var driverName: String?
    /// When the driver's timed grant ends (`nil`: until it is given back or taken).
    @Published var driverUntil: Date?
    /// Owner: people waiting to be let in or asking for the keyboard.
    @Published var requests: [ShareRequest] = []
    /// Guest: you asked for the keyboard (until the server says otherwise).
    @Published var askedForControl = false
    /// Guest: in the waiting room until the owner lets you in.
    @Published var waiting: WaitingRoom?
    /// The server sent you away for good: there is no reconnecting.
    @Published var ended: ShareEnd?
    /// Short message over the terminal ("You have control"...).
    @Published private(set) var flash: String?
    private var flashCount = 0
    private var lastReadOnlyHint: Date?
    /// Toasts of the whole app (the requests answered here are removed there).
    weak var notices: ShareNotices?

    /// What is typed, to save the sent commands in the history.
    private let line = LineTracker()
    private(set) var keyBar: KeyBar!
    private var gesture: CursorGesture?
    /// Trackpad and mouse: scroll wheel, drag to select, secondary click.
    private var pointer: TerminalPointer?
    /// Pinch to change the text size and a tap on a link.
    private var touches: TerminalTouches?
    private var observers: [NSObjectProtocol] = []
    /// Requested by the key bar (grid button).
    var onOpenPanel: (() -> Void)?
    /// What is typed here, to broadcast it to the other panes (`Sessions`).
    var onMirror: ((TerminalSession, MirroredInput) -> Void)?
    /// A paste of several lines that has to be confirmed first (`Sessions`).
    var onConfirmPaste: ((TerminalSession, String) -> Void)?
    /// Set while the output is interpreted: what the terminal answers then
    /// was not typed (and is not broadcast).
    private let feeding = FeedFlag()
    /// Host OS, to suggest the right package manager.
    private let os: String?
    /// Look for suggestions as soon as the echo of what was typed arrives.
    private var suggestAfterEcho = false
    private var query = 0

    /// Lives on the server: closing the tab only detaches it.
    var persistent: Bool { false }
    /// A Telnet terminal (unencrypted; no SFTP, tunnels or server sessions).
    var isTelnet: Bool { false }
    /// Its latency can be measured (terminals of this device).
    var measuresLatency: Bool { false }

    /// Measures the latency once.
    func measureLatency() async {}

    /// Measures the latency every few seconds while connected, until the
    /// task is cancelled (the bar's task, while the terminal is on screen).
    func pollLatency() async {
        guard measuresLatency, state == .connected else { return }
        while !Task.isCancelled {
            await measureLatency()
            try? await Task.sleep(nanoseconds: UInt64(Latency.interval * 1_000_000_000))
        }
    }

    /// Container of `view` on screen: it zooms the terminal out when it
    /// keeps a size bigger than the screen (`followSize`).
    private(set) lazy var viewport = TerminalViewport(terminal: view)
    /// Columns and rows of the terminal on the server that a read-only guest
    /// keeps (the owner's or the driver's), zoomed to fit; `nil`: the
    /// terminal takes the size of this screen.
    fileprivate(set) var followSize: TermSize? {
        didSet {
            guard followSize != oldValue else { return }
            gesture?.suspended = followSize != nil
            touches?.pinchEnabled = followSize == nil
            viewport.follow = followSize
        }
    }

    init(core: TermoakCore, label: String, hostId: String?, accountId: String? = nil, settings: AppSettings) {
        self.core = core
        self.label = label
        self.hostId = hostId
        self.accountId = accountId
        self.settings = settings
        let host = hostId.flatMap { try? core.getHost(id: $0, accountId: accountId) }
        os = host?.os
        hostTheme = host?.settings.theme
        let terminal = TermoakTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), font: nil,
                                           options: TerminalSession.terminalOptions)
        view = terminal
        super.init()
        terminal.onPaste = { [weak self] in self?.pasteClipboard() }
        view.terminalDelegate = self
        applyAppearance(settings)
        keyBar = KeyBar(session: self, settings: settings)
        keyBar.applyTheme(theme)
        view.inputAccessoryView = keyBar
        gesture = CursorGesture(session: self)
        pointer = TerminalPointer(view: view)
        touches = TerminalTouches(session: self)
        gestureMode = settings.gestureMode
        gesture?.configure(gestureMode, cursorByButton: cursorByButton)
        #if DEBUG
        // No blinking in the UI tests: otherwise the app is never "idle" and
        // XCUITest waits a minute on every step.
        if ProcessInfo.processInfo.environment["TERMOAK_TEST_HOST"] != nil {
            view.getTerminal().setCursorStyle(.steadyBlock)
        }
        #endif
        // SwiftTerm releases Ctrl/Alt after the next keyboard press.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: Notification.Name("SwiftTerm.TerminalView.controlModifierReset"), object: view, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.ctrl = false }
            },
            center.addObserver(forName: Notification.Name("SwiftTerm.TerminalView.metaModifierReset"), object: view, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.alt = false }
            },
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Lines kept above the screen (SwiftTerm keeps 500 by default; the
    /// desktop and Android keep 10,000).
    static let scrollbackLines = 10_000

    /// What every terminal view starts with.
    static var terminalOptions: TerminalOptions {
        var options = TerminalOptions.default
        options.scrollback = scrollbackLines
        return options
    }

    var size: (cols: UInt32, rows: UInt32) {
        let t = view.getTerminal()
        return (UInt32(max(t.cols, 2)), UInt32(max(t.rows, 1)))
    }

    func start() {}
    func reconnect() {}
    /// Releases the connection (a server session stays alive there).
    func disconnect() {}
    fileprivate func send(_ data: Data) {}
    fileprivate func resize(cols: UInt32, rows: UInt32) {}
    /// `canWrite` changed.
    fileprivate func writeAccessChanged() {}

    // ----- Live sharing -----

    /// Id of the session on the server: yours, shared with you or the relay
    /// of a shared terminal of this device.
    var shareSessionId: String? { nil }
    /// Connected to the server right now (the owner's actions can be sent).
    var shareAttached: Bool { false }
    /// You.
    var me: SessionParticipant? { participants.first(where: { $0.you }) }
    /// Guest: waiting for the owner to give you the keyboard.
    var requestedControl: Bool { askedForControl || (me?.requestedControl ?? false) }
    /// The others in the session (not in the waiting room).
    var others: [SessionParticipant] { participants.filter { !$0.you && !$0.waiting } }

    /// Owner: lets someone in, hands over the keyboard, kicks someone out...
    func act(_ action: OwnerAction) {
        if let p = action.participantId {
            requests.removeAll { $0.participant.id == p }
            notices?.resolve(participantId: p)
        }
        ownerAction(action)
    }

    fileprivate func ownerAction(_ action: OwnerAction) {}
    /// Guest: asks the owner for the keyboard.
    func requestControl() {}
    /// Guest: gives the keyboard back (or withdraws the request).
    func releaseControl() {}
    /// Guest who joined with a link: changes the name the others see.
    func setGuestName(_ name: String) {}

    /// Shows a short message over the terminal for a few seconds.
    func showFlash(_ text: String) {
        flash = text
        flashCount += 1
        let n = flashCount
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard let self, self.flashCount == n else { return }
            self.flash = nil
        }
    }

    /// Typing in a session where you cannot write: say why (not on every key).
    private func readOnlyHint() {
        if let last = lastReadOnlyHint, Date().timeIntervalSince(last) < 4 { return }
        lastReadOnlyHint = Date()
        showFlash(access == .control ? String(localized: "share.flash.read_only_request")
                                     : String(localized: "share.flash.read_only"))
    }

    fileprivate func addRequest(_ kind: ShareRequest.Kind, _ p: SessionParticipant) {
        guard !requests.contains(where: { $0.kind == kind && $0.participant.id == p.id }) else { return }
        requests.append(ShareRequest(kind: kind, participant: p))
        notifyInBackground([ShareRequest(kind: kind, participant: p)])
    }

    /// New requests become notifications while the app is in the background.
    private func notifyInBackground(_ new: [ShareRequest]) {
        guard let sessionId = shareSessionId else { return }
        for r in new {
            BackgroundNotices.shared.notify(r.kind == .join ? .join : .control, sessionId: sessionId, title: title ?? label,
                                            name: r.participant.name, participantId: r.participant.id)
        }
    }

    /// Owner: the pending requests are those of the people list (the waiting
    /// room and who asked for the keyboard).
    fileprivate func rebuildRequests() {
        let before = Set(requests.map(\.id))
        requests = participants.filter { $0.waiting }.map { ShareRequest(kind: .join, participant: $0) }
            + participants.filter { $0.requestedControl && !$0.waiting }.map { ShareRequest(kind: .control, participant: $0) }
        notifyInBackground(requests.filter { !before.contains($0.id) })
    }

    fileprivate func setPeople(_ people: [SessionParticipant], driver: String?) {
        participants = people
        // Another driver: the right time arrives with its `control`.
        if driver != driverId { driverUntil = nil }
        driverId = driver
        driverName = driver.flatMap { d in people.first(where: { $0.id == d })?.name }
        askedForControl = false
        if isOwner { rebuildRequests() }
    }

    fileprivate func clearSharing() {
        participants = []
        driverId = nil
        driverName = nil
        driverUntil = nil
        requests = []
        askedForControl = false
    }

    /// A timed grant that has (just about) run out: `controlExpired` tells it.
    fileprivate var grantTimeUp: Bool {
        guard let until = driverUntil else { return false }
        return Date() >= until.addingTimeInterval(-2)
    }

    /// Owner: the timed grant of `participantId` ended and you have the keyboard again.
    fileprivate func controlExpiredForOwner(_ participantId: String?) {
        let name = participantId.flatMap { p in participants.first(where: { $0.id == p })?.name }
        if let name, !name.isEmpty {
            showFlash(String(localized: "share.flash.control_expired_owner \(name)"))
        } else {
            showFlash(String(localized: "share.flash.control_expired_owner_anonymous"))
        }
    }

    /// Colors of this terminal: the host's theme or the app's.
    var theme: TerminalTheme { TerminalTheme.forHost(hostTheme, app: settings.terminalTheme) }

    func applyAppearance(_ settings: AppSettings) {
        view.font = settings.terminalFont.ui(settings.fontSize)
        // A kept size is measured again with the new font.
        if followSize != nil { viewport.setNeedsLayout() }
        let theme = TerminalTheme.forHost(hostTheme, app: settings.terminalTheme)
        theme.apply(to: view)
        keyBar?.applyTheme(theme)
        (view as? TermoakTerminalView)?.optionAsMeta = settings.optionAsMeta
        view.bellStyle = TerminalSession.bellStyle(settings.bellFeedback)
        suggestionMode = settings.suggestionMode
        suggestions = []
        gestureMode = settings.gestureMode
        gesture?.configure(gestureMode, cursorByButton: cursorByButton)
        keyBar?.paintGestureButton()
    }

    /// The bell (BEL): a vibration (SwiftTerm's haptic) where there is one,
    /// a flash of the terminal on an iPad; nothing when Settings turns it off.
    static func bellStyle(_ on: Bool) -> BellStyle {
        guard on else { return .none }
        return UIDevice.current.userInterfaceIdiom == .pad ? .visual : .sound
    }

    /// Clears the history and, outside full-screen programs, asks the shell
    /// to clear the screen (Ctrl+L), like the desktop's "Clear terminal".
    func clearTerminal() {
        // ED 3: the lines above the screen.
        view.feed(text: "\u{1b}[3J")
        guard !view.getTerminal().isCurrentBufferAlternate, state == .connected, canWrite else { return }
        input(Data([0x0C]), mirror: false)
    }

    /// Everything that goes to the terminal passes through here: the typed line
    /// is tracked (for the history) and sent. While broadcasting it also
    /// goes to the other panes (`mirror: false` for what the terminal
    /// answers on its own).
    func input(_ data: Data, mirror: Bool = true) {
        guard write(data) else { return }
        if mirror { onMirror?(self, .bytes(data)) }
    }

    /// Something typed in another pane while broadcasting.
    func receiveMirrored(_ m: MirroredInput) {
        switch m {
        case .bytes(let data): write(data)
        case .paste(let text): pasteHere(text)
        case .run(let command): runHere(command)
        }
    }

    /// Sends to this terminal only. `false`: nothing was sent (not
    /// connected or read-only).
    @discardableResult
    private func write(_ data: Data) -> Bool {
        guard state == .connected else { return false }
        // Read-only in a shared session: nothing is sent.
        guard canWrite else {
            readOnlyHint()
            return false
        }
        trackLine(data)
        send(data)
        // Suggestions come when the shell shows what was typed (if it does not,
        // like a password, nothing is suggested).
        guard suggestionMode != .off else { return true }
        suggestAfterEcho = true
        awaitingEcho = true
        // While the new ones arrive, the ones that still fit stay.
        if let l = line.current(), line.atEnd(), !l.trimmingCharacters(in: .whitespaces).isEmpty {
            suggestions = suggestions.compactMap { s in
                guard s.text.hasPrefix(l), s.text.count > l.count else { return nil }
                var n = s
                n.insert = String(s.text.dropFirst(l.count))
                return n
            }
        } else {
            suggestions = []
        }
        return true
    }

    /// The key bar above the keyboard: hidden with a hardware keyboard
    /// attached (unless Settings keeps it).
    func showKeyBar(_ show: Bool) {
        let bar: UIView? = show ? keyBar : nil
        guard view.inputAccessoryView !== bar else { return }
        view.inputAccessoryView = bar
        if view.isFirstResponder { view.reloadInputViews() }
    }

    /// Gestures button: one finger switches from scrolling to moving the cursor (or back).
    func toggleGestures() {
        cursorByButton.toggle()
        gesture?.configure(gestureMode, cursorByButton: cursorByButton)
        keyBar?.paintGestureButton()
    }

    /// Types the rest of a suggestion (without Enter).
    func accept(_ s: CommandSuggestion) {
        input(Data(s.insert.utf8))
    }

    /// The program turned on bracketed paste: the shell does not run pasted
    /// lines until Enter is pressed.
    var bracketedPaste: Bool { view.getTerminal().bracketedPasteMode }

    /// Pastes the clipboard (paste key, the bar's button, ⌘V, the edit
    /// menu). Several lines ask first (Settings), unless bracketed paste is on.
    func pasteClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        if state == .connected, canWrite, let ask = onConfirmPaste,
           PasteCheck.needsConfirmation(text, confirm: settings.confirmMultilinePaste, bracketed: bracketedPaste) {
            ask(self, text)
        } else {
            paste(text)
        }
    }

    func paste(_ text: String) {
        guard pasteHere(text) else { return }
        onMirror?(self, .paste(text))
    }

    /// Pastes in this terminal only, bracketed if its program asked for it.
    @discardableResult
    func pasteHere(_ text: String) -> Bool {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if bracketedPaste {
            // The text cannot end the bracket early.
            normalized = normalized.replacingOccurrences(of: "\u{1b}[201~", with: "")
            normalized = "\u{1b}[200~" + normalized + "\u{1b}[201~"
        }
        return write(Data(normalized.utf8))
    }

    func typeText(_ text: String) {
        input(Data(text.utf8))
    }

    /// Runs a command (snippet or history): types it and presses Enter. It goes
    /// in one go, without waiting for the echo, so it is saved in the history
    /// directly (we know what it is) and the line starts over.
    func run(_ command: String) {
        guard runHere(command) else { return }
        onMirror?(self, .run(command))
    }

    /// Runs a command in this terminal only. `false`: it could not be sent.
    @discardableResult
    func runHere(_ command: String) -> Bool {
        guard state == .connected else { return false }
        guard canWrite else {
            readOnlyHint()
            return false
        }
        let normalized = command.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        send(Data((normalized + "\r").utf8))
        line.reset()
        suggestions = []
        guard let hostId, !command.contains("\n") else { return true }
        let core = core
        Task.detached { _ = try? core.recordCommand(hostId: hostId, command: command) }
        return true
    }

    /// A key from the bar or the panel.
    func press(_ key: ShortcutKey) {
        switch key.action {
        case .modifier(.ctrl):
            ctrl.toggle()
            view.controlModifier = ctrl
        case .modifier(.alt):
            alt.toggle()
            view.metaModifier = alt
        case .paste:
            pasteClipboard()
            releaseModifiers()
        case .steps([.special(.right)]) where suggestionMode == .cursor && !ctrl && !alt && !suggestions.isEmpty:
            // → accepts the suggestion, like on the desktop.
            accept(suggestions[0])
        case .steps(let steps):
            let app = view.getTerminal().applicationCursor
            var bytes: [UInt8] = []
            for (i, step) in steps.enumerated() {
                // The bar modifiers only affect the first part.
                bytes += step.bytes(ctrl: i == 0 && ctrl, alt: i == 0 && alt, appCursor: app)
            }
            releaseModifiers()
            input(Data(bytes))
        }
    }

    /// An arrow (from the cursor gesture).
    func arrow(_ e: SpecialKey) {
        input(Data(e.bytes(ctrl: false, alt: false, appCursor: view.getTerminal().applicationCursor)))
    }

    private func releaseModifiers() {
        if ctrl { ctrl = false; view.controlModifier = false }
        if alt { alt = false; view.metaModifier = false }
    }

    func screenText() -> String {
        let t = view.getTerminal()
        var lines: [String] = []
        for row in 0..<t.rows {
            guard let line = t.getLine(row: row) else { continue }
            lines.append(line.translateToString(trimRight: true))
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate func receive(_ data: Data) {
        feeding.value = true
        view.feed(byteArray: [UInt8](data)[...])
        feeding.value = false
        if awaitingEcho { awaitingEcho = false }
        if suggestAfterEcho {
            suggestAfterEcho = false
            requestSuggestions()
        }
    }

    /// Suggestions for the typed line: only if it is known, the cursor is at
    /// the end and the screen shows it. They are computed off the main
    /// thread; if more was typed meanwhile, they are discarded.
    private func requestSuggestions() {
        let t = view.getTerminal()
        guard suggestionMode != .off, state == .connected, !t.isCurrentBufferAlternate, line.atEnd(),
              let current = line.current(), !current.trimmingCharacters(in: .whitespaces).isEmpty,
              commandEchoed(line: current, before: lineOnScreen(t), afterBlank: true)
        else {
            suggestions = []
            return
        }
        query += 1
        let n = query
        let (core, hostId, os) = (core, hostId, os)
        Task.detached { [weak self] in
            let r = (try? core.completeCommand(hostId: hostId, os: os, line: current, limit: 6)) ?? []
            await self?.show(r, query: n)
        }
    }

    private func show(_ r: [CommandSuggestion], query n: Int) {
        guard n == query, line.current() != nil else { return }
        suggestions = r
    }

    /// New line after reconnecting.
    fileprivate func forgetLine() {
        line.reset()
        suggestions = []
    }

    // ----- Command history -----

    /// Saves in the history the line sent with Enter, only if it was shown on
    /// screen as is (so passwords and lines the shell changed on its own are
    /// not saved).
    private func trackLine(_ data: Data) {
        let t = view.getTerminal()
        if t.isCurrentBufferAlternate {
            // vim, less, htop...: there is no shell line.
            line.forget()
            return
        }
        let pending = line.current()
        var echoed = false
        if let pending, !pending.isEmpty {
            // The whole line on screen (also if the cursor is in the middle,
            // e.g. after moving it with the gesture).
            echoed = commandEchoed(line: pending, before: lineOnScreen(t), afterBlank: true)
        }
        guard let sent = line.feed(data: data), echoed, sent == pending, let hostId else { return }
        let core = core
        Task.detached { _ = try? core.recordCommand(hostId: hostId, command: sent) }
    }

    /// Text of the cursor line on screen, joining wrapped rows and without
    /// trailing spaces.
    private func lineOnScreen(_ t: Terminal) -> String {
        let y = t.getCursorLocation().y
        guard let row = t.getLine(row: y) else { return "" }
        var text = row.translateToString(trimRight: true)
        var r = y
        while r > 0, let current = t.getLine(row: r), current.isWrapped, let previous = t.getLine(row: r - 1) {
            text = previous.translateToString() + text
            r -= 1
        }
        return text
    }

    /// Cursor cell in the view and cell size (as SwiftTerm computes them from
    /// the font). `nil` while looking at the scrollback (not the end), where
    /// the cursor is not in view.
    func cursorPosition() -> (row: Int, column: Int, cell: CGSize)? {
        let maximum = max(0, view.contentSize.height - view.bounds.height)
        guard view.contentOffset.y >= maximum - 2 else { return nil }
        let font = view.font
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let ct = font as CTFont
        let height = ceil(ceil(CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)) * scale) / scale
        let width = ("W" as NSString).size(withAttributes: [.font: font]).width
        let (x, y) = view.getTerminal().getCursorLocation()
        return (y, x, CGSize(width: (width * scale).rounded() / scale, height: height))
    }

    // ----- TerminalViewDelegate -----

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        // Answers to the program's queries and focus or mouse reports are
        // not typed: they are not broadcast to the other panes.
        let reply = feeding.value || TerminalReport.isReport(bytes)
        Task { @MainActor in self.input(bytes, mirror: !reply) }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in self.resize(cols: UInt32(max(newCols, 2)), rows: UInt32(max(newRows, 1))) }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        Task { @MainActor in self.title = title.isEmpty ? nil : title }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        let text = String(decoding: content, as: UTF8.self)
        Task { @MainActor in UIPasteboard.general.string = text }
    }

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        Task { @MainActor in UIApplication.shared.open(url) }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Direction and speed (1–3) of the move-the-cursor gesture.
struct CursorPad: Equatable {
    var direction: SpecialKey
    var level: Int
}

// MARK: - SSH from the phone

final class LocalTerminal: TerminalSession {
    private let address: String
    /// A Telnet host (`SshHost.protocol`).
    private let telnet: Bool
    /// Why it cannot be opened from here (shown instead of connecting).
    private let refusal: String?
    /// Connected over SSH: to start the automatic tunnels.
    var onConnected: ((String, SshSession) -> Void)?
    /// The host's system was detected and saved (its logo changes).
    var onHostChanged: (() -> Void)?
    /// The system was already looked for (once per terminal).
    private var detectedOs = false
    /// Connected when the app went to the background (to reconnect it on
    /// return if the system cut it meanwhile).
    private var connectedWhenLeaving = false
    /// Until when a drop reconnects by itself (just after coming back).
    private var reconnectsUntil: Date?
    /// The last close came with an exit status: the program ended (`exit`,
    /// a logout), it was not the network.
    private var endedByProgram = false

    /// The SSH connection of this terminal (for SFTP and tunnels without
    /// reconnecting). Telnet terminals have none.
    var connection: SshSession? {
        guard let h = handle, !h.isTelnet() else { return nil }
        return h.session()
    }

    override var isTelnet: Bool { telnet }
    override var measuresLatency: Bool { true }

    func connection(for host: String) -> SshSession? {
        hostId == host ? connection : nil
    }
    private var handle: TerminalHandle?
    private var task: Task<Void, Never>?
    /// Shared with the server (relay, only for you) so the copilot AI can type
    /// in it. Sharing stops when the terminal is closed.
    @Published private(set) var shared: SharedTerminal?
    /// Shared by the copilot (not by the user by hand): sharing stops when
    /// the panel is stopped or closed.
    private var sharedByCopilot = false

    /// Id of the relay session, if this terminal is shared.
    var sharedSessionId: String? { shared?.sessionId() }

    /// `refusal`: the tab only shows it (a host that cannot be opened).
    init(core: TermoakCore, host: SshHost, settings: AppSettings, refusal: String? = nil) {
        address = host.address
        telnet = host.isTelnet
        self.refusal = refusal
        super.init(core: core, label: host.label.isEmpty ? host.address : host.label, hostId: host.id,
                   accountId: host.accountId, settings: settings)
    }

    override func start() {
        guard handle == nil, task == nil, let hostId else { return }
        if let refusal {
            state = .closed(refusal)
            return
        }
        state = .connecting(String(localized: "terminal.state.connecting_to \(address)"))
        let auth = AuthBridge { [weak self] prompt in
            Task { @MainActor in self?.prompt = prompt }
        }
        let listener = LocalListener(session: self)
        let (cols, rows) = size
        task = Task {
            defer { task = nil }
            do {
                // Telnet hosts open a Telnet terminal (the same handle);
                // the host's username and password answer its first login
                // prompts if Settings says so.
                let h = try await core.connectTerminal(hostId: hostId, cols: cols, rows: rows, auth: auth,
                                                       listener: listener, accountId: accountId,
                                                       telnetAutoLogin: settings.telnetAutoLogin)
                handle = h
                state = .connected
                let (c, r) = size
                try? h.resize(cols: c, rows: r)
                // Tunnels go over SSH only.
                if !h.isTelnet() {
                    onConnected?(hostId, h.session())
                    detectOs(h.session())
                }
                _ = view.becomeFirstResponder()
            } catch {
                state = .closed(userMessage(error))
            }
        }
    }

    /// The first time a host without a known system connects: the engine
    /// detects it (`/etc/os-release`, `uname`...) and saves it in the host,
    /// so its logo shows (like the desktop).
    private func detectOs(_ session: SshSession) {
        guard !detectedOs, !telnet, let hostId,
              let host = try? core.getHost(id: hostId, accountId: accountId), host.os == nil else { return }
        detectedOs = true
        Task { [weak self] in
            guard (try? await session.detectOsInfo()) != nil else { return }
            self?.onHostChanged?()
        }
    }

    /// The app goes to the background.
    func leaving() {
        connectedWhenLeaving = state == .connected
    }

    /// Back in the foreground after `away` seconds: a terminal the system
    /// cut meanwhile reconnects by itself; one that still looks connected
    /// after a long while is checked first (a keep-alive), and if it drops
    /// in the next seconds it reconnects too. Not the ones you closed.
    func returned(after away: TimeInterval) {
        guard connectedWhenLeaving, !asleep, refusal == nil else { return }
        connectedWhenLeaving = false
        switch state {
        case .closed:
            if !endedByProgram { autoReconnect() }
        case .connected:
            reconnectsUntil = Date().addingTimeInterval(AutoReconnect.window)
            guard away >= AutoReconnect.checkAfter, let h = handle else { return }
            Task { [weak self] in
                let alive = (try? await h.latencyMs(timeoutMs: Latency.timeoutMs)) != nil
                guard let self, !alive, self.handle === h, self.state == .connected else { return }
                self.autoReconnect()
            }
        case .connecting:
            break
        }
    }

    private func autoReconnect() {
        reconnectsUntil = nil
        showFlash(String(localized: "terminal.flash.reconnecting"))
        reconnect()
    }

    override func reconnect() {
        disconnect()
        view.feed(text: "\u{1b}c")
        forgetLine()
        start()
    }

    /// The SSH keep-alive or the Telnet TIMING-MARK round trip; unknown
    /// when there is no answer in time.
    override func measureLatency() async {
        guard state == .connected, let h = handle else {
            latency = nil
            return
        }
        let ms = try? await h.latencyMs(timeoutMs: Latency.timeoutMs)
        // Reconnected or closed meanwhile: that answer is old.
        guard handle === h, state == .connected else { return }
        latency = ms
    }

    override var shareSessionId: String? { shared?.sessionId() }
    override var shareAttached: Bool { shared != nil }

    /// Shares the terminal with the server (relay) if it is not already.
    /// `created`: this call started sharing it.
    private func startRelay(title: String) async throws -> (shared: SharedTerminal, created: Bool) {
        if let c = shared { return (c, false) }
        guard let h = handle else { throw ShareError.notConnected }
        let c = try await core.shareTerminal(terminal: h, title: title)
        // It was closed or reconnected meanwhile: that relay is no longer useful.
        guard handle === h else {
            Task.detached { try? await c.stop() }
            throw ShareError.notConnected
        }
        if let existing = shared {
            Task.detached { try? await c.stop() }
            return (existing, false)
        }
        shared = c
        clearSharing()
        let (cols, rows) = size
        // Participants, requests and the keyboard of this relay.
        let listener = RelayListener(session: self, sessionId: c.sessionId())
        Task.detached {
            try? await c.resize(cols: cols, rows: rows)
            try? await c.setListener(listener: listener)
        }
        return (c, true)
    }

    /// Shares the terminal with the server for the copilot (if it is not
    /// already) and returns the id of the relay session.
    func share(title: String) async throws -> String {
        let r = try await startRelay(title: title)
        if r.created { sharedByCopilot = true }
        return r.shared.sessionId()
    }

    /// Shares the terminal so people can be invited (relay through the
    /// server). It stays shared when the copilot stops.
    func shareWithPeople() async throws -> SharedTerminal {
        let r = try await startRelay(title: displayTitle)
        sharedByCopilot = false
        return r.shared
    }

    /// Stops sharing: the guests leave (the terminal stays open here). The
    /// copilot shares it again by itself if it needs it.
    private func stopSharing() {
        guard let c = shared else { return }
        shared = nil
        sharedByCopilot = false
        clearSharing()
        Task.detached { try? await c.stop() }
    }

    override fileprivate func ownerAction(_ action: OwnerAction) {
        guard let c = shared else { return }
        if case .stopSharing = action {
            stopSharing()
            return
        }
        Task { [weak self] in
            do {
                switch action {
                case .allowJoin(let p): try await c.allowJoin(participantId: p)
                case .denyJoin(let p): try await c.denyJoin(participantId: p)
                case .grantControl(let p, let minutes): try await c.grantControl(participantId: p, minutes: minutes)
                case .denyControl(let p): try await c.denyControl(participantId: p)
                case .takeControl: try await c.takeControl()
                case .kick(let p, let block): try await c.kick(participantId: p, revokeShare: block)
                case .stopSharing: break
                }
            } catch {
                self?.showFlash(userMessage(error))
            }
        }
    }

    /// What the server says about the shared terminal (`sessionId`: of which
    /// relay, in case it was shared again since).
    fileprivate func relayEvent(_ event: SharedTerminalEvent, sessionId: String) {
        guard let c = shared, c.sessionId() == sessionId else { return }
        switch event {
        case .participants(let people, let driver):
            setPeople(people, driver: driver)
        case .control(let driver, let name, let until):
            let before = driverId
            let timeUp = grantTimeUp
            driverId = driver
            driverName = name
            driverUntil = until.map(dateFromMillis)
            if driver != nil, let name, !name.isEmpty {
                showFlash(String(localized: "share.flash.has_control \(name)"))
            } else if before != nil && !timeUp {
                showFlash(String(localized: "share.flash.control_back_owner"))
            }
        case .controlExpired(let p):
            controlExpiredForOwner(p)
        case .resizeRequest:
            // The terminal is here: it keeps the size of this screen.
            break
        case .joinRequest(let p):
            addRequest(.join, p)
        case .controlRequest(let p):
            addRequest(.control, p)
        case .reconnecting:
            showFlash(String(localized: "share.flash.reconnecting"))
        case .reconnected:
            break
        case .ended(let code):
            shared = nil
            sharedByCopilot = false
            clearSharing()
            if code != nil { showFlash(String(localized: "share.flash.sharing_ended")) }
        }
    }

    /// Stopping or closing the copilot: the AI loses access to the terminal if
    /// it was shared for it.
    func stopCopilotSharing() {
        if sharedByCopilot { stopSharing() }
    }

    override func disconnect() {
        task?.cancel()
        task = nil
        stopSharing()
        guard let h = handle else { return }
        handle = nil
        h.closeTerminal()
        let session = h.session()
        Task.detached { try? await session.disconnect() }
    }

    override fileprivate func send(_ data: Data) {
        try? handle?.write(data: data)
    }

    override fileprivate func resize(cols: UInt32, rows: UInt32) {
        try? handle?.resize(cols: cols, rows: rows)
        if let c = shared {
            Task.detached { try? await c.resize(cols: cols, rows: rows) }
        }
    }

    fileprivate func statusChanged(_ status: TerminalStatus) {
        guard case .closed(let code, let reason) = status else { return }
        handle = nil
        stopSharing()
        endedByProgram = code != nil
        // Cut just after coming back from the background (not `exit`): again by itself.
        if let until = reconnectsUntil, Date() < until, state == .connected, code == nil {
            autoReconnect()
            return
        }
        if let reason, !reason.isEmpty {
            state = .closed(reason)
        } else if let code {
            state = .closed(String(localized: "terminal.state.ended_code \(Int(code))"))
        } else {
            state = .closed(String(localized: "terminal.state.connection_closed"))
        }
    }
}

/// Receives the engine output (background thread) and passes it to the main thread.
private final class LocalListener: TerminalListener, @unchecked Sendable {
    private weak var session: LocalTerminal?

    init(session: LocalTerminal) {
        self.session = session
    }

    func onOutput(data: Data) {
        DispatchQueue.main.async { [weak session] in session?.receive(data) }
    }

    func onStatus(status: TerminalStatus) {
        DispatchQueue.main.async { [weak session] in session?.statusChanged(status) }
    }
}

/// Receives what happens in a shared local terminal (background thread).
private final class RelayListener: SharedTerminalListener, @unchecked Sendable {
    private weak var session: LocalTerminal?
    private let sessionId: String

    init(session: LocalTerminal, sessionId: String) {
        self.session = session
        self.sessionId = sessionId
    }

    func onEvent(event: SharedTerminalEvent) {
        let id = sessionId
        DispatchQueue.main.async { [weak session] in session?.relayEvent(event, sessionId: id) }
    }
}

// MARK: - Session that lives on the server

/// Stays open even if the phone sleeps or loses coverage. On return, the
/// server sends the whole scrollback.
final class ServerTerminal: TerminalSession {
    /// How a session is joined with an invitation link.
    enum JoinMode {
        /// Signed in to that server: you appear with your account.
        case account
        /// Without an account, with a display name (`nil`: "Guest N").
        case guest(name: String?)
    }

    private(set) var sessionId: String?
    private var handle: ServerTerminalHandle?
    private var task: Task<Void, Never>?
    /// Joined with an invitation link (instead of attached by id).
    private(set) var link: JoinLink?
    private(set) var joinMode: JoinMode = .account
    /// The first `hello` arrived (who you are is known).
    private var greeted = false
    /// Last size of the view: sent only while you can write.
    private var lastSize: (cols: UInt32, rows: UInt32)?
    /// Size of the terminal on the server (read-only guests keep it).
    private var remoteSize: TermSize?

    override var persistent: Bool { true }
    override var shareSessionId: String? { sessionId }
    override var shareAttached: Bool { handle != nil && greeted }

    /// With `sessionId` it attaches to an existing one; without it, it opens a new one on `hostId`.
    /// `owner`: it is yours (`false` for sessions shared with you); the
    /// server confirms it on connecting.
    init(core: TermoakCore, label: String, hostId: String?, sessionId: String?, owner: Bool = true,
         accountId: String? = nil, settings: AppSettings) {
        self.sessionId = sessionId
        super.init(core: core, label: label, hostId: hostId, accountId: accountId, settings: settings)
        // Until the server says who you are, nothing is sent.
        canWrite = false
        isOwner = owner
        access = owner ? .owner : .view
    }

    /// Joins a shared session with an invitation link.
    convenience init(core: TermoakCore, link: JoinLink, mode: JoinMode, label: String, settings: AppSettings) {
        self.init(core: core, label: label, hostId: nil, sessionId: nil, owner: false, settings: settings)
        self.link = link
        joinMode = mode
    }

    /// Joined as a guest without an account (can change the name).
    var isLinkGuest: Bool {
        if case .guest = joinMode, link != nil { return true }
        return false
    }

    override func start() {
        guard handle == nil, task == nil, ended == nil else { return }
        if link != nil {
            state = .connecting(String(localized: "share.state.joining"))
        } else {
            state = .connecting(String(localized: "terminal.state.connecting_server"))
        }
        greeted = false
        let listener = ServerListener(session: self)
        let (cols, rows) = size
        task = Task {
            defer { task = nil }
            do {
                let h: ServerTerminalHandle
                if let link {
                    switch joinMode {
                    case .account:
                        h = try await core.joinLink(token: link.token, listener: listener)
                    case .guest(let name):
                        h = try await joinSharedSessionAs(serverUrl: link.server, token: link.token, name: name, listener: listener)
                    }
                    sessionId = h.sessionId()
                } else {
                    let id: String
                    if let sessionId {
                        id = sessionId
                    } else if let hostId {
                        // On the host's account (the current one for This-device hosts).
                        if let accountId {
                            id = try await core.account(accountId: accountId)
                                .openServerSession(hostId: hostId, cols: cols, rows: rows, title: label, record: nil).id
                        } else {
                            id = try await core.openServerSession(hostId: hostId, cols: cols, rows: rows, title: label, record: nil).id
                        }
                        sessionId = id
                    } else {
                        return
                    }
                    h = try await core.api(for: accountId).attachServerSession(sessionId: id, listener: listener)
                }
                handle = h
                syncSeat()
                sendSize()
                if canWrite { _ = view.becomeFirstResponder() }
            } catch {
                state = .closed(userMessage(error))
            }
        }
    }

    override func reconnect() {
        // Sent away for good: there is nothing to reconnect to.
        guard ended == nil else { return }
        disconnect()
        view.feed(text: "\u{1b}c")
        forgetLine()
        waiting = nil
        start()
    }

    /// Detaches: the session stays on the server.
    override func disconnect() {
        task?.cancel()
        task = nil
        handle?.detach()
        handle = nil
    }

    /// Terminates the session on the server (for everyone).
    func terminate() {
        guard isOwner else { return }
        if let handle {
            handle.closeSession()
        } else if let sessionId {
            let api = core.api(for: accountId)
            Task { try? await api.closeServerSession(sessionId: sessionId) }
        }
    }

    override fileprivate func send(_ data: Data) {
        guard canWrite else { return }
        handle?.write(data: data)
    }

    override fileprivate func resize(cols: UInt32, rows: UInt32) {
        // While keeping the server's size the view reports that one, not this screen's.
        if followSize == nil { lastSize = (cols, rows) }
        // Read-only: the owner or the driver decide the size (and the library
        // would drop it anyway).
        guard canWrite else { return }
        handle?.resize(cols: cols, rows: rows)
    }

    override fileprivate func writeAccessChanged() {
        updateFollow()
    }

    /// Read-only, the terminal keeps the server's size (zoomed to fit this
    /// screen); with the keyboard, it takes the size of this screen again
    /// (and sends it).
    private func updateFollow() {
        followSize = canWrite ? nil : remoteSize
    }

    /// Sends the size of this screen (when you can write).
    private func sendSize() {
        guard canWrite, let h = handle else { return }
        let (c, r) = lastSize ?? size
        h.resize(cols: c, rows: r)
    }

    /// After the hello, the library knows best whether you can write.
    private func syncSeat() {
        guard greeted, let h = handle else { return }
        canWrite = h.canWrite()
        isOwner = h.isOwner()
    }

    // ----- Live sharing -----

    override fileprivate func ownerAction(_ action: OwnerAction) {
        guard isOwner, let h = handle else { return }
        do {
            switch action {
            case .allowJoin(let p): try h.allowJoin(participantId: p)
            case .denyJoin(let p): try h.denyJoin(participantId: p)
            case .grantControl(let p, let minutes): try h.grantControl(participantId: p, minutes: minutes)
            case .denyControl(let p): try h.denyControl(participantId: p)
            case .takeControl: h.takeControl()
            case .kick(let p, let block): try h.kick(participantId: p, revokeShare: block)
            case .stopSharing: h.stopSharing()
            }
        } catch {
            showFlash(userMessage(error))
        }
    }

    override func requestControl() {
        guard !isOwner, access == .control, let h = handle else { return }
        h.requestControl()
        askedForControl = true
        showFlash(String(localized: "share.flash.control_requested"))
    }

    override func releaseControl() {
        guard !isOwner, let h = handle else { return }
        h.releaseControl()
        askedForControl = false
    }

    override func setGuestName(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLinkGuest, !n.isEmpty, let h = handle else { return }
        h.setName(name: String(n.prefix(40)))
    }

    fileprivate func event(_ event: ServerTerminalEvent) {
        switch event {
        case .hello(let session):
            greeted = true
            waiting = nil
            title = session.title.isEmpty ? nil : session.title
            access = session.access
            isOwner = session.access == .owner
            if session.cols > 0 && session.rows > 0 {
                remoteSize = TermSize(cols: Int(session.cols), rows: Int(session.rows))
            }
            setPeople(session.participants, driver: session.driver)
            driverUntil = session.driverUntil.map(dateFromMillis)
            // Servers before protocol 2 have no people list: `control` could type.
            let me = session.participants.first(where: { $0.you })
            canWrite = isOwner || (me?.isDriver ?? (session.participants.isEmpty && session.access == .control))
            syncSeat()
            updateFollow()
            if !canWrite { _ = view.resignFirstResponder() }
            apply(session.state)
            sendSize()
        case .output(let data):
            if state != .connected && waiting == nil { state = .connected }
            receive(data)
        case .resync:
            // The full scrollback comes next.
            view.feed(text: "\u{1b}c")
        case .status(let st):
            apply(st)
        case .title(let t):
            title = t.isEmpty ? nil : t
        case .resize(let cols, let rows):
            // The owner (or the driver) resized it.
            if cols > 0 && rows > 0 {
                remoteSize = TermSize(cols: Int(cols), rows: Int(rows))
                updateFollow()
            }
        case .participants(let people, let driver):
            setPeople(people, driver: driver)
        case .control(let driver, let name, let write, let until):
            let could = canWrite
            let before = driverId
            // A timed grant that ran out says so itself (`controlExpired`).
            let timeUp = grantTimeUp
            driverId = driver
            driverName = name
            driverUntil = until.map(dateFromMillis)
            canWrite = isOwner || write
            if isOwner {
                if driver != nil, let name, !name.isEmpty {
                    showFlash(String(localized: "share.flash.has_control \(name)"))
                } else if before != nil && !timeUp {
                    showFlash(String(localized: "share.flash.control_back_owner"))
                }
            } else if canWrite && !could {
                askedForControl = false
                showFlash(String(localized: "share.flash.you_have_control"))
                sendSize()
            } else if !canWrite && could && !timeUp {
                showFlash(String(localized: "share.flash.control_lost"))
            }
        case .controlExpired(let p):
            if isOwner {
                controlExpiredForOwner(p)
            } else {
                showFlash(String(localized: "share.flash.control_expired_you"))
            }
        case .waiting(_, let t, let owner):
            waiting = WaitingRoom(title: t, owner: owner)
            if !t.isEmpty { title = t }
            state = .connecting(String(localized: "share.waiting.status"))
        case .joinRequest(let p):
            if isOwner { addRequest(.join, p) }
        case .controlRequest(let p):
            if isOwner { addRequest(.control, p) }
        case .controlDenied:
            askedForControl = false
            showFlash(String(localized: "share.flash.control_denied"))
        case .prompt(let p):
            let h = handle
            if let fingerprint = p.fingerprint {
                prompt = AuthPrompt(kind: .hostKey(host: p.host, port: 22, keyType: p.keyType ?? "", fingerprint: fingerprint)) { [weak self] r in
                    try? h?.answerPrompt(promptId: p.promptId, accept: r != nil, answers: nil)
                    DispatchQueue.main.async { self?.prompt = nil }
                }
            } else {
                let req = AuthRequest(kind: .keyboardInteractive, host: p.host, title: p.host, instructions: p.message, fields: p.fields)
                prompt = AuthPrompt(kind: .fields(req)) { [weak self] r in
                    try? h?.answerPrompt(promptId: p.promptId, accept: r != nil, answers: r)
                    DispatchQueue.main.async { self?.prompt = nil }
                }
            }
        case .promptDone:
            prompt = nil
        case .error(let message):
            // Not fatal (an action that was not allowed): the connection stays.
            showFlash(message)
        case .ended(let code, let message):
            let end = ShareEnd(code: code, message: message)
            ended = end
            waiting = nil
            canWrite = false
            requests = []
            state = .closed(end.title)
        case .closed:
            if case .closed = state {} else { state = .closed(String(localized: "terminal.state.server_session_closed")) }
        default:
            break
        }
    }

    private func apply(_ st: ServerSessionState) {
        switch st {
        case .connecting(let message): state = .connecting(message)
        case .running: state = .connected
        case .hostOffline: state = .connecting(String(localized: "terminal.state.host_offline"))
        case .closed(let code, let reason):
            state = .closed(reason ?? code.map { String(localized: "terminal.state.ended_code \(Int($0))") }
                ?? String(localized: "terminal.state.session_closed"))
        }
    }
}

private final class ServerListener: ServerTerminalListener, @unchecked Sendable {
    private weak var session: ServerTerminal?

    init(session: ServerTerminal) {
        self.session = session
    }

    func onEvent(event: ServerTerminalEvent) {
        DispatchQueue.main.async { [weak session] in session?.event(event) }
    }
}

// MARK: - Open tabs

@MainActor
final class Sessions: ObservableObject {
    @Published private(set) var open: [TerminalSession] = []
    @Published var activeId: UUID?
    /// The terminal screen is shown.
    @Published var showing = false
    /// Quick access panel open instead of the keyboard (on the phone).
    @Published var quickPanelOpen = false
    /// Copilot (AI) panel open; it stays open when switching tabs. Closing it
    /// stops the AI and removes its access to the terminals.
    @Published var copilotOpen = false {
        didSet { if oldValue && !copilotOpen { copilotClosed() } }
    }
    /// Your running server sessions, of every signed-in account (the notice
    /// on the home screen).
    @Published private(set) var onServer: [AccountSession] = []
    /// A paste of several lines waiting to be confirmed.
    @Published var pasteRequest: PasteRequest?

    // ----- Split view (iPad) -----

    /// Terminals shown side by side (2–4, in order); empty: one terminal.
    @Published private(set) var panes: [UUID] = []
    /// Focus mode: the focused pane big, the others small.
    @Published var focusMode = false
    /// What is typed in the focused pane also goes to the other panes.
    @Published var broadcasting = false
    /// Panes that do not take part in the broadcast.
    @Published private(set) var broadcastExcluded: Set<UUID> = []
    /// The screen is wide enough for several panes (iPad, regular width);
    /// otherwise it shows only the focused one and keeps the others.
    @Published var splitAvailable = false
    /// The next terminal opened goes next to the focused one ("New terminal"
    /// in the split menu, ⌘D with nothing else open).
    var splitOnNextOpen = false
    /// Toasts about shared sessions over any screen.
    let notices: ShareNotices

    /// One conversation with the AI per tab.
    private var copilots: [UUID: Copilot] = [:]

    private let core: TermoakCore
    private let settings: AppSettings
    private let tunnels: Tunnels
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// When the app went to the background (to reconnect what was cut).
    private var leftAt: Date?
    private var subscriptions: Set<AnyCancellable> = []
    /// A host changed here (its system detected): the lists reload.
    var onHostChanged: (() -> Void)?

    init(core: TermoakCore, settings: AppSettings, tunnels: Tunnels) {
        self.core = core
        self.settings = settings
        self.tunnels = tunnels
        notices = ShareNotices()
        // Tunnels reuse the connection of a terminal open to the host.
        tunnels.terminalConnection = { [weak self] hostId in
            self?.open.lazy.compactMap { ($0 as? LocalTerminal)?.connection(for: hostId) }.first
        }
        // A hardware keyboard attached or detached, or the setting changed.
        HardwareKeyboard.shared.$connected.removeDuplicates()
            .combineLatest(settings.$keyBarWithHardwareKeyboard.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] connected, keep in
                guard let self else { return }
                self.open.forEach { $0.showKeyBar(!connected || keep) }
            }
            .store(in: &subscriptions)
    }

    /// The key bar shows (no hardware keyboard, or Settings keeps it).
    private var keyBarVisible: Bool {
        !HardwareKeyboard.shared.connected || settings.keyBarWithHardwareKeyboard
    }

    var current: TerminalSession? {
        open.first(where: { $0.id == activeId }) ?? open.last(where: { !$0.asleep }) ?? open.last
    }

    /// Several panes on screen.
    var splitActive: Bool { splitAvailable && panes.count >= 2 }
    /// The terminals of the panes, in order.
    var paneSessions: [TerminalSession] { panes.compactMap { id in open.first(where: { $0.id == id }) } }
    var broadcastActive: Bool { splitActive && broadcasting }
    /// Terminals that receive what is typed while broadcasting (the focused one too).
    var broadcastCount: Int { panes.filter { !broadcastExcluded.contains($0) }.count }

    /// Panes that get what is typed in `source`: the other panes that are not
    /// excluded. Nothing when not broadcasting or when `source` is not a pane.
    func broadcastTargets(from source: TerminalSession) -> [TerminalSession] {
        guard broadcastActive, panes.contains(source.id), !broadcastExcluded.contains(source.id) else { return [] }
        return paneSessions.filter { $0.id != source.id && !broadcastExcluded.contains($0.id) }
    }

    func receivesBroadcast(_ s: TerminalSession) -> Bool {
        broadcastActive && panes.contains(s.id) && !broadcastExcluded.contains(s.id)
    }

    /// Focuses a terminal (a pane in the split view). The keyboard follows
    /// if the previous one had it.
    func focus(_ id: UUID) {
        guard id != activeId, let s = open.first(where: { $0.id == id }) else { return }
        let keyboard = current?.view.isFirstResponder ?? false
        activeId = id
        wake(s)
        if keyboard { _ = s.view.becomeFirstResponder() }
    }

    /// Adds a terminal to the split view: `id` or else the next open one that
    /// is not on screen. `false` if there is nothing to add or no room.
    @discardableResult
    func addPane(_ id: UUID? = nil) -> Bool {
        guard let cur = current else { return false }
        var list = panes.count >= 2 ? panes : [cur.id]
        guard list.count < PaneLayout.maxPanes else { return false }
        let candidate = id
            ?? open.first(where: { !list.contains($0.id) && !$0.asleep })?.id
            ?? open.first(where: { !list.contains($0.id) })?.id
        guard let new = candidate, !list.contains(new), open.contains(where: { $0.id == new }) else { return false }
        list.append(new)
        panes = list
        focus(new)
        return true
    }

    /// Takes a terminal out of the split view (it stays open as a tab).
    func removePane(_ id: UUID) {
        guard let i = panes.firstIndex(of: id) else { return }
        let focused = activeId.flatMap { panes.firstIndex(of: $0) } ?? i
        var list = panes
        list.remove(at: i)
        let next = PaneLayout.focusAfterClose(panes.count, focused: focused, closed: i).map { list[$0] }
        broadcastExcluded.remove(id)
        if list.count < 2 {
            exitSplit()
        } else {
            panes = list
        }
        if let next { focus(next) }
    }

    /// Back to one terminal (the focused one).
    func exitSplit() {
        panes = []
        focusMode = false
        broadcasting = false
        broadcastExcluded = []
    }

    /// ⌘⌥ + arrow: the focus goes to the pane in that direction.
    func moveFocus(_ dir: PaneLayout.Direction) {
        guard splitActive, let cur = activeId, let i = panes.firstIndex(of: cur) else { return }
        let next = focusMode ? PaneLayout.neighborInFocusMode(panes.count, from: i, dir)
                             : PaneLayout.neighbor(panes.count, from: i, dir)
        if let next { focus(panes[next]) }
    }

    func toggleFocusMode() {
        guard splitActive else { return }
        focusMode.toggle()
    }

    func toggleBroadcast() {
        guard splitActive else { return }
        broadcasting.toggle()
    }

    /// A pane stops (or starts again) taking part in the broadcast.
    func toggleExcluded(_ id: UUID) {
        if broadcastExcluded.contains(id) { broadcastExcluded.remove(id) } else { broadcastExcluded.insert(id) }
    }

    /// Something typed in `source` goes to the other panes while broadcasting.
    private func mirror(_ m: MirroredInput, from source: TerminalSession) {
        for target in broadcastTargets(from: source) { target.receiveMirrored(m) }
    }

    /// A snippet (or anything) in every open terminal that can take it.
    /// Returns in how many it went.
    @discardableResult
    func sendToAll(_ text: String, run: Bool) -> Int {
        var sent = 0
        for s in open where !s.asleep {
            let ok = run ? s.runHere(text) : s.pasteHere(text)
            if ok { sent += 1 }
        }
        return sent
    }

    /// The copilot conversation of a tab (created the first time).
    func copilot(for s: TerminalSession) -> Copilot {
        if let c = copilots[s.id] { return c }
        // A server session talks to its own account's AI; a terminal of this
        // device is shared through the current account (relay), which only
        // knows the hosts of its own vaults.
        let c: Copilot
        if s is ServerTerminal {
            c = Copilot(core: core.api(for: s.accountId))
        } else {
            let current = core.currentAccount()?.id
            // The AI cannot run commands on a Telnet host from the server: it
            // only types in the terminal (shared through the relay).
            c = Copilot(core: core, sendsHost: s.accountId != nil && s.accountId == current && !s.isTelnet)
        }
        copilots[s.id] = c
        return c
    }

    /// Panel closed: whatever is working stops and the terminals shared for
    /// the copilot stop being shared.
    private func copilotClosed() {
        for (id, c) in copilots {
            c.stop(open.first(where: { $0.id == id }) as? LocalTerminal)
        }
    }

    /// Shows a tab (if it is asleep, it attaches now).
    func show(_ id: UUID) {
        guard let s = open.first(where: { $0.id == id }) else { return }
        splitOnNextOpen = false
        // Split view: the tab takes the place of the focused pane.
        if panes.count >= 2, !panes.contains(id) {
            let slot = activeId.flatMap { panes.firstIndex(of: $0) } ?? panes.count - 1
            broadcastExcluded.remove(panes[slot])
            panes[slot] = id
        }
        activeId = id
        showing = true
        wake(s)
    }

    /// ⌘⇧] / ⌘⇧[ and Ctrl+Tab / Ctrl+Shift+Tab: the next or previous tab
    /// (round the end).
    func showAdjacent(_ delta: Int) {
        guard let cur = current, let i = open.firstIndex(where: { $0.id == cur.id }) else { return }
        let n = open.count
        guard n > 1 else { return }
        showFromKeyboard(open[((i + delta) % n + n) % n].id)
    }

    /// ⌘1…⌘8: that tab; ⌘9: the last one (like browsers).
    func showTab(number: Int) {
        guard !open.isEmpty else { return }
        let i = number >= 9 ? open.count - 1 : number - 1
        guard open.indices.contains(i) else { return }
        showFromKeyboard(open[i].id)
    }

    /// Moves a tab to another place of the bar (dragged, or Move left/right
    /// in its menu). The panes of the split view keep their own order.
    func moveTab(_ id: UUID, to index: Int) {
        guard let from = open.firstIndex(where: { $0.id == id }) else { return }
        let to = max(0, min(index, open.count - 1))
        guard from != to else { return }
        let s = open.remove(at: from)
        open.insert(s, at: to)
    }

    /// One place to the left (`-1`) or to the right (`1`).
    func moveTab(_ id: UUID, by delta: Int) {
        guard let i = open.firstIndex(where: { $0.id == id }) else { return }
        moveTab(id, to: i + delta)
    }

    /// Shows a tab and the keyboard follows (it is typed in next).
    private func showFromKeyboard(_ id: UUID) {
        let keyboard = current?.view.isFirstResponder ?? false
        show(id)
        guard keyboard || HardwareKeyboard.shared.connected else { return }
        // Once the tab is on screen.
        DispatchQueue.main.async { [weak self] in
            guard let s = self?.current, s.id == id, s.view.window != nil else { return }
            _ = s.view.becomeFirstResponder()
        }
    }

    func wake(_ s: TerminalSession) {
        guard s.asleep else { return }
        s.asleep = false
        s.start()
    }

    func openLocal(_ host: SshHost) {
        add(LocalTerminal(core: core, host: host, settings: settings))
    }

    /// Opens a terminal to each host (several selected in the list). On an
    /// iPad (with `split`), up to four of them go side by side.
    func openLocal(_ hosts: [SshHost], split: Bool = true) {
        let new = openInBackground(hosts, split: split)
        guard let first = new.first else { return }
        activeId = first.id
        showing = true
    }

    /// Opens a terminal to each host without showing them (to run a snippet
    /// on several servers). On an iPad, up to four of them go side by side
    /// when they are shown.
    @discardableResult
    func openInBackground(_ hosts: [SshHost], split: Bool = true) -> [TerminalSession] {
        let new: [TerminalSession] = hosts.map { LocalTerminal(core: core, host: $0, settings: settings) }
        guard !new.isEmpty else { return [] }
        splitOnNextOpen = false
        for s in new {
            prepare(s)
            open.append(s)
        }
        if split && UIDevice.current.userInterfaceIdiom == .pad && new.count >= 2 {
            panes = new.prefix(PaneLayout.maxPanes).map(\.id)
            focusMode = false
            broadcasting = false
            broadcastExcluded = []
        }
        activeId = new[0].id
        new.forEach { $0.start() }
        return new
    }

    /// A persistent session on the host's server (its account). The server
    /// does not open Telnet sessions: a Telnet host's tab says so.
    func openOnServer(_ host: SshHost) {
        if host.isTelnet {
            let reason = host.isUseOnly ? String(localized: "telnet.strict_vault") : String(localized: "telnet.no_server_sessions")
            add(LocalTerminal(core: core, host: host, settings: settings, refusal: reason))
            return
        }
        add(ServerTerminal(core: core, label: host.label.isEmpty ? host.address : host.label,
                           hostId: host.id, sessionId: nil, accountId: host.accountId, settings: settings))
    }

    /// Connects to a host from this device, or through its server when it
    /// is a Use-only host of a Strict vault (its secrets never leave the
    /// server).
    func connect(_ host: SshHost, strict: Bool) {
        if strict && host.isUseOnly && host.accountId != nil { openOnServer(host) } else { openLocal(host) }
    }

    /// `owner`: one of yours (`false` for the ones shared with you).
    /// `accountId`: the account of the session (`nil`: the current one).
    func attach(sessionId: String, label: String, hostId: String?, owner: Bool = true, accountId: String? = nil) {
        if let existing = open.first(where: { ($0 as? ServerTerminal)?.sessionId == sessionId }) {
            show(existing.id)
            return
        }
        add(ServerTerminal(core: core, label: label, hostId: hostId, sessionId: sessionId, owner: owner,
                           accountId: accountId, settings: settings))
    }

    /// Joins a shared session with an invitation link, in a new tab.
    func join(_ link: JoinLink, mode: ServerTerminal.JoinMode, title: String) {
        if let existing = open.first(where: { ($0 as? ServerTerminal)?.link == link && $0.ended == nil }) {
            show(existing.id)
            return
        }
        let label = title.isEmpty ? String(localized: "common.session") : title
        add(ServerTerminal(core: core, link: link, mode: mode, label: label, settings: settings))
    }

    /// The tab of a session on the server (yours, shared with you or a
    /// terminal of this device shared through it).
    func tab(forSession id: String) -> TerminalSession? {
        open.first(where: { $0.shareSessionId == id })
    }

    /// Opens (or goes to) the tab of one of your sessions or of one shared
    /// with you, e.g. from a notice.
    func openSession(_ id: String, title: String, owner: Bool) {
        if let s = tab(forSession: id) {
            show(s.id)
        } else {
            attach(sessionId: id, label: title.isEmpty ? String(localized: "common.session") : title, hostId: nil, owner: owner)
        }
    }

    private func add(_ s: TerminalSession) {
        let previous = current?.id
        prepare(s)
        open.append(s)
        // Split view: a new terminal is one more pane (or takes the focused
        // one's place when there are already four).
        if splitOnNextOpen, panes.count < 2, let previous {
            panes = [previous, s.id]
        } else if panes.count >= 2 {
            if panes.count < PaneLayout.maxPanes {
                panes.append(s.id)
            } else if let slot = activeId.flatMap({ panes.firstIndex(of: $0) }) {
                broadcastExcluded.remove(panes[slot])
                panes[slot] = s.id
            }
        }
        splitOnNextOpen = false
        activeId = s.id
        showing = true
        s.start()
    }

    private func prepare(_ s: TerminalSession) {
        s.showKeyBar(keyBarVisible)
        s.onOpenPanel = { [weak self] in self?.quickPanelOpen = true }
        s.onMirror = { [weak self] source, m in self?.mirror(m, from: source) }
        s.onConfirmPaste = { [weak self] source, text in
            self?.pasteRequest = PasteRequest(session: source, text: text)
        }
        s.notices = notices
        if let local = s as? LocalTerminal {
            // When it connects, the host's automatic tunnels start.
            local.onConnected = { [weak self] hostId, connection in
                Task { await self?.tunnels.onTerminalConnected(hostId: hostId, session: connection) }
            }
            local.onHostChanged = { [weak self] in self?.onHostChanged?() }
        }
    }

    func close(_ id: UUID) {
        guard let i = open.firstIndex(where: { $0.id == id }) else { return }
        // A pane: the focus goes to a neighbouring pane.
        if panes.contains(id) { removePane(id) }
        open[i].disconnect()
        open.remove(at: i)
        copilots[id] = nil
        // Sleeping tabs do not wake up by themselves: if only those remain, go home.
        if activeId == id { activeId = open.last(where: { !$0.asleep })?.id }
        if !open.contains(where: { !$0.asleep }) { showing = false }
    }

    /// Every terminal but this one (the tab menu's "Close other tabs").
    func closeOthers(_ id: UUID) {
        for s in open where s.id != id { close(s.id) }
        if open.contains(where: { $0.id == id }) { show(id) }
    }

    /// The same host again in a new tab: a new connection from here, or a
    /// new session on the server (not for sessions shared with you).
    func duplicate(_ id: UUID) {
        guard let s = open.first(where: { $0.id == id }), s.isOwner, let hostId = s.hostId,
              let host = try? core.getHost(id: hostId, accountId: s.accountId) else { return }
        if s is ServerTerminal { openOnServer(host) } else { openLocal(host) }
    }

    /// Can be duplicated: yours and with a host.
    func canDuplicate(_ s: TerminalSession) -> Bool {
        s.isOwner && s.hostId != nil && (s as? ServerTerminal)?.link == nil
    }

    /// An account signed out: its terminals close (those of its hosts from
    /// this device and its server sessions, which stay on the server).
    func closeTerminals(ofAccount accountId: String) {
        for s in open where s.accountId == accountId { close(s.id) }
        onServer.removeAll { $0.accountId == accountId }
    }

    func closeAll() {
        exitSplit()
        open.forEach { $0.disconnect() }
        open = []
        copilots = [:]
        activeId = nil
        showing = false
    }

    // ----- Server sessions at launch -----

    /// When opening the app or signing in: your server sessions that are
    /// still running, on every signed-in account, appear as sleeping tabs
    /// (not connected) and the screen does not change. The ones shared with
    /// you are not added.
    func restoreFromServer(accounts: [String]) async {
        onServer = await runningSessions(accounts)
        for item in onServer where !open.contains(where: { ($0 as? ServerTerminal)?.sessionId == item.session.id }) {
            let s = item.session
            let h = s.hostId.flatMap { try? core.getHost(id: $0, accountId: item.accountId) }
            let label = !s.title.isEmpty ? s.title : h.map { $0.label.isEmpty ? $0.address : $0.label } ?? String(localized: "common.session")
            let newSession = ServerTerminal(core: core, label: label, hostId: s.hostId, sessionId: s.id,
                                            accountId: item.accountId, settings: settings)
            newSession.asleep = true
            prepare(newSession)
            open.append(newSession)
        }
    }

    /// Checks again how many sessions are running on the servers.
    func refreshServer(accounts: [String]) async {
        onServer = await runningSessions(accounts)
    }

    private func runningSessions(_ accounts: [String]) async -> [AccountSession] {
        var out: [AccountSession] = []
        for id in accounts {
            guard let handle = try? core.account(accountId: id),
                  let list = try? await handle.listServerSessions() else { continue }
            out += list.active.filter(\.restorable).map { AccountSession(accountId: id, session: $0) }
        }
        return out
    }

    /// Accounts signed out: remove their notice and their sleeping tabs.
    func forgetServer(keeping accounts: Set<String>) {
        onServer.removeAll { !accounts.contains($0.accountId) }
        for s in open where s.asleep && s is ServerTerminal && !(s.accountId.map(accounts.contains) ?? !accounts.isEmpty) {
            close(s.id)
        }
    }

    /// Button of the home notice: opens the first tab of a running session (or
    /// attaches to the first one, if it no longer has a tab).
    func openRunningSessions() {
        let ids = Set(onServer.map(\.session.id))
        if let s = open.first(where: { a in (a as? ServerTerminal)?.sessionId.map { ids.contains($0) } ?? false }) {
            show(s.id)
        } else if let item = onServer.first {
            let s = item.session
            let host = s.hostId.flatMap { try? core.getHost(id: $0, accountId: item.accountId) }
            let label = !s.title.isEmpty ? s.title : host.map { $0.label.isEmpty ? $0.address : $0.label } ?? String(localized: "common.session")
            attach(sessionId: s.id, label: label, hostId: s.hostId, accountId: item.accountId)
        }
    }

    /// Text size, font or theme changed in the settings.
    func applyAppearance() {
        open.forEach { $0.applyAppearance(settings) }
    }

    /// Bar keys changed in "Customize".
    func applyKeyboard() {
        open.forEach { $0.keyBar.reload() }
    }

    /// iOS freezes the app shortly after leaving it: ask for a few minutes of
    /// grace so local connections are not cut instantly.
    func enterBackground() {
        if leftAt == nil {
            leftAt = Date()
            open.compactMap { $0 as? LocalTerminal }.forEach { $0.leaving() }
        }
        guard open.contains(where: { !$0.asleep }), backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Terminals") { [weak self] in
            Task { @MainActor in self?.endBackground() }
        }
    }

    /// Back in the foreground: the terminals of this device that the
    /// system cut meanwhile reconnect by themselves.
    func returnedToForeground() {
        endBackground()
        guard let leftAt else { return }
        self.leftAt = nil
        let away = Date().timeIntervalSince(leftAt)
        open.compactMap { $0 as? LocalTerminal }.forEach { $0.returned(after: away) }
    }

    func endBackground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

enum ShareError: LocalizedError {
    case notConnected
    var errorDescription: String? { String(localized: "terminal.error.not_connected") }
}

/// A server session and the account it runs on.
struct AccountSession: Identifiable {
    let accountId: String
    let session: ServerSession
    var id: String { itemKey(accountId, session.id) }
}

extension ServerSession {
    /// Not closed (running, connecting or waiting for the host).
    var isRunning: Bool {
        if case .closed = state { return false }
        return true
    }

    /// Yours, running on the server (not a relay: shared terminals, also the
    /// copilot ones, are not restored).
    var restorable: Bool { kind == "server" && isRunning }
}
