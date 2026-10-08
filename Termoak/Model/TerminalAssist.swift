import TermoakKit
import Combine
import Foundation

/// A command the AI proposes in a terminal, to be typed (never run).
struct AiProposal: Identifiable, Equatable {
    enum Origin: Equatable {
        /// "Fix" on the chip of a failed command.
        case fix
        /// A `# request` typed at the prompt (that line is replaced).
        case request(line: String)
    }

    enum State: Equatable {
        case asking
        /// Waiting for "Type it" (a dangerous one asks first).
        case ready(AiCommandSuggestion)
        /// Already typed in place of the `# request` line.
        case typed(AiCommandSuggestion)
        case failed(String)
    }

    let id = UUID()
    let origin: Origin
    var state: State
}

/// The AI's explanation of a failed command, in a sheet.
struct AiExplanationItem: Identifiable, Equatable {
    let id = UUID()
    let title: String
    var answer: String?
    var provider: String?
    var error: String?
}

/// The AI in a terminal, like the desktop's: the engine's `CommandWatcher`
/// follows the commands (OSC 133/633 or the prompt coming back), a failed
/// one shows "Command failed · Explain · Fix", and a `# request` line turns
/// into a command (⌘↩ or the key bar's AI key). Whatever is sent goes
/// through `redactSecrets` on the device; a proposed command is only typed,
/// never run.
@MainActor
final class TerminalAssist: ObservableObject {
    /// The command of the chip (`nil`: no chip).
    @Published private(set) var failed: LastCommandInfo?
    @Published var proposal: AiProposal?
    @Published var explanation: AiExplanationItem?

    /// Its terminal (set by `TerminalSession`).
    weak var session: TerminalSession?
    private let watcher = CommandWatcher(screen: nil)
    private var idleTask: Task<Void, Never>?
    private var chipTask: Task<Void, Never>?
    /// Answers of an older question are dropped.
    private var generation = 0

    nonisolated init() {}

    // ----- Commands -----

    /// A piece of output, after the terminal showed it.
    func output(_ data: Data, alternateScreen: Bool) {
        let ev = watcher.output(data: data, alternateScreen: alternateScreen)
        if ev.started { failed = nil }
        if let ended = ev.ended { commandEnded(ended) }
    }

