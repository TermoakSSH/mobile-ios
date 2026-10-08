import TermoakKit
import Foundation

/// What arrives live from the task (server events) and is not saved in its
/// conversation yet.
struct LiveItem: Identifiable {
    enum Kind { case text, reasoning, tool, notice }

    let id: Int
    let kind: Kind
    /// Text, reasoning, tool summary or notice.
    var text: String
    /// Tools: call id (`call_id`), name and output.
    var callId = ""
    var name = ""
    var output: String?
    var error = false
}

/// Conversation with the AI tied to a terminal tab (the "Copilot" panel).
/// The AI works on the server: the first request creates a task and the
/// following ones are messages of that task.
@MainActor
final class Copilot: ObservableObject {
    /// The AI of the account the terminal belongs to.
    private let core: AccountApi
    /// The host is known to that account's server (the task can name it).
    private let sendsHost: Bool

    @Published private(set) var task: AiTask? {
        didSet { conversation = task.map(turns) ?? [] }
    }
    /// The saved conversation of the task, already split into turns.
    @Published private(set) var conversation: [Turn] = []
    /// Task permissions (chosen before the first message).
    @Published var mode: AiPermissionMode = .ask
    @Published var draft = ""
    @Published private(set) var sending = false
    @Published var error: String? {
        didSet { accessProblem = nil }
    }
    /// The current error is fixed in Settings → AI (no key of your own, or
    /// this month's credit is spent). Set by `fail(_:)` after `error`.
    @Published private(set) var accessProblem: AiAccessProblem?
    /// Sent messages that do not appear in the saved conversation yet.
    @Published private(set) var pending: [String] = []
    @Published private(set) var live: [LiveItem] = []
    @Published private(set) var liveApprovals: [AiApproval] = []
    /// What the approvals that arrived live show (server 0.6), by id.
    private var livePreviews: [String: ApprovalPreview] = [:]
    @Published private(set) var liveStatus: AiTaskStatus?
    /// Increases with every content change (to scroll to the end of the conversation).
    @Published private(set) var changes = 0

    private var decided: Set<String> = []
    /// Tool outputs received live (by `call_id`), in case the call is
    /// already saved but its result is not yet.
    private var results: [String: (output: String, error: Bool)] = [:]
    private var nextId = 0
    /// The next text chunk starts a new item (another turn).
    private var splitNext = false
    /// Events that arrive while the task is being created (no id yet).
    private var creating = false
    private var buffer: [AiEvent] = []
    /// Increases with "New conversation": whatever arrives from the previous one is ignored.
    private var generation = 0
    /// Whether the AI of this conversation types in the terminal or only sees
    /// its screen (nil: nothing asked yet).
    @Published private(set) var access: Access?
    /// Last server session (own or relay) given to the AI. If it is a
    /// different one when sending (shared again or the SSH reconnected), the
    /// AI is told about the new one.
    private var taskSession: String?
    /// What goes with the next message (host, last command, selection), as
    /// removable chips; their text is redacted by the engine.
    @Published private(set) var chips: [ContextChip] = []
    /// Something attached (the chips, or the screen when the AI can't read
    /// the terminal) has secrets, hidden before leaving the device.
    @Published private(set) var secretsHidden = false
    /// The screen sent in this conversation had secrets (hidden).
    private var screenRedacted = false
    /// The terminal's context the chips are made from.
    private var hostChip: ContextChip?
    private var lastCommand: LastCommandInfo?
    /// The last command already sent (its chip isn't offered again).
    private var sentCommand: LastCommandInfo?
    private var selection: String?
    /// Chips removed by hand (until the context changes).
    private var removed: Set<ContextChip> = []
    /// Mode chosen mid-task, until the reloaded task confirms it.
    @Published private(set) var pendingMode: AiPermissionMode?
    /// Stopped while the task was being created: it is cancelled as soon as it exists.
    private var stopWhenCreated = false

    enum Access {
        /// The task carries the session: the AI types the commands in the terminal.
        case terminal
        /// The terminal could not be shared: the screen is attached instead.
        case screen
    }

    init(core: AccountApi, sendsHost: Bool = true) {
        self.core = core
        self.sendsHost = sendsHost
    }

