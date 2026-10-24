import TermoakKit
import SwiftUI

// Teams security (0.7 phase 4d): access policies of a vault, its groups and
// hosts (vault Admins), and the vault's recorded sessions with a player.

/// A vault's access policies: the whole vault's and each group's and
/// host's; open one to change it.
struct VaultAccessView: View {
    let vault: VaultInfo
    @EnvironmentObject private var model: AppModel
    @State private var policies: [AccessPolicyRecord]?
    @State private var error: String?

    private var hosts: [SshHost] { (try? model.core.listHosts(filter: ItemFilter(accountIds: [vault.accountId], vaultIds: [vault.id], includeDevice: false))) ?? [] }
    private var groups: [HostGroup] { (try? model.core.listGroups(filter: ItemFilter(accountIds: [vault.accountId], vaultIds: [vault.id], includeDevice: false))) ?? [] }

    var body: some View {
        List {
            Section { Text("access_policy.vault_hint").font(.footnote).foregroundColor(.secondary) }
            if let error { Section { Text(verbatim: error).foregroundColor(Brand.red) } }
            if let list = policies {
                Section {
                    NavigationLink {
                        AccessPolicyEditor(vault: vault, kind: "vault", targetId: vault.id, name: vault.displayName)
                    } label: {
                        row(String(localized: "access_policy.target_vault"), list.first { $0.targetKind == .vault }?.policy)
                    }
                    ForEach(list.filter { $0.targetKind != .vault }, id: \.id) { r in
                        let name = r.targetKind == .group ? (groups.first { $0.id == r.targetId }?.name ?? String(localized: "access_policy.missing_target"))
                            : (hosts.first { $0.id == r.targetId }?.displayName ?? String(localized: "access_policy.missing_target"))
                        NavigationLink {
                            AccessPolicyEditor(vault: vault, kind: r.targetKind.name, targetId: r.targetId, name: name)
                        } label: {
                            row(r.targetKind == .group ? String(localized: "access_policy.target_group \(name)") : String(localized: "access_policy.target_host \(name)"), r.policy)
                        }
                    }
                } footer: { Text(list.isEmpty ? LocalizedStringKey("access_policy.empty") : LocalizedStringKey("access_policy.where_hint")) }
            } else if error == nil {
                ProgressView()
            }
        }
        .navigationTitle("access.policy_needed_title")
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ title: String, _ p: AccessPolicyInfo?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
            Text(verbatim: p.map(policySummary) ?? String(localized: "access_policy.summary_direct")).font(.caption).foregroundColor(.secondary)
        }
    }

    private func load() async {
        do {
            policies = try await model.core.account(accountId: vault.accountId).accessPolicies(vaultId: vault.id)
        } catch {
            self.error = userMessage(error)
        }
    }
}

/// "Approval · up to 1 h" / "Direct" (+ "Recorded").
func policySummary(_ p: AccessPolicyInfo) -> String {
    let base = p.mode == .direct ? String(localized: "access_policy.summary_direct")
        : String(localized: "access_policy.summary_approval \(AccessTexts.duration(Int(p.maxMinutes)))")
    return p.recordSessions ? base + " · " + String(localized: "access.recorded") : base
}

/// The access policy of a host, group or the whole vault: Direct or With
/// approval (approvers, longest window, how long a request waits, Admins
/// too, self-approval), recording and certificate options; what applies
/// without one; remove it.
struct AccessPolicyEditor: View {
    let vault: VaultInfo
    /// `host`, `group` or `vault`.
    let kind: String
    let targetId: String
    let name: String

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false
    @State private var own: AccessPolicyRecord?
    @State private var inherited: String?
    @State private var approval = true
    @State private var approvers: Set<String> = []
    @State private var people: [(id: String, name: String)] = []
    @State private var maxText = "60"
    @State private var ttlText = "240"
    @State private var managers = false
    @State private var selfApproval = false
    @State private var record = false
    @State private var principals = ""
    @State private var certTtl = ""
    @State private var customExt = false
    @State private var extensions: Set<String> = ["permit-pty", "permit-port-forwarding", "permit-agent-forwarding"]
    @State private var source = ""
    @State private var force = ""
    @State private var error: String?

