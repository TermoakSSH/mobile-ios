import TermoakKit
import SwiftUI

/// Copilot: chat with the server's AI tied to the terminal in front of you.
/// You see live what it does (text, tools with their output and approvals).
/// On a phone it slides in from the right; on a tablet it sits next to the
/// terminal.
struct CopilotPanel: View {
    @ObservedObject var copilot: Copilot
    @ObservedObject var session: TerminalSession
    let onClose: () -> Void

    @EnvironmentObject private var account: Accounts
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppModel
    @State private var loggingIn = false
    @State private var showingAiSettings = false
    @FocusState private var typing: Bool

    static var suggestions: [String] {
        [
            String(localized: "copilot.suggestion.error"),
            String(localized: "copilot.suggestion.disk"),
            String(localized: "copilot.suggestion.slow"),
        ]
    }

    private var theme: TerminalTheme { settings.terminalTheme }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if account.loggedIn != true {
                EmptyState(
                    icon: "sparkles",
                    title: String(localized: "copilot.logged_out.title"),
                    text: String(localized: "copilot.logged_out.text"),
                    action: String(localized: "common.log_in")
                ) { loggingIn = true }
            } else {
                // The box to write in stays under the conversation, above the
                // keyboard when it is open (the conversation shrinks).
                conversation
                    .safeAreaInset(edge: .bottom, spacing: 0) { bottom }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.barColor.ignoresSafeArea())
        .sheet(isPresented: $loggingIn) {
            LoginView(welcome: false) {}.environmentObject(account).environmentObject(settings)
        }
        .sheet(isPresented: $showingAiSettings) { AiSettingsSheet().environmentObject(model) }
        .onAppear {
            copilot.resume()
            updateContext()
        }
        .onChange(of: session.lastCommand) { _ in updateContext() }
        .onReceive(account.aiEvents) { copilot.receive($0) }
        .onReceive(account.changes) { kind in
            // Events were lost: what is saved wins.
            if kind == "lagged" { Task { await copilot.reload() } }
        }
        .task(id: copilot.task?.id) {
            // Without live events, ask every now and then.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if copilot.running && !account.live { await copilot.reload() }
            }
        }
    }

    // ----- Header -----

    private var header: some View {
        let c = context
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundColor(Brand.blue)
                Text("copilot.title").font(.headline)
                Spacer(minLength: 0)
                if account.loggedIn == true { modePicker }
                Button { copilot.newConversation() } label: {
                    Image(systemName: "square.and.pencil").frame(width: 34, height: 34)
                }
                .disabled(copilot.isEmpty)
                .accessibilityLabel("copilot.new_conversation")
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 34, height: 34)
                }
                .accessibilityLabel("copilot.close")
            }
            HStack(spacing: 5) {
                Image(systemName: c.icon)
                Text(c.text).lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundColor(.accentColor)
            if let notice = c.notice {
                Text(notice).font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.top, 8).padding(.bottom, 8)
    }

    /// Permissions mid-conversation (without a task: the ones it will be created with).
    private var modePicker: some View {
        let current = copilot.currentMode
        return Menu {
            Picker("common.permissions", selection: Binding(get: { copilot.currentMode },
                                                           set: { copilot.changeMode($0) })) {
                ForEach(AiPermissionMode.all, id: \.self) { m in
                    Label(m.title, systemImage: m.icon).tag(m)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: current.icon)
                Text(current.title).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .foregroundColor(current == .auto ? Brand.amber : .primary)
        }
        .accessibilityLabel(Text("copilot.permissions_label \(current.title)"))
    }

    /// Which terminal the AI sees and whether it can type in it.
    private var context: (icon: String, text: String, notice: String?) {
        let host = session.hostId.flatMap { try? model.core.getHost(id: $0, accountId: session.accountId) }
        let name = host.map { $0.label.isEmpty ? $0.address : $0.label } ?? session.label
        let onServer = session is ServerTerminal
        let shared = (session as? LocalTerminal)?.shared != nil
        let icon = onServer ? "icloud" : "server.rack"
        if copilot.access == .screen {
            return (icon, name, String(localized: "copilot.context.no_access"))
        }
        if onServer || shared || copilot.access == .terminal {
            return (icon, name, String(localized: "copilot.context.writes"))
        }
        if session is LocalTerminal {
            return (icon, name, String(localized: "copilot.context.will_share"))
        }
        return ("terminal", String(localized: "copilot.context.this_terminal"),
                String(localized: "copilot.context.screen_only"))
    }

    // ----- Conversation -----

    private var working: Bool {
        if copilot.sending { return true }
        guard copilot.running, copilot.status != .waitingApproval else { return false }
        return copilot.live.last?.kind != .text
    }

    private var conversation: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if copilot.isEmpty {
                        emptyContent
                    } else {
                        ForEach(copilot.conversation) { t in
                            TurnView(turn: complete(t), running: copilot.running)
                        }
                        ForEach(Array(copilot.pending.enumerated()), id: \.offset) { _, text in
                            TurnView(turn: .user(0, text))
                        }
                        ForEach(copilot.live) { e in item(e) }
                        ForEach(copilot.approvals, id: \.id) { a in
                            ApprovalCard(approval: a, task: String(localized: "copilot.approval_title"), copilot: true,
                                         preview: copilot.preview(for: a.id)) { choice in
                                copilot.decide(a, choice)
                            }
                            .padding(.horizontal)
                        }
                        if working {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("common.working").font(.subheadline).foregroundColor(.secondary)
                            }
                            .padding(.horizontal)
                        }
                        if !copilot.running, let e = copilot.task?.error, !e.isEmpty {
                            Text(e).font(.footnote).foregroundColor(Brand.red).padding(.horizontal)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.vertical, 10)
            }
            .dismissesKeyboardOnScroll(active: typing) { typing = false }
            .onChange(of: copilot.changes) { _ in reader.scrollTo("end", anchor: .bottom) }
            .onAppear { reader.scrollTo("end", anchor: .bottom) }
            // The keyboard takes the bottom: the last message stays in view.
            .onChange(of: typing) { if $0 { scrollToEnd(reader) } }
            .onKeyboardShown { if typing { scrollToEnd(reader) } }
        }
    }

    /// A saved tool whose result has only arrived live.
    private func complete(_ t: Turn) -> Turn {
        if case let .tool(n, callId, name, input, output, _) = t, output == nil,
           let r = copilot.result(for: callId) {
            return .tool(n, callId: callId, name: name, input: input, output: r.output, error: r.error)
        }
        return t
    }

    @ViewBuilder private func item(_ e: LiveItem) -> some View {
        switch e.kind {
        case .text:
            TurnView(turn: .assistant(e.id, e.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        case .reasoning:
            TurnView(turn: .reasoning(e.id, e.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        case .tool:
            TurnView(turn: .tool(e.id, callId: e.callId, name: e.name, input: e.text,
                                 output: e.output, error: e.error),
                     running: true)
        case .notice:
            Label(e.text, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundColor(Brand.amber)
                .padding(.horizontal)
        }
    }

    /// No conversation yet: suggestions and permissions.
    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("copilot.empty.title").font(.headline)
                Text("copilot.empty.text")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)
            ForEach(CopilotPanel.suggestions, id: \.self) { s in
                Button {
                    copilot.draft = s
                    typing = true
                } label: {
                    Text(s)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "common.permissions").uppercased()).font(.caption2.weight(.semibold)).foregroundColor(.secondary)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(AiPermissionMode.all, id: \.self) { m in
                        let chosen = copilot.mode == m
                        Button { copilot.mode = m } label: {
                            Label(m.title, systemImage: m.icon)
                                .font(.footnote.weight(chosen ? .semibold : .regular))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .padding(.horizontal, 8).padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(chosen ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .foregroundColor(chosen ? .accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
                Text(copilot.mode.explanation).font(.caption2).foregroundColor(.secondary)
            }
            .padding(.top, 10)
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }

    // ----- Footer -----

    /// The error (if any) and the box to write in.
    private var bottom: some View {
        VStack(spacing: 0) {
            if let e = copilot.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(e)
                        if copilot.accessProblem != nil {
                            OpenAiSettingsButton { showingAiSettings = true }
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.accentColor)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button { copilot.error = nil } label: { Image(systemName: "xmark").font(.caption) }
                }
                .font(.caption)
                .foregroundColor(Brand.red)
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            Divider()
            footer
        }
        .background(theme.barColor)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if copilot.running {
                Button { copilot.stop(session as? LocalTerminal) } label: {
                    Label("copilot.stop", systemImage: "stop.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Brand.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundColor(Brand.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("copilot.stop_ai")
            }
            chipsRow
            field
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    /// What goes with the next message, each one removable.
    @ViewBuilder private var chipsRow: some View {
        if !copilot.chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(copilot.chips, id: \.self) { chip in
                        ContextChipView(chip: chip) { copilot.remove(chip) }
                    }
                }
            }
        }
        if copilot.secretsHidden {
            Label("copilot.secrets_hidden", systemImage: "eye.slash")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The host and the last command of the terminal, for the chips.
    private func updateContext() {
        let host = session.hostId.flatMap { try? model.core.getHost(id: $0, accountId: session.accountId) }
        let name = host.map { $0.label.isEmpty ? $0.address : $0.label } ?? session.label
        let chip = session.hostId == nil ? nil : contextChipHost(name: name, os: host?.os)
        copilot.updateContext(host: chip, last: session.lastCommand)
    }

    private var field: some View {
        HStack(spacing: 8) {
            TextField(copilot.task == nil ? String(localized: "copilot.ask_placeholder") : String(localized: "common.reply_placeholder"),
                      text: $copilot.draft)
                .textFieldStyle(.roundedBorder)
                .focused($typing)
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "paperplane.fill").frame(width: 34, height: 34)
            }
            .disabled(copilot.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || copilot.sending)
            .accessibilityLabel("copilot.send")
        }
    }

    private func send() {
        copilot.send(from: session)
    }
}

/// A context chip of the copilot: what it is (host, folder, last command,
/// selection) and an (x) to leave it out.
private struct ContextChipView: View {
    let chip: ContextChip
    let onRemove: () -> Void

    private var icon: String {
        switch chip.kind {
        case .host: return "server.rack"
        case .directory: return "folder"
        case .lastCommand: return "terminal"
        case .selection: return "text.cursor"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(verbatim: chip.label).font(.caption).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.caption2.weight(.semibold)).frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("copilot.chip.remove \(chip.label)"))
        }
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 3)
        .background(Color(.tertiarySystemFill), in: Capsule())
    }
}
