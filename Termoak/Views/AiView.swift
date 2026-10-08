import TermoakKit
import SwiftUI

/// A task's state with its colour.
func statusStyle(_ s: AiTaskStatus) -> (String, Color) {
    switch s {
    case .queued: return (String(localized: "ai.status.queued"), .secondary)
    case .running: return (String(localized: "ai.status.running"), Brand.blue)
    case .waitingApproval: return (String(localized: "ai.status.waiting_approval"), Brand.amber)
    case .completed: return (String(localized: "ai.status.completed"), Brand.green)
    case .failed: return (String(localized: "ai.status.failed"), Brand.red)
    case .cancelled: return (String(localized: "ai.status.cancelled"), .secondary)
    case .unknown: return ("—", .secondary)
    }
}

private extension AiTask {
    var isActive: Bool { status == .queued || status == .running || status == .waitingApproval }
}

/// AI tasks on the server and the approvals they wait for (pushed from the
/// Connections tab).
struct AiView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @State private var tasks: [AiTask] = []
    @State private var approvals: [AiApproval] = []
    @State private var creating = false
    @State private var loggingIn = false
    @State private var error: String?

    /// The account whose AI is on screen (the server runs its tasks).
    private var aiAccountId: String? { account.aiAccount?.id }
    private var api: AccountApi { model.core.api(for: aiAccountId) }

    var body: some View {
        Group {
            if account.aiAccount == nil {
                EmptyState(
                    icon: "sparkles",
                    title: String(localized: "ai.empty.title"),
                    text: String(localized: "ai.empty.text"),
                    action: String(localized: "common.log_in")
                ) { loggingIn = true }
            } else {
                list
            }
        }
        .navigationTitle("connections.ai_tasks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if account.aiAccount != nil {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("ai.new.title")
                }
            }
        }
        .sheet(isPresented: $creating) { NewTaskView(accountId: aiAccountId).environmentObject(model) }
        .sheet(isPresented: $loggingIn) {
            LoginView(welcome: false) {}.environmentObject(account).environmentObject(model.settings)
        }
        .alert("common.error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: { Text(error ?? "") }
        .task { await load() }
        .onReceive(account.changes) { kind in
            if kind == "ai" || kind == "lagged" { Task { await load() } }
        }
        .onChange(of: creating) { open in if !open { Task { await load() } } }
        .onChange(of: account.aiAccountId) { _ in
            tasks = []
            approvals = []
            Task { await load() }
        }
    }

    /// Several accounts signed in: which one's AI (its tasks, approvals and
    /// new tasks), like Android.
    private var accountPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(account.active, id: \.id) { a in
                    AiAccountChip(account: a, selected: a.id == aiAccountId) { account.aiAccountId = a.id }
                }
            }
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        .listRowBackground(Color.clear)
    }

    private var list: some View {
        List {
            if account.active.count > 1 {
                Section { accountPicker }
            }
            if !approvals.isEmpty {
                Section("ai.section.approvals") {
                    ForEach(approvals, id: \.id) { a in
                        ApprovalCard(approval: a, task: tasks.first { $0.id == a.taskId }?.title, preview: a.shownPreview) { choice in
                            decide(a, choice)
                        }
                    }
                }
            }
            Section {
                NavigationLink { AiMemoriesView(accountId: aiAccountId) } label: { Label("ai.memories", systemImage: "brain.head.profile") }
            }
            Section("ai.section.tasks") {
                if tasks.isEmpty {
                    Text("ai.tasks.empty")
                        .foregroundColor(.secondary)
                }
                ForEach(tasks, id: \.id) { t in
                    NavigationLink { TaskView(taskId: t.id, accountId: aiAccountId) } label: { TaskRow(task: t) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    private func load() async {
        guard account.aiAccount != nil else { return }
        let api = self.api
        do {
            tasks = try await api.listAiTasks(limit: 50)
            approvals = try await api.listPendingApprovals()
            await account.refreshApprovals()
        } catch {
            self.error = userMessage(error)
        }
    }

    private func decide(_ a: AiApproval, _ choice: ApprovalChoice) {
        Task {
            do {
                try await api.decide(taskId: a.taskId, approvalId: a.id, choice)
            } catch {
                self.error = userMessage(error)
            }
            await load()
        }
    }
}

private struct TaskRow: View {
    let task: AiTask

    var body: some View {
        let (text, color) = statusStyle(task.status)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.title.isEmpty ? task.prompt : task.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer()
                if task.isActive { ProgressView().scaleEffect(0.7) }
            }
            HStack(spacing: 8) {
                Chip(text, color)
                Text(verbatim: "\(relativeTime(task.updatedAt)) · \(task.usedProvider ?? task.provider)")
                    .font(.caption2).foregroundColor(.secondary)
            }
            if let detail = task.error ?? task.result, !detail.isEmpty {
                Text(detail).font(.caption).foregroundColor(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }
}

/// An action the AI wants to take that needs your permission: with server
/// 0.6, its risk and why, the exact command, the file's diff or the plan;
/// Approve, Edit and approve (editable commands and plans), Deny with an
/// optional reason, and approve the rest of the task.
struct ApprovalCard: View {
    let approval: AiApproval
    let task: String?
    /// In the copilot: a standalone card with an amber border and the buttons on two rows.
    var copilot = false
    /// What the server shows about it (`nil` before server 0.6).
    var preview: ApprovalPreview? = nil
    let decide: (ApprovalChoice) -> Void

    @State private var editing = false
    @State private var denying = false

    /// The command, if the tool runs one.
    private var command: String? {
        if let c = preview?.command, !c.isEmpty { return c }
        guard let d = approval.inputJson.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let c = o["command"] as? String, !c.isEmpty else { return nil }
        return c
    }

    private var isPlan: Bool { preview?.kind == "plan" || approval.tool == "plan" }

    var body: some View {
        card
            .sheet(isPresented: $editing) {
                ApprovalTextSheet(title: isPlan ? String(localized: "ai.approval.edit_plan") : String(localized: "ai.approval.edit"),
                                  hint: isPlan ? String(localized: "ai.approval.edit_plan_hint") : String(localized: "ai.approval.edit_hint"),
                                  initial: preview?.editableText ?? command ?? "",
                                  action: String(localized: "ai.approval.approve_edited"), required: true) { text in
                    decide(ApprovalChoice(approve: true, edited: text))
                }
            }
            .sheet(isPresented: $denying) {
                ApprovalTextSheet(title: String(localized: "ai.approval.deny_title"), hint: String(localized: "ai.approval.deny_hint"),
                                  initial: "", placeholder: String(localized: "ai.approval.reason_placeholder"),
                                  action: String(localized: "common.deny"), required: false, destructive: true) { text in
                    decide(ApprovalChoice(approve: false, reason: text))
                }
            }
    }

    @ViewBuilder private var card: some View {
        if copilot {
            content
                .padding(12)
                .background(Brand.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.amber.opacity(0.8), lineWidth: 1))
        } else {
            content.padding(.vertical, 6)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let e = preview?.explanation, !e.isEmpty {
                Text(e).font(.footnote).foregroundColor(.secondary)
            }
            details
            if let reasons = preview?.reasons, !reasons.isEmpty { reasonList(reasons) }
            actions
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(task ?? approval.tool, systemImage: isPlan ? "list.number" : "wrench.and.screwdriver")
                .font(.subheadline.weight(.semibold)).foregroundColor(Brand.amber).lineLimit(1)
            Spacer(minLength: 4)
            if let risk = preview?.risk { riskChip(risk) }
        }
    }

    @ViewBuilder private var details: some View {
        if isPlan, let plan = preview?.plan ?? nonEmpty(approval.summary) {
            Text("ai.approval.plan_title").font(.caption.weight(.semibold)).foregroundColor(.secondary)
            block(plan)
        } else if preview?.kind == "file", let p = preview {
            fileDetails(p)
        } else if let command {
            if !approval.summary.isEmpty && approval.summary != command {
                Text(approval.summary).font(.footnote)
            }
            if let host = preview?.host, !host.isEmpty {
                Label(host, systemImage: "server.rack").font(.caption).foregroundColor(.secondary)
            }
            block(command)
        } else {
            block(approval.summary.isEmpty ? approval.inputJson : approval.summary)
        }
    }

    @ViewBuilder private func fileDetails(_ p: ApprovalPreview) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundColor(.secondary)
            Text(verbatim: p.path ?? approval.summary).font(.system(.footnote, design: .monospaced)).lineLimit(2)
            if p.newFile { Chip(String(localized: "ai.approval.new_file"), Brand.green) }
            Spacer(minLength: 0)
            if let a = p.added { Text(verbatim: "+\(a)").font(.caption.monospacedDigit()).foregroundColor(Brand.green) }
            if let r = p.removed { Text(verbatim: "−\(r)").font(.caption.monospacedDigit()).foregroundColor(Brand.red) }
        }
        if let diff = p.diff, !diff.isEmpty {
            DiffView(diff: diff)
            if p.diffTruncated {
                Text("ai.approval.diff_truncated").font(.caption).foregroundColor(.secondary)
            }
        } else if let e = p.diffError {
            Text("ai.approval.no_diff \(e)").font(.caption).foregroundColor(.secondary)
        } else if p.added == 0 && p.removed == 0 {
            Text("ai.approval.no_changes").font(.caption).foregroundColor(.secondary)
        }
    }

    private func reasonList(_ reasons: [ApprovalPreview.Reason]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(reasons.enumerated()), id: \.offset) { _, r in
                Label(reasonText(r), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if copilot {
            VStack(alignment: .leading, spacing: 8) {
                HStack { approveButton; denyButton }
                secondaryButtons.font(.footnote).buttonStyle(.borderless)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack { approveButton; denyButton; Spacer() }
                HStack(spacing: 16) { secondaryButtons }.font(.footnote)
            }
            .buttonStyle(.borderless)
        }
    }

    private var approveButton: some View {
        Button { decide(ApprovalChoice(approve: true)) } label: {
            Label(isPlan ? String(localized: "ai.approval.approve_plan") : String(localized: "common.approve"), systemImage: "checkmark")
        }
        .buttonStyle(.borderedProminent)
    }

    private var denyButton: some View {
        Button { denying = true } label: { Label("ai.approval.deny_with_reason", systemImage: "xmark") }
            .buttonStyle(.bordered)
    }

    @ViewBuilder private var secondaryButtons: some View {
        if preview?.editable == true {
            Button(isPlan ? String(localized: "ai.approval.edit_plan") : String(localized: "ai.approval.edit")) { editing = true }
        }
        if !isPlan {
            Button(copilot ? "ai.approve_always" : "ai.always") { decide(ApprovalChoice(approve: true, always: true)) }
        }
    }

    private func riskChip(_ risk: String) -> some View {
        let (text, color): (String, Color)
        switch risk {
        case "high": (text, color) = (String(localized: "ai.risk.high"), Brand.red)
        case "medium": (text, color) = (String(localized: "ai.risk.medium"), Brand.amber)
        default: (text, color) = (String(localized: "ai.risk.low"), Brand.green)
        }
        return Chip(text, color)
    }

    private func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

    private func block(_ text: String) -> some View {
        Text(text)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The classifier's reason in the app's language (the server's English text
/// for an unknown one).
func reasonText(_ r: ApprovalPreview.Reason) -> String {
    switch r.code {
    case "pipe": return String(localized: "ai.reason.pipe")
    case "chain": return String(localized: "ai.reason.chain")
    case "redirect": return String(localized: "ai.reason.redirect")
    case "substitution": return String(localized: "ai.reason.substitution")
    case "sudo": return String(localized: "ai.reason.sudo")
    case "rm_rf": return String(localized: "ai.reason.rm_rf")
    case "delete": return String(localized: "ai.reason.delete")
    case "disk": return String(localized: "ai.reason.disk")
    case "reboot": return String(localized: "ai.reason.reboot")
    case "service": return String(localized: "ai.reason.service")
    case "packages": return String(localized: "ai.reason.packages")
    case "firewall": return String(localized: "ai.reason.firewall")
    case "permissions": return String(localized: "ai.reason.permissions")
    case "kill": return String(localized: "ai.reason.kill")
    case "users": return String(localized: "ai.reason.users")
    case "remote_script": return String(localized: "ai.reason.remote_script")
    case "containers": return String(localized: "ai.reason.containers")
    case "cron": return String(localized: "ai.reason.cron")
    case "git_history": return String(localized: "ai.reason.git_history")
    case "redacted": return String(localized: "ai.reason.redacted")
    case "changes": return String(localized: "ai.reason.changes")
    case "critical_file": return String(localized: "ai.reason.critical_file")
    case "system_path":
        if let path = ApprovalPreview.reasonPath(r.text) { return String(localized: "ai.reason.system_path \(path)") }
        return r.text
    default: return r.text
    }
}

/// A unified diff with the added lines in green, the removed ones in red and
/// the hunk headers in blue; it scrolls sideways and stops growing at 14 lines.
private struct DiffView: View {
    let diff: String

    private var lines: [Substring] { diff.split(separator: "\n", omittingEmptySubsequences: false) }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
            .padding(8)
        }
        .frame(maxHeight: min(CGFloat(lines.count) * 16 + 16, 240))
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ line: Substring) -> some View {
        let kind = DiffLineKind(line)
        let color: Color
        switch kind {
        case .added: color = Brand.green
        case .removed: color = Brand.red
        case .hunk: color = Brand.blue
        case .header: color = .secondary
        case .context: color = .primary
        }
        return Text(verbatim: line.isEmpty ? " " : String(line))
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(color)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(kind == .added ? Brand.green.opacity(0.08) : kind == .removed ? Brand.red.opacity(0.08) : Color.clear)
    }
}

/// Edit the command or plan before approving it, or say why it's denied.
private struct ApprovalTextSheet: View {
    let title: String
    let hint: String
    let initial: String
    var placeholder = ""
    let action: String
    /// The text can't be empty (an edit).
    let required: Bool
    var destructive = false
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty && !placeholder.isEmpty {
                            Text(placeholder).foregroundColor(.secondary).padding(.top, 8).padding(.leading, 5)
                        }
                        TextEditor(text: $text)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 120)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    if required && empty { Text("ai.approval.edit_empty").foregroundColor(Brand.red) } else { Text(hint) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action) {
                        done(text)
                        dismiss()
                    }
                    .disabled(required && empty)
                }
            }
        }
        .onAppear { text = initial }
    }
}

