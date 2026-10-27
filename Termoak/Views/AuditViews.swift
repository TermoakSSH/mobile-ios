import TermoakKit
import SwiftUI

// The extended audit (0.7 phase 5c, docs-next/E2EE-SSO-AUDIT.md §4): your
// activity (Settings → Security), a team's (Teams → a team → Audit, owners
// and admins) and a vault's (Admins): presets, time range, person, text,
// load more, export to the share sheet; for teams also retention and the
// SIEM sinks (state, test, pause, delete; adding them stays on the desktop
// and the web).

enum AuditViewScope {
    case me, team, vault

    var engine: AuditScope {
        switch self {
        case .me: return .me
        case .team: return .team
        case .vault: return .vault
        }
    }
}

/// A file made by an audit export, for the share sheet.
struct AuditExportFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct AuditView: View {
    let accountId: String
    let scope: AuditViewScope
    let scopeId: String?
    let name: String?
    @EnvironmentObject private var model: AppModel
    @State private var filters = AuditFilters()
    @State private var entries: [AuditEvent] = []
    @State private var more = false
    @State private var loading = false
    @State private var error: String?
    @State private var names: [String: String] = [:]
    @State private var exported: AuditExportFile?
    @State private var tab = 0
    @State private var retention: AuditRules.RetentionView?
    @State private var retentionText = ""
    @State private var sinks: [AuditSinkInfo]?
    @State private var busy = false
    @State private var message: String?
    @State private var deleting: AuditSinkInfo?

    private var handle: AccountHandle? { try? model.core.account(accountId: accountId) }
    private var id: String? { scope == .me ? nil : scopeId }