    var status: AiTaskStatus? { liveStatus ?? task?.status }

    /// Permissions shown in the picker: the task's (after "Always approve"
    /// it becomes Autonomous) or the ones chosen to create it.
    var currentMode: AiPermissionMode { pendingMode ?? task?.mode ?? mode }

    var running: Bool {
        guard let e = status else { return false }
        return e == .queued || e == .running || e == .waitingApproval
    }

    /// Nothing yet: the suggestions and permissions are shown.
    var isEmpty: Bool { task == nil && pending.isEmpty && !sending }

    /// Pending approvals: those of the saved task and those that arrived
    /// live, without the ones already decided.
    var approvals: [AiApproval] {
        var seen = Set<String>()
        var out: [AiApproval] = []
        for a in (task?.pendingApprovals ?? []) + liveApprovals
        where !decided.contains(a.id) && !seen.contains(a.id) {
            seen.insert(a.id)
            out.append(a)
        }
        return out
    }

    /// Live output of a saved tool call without a result.
    func result(for callId: String) -> (output: String, error: Bool)? {
        results[callId]
    }

    // ----- Actions -----

    /// Starts another conversation (the previous task stays in the AI section).
    func newConversation() {
        generation += 1
        access = nil
        taskSession = nil
        pendingMode = nil
        stopWhenCreated = false
        task = nil
        draft = ""
        error = nil
        sending = false
        pending = []
        live = []
        liveApprovals = []
        liveStatus = nil
        decided = []
        results = [:]
        splitNext = false
        creating = false
        buffer = []
        selection = nil
        sentCommand = nil
        removed = []
        screenRedacted = false
        rebuildChips()
        changes += 1
    }

    // ----- Context chips -----

    /// The terminal in front of the panel: its host (only offered before the
    /// first message) and the last command that ended in it.
    func updateContext(host: ContextChip?, last: LastCommandInfo?) {
        hostChip = host
        lastCommand = last
        rebuildChips()
    }

    /// "Ask AI about this": the selected text goes with the next message
    /// (it replaces a previous selection).
    func attach(selection text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        selection = text
        removed = removed.filter { $0.kind != .selection }
        rebuildChips()
    }

    /// The chip's (x): it doesn't go with the message.
    func remove(_ chip: ContextChip) {
        removed.insert(chip)
        if chip.kind == .selection { selection = nil }
        rebuildChips()
    }

    private func rebuildChips() {
        var out: [ContextChip] = []
        if task == nil, pending.isEmpty, let hostChip { out.append(hostChip) }
        if let last = lastCommand, last != sentCommand {
            out.append(contextChipLastCommand(last: last, label: Copilot.lastCommandLabel(last)))
        }
        if let selection {
            let label = String(localized: "copilot.chip.selection \(CopilotChipLabel.lines(selection))")
            out.append(contextChipSelection(text: selection, label: label))
        }
        chips = out.filter { !removed.contains($0) }
        secretsHidden = screenRedacted || chipsHadSecrets
    }

    /// "make · exit 2", "make · failed", or the command alone.
    static func lastCommandLabel(_ last: LastCommandInfo) -> String {
        let command = CopilotChipLabel.command(last.command) ?? String(localized: "copilot.chip.last_command")
        if let code = last.exitCode, code != 0 { return String(localized: "copilot.chip.exit \(command) \(Int(code))") }
        if last.failure != nil { return String(localized: "copilot.chip.failed \(command)") }
        return command
    }

    /// Whether the chips' source text had secrets (the engine hides them).
    private var chipsHadSecrets: Bool {
        chips.contains { chip in
            switch chip.kind {
            case .selection: return selection.map { containsSecrets(text: $0) } ?? false
            case .lastCommand: return lastCommand.map { containsSecrets(text: $0.output) || containsSecrets(text: $0.command ?? "") } ?? false
            default: return false
            }
        }
    }

    /// Sends what was typed. The AI types in the terminal through its server
    /// session; a direct SSH terminal is first shared with the server (relay,
    /// only for you). If that is not possible, the screen contents are attached.
    func send(from session: TerminalSession) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        draft = ""
        error = nil
        pending.append(text)
        sending = true
        changes += 1