struct TaskView: View {
    let taskId: String
    /// The task's account (`nil`: the current one).
    var accountId: String? = nil
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @State private var task: AiTask?
    @State private var message = ""
    @State private var error: String?
    /// Sending failed for a reason fixed in Settings → AI.
    @State private var problem: AiAccessProblem?
    @State private var showingAiSettings = false
    @State private var savingRunbook = false
    @State private var runbookSaved = false
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool

    private var api: AccountApi { model.core.api(for: accountId) }

    var body: some View {
        Group {
            if let t = task {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            taskHeader
                            let conversation = turns(t)
                            if conversation.isEmpty { TurnView(turn: .user(0, stripContext(t.prompt))) }
                            ForEach(conversation) { TurnView(turn: $0, running: t.isActive) }
                            ForEach(t.pendingApprovals, id: \.id) { a in
                                ApprovalCard(approval: a, task: nil, preview: a.shownPreview) { choice in
                                    Task {
                                        do {
                                            try await api.decide(taskId: a.taskId, approvalId: a.id, choice)
                                        } catch {
                                            self.error = userMessage(error)
                                        }
                                        await account.refreshApprovals()
                                        await load()
                                    }
                                }
                                .padding(.horizontal)
                            }
                            if t.isActive {
                                HStack { ProgressView(); Text(statusStyle(t.status).0 + "…").foregroundColor(.secondary) }.padding()
                            }
                            if let e = t.error { Text(e).foregroundColor(Brand.red).padding() }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(.vertical, 8)
                    }
                    .dismissesKeyboardOnScroll(active: typing) { typing = false }
                    // The reply box stays under the conversation, above the
                    // keyboard when it is open (the conversation shrinks).
                    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                    .onAppear { scrollToEnd(reader, animated: false) }
                    .onChange(of: t.rawJson) { _ in scrollToEnd(reader) }
                    // The keyboard takes the bottom: the last message stays in view.
                    .onChange(of: typing) { if $0 { scrollToEnd(reader) } }
                    .onKeyboardShown { if typing { scrollToEnd(reader) } }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(task.map { $0.title.isEmpty ? String(localized: "ai.task.title") : $0.title } ?? String(localized: "ai.task.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if task?.isActive == true {
                    Button("common.cancel") { Task { try? await api.cancelAiTask(taskId: taskId); await load() } }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if let t = task {
                    TaskActionsMenu(active: t.isActive, mode: t.mode,
                                    ranSteps: !t.steps.isEmpty || t.fanOut,
                                    onMode: setMode, onRunbook: { savingRunbook = true }, onDelete: { deleting = true })
                }
            }
        }
        .sheet(isPresented: $savingRunbook) {
            RunbookSheet(taskId: taskId, api: api) {
                runbookSaved = true
                account.sync()
            }
        }
        .confirmationDialog("ai.delete.title", isPresented: $deleting, titleVisibility: .visible) {
            Button("ai.delete_task", role: .destructive, action: delete)
        } message: { Text("ai.delete.message") }
        .alert("ai.runbook.saved", isPresented: $runbookSaved) {
            Button("common.ok", role: .cancel) {}
        } message: { Text("ai.runbook.saved.message") }
        .task {
            // While it works it refreshes by itself (and with the server events).
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: task?.isActive == true ? 3_000_000_000 : 15_000_000_000)
            }
        }
        .onReceive(account.changes) { kind in if kind == "ai" { Task { await load() } } }
        .sheet(isPresented: $showingAiSettings) { AiSettingsSheet().environmentObject(model) }
        .alert("common.error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    /// The reply box (with the error that is fixed in Settings → AI).
    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            if let problem {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundColor(Brand.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(problem.message).foregroundColor(Brand.red)
                        OpenAiSettingsButton { showingAiSettings = true }
                            .font(.footnote.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button { self.problem = nil } label: { Image(systemName: "xmark").font(.caption) }
                        .foregroundColor(.secondary)
                }
                .font(.footnote)
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            HStack(spacing: 8) {
                TextField("common.reply_placeholder", text: $message)
                    .textFieldStyle(.roundedBorder)
                    .focused($typing)
                    .submitLabel(.send)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "paperplane.fill") }
                    .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("copilot.send")
            }
            .padding(8)
        }
        .background(.bar)
    }

    /// The approved plan and, for one conversation per host, the hosts' table.
    @ViewBuilder private var taskHeader: some View {
        if let plan = task?.plan, plan.approved, !plan.text.isEmpty {
            ApprovedPlan(plan: plan.text, edited: plan.edited).padding(.horizontal)
        }
        if let runs = task?.hosts, !runs.isEmpty {
            HostRunsTable(runs: runs, accountId: accountId).padding(.horizontal)
        }
    }

    private func setMode(_ mode: AiPermissionMode) {
        Task {
            do {
                try await api.setAiTaskMode(taskId: taskId, mode: mode)
            } catch {
                self.error = userMessage(error)
            }
            await load()
        }
    }

    private func delete() {
        Task {
            do {
                try await api.deleteAiTask(taskId: taskId)
                await account.refreshApprovals()
                dismiss()
            } catch {
                self.error = userMessage(error)
            }
        }
    }

    private func load() async {
        do {
            task = try await api.getAiTask(taskId: taskId)
        } catch {
            self.error = userMessage(error)
        }
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        message = ""
        problem = nil
        Task {
            do {
                task = try await api.sendAiMessage(taskId: taskId, text: text)
            } catch {
                // Not lost: back in the field to send it again.
                if message.isEmpty { message = text }
                if let p = AiAccessProblem(error) {
                    problem = p
                } else {
                    self.error = userMessage(error)
                }
            }
        }
    }
}

/// An account to choose in the AI section: its avatar and email.
private struct AiAccountChip: View {
    let account: AccountInfo
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                AccountAvatar(account: account, size: 18)
                Text(verbatim: account.email).font(.subheadline).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundColor(selected ? .accentColor : .primary)
            .background(selected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground), in: Capsule())
            .overlay(Capsule().stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
