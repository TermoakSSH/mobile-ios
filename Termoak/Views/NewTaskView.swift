import TermoakKit
import SwiftUI

/// A new AI task (server 0.6, like the desktop): the request, the
/// permissions, where it runs (some hosts, a group or a tag, and one
/// conversation per host), "Plan before acting", and the provider, model
/// and effort. It runs on the chosen account's server, with its hosts.
struct NewTaskView: View {
    /// The account whose server runs the task (`nil`: the current one).
    var accountId: String? = nil
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Target: Hashable { case hosts, group, tag }

    @State private var prompt = ""
    @State private var mode: AiPermissionMode = .ask
    @State private var target: Target = .hosts
    @State private var selected: Set<String> = []
    @State private var groupId: String?
    @State private var tag: String?
    @State private var fanOut = false
    @State private var planFirst = false
    @State private var providers: AiProviders?
    @State private var providerKey: String?
    @State private var providerModel: String?
    @State private var effort: String?
    @State private var busy = false
    @State private var error: String?
    /// The error is fixed in Settings → AI.
    @State private var problem: AiAccessProblem?
    @State private var showingAiSettings = false
    @State private var hosts: [SshHost] = []
    @State private var groups: [HostGroup] = []
    @FocusState private var typing: Bool

    private var api: AccountApi { model.core.api(for: accountId) }