    private var handle: AccountHandle? { try? model.core.account(accountId: vault.accountId) }

    var body: some View {
        Form {
            if let inherited { Section { Text(verbatim: inherited).font(.footnote).foregroundColor(.secondary) } }
            Section {
                Picker("access_policy.mode.label", selection: $approval) {
                    Text("access_policy.summary_direct").tag(false)
                    Text("access_policy.mode.approval").tag(true)
                }
                .pickerStyle(.segmented)
                if approval {
                    TextField("access_policy.max", text: $maxText).keyboardType(.numberPad)
                    TextField("access_policy.ttl", text: $ttlText).keyboardType(.numberPad)
                    Toggle("access_policy.managers", isOn: $managers)
                    Toggle("access_policy.self_approval", isOn: $selfApproval)
                }
                Toggle("access_policy.record", isOn: $record)
            } footer: { Text("access_policy.mode.hint") }
            if approval {
                Section {
                    ForEach(people, id: \.id) { p in
                        Toggle(isOn: Binding(get: { approvers.contains(p.id) }, set: { on in
                            if on { approvers.insert(p.id) } else { approvers.remove(p.id) }
                        })) { Text(verbatim: p.name) }
                    }
                } header: { Text("access_policy.approvers") } footer: { Text("access_policy.approvers_hint") }
            }
            Section {
                TextField("cert_fields.principals", text: $principals).font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("cert_fields.ttl", text: $certTtl).keyboardType(.numberPad)
                Toggle("cert_fields.extensions_custom", isOn: $customExt)
                if customExt {
                    ForEach(certExtensions, id: \.self) { e in
                        Toggle(isOn: Binding(get: { extensions.contains(e) }, set: { on in
                            if on { extensions.insert(e) } else { extensions.remove(e) }
                        })) { Text(verbatim: e).font(.callout.monospaced()) }
                    }
                }
                TextField("cert_fields.source_address", text: $source).font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("cert_fields.force_command_placeholder", text: $force).font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("access_policy.cert_overrides") } footer: { Text("cert_fields.force_command_hint") }
            if let error { Section { Text(verbatim: error).foregroundColor(Brand.red) } }
            Section {
                Button("access_policy.save") { save() }
                    .disabled(approval && (AccessRules.number(maxText, in: 1...10080) == nil || AccessRules.number(ttlText, in: 5...10080) == nil))
                if own != nil {
                    Button("access_policy.remove", role: .destructive) { remove() }
                }
            }
        }
        .navigationTitle(Text(verbatim: kind == "host" ? String(localized: "access_policy.title_host \(name)")
                              : kind == "group" ? String(localized: "access_policy.title_group \(name)")
                              : String(localized: "access_policy.title_vault \(name)")))
        .navigationBarTitleDisplayMode(.inline)
        .task { if !loaded { await load() } }
    }

    private func load() async {
        guard let h = handle else { return }
        loaded = true
        if let members = try? await h.vaultMembers(vaultId: vault.id) {
            people = members.compactMap { m in
                guard let u = m.userId, m.kind == .user || m.implicit else { return nil }
                return (u, m.name.isEmpty ? (m.email ?? u) : m.name)
            }
        }
        do {
            let list = try await h.accessPolicies(vaultId: vault.id)
            own = list.first { $0.targetKind.name == kind && $0.targetId == targetId }
            let groups = (try? model.core.listGroups(filter: ItemFilter(accountIds: [vault.accountId], vaultIds: [vault.id], includeDevice: false))) ?? []
            let host = kind == "host" ? try? model.core.getHost(id: targetId, accountId: vault.accountId) : nil
            var start = own?.policy
            if own == nil, let t = AccessRules.inheritedTarget(
                kind: kind, groupOfHost: host?.groupId, parentOf: { id in groups.first { $0.id == id }?.parentId },
                hasPolicy: { k, id in list.contains { $0.targetKind.name == k && $0.targetId == id } }, vaultId: vault.id) {
                let r = list.first { $0.targetKind.name == t.0 && $0.targetId == t.1 }
                let from = t.0 == "group" ? String(localized: "access.target_group \(groups.first { $0.id == t.1 }?.name ?? "")")
                    : String(localized: "access_policy.the_vault")
                inherited = r?.policy.mode == .approval ? String(localized: "access_policy.inherits_approval \(from)")
                    : String(localized: "access_policy.inherits_direct \(from)")
                start = r?.policy
            } else if own == nil && kind != "vault" {
                inherited = String(localized: "access_policy.none")
            } else if own != nil {
                inherited = String(localized: "access_policy.own")
            }
            if let p = start {
                approval = p.mode != .direct
                approvers = own == nil ? [] : Set(p.approvers)
                maxText = String(p.maxMinutes)
                ttlText = String(p.requestTtlMinutes)
                managers = p.requireForManagers
                selfApproval = p.allowSelfApproval
                record = p.recordSessions
                principals = (p.principals ?? []).joined(separator: ", ")
                certTtl = p.certTtlMinutes.map { String($0) } ?? ""
                customExt = p.extensions != nil
                if let e = p.extensions { extensions = Set(e) }
                source = p.sourceAddress ?? ""
                force = p.forceCommand ?? ""
            }
        } catch {
            self.error = userMessage(error)
        }
    }

