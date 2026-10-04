import TermoakKit
import SwiftUI

/// Settings → AI (only when signed in): this month's credit for the server's
/// AI and your own API keys, which are used first and spend no credit.
struct AiSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var access: AiAccessInfo?
    @State private var keys: [AiKeyInfo] = []
    @State private var error: String?

    var body: some View {
        Form {
            if let access {
                Section {
                    status(access)
                } header: { Text("settings.ai.status") }

                let providers = allProviders(access)
                if providers.isEmpty {
                    Section { Text("settings.ai.no_providers").foregroundColor(.secondary) }
                }
                ForEach(providers, id: \.provider) { p in
                    AiKeySection(provider: p, saved: keys.first { $0.provider == p.provider }) { await load() }
                }

                Section {
                    EmptyView()
                } footer: {
                    Label("settings.ai.privacy", systemImage: "lock")
                }
            } else if let error {
                Section {
                    Text(error).foregroundColor(Brand.red)
                    Button("common.retry") { Task { await load() } }
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .navigationTitle("settings.ai")
        .task { await load() }
    }

    /// Whether the server's AI is included, this month's credit and whether
    /// your keys go first.
    @ViewBuilder private func status(_ a: AiAccessInfo) -> some View {
        if !a.serverAi {
            Label("settings.ai.status.own_keys", systemImage: "key")
            if a.ownKeys.isEmpty {
                Text("settings.ai.status.add_key").font(.footnote).foregroundColor(.secondary)
            }
        } else if let credit = a.creditUsd {
            let left = a.remainingUsd ?? max(credit - a.spentUsd, 0)
            let used = credit > 0 ? min(max(a.spentUsd / credit, 0), 1) : 1
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("settings.ai.credit.spent \(formatUsd(a.spentUsd)) \(formatUsd(credit))")
                    Spacer()
                    Text("settings.ai.credit.left \(formatUsd(left))")
                        .font(.footnote).foregroundColor(.secondary)
                }
                ProgressView(value: used)
                    .tint(used >= 1 ? Brand.red : (used >= 0.8 ? Brand.amber : Brand.blue))
            }
            .padding(.vertical, 4)
        } else {
            Label("settings.ai.status.server", systemImage: "sparkles")
            Text("settings.ai.spent \(formatUsd(a.spentUsd))").foregroundColor(.secondary)
        }
        if a.serverAi && !a.ownKeys.isEmpty {
            Label("settings.ai.status.keys_first", systemImage: "checkmark.seal")
                .foregroundColor(Brand.green)
        }
    }

    /// The providers that take your own key, plus any saved key of a provider
    /// the server no longer offers (so it can still be deleted).
    private func allProviders(_ a: AiAccessInfo) -> [AiKeyProvider] {
        var list = a.providers
        for k in keys where !list.contains(where: { $0.provider == k.provider }) {
            list.append(AiKeyProvider(provider: k.provider, label: k.label, defaultModel: nil, models: []))
        }
        return list
    }

    private func load() async {
        do {
            let a = try await model.core.aiAccess()
            let k = try await model.core.listAiKeys()
            access = a
            keys = k
            error = nil
        } catch {
            // Already loaded: keep what is shown.
            if access == nil { self.error = errorMessage(error) }
        }
    }
}

/// One provider: the saved key, a field for a new one, the model and the
/// Test / Save / Delete actions with their result.
private struct AiKeySection: View {
    let provider: AiKeyProvider
    let saved: AiKeyInfo?
    /// Something was saved or deleted: reload the screen.
    let changed: () async -> Void

    @EnvironmentObject private var model: AppModel
    @State private var key = ""
    @State private var modelName: String
    @State private var busy = false
    @State private var feedback: Feedback?
    @State private var deleting = false

    private enum Feedback {
        case success(String)
        case failure(String)
    }

    init(provider: AiKeyProvider, saved: AiKeyInfo?, changed: @escaping () async -> Void) {
        self.provider = provider
        self.saved = saved
        self.changed = changed
        _modelName = State(initialValue: saved?.model ?? "")
    }

    private var typedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// `nil`: the provider's default model.
    private var chosenModel: String? {
        let m = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? nil : m
    }

    /// A new key typed, or a saved key whose model changed.
    private var canSave: Bool {
        if !typedKey.isEmpty { return true }
        guard let saved else { return false }
        return chosenModel != saved.model
    }