    var body: some View {
        NavigationView {
            Form {
                promptSection
                modeSection
                targetSection
                optionsSection
                if let providers, !providers.shown.isEmpty { providerSection(providers) }
                errorSection
            }
            .dismissesKeyboardOnScroll(active: typing) { typing = false }
            .navigationTitle("ai.new.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? String(localized: "ai.new.creating") : String(localized: "ai.new.start"), action: create)
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || providerUnavailable)
                }
            }
        }
        .sheet(isPresented: $showingAiSettings) { AiSettingsSheet().environmentObject(model) }
        .onAppear(perform: loadHosts)
        .task { providers = try? await api.listAiProviders() }
    }

    private var promptSection: some View {
        Section("ai.new.prompt") {
            // Grows with the text up to a limit and then scrolls inside, so
            // the line being typed never ends up under the keyboard.
            TextEditor(text: $prompt)
                .frame(minHeight: 110, maxHeight: 220)
                .focused($typing)
        }
    }

    private var modeSection: some View {
        Section {
            Picker("common.permissions", selection: $mode) {
                ForEach(AiPermissionMode.all, id: \.self) { m in Text(m.title).tag(m) }
            }
            .pickerStyle(.menu)
        } footer: {
            Text(mode.explanation)
        }
    }

    // MARK: Where it runs

    private var targetSection: some View {
        Section {
            Picker("ai.new.target", selection: $target) {
                Text("nav.hosts").tag(Target.hosts)
                if !groups.isEmpty { Text("ai.new.target.group").tag(Target.group) }
                if !tags.isEmpty { Text("ai.new.target.tag").tag(Target.tag) }
            }
            .pickerStyle(.segmented)
            targetChoices
        } header: {
            Text("ai.new.where")
        } footer: {
            Text(targetFooter)
        }
    }

    @ViewBuilder private var targetChoices: some View {
        switch target {
        case .hosts:
            if hosts.isEmpty { Text("ai.new.no_hosts").foregroundColor(.secondary) }
            ForEach(hosts, id: \.id) { h in
                choiceRow(h.displayName, chosen: selected.contains(h.id)) {
                    if selected.contains(h.id) { selected.remove(h.id) } else { selected.insert(h.id) }
                }
            }
        case .group:
            ForEach(groups, id: \.id) { g in
                choiceRow(g.name, detail: String(localized: "ai.hosts_count \(hostsIn(g.id).count)"), chosen: groupId == g.id) {
                    groupId = groupId == g.id ? nil : g.id
                }
            }
        case .tag:
            ForEach(tags, id: \.self) { t in
                choiceRow(t, detail: String(localized: "ai.hosts_count \(hostsTagged(t).count)"), chosen: tag == t) {
                    tag = tag == t ? nil : t
                }
            }
        }
    }

    private func choiceRow(_ title: String, detail: String? = nil, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(verbatim: title).foregroundColor(.primary)
                Spacer()
                if let detail { Text(verbatim: detail).font(.caption).foregroundColor(.secondary) }
                if chosen { Image(systemName: "checkmark").foregroundColor(.accentColor) }
            }
        }
    }

    private var targetFooter: String {
        switch target {
        case .hosts: return String(localized: "ai.new.where.hosts_footer")
        case .group: return String(localized: "ai.new.where.group_footer")
        case .tag: return String(localized: "ai.new.where.tag_footer")
        }
    }

    // MARK: Plan first, one conversation per host

    /// How many hosts the task reaches (for "one conversation per host").
    private var targetCount: Int {
        switch target {
        case .hosts: return selected.count
        case .group: return groupId.map { hostsIn($0).count } ?? 0
        case .tag: return tag.map { hostsTagged($0).count } ?? 0
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle(isOn: $planFirst) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ai.plan_first")
                    Text("ai.plan_first_hint").font(.caption).foregroundColor(.secondary)
                }
            }
            if targetCount > 1 {
                Toggle(isOn: $fanOut) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ai.fan_out \(targetCount)")
                        Text(fanOut ? "ai.fan_out_hint" : "ai.fan_out_off_hint").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Provider, model and effort

    private func providerSection(_ list: AiProviders) -> some View {
        Section {
            Picker("ai.provider", selection: $providerKey) {
                Text(defaultProviderTitle(list)).tag(String?.none)
                ForEach(list.shown, id: \.key) { p in
                    Text(p.available ? p.label : String(localized: "ai.provider_unavailable \(p.label)")).tag(Optional(p.key))
                        .disabled(!p.available)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: providerKey) { _ in providerModel = nil }
            if let p = list.providers.first(where: { $0.key == providerKey }), !p.models.isEmpty {
                Picker("ai.model", selection: $providerModel) {
                    Text(p.defaultModel.map { String(localized: "ai.model_default_named \($0)") } ?? String(localized: "ai.model_default"))
                        .tag(String?.none)
                    ForEach(p.models, id: \.self) { m in Text(verbatim: m).tag(Optional(m)) }
                }
                .pickerStyle(.menu)
            }
            Picker("ai.effort", selection: $effort) {
                Text("ai.effort.default").tag(String?.none)
                Text("ai.effort.low").tag(Optional("low"))
                Text("ai.effort.medium").tag(Optional("medium"))
                Text("ai.effort.high").tag(Optional("high"))
            }
            .pickerStyle(.menu)
        } header: {
            Text("ai.new.provider_section")
        } footer: {
            if let p = list.providers.first(where: { $0.key == providerKey }), let reason = p.unavailableReason {
                Text(verbatim: reason)
            }
        }
    }

    /// The chosen provider can't be used (its reason is under the picker).
    private var providerUnavailable: Bool {
        guard let providerKey, let p = providers?.providers.first(where: { $0.key == providerKey }) else { return false }
        return !p.available
    }

    private func defaultProviderTitle(_ list: AiProviders) -> String {
        guard let d = list.defaultEntry else { return String(localized: "ai.provider_default") }
        return String(localized: "ai.provider_default_named \(d.label)")
    }

    @ViewBuilder private var errorSection: some View {
        if let error {
            Section {
                Text(error).foregroundColor(Brand.red)
                if problem != nil { OpenAiSettingsButton { showingAiSettings = true } }
            }
        }
    }

    // MARK: Data

    private var tags: [String] {
        Array(Set(hosts.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The hosts of a group and of the groups inside it.
    private func hostsIn(_ id: String) -> [SshHost] {
        var ids: Set<String> = [id]
        var pending = [id]
        while let g = pending.popLast() {
            for child in groups where child.parentId == g && !ids.contains(child.id) {
                ids.insert(child.id)
                pending.append(child.id)
            }
        }
        return hosts.filter { $0.groupId.map(ids.contains) ?? false }
    }

    private func hostsTagged(_ t: String) -> [SshHost] {
        hosts.filter { $0.tags.contains(t) }
    }

    private func loadHosts() {
        // The AI runs on the account's server: only its hosts.
        let owner = accountId ?? model.account.current?.id
        let filter = ItemFilter(accountIds: owner.map { [$0] } ?? [], vaultIds: nil, includeDevice: false)
        // Its tools work over SSH: Telnet hosts are left out.
        hosts = ((try? model.core.listHosts(filter: filter)) ?? [])
            .filter { !$0.isTelnet }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        groups = ((try? model.core.listGroups(filter: filter)) ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func create() {
        var request = NewAiTask(prompt: prompt)
        request.provider = NewAiTask.provider(providerKey, model: providerModel)
        request.effort = effort
        switch target {
        case .hosts: request.hostIds = hosts.map(\.id).filter(selected.contains)
        case .group: request.groupId = groupId
        case .tag: request.tag = tag
        }
        request.fanOut = fanOut && targetCount > 1
        request.planFirst = planFirst
        busy = true
        error = nil
        problem = nil
        Task {
            defer { busy = false }
            do {
                _ = try await api.createAiTask(request, mode: mode)
                dismiss()
            } catch {
                problem = AiAccessProblem(error)
                self.error = problem?.message ?? userMessage(error)
            }
        }
    }
}