        let local = session as? LocalTerminal
        let own = (session as? ServerTerminal)?.sessionId
        // Nothing leaves the device with its secrets: the screen (attached
        // when the AI can't read the terminal) is redacted here, the chips by
        // the engine.
        let rawScreen = session.screenText()
        let screen = redactSecrets(text: rawScreen)
        let screenHadSecrets = containsSecrets(text: rawScreen)
        let name = session.hostId == nil ? "local terminal" : session.label
        let context = chips.isEmpty ? "" : copilotContextBlock(label: name, chips: chips)
        let used = (lastCommand: chips.contains { $0.kind == .lastCommand } ? lastCommand : nil,
                    selection: chips.contains { $0.kind == .selection })
        let hostIds = sendsHost ? (session.hostId.map { [$0] } ?? []) : []
        let id = task?.id
        if id == nil {
            creating = true
            buffer = []
        }
        let gen = generation
        Task {
            defer { if gen == generation { sending = false } }
            do {
                // The session the AI will use to type in the terminal. A direct
                // SSH terminal that is not shared is shared now (also if sharing
                // stopped when the panel was stopped or closed), unless it already failed.
                var sessionId = own ?? local?.sharedSessionId
                if sessionId == nil, let local, access != .screen {
                    do {
                        sessionId = try await local.share(title: "Copilot · \(local.label)")
                    } catch {
                        // Remembered: not retried in this conversation.
                        if gen == generation { access = .screen }
                    }
                }
                guard gen == generation else { return }
                if let id {
                    var request = context + text
                    if let sessionId {
                        if sessionId != taskSession {
                            request = Copilot.withSession(sessionId, context + text)
                        }
                    } else {
                        request = Copilot.withContext(context + text, screen: screen, name: name)
                    }
                    if sessionId == nil && screenHadSecrets { screenRedacted = true }
                    _ = try await core.sendAiMessage(taskId: id, text: request)
                    if gen == generation, let sessionId {
                        taskSession = sessionId
                        access = .terminal
                    }
                } else {
                    let request = sessionId == nil
                        ? Copilot.withContext(context + text, screen: screen, name: name) : context + text
                    if sessionId == nil && screenHadSecrets { screenRedacted = true }
                    let t = try await core.createAiTask(request: AiTaskRequest(
                        prompt: request, mode: mode, hostIds: hostIds, sessionId: sessionId))
                    guard gen == generation else { return }
                    taskSession = sessionId
                    access = sessionId == nil ? .screen : .terminal
                    task = t
                    creating = false
                    // What arrived while it was being created.
                    let arrived = buffer
                    buffer = []
                    arrived.forEach { receive($0) }
                    if stopWhenCreated {
                        // Stopped (or the panel closed) while it was being created.
                        stopWhenCreated = false
                        stop(local)
                        return
                    }
                }
                // What was attached went with it: not offered again.
                if gen == generation {
                    if let last = used.lastCommand { sentCommand = last }
                    if used.selection { selection = nil }
                    removed = []
                    rebuildChips()
                }
                await reload()
            } catch {
                guard gen == generation else { return }
                creating = false
                stopWhenCreated = false
                buffer = []
                pending.removeAll { $0 == text }
                if draft.isEmpty { draft = text }
                fail(error)
                changes += 1
            }
        }
    }

    /// "Stop" (or closing the panel): cancels the task if it is working and,
    /// if the terminal was shared for the copilot, stops sharing it (the AI
    /// loses access). Server sessions are left alone.
    func stop(_ local: LocalTerminal?) {
        local?.stopCopilotSharing()
        if running {
            cancel()
        } else if creating {
            stopWhenCreated = true
        }
    }

    /// Changes the permissions: without a task, those of the one to be created;
    /// with a task, the task's (also when stopped: they apply to the next messages).
    func changeMode(_ m: AiPermissionMode) {
        mode = m
        guard let id = task?.id, m != task?.mode || pendingMode != nil else { return }
        pendingMode = m
        let gen = generation
        Task {
            do {
                try await core.setAiTaskMode(taskId: id, mode: m)
                await reload()
            } catch {
                if gen == generation { fail(error) }
            }
            if gen == generation && pendingMode == m { pendingMode = nil }
        }
    }

    func cancel() {
        guard let id = task?.id else { return }
        Task {
            do {
                try await core.cancelAiTask(taskId: id)
            } catch {
                fail(error)
            }
            await reload()
        }
    }

    /// What an approval shows: from the saved task, or as it arrived live.
    func preview(for approvalId: String) -> ApprovalPreview? {
        if let p = livePreviews[approvalId] { return p }
        return approvals.first { $0.id == approvalId }?.shownPreview
    }

    func decide(_ a: AiApproval, _ choice: ApprovalChoice) {
        Task {
            do {
                try await core.decide(taskId: a.taskId, approvalId: a.id, choice)
                decided.insert(a.id)
                liveApprovals.removeAll { $0.id == a.id }
                changes += 1
            } catch {
                fail(error)
            }
            await reload()
        }
    }

    /// Fetches the task with its conversation again and removes from the
    /// "live" items whatever is already saved.
    func reload() async {
        guard let id = task?.id else { return }
        guard let t = try? await core.getAiTask(taskId: id), t.id == task?.id else { return }
        task = t
        liveStatus = nil
        consolidate(t)
        if !running {
            // Finished: everything is in the conversation already.
            live.removeAll { $0.kind != .notice }
            liveApprovals = []
        }
        changes += 1
    }

    /// The panel is visible again (opened or tab switched): no events arrived
    /// while it was hidden, so the half-written text is useless; the
    /// conversation is reloaded.
    func resume() {
        live.removeAll { $0.kind == .text || $0.kind == .reasoning }
        splitNext = true
        Task { await reload() }
    }

    // ----- Live events -----

    func receive(_ e: AiEvent) {
        guard let id = task?.id else {
            if creating { buffer.append(e) }
            return
        }
        guard e.taskId == id else { return }
        let ev = e.event
        switch ev["type"] as? String {
        case "text":
            append(.text, ev["delta"] as? String ?? "")
        case "reasoning":
            append(.reasoning, ev["delta"] as? String ?? "")
        case "reset":
            if let i = live.lastIndex(where: { $0.kind == .text }) { live.remove(at: i) }
        case "notice":
            add(LiveItem(id: next(), kind: .notice, text: ev["message"] as? String ?? ""))
        case "tool_call":
            let callId = string(ev["call_id"])
            guard !live.contains(where: { $0.kind == .tool && $0.callId == callId }) else { break }
            add(LiveItem(id: next(), kind: .tool, text: ev["summary"] as? String ?? "",
                           callId: callId, name: ev["tool"] as? String ?? ""))
        case "tool_result":
            let callId = string(ev["call_id"])
            let output = ev["output"] as? String ?? ""
            let failed = !((ev["ok"] as? Bool) ?? true)
            results[callId] = (output, failed)
            if let i = live.firstIndex(where: { $0.kind == .tool && $0.callId == callId }) {
                live[i].output = output
                live[i].error = failed
            }
            splitNext = true
        case "approval_requested":
            let aid = string(ev["approval_id"])
            guard !aid.isEmpty, !decided.contains(aid), !liveApprovals.contains(where: { $0.id == aid }) else { break }
            if let p = ev["preview"] as? [String: Any] { livePreviews[aid] = ApprovalPreview.parse(p) }
            liveApprovals.append(AiApproval(
                id: aid, taskId: id, tool: ev["tool"] as? String ?? "", inputJson: json(ev["input"]),
                summary: ev["summary"] as? String ?? "", status: "pending", decidedBy: nil,
                createdAt: Int64(Date().timeIntervalSince1970 * 1000), decidedAt: nil))
        case "approval_decided":
            let aid = string(ev["approval_id"])
            decided.insert(aid)
            liveApprovals.removeAll { $0.id == aid }
        case "status":
            if let s = ev["status"] as? String { liveStatus = Copilot.taskStatus(s) }
        case "message":
            splitNext = true
            Task {
                await reload()
                // It is saved right after the notice: once more, just in case.
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await reload()
            }
        case "finished":
            splitNext = true
            if let s = ev["status"] as? String { liveStatus = Copilot.taskStatus(s) }
            Task {
                await reload()
                live.removeAll { $0.kind != .notice }
                liveApprovals = []
                changes += 1
            }
        default:
            return
        }
        changes += 1
    }

    private func next() -> Int {
        nextId += 1
        return nextId
    }

    private func add(_ e: LiveItem) {
        live.append(e)
        splitNext = false
    }

    /// A chunk of text or reasoning: appended to the current one.
    private func append(_ kind: LiveItem.Kind, _ delta: String) {
        guard !delta.isEmpty else { return }
        if !splitNext, let i = live.indices.last, live[i].kind == kind {
            live[i].text += delta
        } else {
            add(LiveItem(id: next(), kind: kind, text: delta))
        }
    }

    /// Removes the "live" items that already appear in the saved conversation.
    private func consolidate(_ t: AiTask) {
        var texts = Set<String>()
        var reasonings = Set<String>()
        var calls = Set<String>()
        var userTexts: [String] = []
        for turn in conversation {
            switch turn {
            case .user(_, let s): userTexts.append(s)
            case .assistant(_, let s): texts.insert(s)
            case .reasoning(_, let s): reasonings.insert(s)
            case let .tool(_, callId, _, _, _, _): calls.insert(callId)
            }
        }
        live.removeAll { e in
            let s = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch e.kind {
            case .text: return s.isEmpty || texts.contains(s)
            case .reasoning: return s.isEmpty || reasonings.contains(s)
            case .tool: return calls.contains(e.callId)
            case .notice: return false
            }
        }
        for u in userTexts {
            if let i = pending.firstIndex(of: u) { pending.remove(at: i) }
        }
        let saved = Set(t.pendingApprovals.map(\.id))
        liveApprovals.removeAll { saved.contains($0.id) }
    }

    // ----- Helpers -----

    /// Shows an error; a missing AI key or a spent credit gets its own
    /// message and the button to Settings → AI.
    private func fail(_ error: Error) {
        let problem = AiAccessProblem(error)
        self.error = problem?.message ?? userMessage(error)
        // After `error`: its didSet clears it.
        accessProblem = problem
    }

    /// Tells the AI that the terminal is now another session.
    static func withSession(_ id: String, _ text: String) -> String {
        "<context>\nThe user's terminal is now session \(id): use it with read_terminal and send_to_terminal.\n</context>\n\n\(text)"
    }

    /// The request preceded by what the screen shows (like the desktop).
    static func withContext(_ text: String, screen: String, name: String) -> String {
        let lines = screen.components(separatedBy: "\n").map { line -> String in
            var l = line
            while let u = l.last, u.isWhitespace { l.removeLast() }
            return l
        }
        let cleaned = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return text }
        let last = String(cleaned.suffix(4000))
        return "<context>\nThe last lines shown by the user's terminal (\(name)):\n```\n\(last)\n```\n</context>\n\n\(text)"
    }

    static func taskStatus(_ s: String) -> AiTaskStatus {
        switch s {
        case "queued": return .queued
        case "running": return .running
        case "waiting_approval": return .waitingApproval
        case "completed": return .completed
        case "failed": return .failed
        case "cancelled": return .cancelled
        default: return .unknown
        }
    }

    private func string(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    private func json(_ v: Any?) -> String {
        guard let v, JSONSerialization.isValidJSONObject(v),
              let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else {
            return (v as? String) ?? ""
        }
        return String(decoding: d, as: UTF8.self)
    }
}

extension AiPermissionMode {
    /// In the order of the pickers.
    static let all: [AiPermissionMode] = [.ask, .confirm, .auto, .readOnly]

    var title: String {
        switch self {
        case .ask: return String(localized: "ai.mode.ask")
        case .confirm: return String(localized: "ai.mode.confirm")
        case .auto: return String(localized: "ai.mode.auto")
        case .readOnly: return String(localized: "ai.mode.read_only")
        }
    }

    var icon: String {
        switch self {
        case .ask: return "hand.raised"
        case .confirm: return "hand.raised.fill"
        case .auto: return "bolt"
        case .readOnly: return "eye"
        }
    }

    var explanation: String {
        switch self {
        case .ask: return String(localized: "ai.mode.ask.explanation")
        case .confirm: return String(localized: "ai.mode.confirm.explanation")
        case .auto: return String(localized: "ai.mode.auto.explanation")
        case .readOnly: return String(localized: "ai.mode.read_only.explanation")
        }
    }
}
