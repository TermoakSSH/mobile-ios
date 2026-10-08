import TermoakKit
import SwiftUI

// What a task of server 0.6 adds to its page: the per-host table of a task
// with one conversation per host, the approved plan, and the task's menu
// (permissions while it works, Save as runbook, Delete).

/// The hosts of a multi-host task: each one's state, result, time, cost and
/// approvals waiting; a row opens that host's conversation.
struct HostRunsTable: View {
    let runs: [AiHostRun]
    /// The task's account (`nil`: the current one).
    let accountId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ai.hosts_count \(runs.count)").font(.headline)
            Text("ai.hosts.hint").font(.caption).foregroundColor(.secondary)
            ForEach(runs) { run in
                NavigationLink { TaskView(taskId: run.taskId, accountId: accountId) } label: { HostRunRow(run: run) }
                    .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct HostRunRow: View {
    let run: AiHostRun

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: run.label.isEmpty ? run.hostId : run.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                    let (text, color) = aiRunStatus(run.status)
                    Chip(text, color)
                    if run.pendingApprovals > 0 {
                        Chip(String(localized: "ai.hosts.approvals \(run.pendingApprovals)"), Brand.amber)
                    }
                }
                if let line = run.error ?? run.summary, !line.isEmpty {
                    Text(verbatim: line).font(.caption).foregroundColor(run.error != nil ? Brand.red : .secondary).lineLimit(3)
                }
                Text(verbatim: details).font(.caption2).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// "1 min 5 s · $0.01".
    private var details: String {
        var parts: [String] = []
        if let ms = run.durationMs { parts.append(aiDuration(ms: ms)) }
        if run.costMicros > 0 { parts.append(formatUsd(Double(run.costMicros) / 1_000_000)) }
        return parts.joined(separator: " · ")
    }
}

/// A task's state as the server writes it (`queued`, `running`...).
func aiRunStatus(_ status: String) -> (String, Color) {
    switch status {
    case "queued": return (String(localized: "ai.status.queued"), .secondary)
    case "running": return (String(localized: "ai.status.running"), Brand.blue)
    case "waiting_approval": return (String(localized: "ai.status.waiting_approval"), Brand.amber)
    case "completed": return (String(localized: "ai.status.completed"), Brand.green)
    case "failed": return (String(localized: "ai.status.failed"), Brand.red)
    case "cancelled": return (String(localized: "ai.status.cancelled"), .secondary)
    default: return (status, .secondary)
    }
}

/// The plan the task follows (approved, or edited and approved).
struct ApprovedPlan: View {
    let plan: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("ai.plan.approved", systemImage: "list.number").font(.subheadline.weight(.semibold))
            Text(plan)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The task's menu: its permissions while it works, Save as runbook once it
/// ran commands, and Delete.
struct TaskActionsMenu: View {
    let active: Bool
    /// The task's permissions (`nil`: unknown).
    let mode: AiPermissionMode?
    /// It ran commands or file writes.
    let ranSteps: Bool
    let onMode: (AiPermissionMode) -> Void
    let onRunbook: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Menu {
            if active, let mode {
                Picker("common.permissions", selection: Binding(get: { mode }, set: { onMode($0) })) {
                    ForEach(AiPermissionMode.all, id: \.self) { m in Label(m.title, systemImage: m.icon).tag(m) }
                }
            }
            if !active && ranSteps {
                Button(action: onRunbook) { Label("ai.runbook.save", systemImage: "chevron.left.forwardslash.chevron.right") }
            }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("ai.delete_task", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(Text("ai.task.actions"))
    }
}

extension AiPermissionMode {
    /// From the server's name (`read_only`, `ask`, `confirm`, `auto`).
    init?(apiName: String?) {
        switch apiName {
        case "read_only": self = .readOnly
        case "ask": self = .ask
        case "confirm": self = .confirm
        case "auto": self = .auto
        default: return nil
        }
    }
}

/// "Save as runbook": the commands the task ran as a snippet (tags ai and
/// runbook) in your personal vault, with a name to review first.
struct RunbookSheet: View {
    let taskId: String
    let api: AccountApi
    /// Saved: the account syncs to get the new snippet.
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var runbook: AiRunbook?
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                if let runbook {
                    content(runbook)
                } else if error == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let error {
                    Section { Text(error).foregroundColor(Brand.red) }
                }
            }
            .navigationTitle("ai.runbook.save")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save", action: save).disabled(saving || (runbook?.steps ?? 0) == 0)
                }
            }
        }
        .navigationViewStyle(.stack)
        .task { await load() }
    }

    @ViewBuilder private func content(_ r: AiRunbook) -> some View {
        if r.steps == 0 {
            Section { Text("ai.runbook.empty").foregroundColor(.secondary) }
        } else {
            Section {
                TextField("common.name", text: $name)
            } footer: {
                Text("ai.runbook.hint")
            }
            Section("snippets.editor.command") {
                Text(r.script)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                if !r.variables.isEmpty {
                    Text(verbatim: r.variables.map { "{{\($0)}}" }.joined(separator: " "))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private func load() async {
        do {
            let r = try await api.aiRunbook(taskId: taskId)
            runbook = r
            name = r.name
        } catch {
            self.error = userMessage(error)
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await api.saveAiRunbook(taskId: taskId, name: name)
                onSaved()
                dismiss()
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}