    /// Enter at the shell's line: `command` is the typed line (if it is
    /// known), `prompt` what is in front of it.
    func enter(command: String?, prompt: String?) {
        failed = nil
        if case .typed = proposal?.state { proposal = nil }
        guard watcher.enter(command: command, prompt: prompt) else { return }
        // Without shell integration, it ends when the prompt is back.
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled, self.watcher.waitingForPrompt(), let s = self.session else { return }
                let probe = s.cursorLineProbe()
                if let ended = self.watcher.idle(alternateScreen: probe.alternate, beforeCursor: probe.before,
                                                 afterBlank: probe.afterBlank) {
                    self.commandEnded(ended)
                    return
                }
            }
        }
    }

    /// A new connection: nothing of the old one counts.
    func reset() {
        watcher.reset()
        idleTask?.cancel()
        failed = nil
        proposal = nil
    }

    private func commandEnded(_ e: CommandEnded) {
        guard let s = session, let last = e.last else { return }
        s.lastCommand = last
        guard TerminalAiRules.showsFixChip(failed: last.failure != nil, enabled: s.settings.aiFixChip,
                                           aiAvailable: s.aiAccountId != nil, canWrite: s.canWrite) else { return }
        failed = last
        chipTask?.cancel()
        chipTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(TerminalAiRules.chipSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.failed == last else { return }
            self.failed = nil
        }
    }

    func dismissChip() {
        failed = nil
    }

    // ----- Asking the AI -----

    private var api: AccountApi? {
        guard let s = session, let id = s.aiAccountId else { return nil }
        return s.core.api(for: id)
    }

    /// What the AI gets about the terminal: the host's system and the end
    /// of the screen (the engine hides its secrets before sending it).
    private func context(screen: String? = nil) -> AiAssistContext {
        let text = screen ?? session.map { textTail(text: $0.screenText(), maxLines: 60, maxChars: 4000) }
        return AiAssistContext(os: session?.os, screen: text, cwd: nil)
    }

    private static func errorText(_ error: Error) -> String {
        AiAccessProblem(error)?.message ?? userMessage(error)
    }

    private func forAi(_ last: LastCommandInfo) -> String {
        redactSecrets(text: TerminalAiRules.forAi(command: last.command, output: last.output, exitCode: last.exitCode))
    }

    /// "Explain": why the command failed, in a sheet.
    func explainFailed() {
        guard let last = failed ?? session?.lastCommand else { return }
        failed = nil
        let short = shortenText(text: last.command ?? "", max: 48)
        let title = last.command == nil ? String(localized: "terminal.ai_ask.error_title")
                                        : String(localized: "terminal.ai_ask.failed_title \(short)")
        guard let api else {
            explanation = AiExplanationItem(title: title, error: String(localized: "terminal.ai.not_signed_in"))
            return
        }
        let question = last.exitCode.map { String(localized: "terminal.ai_ask.failed_exit \(Int($0))") }
            ?? String(localized: "terminal.ai_ask.failed")
        let item = AiExplanationItem(title: title)
        explanation = item
        let (text, ctx) = (forAi(last), context())
        Task { [weak self] in
            do {
                let r = try await api.aiExplain(text: text, question: question, context: ctx, provider: nil)
                guard let self, self.explanation?.id == item.id else { return }
                self.explanation?.answer = r.answer.isEmpty ? String(localized: "terminal.ai.no_answer") : r.answer
                self.explanation?.provider = r.provider
            } catch {
                guard let self, self.explanation?.id == item.id else { return }
                self.explanation?.error = Self.errorText(error)
            }
        }
    }

    /// "Fix": a corrected command, to type after reviewing it.
    func fixFailed() {
        guard let last = failed ?? session?.lastCommand else { return }
        failed = nil
        let request = String(localized: "terminal.ai_ask.fix \(redactSecrets(text: last.command ?? ""))")
        // What the command printed is the screen that matters.
        propose(request: request, context: context(screen: forAi(last)), origin: .fix)
    }

    /// ⌘↩ or the AI key: the `# request` being typed becomes a command.
    func askForLine() {
        guard let s = session, s.state == .connected, s.canWrite else { return }
        guard let line = s.typedLine(), let request = nlRequest(line: line) else {
            s.showFlash(String(localized: "terminal.ai.request_hint"))
            return
        }
        propose(request: redactSecrets(text: request), context: context(), origin: .request(line: line))
    }

    private func propose(request: String, context: AiAssistContext, origin: AiProposal.Origin) {
        generation += 1
        let n = generation
        guard let api else {
            proposal = AiProposal(origin: origin, state: .failed(String(localized: "terminal.ai.not_signed_in")))
            return
        }
        proposal = AiProposal(origin: origin, state: .asking)
        Task { [weak self] in
            let state: AiProposal.State
            do {
                let r = try await api.aiSuggest(request: request, context: context, provider: nil)
                state = typeableCommand(command: r.command).isEmpty
                    ? .failed(String(localized: "terminal.ai.no_command")) : .ready(r)
            } catch {
                state = .failed(Self.errorText(error))
            }
            guard let self, self.generation == n, self.proposal != nil else { return }
            self.ready(state, origin: origin)
        }
    }

    /// A `# request` still at the prompt is replaced at once, unless the
    /// command is dangerous (that one waits for "Type it" and a question).
    private func ready(_ state: AiProposal.State, origin: AiProposal.Origin) {
        guard case .ready(let s) = state, case .request(let line) = origin,
              !AiCommandRisk(s.risk).needsConfirmation, session?.typedLine() == line else {
            proposal?.state = state
            return
        }
        session?.typeAiCommand(s.command, replacing: line)
        proposal?.state = .typed(s)
    }

    /// "Type it": the command at the prompt, without Enter.
    func typeProposal() {
        guard let p = proposal, case .ready(let s) = p.state else { return }
        var line: String?
        if case .request(let l) = p.origin { line = l }
        session?.typeAiCommand(s.command, replacing: line)
        proposal = nil
    }

    func dismissProposal() {
        generation += 1
        proposal = nil
    }
}