    private func save() {
        guard let h = handle else { return }
        let t = AccessRules.templates(principals)
        let s = source.trimmingCharacters(in: .whitespaces)
        let f = force.trimmingCharacters(in: .whitespaces)
        let p = AccessPolicyInfo(
            mode: approval ? .approval : .direct,
            approvers: approval ? people.map(\.id).filter { approvers.contains($0) } : [],
            maxMinutes: UInt32(AccessRules.number(maxText, in: 1...10080) ?? 60),
            requestTtlMinutes: UInt32(AccessRules.number(ttlText, in: 5...10080) ?? 240),
            allowSelfApproval: approval && selfApproval,
            requireForManagers: approval && managers,
            principals: t.isEmpty ? nil : t,
            certTtlMinutes: AccessRules.number(certTtl, in: 1...1440).map { UInt32($0) },
            extensions: customExt ? certExtensions.filter { extensions.contains($0) } : nil,
            sourceAddress: s.isEmpty ? nil : s,
            forceCommand: f.isEmpty ? nil : f,
            recordSessions: record)
        Task {
            do {
                own = try await h.setAccessPolicy(vaultId: vault.id, targetKind: .of(kind), targetId: targetId, policy: p)
                account.sync(vault.accountId)
                dismiss()
            } catch {
                self.error = userMessage(error)
            }
        }
    }

