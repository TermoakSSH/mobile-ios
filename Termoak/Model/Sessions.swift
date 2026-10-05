import TermoakKit
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
    let view: TerminalView

    @Published var state: TerminalState = .connecting(TerminalState.connectingMessage) {
        didSet {
            switch state {
            case .connected: if connectedAt == nil { connectedAt = Date() }
            case .connecting, .closed: connectedAt = nil
            }
        }
    }
    /// When the current connection was made (the time shown in Connections).
    private(set) var connectedAt: Date?
    /// Tab of a server session that was open at launch: it is not attached
    /// until tapped.
    @Published var asleep = false
    @Published var title: String?
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

    /// What is typed, to save the sent commands in the history.
    private let line = LineTracker()
    private(set) var keyBar: KeyBar!
    private var gesture: CursorGesture?
    private var observers: [NSObjectProtocol] = []
    /// Requested by the key bar (grid button).
    var onOpenPanel: (() -> Void)?
    /// Host OS, to suggest the right package manager.
    private let os: String?
    /// Look for suggestions as soon as the echo of what was typed arrives.
    private var suggestAfterEcho = false
    private var query = 0

    /// Lives on the server: closing the tab only detaches it.
    var persistent: Bool { false }

    init(core: TermoakCore, label: String, hostId: String?, settings: AppSettings) {
        self.core = core
        self.label = label
        self.hostId = hostId
        os = hostId.flatMap { try? core.getHost(id: $0).os }
        view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        super.init()
        view.terminalDelegate = self
        applyAppearance(settings)
        keyBar = KeyBar(session: self, settings: settings)
        view.inputAccessoryView = keyBar
        gesture = CursorGesture(session: self)
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

    func applyAppearance(_ settings: AppSettings) {
        view.font = settings.terminalFont.ui(settings.fontSize)
        settings.terminalTheme.apply(to: view)
        keyBar?.applyTheme(settings.terminalTheme)
        suggestionMode = settings.suggestionMode
        suggestions = []
        gestureMode = settings.gestureMode
        gesture?.configure(gestureMode, cursorByButton: cursorByButton)
        keyBar?.paintGestureButton()
    }

    /// Everything that goes to the terminal passes through here: the typed line
    /// is tracked (for the history) and sent.
    func input(_ data: Data) {
        guard state == .connected else { return }
        trackLine(data)
        send(data)
        // Suggestions come when the shell shows what was typed (if it does not,
        // like a password, nothing is suggested).
        guard suggestionMode != .off else { return }
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

    func paste(_ text: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        input(Data(normalized.utf8))
    }

    func typeText(_ text: String) {
        input(Data(text.utf8))
    }

    /// Runs a command (snippet or history): types it and presses Enter. It goes
    /// in one go, without waiting for the echo, so it is saved in the history
    /// directly (we know what it is) and the line starts over.
    func run(_ command: String) {
        guard state == .connected else { return }
        let normalized = command.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        send(Data((normalized + "\r").utf8))
        line.reset()
        suggestions = []
        guard let hostId, !command.contains("\n") else { return }
        let core = core
        Task.detached { _ = try? core.recordCommand(hostId: hostId, command: command) }
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
            if let t = UIPasteboard.general.string { paste(t) }
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
        view.feed(byteArray: [UInt8](data)[...])
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
        Task { @MainActor in self.input(bytes) }
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
    /// Connected: to start the automatic tunnels.
    var onConnected: ((String, SshSession) -> Void)?

    /// The SSH connection of this terminal (for SFTP and tunnels without reconnecting).
    var connection: SshSession? { handle?.session() }

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

    init(core: TermoakCore, host: SshHost, settings: AppSettings) {
        address = host.address
        super.init(core: core, label: host.label.isEmpty ? host.address : host.label, hostId: host.id, settings: settings)
    }

    override func start() {
        guard handle == nil, task == nil, let hostId else { return }
        state = .connecting(String(localized: "terminal.state.connecting_to \(address)"))
        let auth = AuthBridge { [weak self] prompt in
            Task { @MainActor in self?.prompt = prompt }
        }
        let listener = LocalListener(session: self)
        let (cols, rows) = size
        task = Task {
            defer { task = nil }
            do {
                let h = try await core.connectTerminal(hostId: hostId, cols: cols, rows: rows, auth: auth, listener: listener)
                handle = h
                state = .connected
                let (c, r) = size
                try? h.resize(cols: c, rows: r)
                onConnected?(hostId, h.session())
                _ = view.becomeFirstResponder()
            } catch {
                state = .closed(errorMessage(error))
            }
        }
    }

    override func reconnect() {
        disconnect()
        view.feed(text: "\u{1b}c")
        forgetLine()
        start()
    }

    /// Shares the terminal with the server for the copilot (if it is not
    /// already) and returns the id of the relay session.
    func share(title: String) async throws -> String {
        if let c = shared { return c.sessionId() }
        guard let h = handle else { throw ShareError.notConnected }
        let c = try await core.shareTerminal(terminal: h, title: title)
        // It was closed or reconnected meanwhile: that relay is no longer useful.
        guard handle === h else {
            Task.detached { try? await c.stop() }
            throw ShareError.notConnected
        }
        if let existing = shared {
            Task.detached { try? await c.stop() }
            return existing.sessionId()
        }
        shared = c
        sharedByCopilot = true
        let (cols, rows) = size
        Task.detached { try? await c.resize(cols: cols, rows: rows) }
        return c.sessionId()
    }

    private func stopSharing() {
        guard let c = shared else { return }
        shared = nil
        sharedByCopilot = false
        Task.detached { try? await c.stop() }
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

// MARK: - Session that lives on the server

/// Stays open even if the phone sleeps or loses coverage. On return, the
/// server sends the whole scrollback.
final class ServerTerminal: TerminalSession {
    private(set) var sessionId: String?
    private var handle: ServerTerminalHandle?
    private var task: Task<Void, Never>?

    override var persistent: Bool { true }

    /// With `sessionId` it attaches to an existing one; without it, it opens a new one on `hostId`.
    init(core: TermoakCore, label: String, hostId: String?, sessionId: String?, settings: AppSettings) {
        self.sessionId = sessionId
        super.init(core: core, label: label, hostId: hostId, settings: settings)
    }

    override func start() {
        guard handle == nil, task == nil else { return }
        state = .connecting(String(localized: "terminal.state.connecting_server"))
        let listener = ServerListener(session: self)
        let (cols, rows) = size
        task = Task {
            defer { task = nil }
            do {
                let id: String
                if let sessionId {
                    id = sessionId
                } else if let hostId {
                    id = try await core.openServerSession(hostId: hostId, cols: cols, rows: rows, title: label, record: nil).id
                    sessionId = id
                } else {
                    return
                }
                let h = try await core.attachServerSession(sessionId: id, listener: listener)
                handle = h
                let (c, r) = size
                h.resize(cols: c, rows: r)
                _ = view.becomeFirstResponder()
            } catch {
                state = .closed(errorMessage(error))
            }
        }
    }

    override func reconnect() {
        disconnect()
        view.feed(text: "\u{1b}c")
        forgetLine()
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
        if let handle {
            handle.closeSession()
        } else if let sessionId {
            Task { try? await core.closeServerSession(sessionId: sessionId) }
        }
    }

    override fileprivate func send(_ data: Data) {
        handle?.write(data: data)
    }

    override fileprivate func resize(cols: UInt32, rows: UInt32) {
        handle?.resize(cols: cols, rows: rows)
    }

    fileprivate func event(_ event: ServerTerminalEvent) {
        switch event {
        case .hello(let session):
            title = session.title.isEmpty ? nil : session.title
            apply(session.state)
        case .output(let data):
            if state != .connected { state = .connected }
            receive(data)
        case .resync:
            // The full scrollback comes next.
            view.feed(text: "\u{1b}c")
        case .status(let st):
            apply(st)
        case .title(let t):
            title = t.isEmpty ? nil : t
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
            state = .closed(message)
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
    /// Your running server sessions (the notice on the home screen).
    @Published private(set) var onServer: [ServerSession] = []

    /// One conversation with the AI per tab.
    private var copilots: [UUID: Copilot] = [:]

    private let core: TermoakCore
    private let settings: AppSettings
    private let tunnels: Tunnels
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(core: TermoakCore, settings: AppSettings, tunnels: Tunnels) {
        self.core = core
        self.settings = settings
        self.tunnels = tunnels
        // Tunnels reuse the connection of a terminal open to the host.
        tunnels.terminalConnection = { [weak self] hostId in
            self?.open.lazy.compactMap { ($0 as? LocalTerminal)?.connection(for: hostId) }.first
        }
    }

    var current: TerminalSession? {
        open.first(where: { $0.id == activeId }) ?? open.last(where: { !$0.asleep }) ?? open.last
    }

    /// The copilot conversation of a tab (created the first time).
    func copilot(for s: TerminalSession) -> Copilot {
        if let c = copilots[s.id] { return c }
        let c = Copilot(core: core)
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
        activeId = id
        showing = true
        wake(s)
    }

    func wake(_ s: TerminalSession) {
        guard s.asleep else { return }
        s.asleep = false
        s.start()
    }

    func openLocal(_ host: SshHost) {
        add(LocalTerminal(core: core, host: host, settings: settings))
    }

    func openOnServer(_ host: SshHost) {
        add(ServerTerminal(core: core, label: host.label.isEmpty ? host.address : host.label,
                              hostId: host.id, sessionId: nil, settings: settings))
    }

    func attach(sessionId: String, label: String, hostId: String?) {
        if let existing = open.first(where: { ($0 as? ServerTerminal)?.sessionId == sessionId }) {
            show(existing.id)
            return
        }
        add(ServerTerminal(core: core, label: label, hostId: hostId, sessionId: sessionId, settings: settings))
    }

    private func add(_ s: TerminalSession) {
        prepare(s)
        open.append(s)
        activeId = s.id
        showing = true
        s.start()
    }

    private func prepare(_ s: TerminalSession) {
        s.onOpenPanel = { [weak self] in self?.quickPanelOpen = true }
        if let local = s as? LocalTerminal {
            // When it connects, the host's automatic tunnels start.
            local.onConnected = { [weak self] hostId, connection in
                Task { await self?.tunnels.onTerminalConnected(hostId: hostId, session: connection) }
            }
        }
    }

    func close(_ id: UUID) {
        guard let i = open.firstIndex(where: { $0.id == id }) else { return }
        open[i].disconnect()
        open.remove(at: i)
        copilots[id] = nil
        // Sleeping tabs do not wake up by themselves: if only those remain, go home.
        if activeId == id { activeId = open.last(where: { !$0.asleep })?.id }
        if !open.contains(where: { !$0.asleep }) { showing = false }
    }

    func closeAll() {
        open.forEach { $0.disconnect() }
        open = []
        copilots = [:]
        activeId = nil
        showing = false
    }

    // ----- Server sessions at launch -----

    /// When opening the app or logging in: your server sessions that are still
    /// running appear as sleeping tabs (not connected) and the screen does not
    /// change. The ones shared with you are not added.
    func restoreFromServer() async {
        guard let list = try? await core.listServerSessions() else { return }
        onServer = list.active.filter(\.restorable)
        let hosts = Dictionary(((try? core.listHosts()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for s in onServer where !open.contains(where: { ($0 as? ServerTerminal)?.sessionId == s.id }) {
            let h = s.hostId.flatMap { hosts[$0] }
            let label = !s.title.isEmpty ? s.title : h.map { $0.label.isEmpty ? $0.address : $0.label } ?? String(localized: "common.session")
            let newSession = ServerTerminal(core: core, label: label, hostId: s.hostId, sessionId: s.id, settings: settings)
            newSession.asleep = true
            prepare(newSession)
            open.append(newSession)
        }
    }

    /// Checks again how many sessions are running on the server.
    func refreshServer() async {
        guard let list = try? await core.listServerSessions() else { return }
        onServer = list.active.filter(\.restorable)
    }

    /// Logged out of the account: remove the notice and the sleeping tabs.
    func forgetServer() {
        onServer = []
        for s in open where s.asleep { close(s.id) }
    }

    /// Button of the home notice: opens the first tab of a running session (or
    /// attaches to the first one, if it no longer has a tab).
    func openRunningSessions() {
        let ids = Set(onServer.map(\.id))
        if let s = open.first(where: { a in (a as? ServerTerminal)?.sessionId.map { ids.contains($0) } ?? false }) {
            show(s.id)
        } else if let s = onServer.first {
            let host = s.hostId.flatMap { try? core.getHost(id: $0) }
            let label = !s.title.isEmpty ? s.title : host.map { $0.label.isEmpty ? $0.address : $0.label } ?? String(localized: "common.session")
            attach(sessionId: s.id, label: label, hostId: s.hostId)
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
        guard open.contains(where: { !$0.asleep }), backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Terminals") { [weak self] in
            Task { @MainActor in self?.endBackground() }
        }
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
