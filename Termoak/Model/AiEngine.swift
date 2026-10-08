import TermoakKit
import Foundation

// The AI screens on top of the engine's typed calls (0.6.1): decisions with
// an edit or a reason, new tasks with a plan first, a group or tag and one
// conversation per host, the providers, the runbook. No hand-written JSON.

extension ApprovalPreview {
    /// What the engine says an approval is about (`AiApproval.preview`).
    init(_ p: AiApprovalPreview) {
        self.init()
        kind = p.kind
        host = p.host
        command = p.command
        path = p.path
        diff = p.diff
        diffTruncated = p.truncated
        added = p.added.map(Int.init)
        removed = p.removed.map(Int.init)
        newFile = p.newFile
        diffError = p.diffError
        switch p.risk {
        case .low: risk = "low"
        case .medium: risk = "medium"
        case .high: risk = "high"
        }
        reasons = p.reasons.map { Reason(code: $0.code, text: $0.text) }
        explanation = p.explanation
        plan = p.plan
        editable = p.editable
    }
}

extension AiApproval {
    /// What the card shows (`nil` on servers before 0.6: the summary then).
    var shownPreview: ApprovalPreview? { preview.map(ApprovalPreview.init) }
}

extension ApprovalChoice {
    /// The engine's decision: the edit only when approving, empty texts left out.
    var decision: AiDecision {
        AiDecision(approve: approve, always: always, edited: cleanEdited, reason: cleanReason)
    }
}

extension NewAiTask {
    /// The engine's request with these permissions.
    func request(mode: AiPermissionMode) -> AiTaskRequest {
        AiTaskRequest(prompt: cleanPrompt, mode: mode, provider: cleanProvider, hostIds: hostIds,
                      effort: cleanEffort, planFirst: planFirst, groupId: groupId, tag: cleanTag, fanOut: fanOut)
    }
}

extension AiProviders {
    /// The ones to offer: not hidden.
    var shown: [AiProvider] { providers.filter { !$0.hidden } }
    var defaultEntry: AiProvider? { providers.first { $0.key == defaultProvider } }
}

extension AiProvider {
    /// Why it can't be used, in the app's language (the server's text for an
    /// unknown code).
    var unavailableReason: String? {
        guard !available else { return nil }
        return aiProviderReason(code: reasonCode) ?? reason
    }
}

extension AccountApi {
    /// Approves or denies, with an edited command or plan or a reason.
    func decide(taskId: String, approvalId: String, _ choice: ApprovalChoice) async throws {
        try await decideApprovalWith(taskId: taskId, approvalId: approvalId, decision: choice.decision)
    }

    /// Creates a task with the options of server 0.6.
    func createAiTask(_ request: NewAiTask, mode: AiPermissionMode) async throws -> AiTask {
        try await createAiTask(request: request.request(mode: mode))
    }

    /// Saves the runbook as a snippet (tags ai, runbook) in your personal
    /// vault, with the name typed (the task's title when empty).
    func saveRunbook(taskId: String, name: String) async throws -> Snippet {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await saveRunbook(taskId: taskId, vaultId: nil, name: n.isEmpty ? nil : n)
    }
}
