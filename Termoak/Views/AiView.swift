import TermoakKit
import SwiftUI

private func statusStyle(_ s: AiTaskStatus) -> (String, Color) {
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

struct AiView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Account
    @State private var tasks: [AiTask] = []
    @State private var approvals: [AiApproval] = []
    @State private var creating = false
    @State private var loggingIn = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Group {
                if account.loggedIn != true {
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
            .navigationTitle("nav.ai")
            .toolbar { MenuButton() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if account.loggedIn == true {
                        Button { creating = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("ai.new.title")
                    }
                }
            }
            .sheet(isPresented: $creating) { NewTaskView().environmentObject(model) }
            .sheet(isPresented: $loggingIn) {
                LoginView(welcome: false) {}.environmentObject(account).environmentObject(model.settings)
            }
            .alert("common.error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("common.ok", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .navigationViewStyle(.stack)
        .task { await load() }
        .onReceive(account.changes) { kind in
            if kind == "ai" || kind == "lagged" { Task { await load() } }
        }
        .onChange(of: creating) { open in if !open { Task { await load() } } }
    }

    private var list: some View {
        List {
            if !approvals.isEmpty {
                Section("ai.section.approvals") {
                    ForEach(approvals, id: \.id) { a in
                        ApprovalCard(approval: a, task: tasks.first { $0.id == a.taskId }?.title) { approve, always in
                            decide(a, approve: approve, always: always)
                        }
                    }
                }
            }
            Section("ai.section.tasks") {
                if tasks.isEmpty {
                    Text("ai.tasks.empty")
                        .foregroundColor(.secondary)
                }
                ForEach(tasks, id: \.id) { t in
                    NavigationLink { TaskView(taskId: t.id) } label: { TaskRow(task: t) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    private func load() async {
        guard account.loggedIn == true else { return }
        do {
            tasks = try await model.core.listAiTasks(limit: 50)
            approvals = try await model.core.listPendingApprovals()
            await account.refreshApprovals()
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func decide(_ a: AiApproval, approve: Bool, always: Bool) {
        Task {
            do {
                try await model.core.decideApproval(taskId: a.taskId, approvalId: a.id, approve: approve, always: always)
            } catch {
                self.error = errorMessage(error)
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

/// An action the AI wants to take that needs your permission.
struct ApprovalCard: View {
    let approval: AiApproval
    let task: String?
    /// In the copilot: a standalone card with an amber border and the buttons on two rows.
    var copilot = false
    let decide: (Bool, Bool) -> Void

    /// The command, if the tool runs one.
    private var command: String? {
        guard let d = approval.inputJson.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let c = o["command"] as? String, !c.isEmpty else { return nil }
        return c
    }

    var body: some View {
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
            Label(task ?? approval.tool, systemImage: "wrench.and.screwdriver")
                .font(.subheadline.weight(.semibold)).foregroundColor(Brand.amber).lineLimit(1)
            if let command {
                if !approval.summary.isEmpty && approval.summary != command {
                    Text(approval.summary).font(.footnote)
                }
                block(command)
            } else {
                block(approval.summary.isEmpty ? approval.inputJson : approval.summary)
            }
            if copilot {
                HStack {
                    Button { decide(true, false) } label: { Label("common.approve", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent)
                    Button { decide(false, false) } label: { Label("common.deny", systemImage: "xmark") }
                        .buttonStyle(.bordered)
                }
                Button("ai.approve_always") { decide(true, true) }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            } else {
                HStack {
                    Button { decide(true, false) } label: { Label("common.approve", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent)
                    Button { decide(false, false) } label: { Label("common.deny", systemImage: "xmark") }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("ai.always") { decide(true, true) }.font(.footnote)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func block(_ text: String) -> some View {
        Text(text)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct NewTaskView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var selected: Set<String> = []
    @State private var mode: AiPermissionMode = .ask
    @State private var busy = false
    @State private var error: String?
    /// The error is fixed in Settings → AI.
    @State private var problem: AiAccessProblem?
    @State private var showingAiSettings = false
    @State private var hosts: [SshHost] = []

    var body: some View {
        NavigationView {
            Form {
                Section("ai.new.prompt") {
                    TextEditor(text: $prompt).frame(minHeight: 110)
                }
                Section {
                    Picker("common.permissions", selection: $mode) {
                        ForEach(AiPermissionMode.all, id: \.self) { m in
                            Text(m.title).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text(mode.explanation)
                }
                Section("nav.hosts") {
                    if hosts.isEmpty { Text("ai.new.no_hosts").foregroundColor(.secondary) }
                    ForEach(hosts, id: \.id) { h in
                        Button {
                            if selected.contains(h.id) { selected.remove(h.id) } else { selected.insert(h.id) }
                        } label: {
                            HStack {
                                Text(h.label).foregroundColor(.primary)
                                Spacer()
                                if selected.contains(h.id) { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                            }
                        }
                    }
                }
                if let error {
                    Section {
                        Text(error).foregroundColor(Brand.red)
                        if problem != nil { OpenAiSettingsButton { showingAiSettings = true } }
                    }
                }
            }
            .navigationTitle("ai.new.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? String(localized: "ai.new.creating") : String(localized: "ai.new.start"), action: create)
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }
            }
        }
        .sheet(isPresented: $showingAiSettings) { AiSettingsSheet().environmentObject(model) }
        .onAppear {
            hosts = ((try? model.core.listHosts()) ?? [])
                .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        }
    }

    private func create() {
        busy = true
        error = nil
        problem = nil
        Task {
            defer { busy = false }
            do {
                _ = try await model.core.createAiTask(request: AiTaskRequest(
                    prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    mode: mode, hostIds: Array(selected)))
                dismiss()
            } catch {
                problem = AiAccessProblem(error)
                self.error = problem?.message ?? errorMessage(error)
            }
        }
    }
}

struct TaskView: View {
    let taskId: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Account
    @State private var task: AiTask?
    @State private var message = ""
    @State private var error: String?
    /// Sending failed for a reason fixed in Settings → AI.
    @State private var problem: AiAccessProblem?
    @State private var showingAiSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if let t = task {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            let conversation = turns(t)
                            if conversation.isEmpty { TurnView(turn: .user(0, stripContext(t.prompt))) }
                            ForEach(conversation) { TurnView(turn: $0, running: t.isActive) }
                            ForEach(t.pendingApprovals, id: \.id) { a in
                                ApprovalCard(approval: a, task: nil) { approve, always in
                                    Task {
                                        try? await model.core.decideApproval(taskId: a.taskId, approvalId: a.id, approve: approve, always: always)
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
                    .onChange(of: t.rawJson) { _ in withAnimation { reader.scrollTo("end") } }
                }
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
                    Button(action: send) { Image(systemName: "paperplane.fill") }
                        .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("copilot.send")
                }
                .padding(8)
                .background(.bar)
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .navigationTitle(task.map { $0.title.isEmpty ? String(localized: "ai.task.title") : $0.title } ?? String(localized: "ai.task.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if task?.isActive == true {
                    Button("common.cancel") { Task { try? await model.core.cancelAiTask(taskId: taskId); await load() } }
                }
            }
        }
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

    private func load() async {
        do {
            task = try await model.core.getAiTask(taskId: taskId)
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespaces)
        message = ""
        problem = nil
        Task {
            do {
                task = try await model.core.sendAiMessage(taskId: taskId, text: text)
            } catch {
                // Not lost: back in the field to send it again.
                if message.isEmpty { message = text }
                if let p = AiAccessProblem(error) {
                    problem = p
                } else {
                    self.error = errorMessage(error)
                }
            }
        }
    }
}