    var body: some View {
        List {
            if scope == .team {
                Picker("teams.audit", selection: $tab) {
                    Text("audit.team_title").tag(0)
                    Text("audit.sinks.title").tag(1)
                }
                .pickerStyle(.segmented)
            }
            if scope == .team && tab == 1 {
                settingsSections
            } else {
                filterSection
                if let error { Text(verbatim: error).foregroundColor(Brand.red) }
                Section {
                    if entries.isEmpty && !loading && error == nil { Text("audit.empty").foregroundColor(.secondary) }
                    ForEach(entries, id: \.id) { e in AuditRow(event: e, who: AuditRules.actor(e.actor, names: names)) }
                    if loading {
                        ProgressView()
                    } else if more {
                        Button("audit.load_more") { Task { await load(next: true) } }
                    } else if !entries.isEmpty {
                        Text("audit.count \(entries.count)").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle(Text(scope == .team ? "audit.team_title" : (scope == .vault ? "vaults.activity" : "audit.account_title")))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(E2eeBook.shared.audit(accountId)?.exports ?? AuditRules.formats, id: \.self) { f in
                        Button(f.uppercased()) { export(f) }
                    }
                } label: { Label("audit.export", systemImage: "square.and.arrow.up") }
            }
        }
        .sheet(item: $exported) { f in ShareSheet(urls: [f.url]) }
        .task(id: "\(accountId)/\(scopeId ?? "")") {
            await loadNames()
            if scope == .team { await loadSettings() }
        }
        .task(id: "\(filters.preset.rawValue)/\(filters.range.rawValue)") { await load(next: false) }
        .alert(Text("audit.sink.delete_title \(deleting?.name ?? "")"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("common.delete", role: .destructive) {
                guard let s = deleting else { return }
                sinkAction { try await $0.deleteAuditSink(scope: .team, sinkId: s.id, id: scopeId); return nil }
            }
            Button("common.cancel", role: .cancel) {}
        } message: { Text("audit.sink.delete_message") }
    }

    @ViewBuilder private var filterSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(AuditPreset.allCases) { p in
                        Button(LocalizedStringKey(p.label)) { filters.preset = p }
                            .buttonStyle(.bordered).tint(filters.preset == p ? Brand.blue : .secondary)
                    }
                }
            }
            Picker("audit.filter.range", selection: $filters.range) {
                ForEach(AuditRange.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
            }
            TextField("audit.filter.text", text: $filters.text).onSubmit { Task { await load(next: false) } }
            if scope != .me {
                TextField("audit.filter.actor", text: $filters.actor).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { Task { await load(next: false) } }
            }
            Button("audit.filter.apply") { Task { await load(next: false) } }
        }
    }

    @ViewBuilder private var settingsSections: some View {
        if let message { Text(verbatim: message).foregroundColor(Brand.green) }
        if let r = retention {
            Section {
                Text("audit.retention.hint \(String(r.defaultDays)) \(String(r.maxDays))").font(.caption).foregroundColor(.secondary)
                HStack {
                    TextField(String(localized: "audit.retention.default \(String(r.defaultDays))"), text: $retentionText).keyboardType(.numberPad)
                    Text("audit.retention.days").foregroundColor(.secondary)
                }
                if AuditRules.parseRetention(retentionText, max: r.maxDays) == .invalid {
                    Text("audit.retention.invalid \(String(r.maxDays))").font(.caption).foregroundColor(Brand.red)
                }
                Button("common.save") {
                    guard case .ok(let days) = AuditRules.parseRetention(retentionText, max: r.maxDays), let t = scopeId else { return }
                    sinkAction { _ = try await $0.setTeamAuditRetention(teamId: t, days: days); return String(localized: "audit.retention.saved") }
                }
                .disabled(busy || AuditRules.parseRetention(retentionText, max: r.maxDays) == .invalid)
            } header: { Text("audit.retention.title") }
        }
        Section {
            Text("audit.sinks.hint").font(.caption).foregroundColor(.secondary)
            if let sinks {
                if sinks.isEmpty { Text("audit.sinks.none").foregroundColor(.secondary) }
                ForEach(sinks, id: \.id) { s in sinkRow(s) }
            } else {
                ProgressView()
            }
            Text("audit.sinks.add_elsewhere").font(.caption).foregroundColor(.secondary)
        } header: { Text("audit.sinks.title") }
    }

    private func sinkRow(_ s: AuditSinkInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: s.name).font(.headline)
            Text(verbatim: AuditRules.sinkTarget(kind: s.kind, url: s.url, host: s.host, port: s.port, transport: s.transport))
                .font(.caption.monospaced()).foregroundColor(.secondary).lineLimit(1)
            switch AuditRules.sinkState(enabled: s.enabled, failures: s.failures, lastSuccessAt: s.lastSuccessAt) {
            case .paused: Text("audit.sink.state.disabled").font(.caption).foregroundColor(.secondary)
            case .failing: Text("audit.sink.state.failing \(Int(s.failures)) \(s.lastError ?? "")").font(.caption).foregroundColor(Brand.red)
            case .delivered: Text("audit.sink.state.delivered \(AccessTexts.dateTime(s.lastSuccessAt ?? 0))").font(.caption).foregroundColor(Brand.green)
            case .waiting: Text("audit.sink.state.waiting").font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Button("audit.sink.test") {
                    sinkAction {
                        let t = try await $0.testAuditSink(scope: .team, sinkId: s.id, id: scopeId)
                        return t.ok ? String(localized: "audit.sink.test_ok") : String(localized: "audit.sink.test_failed \(t.error ?? "")")
                    }
                }
                .disabled(busy || !s.enabled)
                Button(s.enabled ? LocalizedStringKey("audit.sink.state.disabled") : LocalizedStringKey("audit.sink.enabled")) {
                    sinkAction { _ = try await $0.updateAuditSink(scope: .team, sinkId: s.id, id: scopeId, name: nil, actions: nil, enabled: !s.enabled); return nil }
                }
                .disabled(busy)
                Spacer()
                Button(role: .destructive) { deleting = s } label: { Image(systemName: "trash") }
            }
            .buttonStyle(.borderless)
        }
    }

    private func load(next: Bool) async {
        guard let h = handle else { return }
        loading = true
        defer { loading = false }
        do {
            let before = next ? entries.last?.id : nil
            let page = try await h.auditSearch(scope: scope.engine, query: filters.query(now: nowMs(), before: before).engine, id: id)
            entries = next ? entries + page : page
            more = AuditRules.nextBefore(lastId: entries.last?.id, lastPage: page.count) != nil
            error = nil
        } catch {
            self.error = userMessage(error)
        }
    }

    private func loadNames() async {
        guard let h = handle else { return }
        switch scope {
        case .team:
            if let t = scopeId, let list = try? await h.listTeamMembers(teamId: t) { names = Dictionary(list.map { ($0.userId, $0.email) }, uniquingKeysWith: { a, _ in a }) }
        case .vault:
            if let v = scopeId, let list = try? await h.vaultMembers(vaultId: v) {
                names = Dictionary(list.compactMap { m in m.userId.map { ($0, m.email ?? m.name) } }, uniquingKeysWith: { a, _ in a })
            }
        case .me:
            if let a = model.account.account(accountId), let u = a.userId { names = [u: String(localized: "vault_e2ee.you \(a.email)")] }
        }
    }

    private func loadSettings() async {
        guard let h = handle, let t = scopeId else { return }
        retention = AuditRules.retentionView((try? await h.apiRequest(method: .get, path: "/api/v1/teams/\(t)/audit/settings", bodyJson: nil)) ?? "")
        retentionText = retention?.days.map(String.init) ?? ""
        sinks = (try? await h.auditSinks(scope: .team, id: t)) ?? []
    }

    private func export(_ format: String) {
        guard let h = handle else { return }
        Task {
            do {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audit", isDirectory: true)
                try? FileManager.default.removeItem(at: dir)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                let url = dir.appendingPathComponent(AuditRules.exportName(scope: name ?? "audit", format: format, date: f.string(from: Date())))
                _ = try await h.auditExport(scope: scope.engine, query: filters.exportQuery(now: nowMs()).engine, format: format, localPath: url.path, id: id)
                exported = AuditExportFile(url: url)
            } catch {
                self.error = userMessage(error)
            }
        }
    }

    private func sinkAction(_ f: @escaping (AccountHandle) async throws -> String?) {
        guard let h = handle else { return }
        busy = true
        Task {
            defer { busy = false }
            do { message = try await f(h) } catch { message = userMessage(error) }
            await loadSettings()
        }
    }
}

/// An audit entry in words.
struct AuditRow: View {
    let event: AuditEvent
    let who: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: AuditRules.actionKey(event.action).map { NSLocalizedString($0, comment: "") } ?? event.action).font(.subheadline)
            Text(verbatim: "\(who) · \(AccessTexts.dateTime(event.createdAt))").font(.caption).foregroundColor(.secondary).lineLimit(1)
            let detail = [event.target, AuditRules.detailSummary(event.detailJson)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !detail.isEmpty { Text(verbatim: detail).font(.caption).foregroundColor(.secondary).lineLimit(2) }
        }
    }
}