    private var defaultModelName: String {
        provider.defaultModel ?? String(localized: "settings.ai.model.default")
    }

    var body: some View {
        Section {
            if let saved {
                HStack {
                    Label("settings.ai.key.saved", systemImage: "checkmark.circle.fill")
                        .foregroundColor(Brand.green)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: "•••• \(saved.hint)").font(.system(.subheadline, design: .monospaced))
                        Text(verbatim: saved.model ?? defaultModelName)
                            .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                }
            } else {
                Text("settings.ai.key.none").foregroundColor(.secondary)
            }

            SecureField(saved == nil ? String(localized: "settings.ai.key.placeholder")
                                     : String(localized: "settings.ai.key.replace"),
                        text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            HStack {
                Text("settings.ai.model")
                TextField(defaultModelName, text: $modelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(.secondary)
                if !provider.models.isEmpty {
                    Menu {
                        Button { modelName = "" } label: {
                            if chosenModel == nil {
                                Label("settings.ai.model.default", systemImage: "checkmark")
                            } else {
                                Text("settings.ai.model.default")
                            }
                        }
                        ForEach(provider.models, id: \.self) { m in
                            Button { modelName = m } label: {
                                if chosenModel == m {
                                    Label(m, systemImage: "checkmark")
                                } else {
                                    Text(verbatim: m)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .accessibilityLabel(Text("settings.ai.model.choose"))
                }
            }

            HStack(spacing: 18) {
                Button("settings.ai.test", action: test)
                    .disabled(busy || (typedKey.isEmpty && saved == nil))
                Button("common.save", action: save)
                    .disabled(busy || !canSave)
                Spacer()
                if busy { ProgressView() }
                if saved != nil {
                    Button("common.delete", role: .destructive) { deleting = true }
                        .disabled(busy)
                        .confirmationDialog(Text("settings.ai.delete.title \(provider.label)"),
                                            isPresented: $deleting, titleVisibility: .visible) {
                            Button("common.delete", role: .destructive, action: delete)
                        } message: { Text("settings.ai.delete.message") }
                }
            }
            .buttonStyle(.borderless)

            if let feedback {
                switch feedback {
                case .success(let text):
                    Label(text, systemImage: "checkmark.circle")
                        .font(.footnote).foregroundColor(Brand.green)
                case .failure(let text):
                    Label(text, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundColor(Brand.red)
                }
            }
        } header: {
            Text(verbatim: provider.label)
        }
    }

    // ----- Actions -----

    /// Checks the typed key, or the saved one if the field is empty.
    private func test() {
        let typed = typedKey
        run(reload: false) {
            let r = try await model.core.testAiKey(provider: provider.provider, key: typed.isEmpty ? nil : typed)
            if r.ok { return .success(String(localized: "settings.ai.test.ok")) }
            if r.status == 401 || r.status == 403 {
                return .failure(String(localized: "settings.ai.test.rejected"))
            }
            let detail = r.error ?? r.status.map { "HTTP \($0)" } ?? "—"
            return .failure(String(localized: "settings.ai.test.failed \(detail)"))
        }
    }

    private func save() {
        let typed = typedKey
        let chosen = chosenModel
        run(reload: true) {
            // Empty field with a saved key: only the model changes.
            let info = try await model.core.setAiKey(provider: provider.provider, key: typed.isEmpty ? nil : typed,
                                                     model: chosen)
            key = ""
            modelName = info.model ?? ""
            return .success(String(localized: "settings.ai.saved"))
        }
    }

    private func delete() {
        run(reload: true) {
            _ = try await model.core.deleteAiKey(provider: provider.provider)
            key = ""
            return .success(String(localized: "settings.ai.deleted"))
        }
    }

    private func run(reload: Bool, _ action: @escaping () async throws -> Feedback) {
        busy = true
        feedback = nil
        Task {
            do {
                feedback = try await action()
            } catch {
                feedback = .failure(AiAccessProblem(error)?.message ?? errorMessage(error))
            }
            busy = false
            if reload { await changed() }
        }
    }
}

/// Settings → AI on its own, opened from an AI error (missing key or no
/// credit left) without leaving the current screen.
struct AiSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            AiSettingsView()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.done") { dismiss() }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}

/// "Open AI settings", next to an error that is fixed there.
struct OpenAiSettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("ai.error.open_settings", systemImage: "key")
        }
    }
}