    private func remove() {
        guard let h = handle, let id = own?.id else { return }
        Task {
            do {
                try await h.deleteAccessPolicy(vaultId: vault.id, policyId: id)
                account.sync(vault.accountId)
                dismiss()
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}

// MARK: - Recordings

/// A vault's recorded sessions (vault Admins): server sessions and the
/// terminals the apps recorded and uploaded; play one or share its `.cast`.
struct VaultRecordingsView: View {
    let vault: VaultInfo
    @EnvironmentObject private var model: AppModel
    @State private var list: [VaultRecording]?
    @State private var error: String?
    @State private var working: String?
    @State private var playing: PlayingRecording?
    @State private var sharing: SharedRecording?

    var body: some View {
        List {
            Section { Text("recordings.hint").font(.footnote).foregroundColor(.secondary) }
            if let error { Section { Text(verbatim: error).foregroundColor(Brand.red) } }
            if let list {
                if list.isEmpty { Text("recordings.empty").foregroundColor(.secondary) }
                ForEach(list, id: \.sessionId) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: r.title.isEmpty ? String(r.sessionId.prefix(8)) : r.title)
                            Text(verbatim: String(localized: "recordings.by \(r.ownerEmail ?? String(r.ownerId.prefix(8))) \(AccessTexts.dateTime(r.createdAt))")
                                 + (r.kind == "device" ? " · " + String(localized: "recordings.from_device") : ""))
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if working == r.sessionId {
                            ProgressView()
                        } else {
                            Button { download(r) { url in
                                if let text = try? String(contentsOf: url, encoding: .utf8), let cast = Asciicast.parse(text) {
                                    playing = PlayingRecording(title: r.title, cast: cast)
                                } else {
                                    error = String(localized: "recordings.error.format")
                                }
                            } } label: { Image(systemName: "play.circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("recordings.play")
                            Button { download(r) { sharing = SharedRecording(url: $0) } } label: { Image(systemName: "square.and.arrow.up") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("recordings.share")
                        }
                    }
                }
            } else if error == nil {
                ProgressView()
            }
        }
        .navigationTitle("vaults.tab.recordings")
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $playing) { p in RecordingPlayerView(title: p.title, cast: p.cast) }
        .sheet(item: $sharing) { s in ShareLink(item: s.url) { Label("recordings.share", systemImage: "square.and.arrow.up") }.padding() }
    }

    private func load() async {
        do {
            list = try await model.core.account(accountId: vault.accountId).vaultRecordings(vaultId: vault.id).sorted { $0.createdAt > $1.createdAt }
        } catch {
            self.error = userMessage(error)
        }
    }

    /// Downloads one (audited by the server) to a temporary `.cast`.
    private func download(_ r: VaultRecording, then use: @escaping (URL) -> Void) {
        guard let h = try? model.core.account(accountId: vault.accountId) else { return }
        let safe = r.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent((safe.isEmpty ? r.sessionId : safe) + ".cast")
        working = r.sessionId
        Task {
            defer { working = nil }
            do {
                try? FileManager.default.removeItem(at: url)
                _ = try await h.downloadVaultRecording(vaultId: vault.id, sessionId: r.sessionId, localPath: url.path, listener: nil, cancel: nil)
                use(url)
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}

private struct PlayingRecording: Identifiable {
    let id = UUID()
    let title: String
    let cast: Asciicast
}

private struct SharedRecording: Identifiable {
    let id = UUID()
    let url: URL
}

/// Plays a recording into a terminal emulator (the engine's), honouring its
/// size changes: play/pause, from the start, 1–8×; long pauses are cut.
struct RecordingPlayerView: View {
    let title: String
    let cast: Asciicast
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    @State private var index = 0
    @State private var playing = true
    @State private var speed = 1.0
    @State private var run = 0
    @State private var screen: TerminalScreen?

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: lines.joined(separator: "\n"))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(8)
                }
                .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                        .accessibilityLabel(playing ? Text("recordings.pause") : Text("recordings.play"))
                    Button { restart() } label: { Image(systemName: "backward.end.fill") }
                        .accessibilityLabel("recordings.restart")
                    Picker("recordings.speed", selection: $speed) {
                        ForEach(Asciicast.speeds, id: \.self) { s in Text(verbatim: "\(Int(s))×").tag(s) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding()
            .navigationTitle(Text(verbatim: String(localized: "recordings.player_title \(title)")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } } }
            .task(id: "\(run)-\(playing)-\(speed)") { await play() }
        }
        .navigationViewStyle(.stack)
    }

    private func restart() {
        screen = nil
        index = 0
        playing = true
        run += 1
    }

    private func play() async {
        if screen == nil { screen = TerminalScreen(cols: UInt32(cast.width), rows: UInt32(cast.height), scrollback: 0) }
        guard let screen else { return }
        render(screen)
        while playing && index < cast.events.count && !Task.isCancelled {
            let ev = cast.events[index]
            let prev = index == 0 ? 0 : cast.events[index - 1].time
            try? await Task.sleep(nanoseconds: UInt64(Asciicast.wait(previous: prev, time: ev.time, speed: speed) * 1_000_000_000))
            if Task.isCancelled { return }
            switch ev {
            case .output(_, let data): _ = screen.feed(data: Data(data.utf8))
            case .resize(_, let c, let r): screen.resize(cols: UInt32(c), rows: UInt32(r))
            }
            index += 1
            render(screen)
        }
        if index >= cast.events.count { playing = false }
    }

    private func render(_ screen: TerminalScreen) {
        let s = screen.snapshot()
        lines = s.lines.map { line in
            var out = ""
            var col = 0
            for run in line.runs {
                let c = Int(run.col)
                if c > col { out += String(repeating: " ", count: c - col) }
                out += run.text
                col = c + Int(run.cells)
            }
            return out
        }
    }
}
