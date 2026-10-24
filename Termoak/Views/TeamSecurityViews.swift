import TermoakKit
import SwiftUI

// Teams security (0.7 phase 4d): the SSH CA panel (a team's in Teams →
// Security, yours in Settings → SSH certificates), the team policy, 2FA
// compliance and principals, issued certificates and the connection's
// certificates.

/// The SSH certificate authority of a team (or, with `teamId == nil`, your
/// personal one): create it, its fingerprint, public key and `sshd_config`
/// lines, the install command (the script in a heredoc: `install.sh` needs
/// a manager's token, so a host can't fetch it with `curl … | sh`) to copy
/// or share, rotate, disable, issued certificates and revocation.
struct CAPanel: View {
    let accountId: String
    let teamId: String?
    let teamName: String?

    @EnvironmentObject private var model: AppModel
    @State private var overview: CaOverview?
    @State private var error: String?
    @State private var busy = false
    @State private var algorithm = "ed25519"
    @State private var krl = true
    @State private var principals = false
    @State private var refresh = true
    @State private var command: String?
    @State private var copied: String?
    @State private var rotating = false
    @State private var overlap = "24"
    @State private var disabling = false
    @State private var typed = ""
    @State private var revokingKey = false
    @State private var keyText = ""

    private var handle: AccountHandle? { try? model.core.account(accountId: accountId) }
    private var personal: Bool { teamId == nil }

    var body: some View {
        Section {
            Text(personal ? LocalizedStringKey("ca.hint_personal") : LocalizedStringKey("ca.hint_team")).font(.footnote).foregroundColor(.secondary)
            if let error { Text(verbatim: error).foregroundColor(Brand.red) }
            if let o = overview {
                if let ca = o.ca {
                    HStack {
                        Text("ca.status.active").font(.caption.weight(.semibold)).foregroundColor(Brand.green)
                        Text(verbatim: "\(ca.algorithm) · " + String(localized: "ca.created_at \(AccessTexts.date(ca.createdAt))"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    copyRow("ca.fingerprint", ca.fingerprint, done: String(localized: "ca.copied.fingerprint"))
                    copyRow("ca.public_key", ca.publicKey, done: String(localized: "ca.copied.public_key"))
                    ForEach(o.previous, id: \.id) { p in
                        Text(verbatim: String(localized: "ca.retiring \(p.fingerprint) \(p.retireAt.map(AccessTexts.dateTime) ?? "")"))
                            .font(.caption).foregroundColor(Brand.amber)
                    }
                    let lines = AccessRules.sshdLines(base: o.sshdConfig, optional: o.sshdConfigOptional, krl: krl, principals: principals)
                    copyRow("ca.sshd_config", lines.joined(separator: "\n"), done: String(localized: "ca.copied.sshd"))
                    Text(verbatim: String(localized: "ca.sshd_config_hint \(o.keysUrl)")).font(.caption).foregroundColor(.secondary)
                } else {
                    Text(personal ? LocalizedStringKey("ca.none_personal") : LocalizedStringKey("ca.none_team"))
                    if o.canManage {
                        Picker("ca.algorithm.label", selection: $algorithm) {
                            Text("ca.algorithm.ed25519").tag("ed25519")
                            Text("ca.algorithm.ecdsa").tag("ecdsa-p256")
                        }
                        Text("ca.algorithm.hint").font(.caption).foregroundColor(.secondary)
                        Button("ca.create") { act { _ = try await $0.createCa(teamId: teamId, algorithm: algorithm) } }.disabled(busy)
                    }
                }
            } else if error == nil {
                ProgressView()
            }
        } header: { Text("ca.title") }

        if let o = overview, o.ca != nil, o.canManage {
            Section {
                Toggle("ca.install.krl", isOn: $krl)
                Toggle("ca.install.principals", isOn: $principals)
                Toggle("ca.install.refresh", isOn: $refresh)
                Text(verbatim: "sudo sh -s <<'TERMOAK_CA' … TERMOAK_CA").font(.caption.monospaced()).foregroundColor(.secondary)
                Text("ca.install.hint").font(.caption).foregroundColor(.secondary)
                Button { withCommand { UIPasteboard.general.string = $0; copied = String(localized: "ca.copied.install") } } label: {
                    Label("ca.install.copy", systemImage: "doc.on.doc")
                }
                .disabled(busy)
                if let command {
                    ShareLink(item: command) { Label("ca.install.share", systemImage: "square.and.arrow.up") }
                } else {
                    Button { withCommand { _ in } } label: { Label("ca.install.share", systemImage: "square.and.arrow.up") }
                }
                if let copied { Text(verbatim: copied).font(.caption).foregroundColor(Brand.green) }
            } header: { Text("ca.install.title") }
            Section {
                NavigationLink { IssuedCertificatesView(accountId: accountId, teamId: teamId) } label: { Label("ca.certs.open", systemImage: "list.bullet.rectangle") }
                Button { revokingKey = true } label: { Label("ca.revoke_key.button", systemImage: "key.slash") }
                Button { rotating = true } label: { Label("ca.rotate.button", systemImage: "arrow.triangle.2.circlepath") }
                Button(role: .destructive) { disabling = true } label: { Label("ca.disable.button", systemImage: "xmark.shield") }
            }
        }
        EmptyView()
            .task(id: accountId + (teamId ?? "")) { await load() }
            .onChange(of: krl) { _ in command = nil }
            .onChange(of: principals) { _ in command = nil }
            .onChange(of: refresh) { _ in command = nil }
            .alert(Text("ca.rotate.title"), isPresented: $rotating) {
                TextField("ca.rotate.overlap", text: $overlap).keyboardType(.numberPad)
                Button("ca.rotate.ok") {
                    guard let h = AccessRules.number(overlap, in: 1...720) else { error = String(localized: "ca.rotate.overlap_error"); return }
                    act { _ = try await $0.rotateCa(teamId: teamId, overlapHours: UInt32(h)) }
                }
                Button("common.cancel", role: .cancel) {}
            } message: { Text("ca.rotate.message") }
            .alert(Text("ca.disable.title"), isPresented: $disabling) {
                TextField(personal ? "personal" : (teamName ?? ""), text: $typed)
                Button("ca.disable.ok", role: .destructive) {
                    let word = personal ? "personal" : (teamName ?? "")
                    guard typed.trimmingCharacters(in: .whitespaces) == word else { error = String(localized: "ca.disable.mismatch"); return }
                    act { try await $0.disableCa(teamId: teamId, confirm: word) }
                }
                Button("common.cancel", role: .cancel) {}
            } message: { Text(verbatim: String(localized: "ca.disable.message") + "\n" + String(localized: "ca.disable.type \(personal ? "personal" : (teamName ?? ""))")) }
            .alert(Text("ca.revoke_key.title"), isPresented: $revokingKey) {
                TextField("ca.revoke_key.key", text: $keyText)
                Button("ca.revoke_key.ok", role: .destructive) {
                    guard AccessRules.looksLikePublicKey(keyText) else { error = String(localized: "ca.revoke_key.invalid"); return }
                    let key = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
                    act { _ = try await $0.revokeCertificates(teamId: teamId, target: .publicKey(publicKey: key), reason: nil) }
                }
                Button("common.cancel", role: .cancel) {}
            } message: { Text("ca.revoke_key.message") }
    }

    private func copyRow(_ label: LocalizedStringKey, _ value: String, done: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption).foregroundColor(.secondary)
                Spacer()
                Button { UIPasteboard.general.string = value; copied = done } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
            }
            Text(verbatim: value).font(.caption.monospaced()).textSelection(.enabled).lineLimit(6)
        }
    }

    private func load() async {
        guard let h = handle else { return }
        do {
            overview = try await h.caInfo(teamId: teamId)
            error = nil
        } catch {
            self.error = userMessage(error)
        }
    }

    private func act(_ call: @escaping (AccountHandle) async throws -> Void) {
        guard let h = handle else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await call(h)
                await load()
            } catch {
                self.error = userMessage(error)
            }
        }
    }

    /// The install command for the chosen options (fetched once per choice).
    private func withCommand(_ use: @escaping (String) -> Void) {
        if let command { use(command); return }
        guard let h = handle else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let c = AccessRules.installCommand(try await h.caInstallScript(teamId: teamId, krl: krl, principals: principals, refresh: refresh))
                command = c
                use(c)
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}

/// Teams → a team → Security: the CA, the team policy (read-only for
/// members) and, for owners and admins, 2FA compliance and principals.
struct TeamSecurityView: View {
    let accountId: String
    let teamId: String
    let teamName: String
    let canManage: Bool

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @State private var policy: TeamSecurityPolicy?
    @State private var members: [TeamComplianceMember] = []
    @State private var error: String?
    @State private var saved = false
    @State private var editing: TeamComplianceMember?
    @State private var principal = ""

    private var handle: AccountHandle? { try? model.core.account(accountId: accountId) }

    var body: some View {
        Form {
            if !canManage { Section { Text("team_security.read_only").font(.footnote).foregroundColor(.secondary) } }
            CAPanel(accountId: accountId, teamId: teamId, teamName: teamName)
            if let p = Binding($policy) {
                TeamPolicySections(policy: p, canManage: canManage) { save() }
                if saved { Section { Text("team_security.saved").foregroundColor(Brand.green) } }
            }
            if canManage && !members.isEmpty {
                Section {
                    let missing = members.filter { !$0.totpEnabled }.count
                    Text(verbatim: missing == 0 ? String(localized: "team_security.compliance.all")
                         : String(localized: "team_security.compliance.missing \(missing)"))
                        .font(.footnote).foregroundColor(.secondary)
                    ForEach(members, id: \.userId) { m in
                        Button { editing = m; principal = m.principal ?? "" } label: { ComplianceRow(member: m) }
                    }
                } header: { Text("team_security.compliance.title") }
            }
            if let error { Section { Text(verbatim: error).foregroundColor(Brand.red) } }
        }
        .navigationTitle(Text(verbatim: String(localized: "team_security.title \(teamName)")))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert(Text(verbatim: String(localized: "team_security.principal.title \(editing?.email ?? "")")),
               isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField(AccessRules.defaultPrincipal(editing?.email ?? ""), text: $principal)
            Button("common.save") { if let m = editing { setPrincipal(m) } }
            Button("common.cancel", role: .cancel) {}
        } message: { Text(verbatim: String(localized: "team_security.principal.message \(AccessRules.defaultPrincipal(editing?.email ?? ""))")) }
    }

    private func load() async {
        guard let h = handle else { return }
        do {
            policy = try await h.teamPolicy(teamId: teamId)
        } catch {
            self.error = userMessage(error)
        }
        if canManage { members = (try? await h.teamCompliance(teamId: teamId)) ?? [] }
    }

    private func save() {
        guard let h = handle, let p = policy else { return }
        saved = false
        error = nil
        Task {
            do {
                policy = try await h.setTeamPolicy(teamId: teamId, policy: p)
                saved = true
                account.sync(accountId)
                if canManage { members = (try? await h.teamCompliance(teamId: teamId)) ?? members }
            } catch {
                self.error = userMessage(error)
            }
        }
    }

    private func setPrincipal(_ m: TeamComplianceMember) {
        let v = principal.trimmingCharacters(in: .whitespaces)
        guard v.isEmpty || AccessRules.principalValid(v) else { error = String(localized: "team_security.principal.invalid"); return }
        guard let h = handle else { return }
        Task {
            do {
                try await h.setMemberPrincipal(teamId: teamId, userId: m.userId, principal: v.isEmpty ? nil : v)
                members = (try? await h.teamCompliance(teamId: teamId)) ?? members
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}

private struct ComplianceRow: View {
    let member: TeamComplianceMember

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: member.name.isEmpty ? member.email : member.name).foregroundColor(.primary)
                Text(verbatim: String(localized: "team_security.compliance.principal \(member.email) \(member.principal ?? AccessRules.defaultPrincipal(member.email))"))
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if member.totpEnabled {
                Text("team_security.compliance.on").font(.caption2.weight(.semibold)).foregroundColor(Brand.green)
            } else if member.blocked {
                Text("team_security.compliance.blocked").font(.caption2.weight(.semibold)).foregroundColor(Brand.red)
            } else if let d = member.deadline {
                Text(verbatim: String(localized: "team_security.compliance.until \(AccessTexts.date(d))")).font(.caption2.weight(.semibold)).foregroundColor(Brand.amber)
            } else {
                Text("team_security.compliance.off").font(.caption2.weight(.semibold)).foregroundColor(.secondary)
            }
        }
    }
}

/// The team policy form.
struct TeamPolicySections: View {
    @Binding var policy: TeamSecurityPolicy
    let canManage: Bool
    var onSave: () -> Void
    @State private var grace = ""
    @State private var defTtl = ""
    @State private var maxTtl = ""
    @State private var principals = ""
    @State private var source = ""

    var body: some View {
        Section {
            Toggle("team_security.require_2fa", isOn: $policy.require2fa)
            if policy.require2fa {
                TextField("team_security.grace_days", text: $grace).keyboardType(.numberPad)
            }
            Toggle("team_security.allow_reveal", isOn: $policy.allowReveal)
            Toggle("team_security.ai.allowed", isOn: $policy.aiAllowed)
            if policy.aiAllowed {
                Picker("team_security.ai.approval", selection: $policy.aiApproval) {
                    Text("team_security.ai.approval_default").tag(AiApprovalLevel.default)
                    Text("team_security.ai.approval_always").tag(AiApprovalLevel.always)
                }
            }
            Toggle("team_security.networks", isOn: $policy.networksAllowed)
            Toggle("team_security.record", isOn: $policy.recordSessions)
        } header: { Text("team_security.policy_title") } footer: { Text("team_security.require_2fa_hint") }
        .disabled(!canManage)
        Section {
            TextField("cert_fields.default_ttl", text: $defTtl).keyboardType(.numberPad)
            TextField("cert_fields.max_ttl", text: $maxTtl).keyboardType(.numberPad)
            TextField("cert_fields.principals", text: $principals).font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
            ForEach(certExtensions, id: \.self) { e in
                Toggle(isOn: Binding(get: { policy.certificates.extensions.contains(e) }, set: { on in
                    var l = policy.certificates.extensions.filter { $0 != e }
                    if on { l.append(e) }
                    policy.certificates.extensions = certExtensions.filter { l.contains($0) }
                })) { Text(verbatim: e).font(.callout.monospaced()) }
            }
            TextField("cert_fields.source_address", text: $source).font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: { Text("team_security.cert_defaults") } footer: { Text("cert_fields.principals_hint") }
        .disabled(!canManage)
        if canManage {
            Section {
                Button("team_security.save") { apply(); onSave() }
                    .disabled(AccessRules.number(grace, in: 0...90) == nil || AccessRules.number(defTtl, in: 1...1440) == nil
                              || AccessRules.number(maxTtl, in: 1...1440) == nil)
            }
        }
        EmptyView().onAppear { read() }
    }

    private func read() {
        grace = String(policy.graceDays)
        defTtl = String(policy.certificates.defaultTtlMinutes)
        maxTtl = String(policy.certificates.maxTtlMinutes)
        principals = policy.certificates.principals.joined(separator: ", ")
        source = policy.certificates.sourceAddress ?? ""
    }

    private func apply() {
        policy.graceDays = UInt32(AccessRules.number(grace, in: 0...90) ?? 7)
        policy.certificates.defaultTtlMinutes = UInt32(AccessRules.number(defTtl, in: 1...1440) ?? 60)
        policy.certificates.maxTtlMinutes = UInt32(AccessRules.number(maxTtl, in: 1...1440) ?? 480)
        let t = AccessRules.templates(principals)
        policy.certificates.principals = t.isEmpty ? ["{login}"] : t
        let s = source.trimmingCharacters(in: .whitespaces)
        policy.certificates.sourceAddress = s.isEmpty ? nil : s
    }
}

/// The certificate extensions a policy can choose.
let certExtensions = ["permit-pty", "permit-port-forwarding", "permit-agent-forwarding", "permit-X11-forwarding", "permit-user-rc"]

/// Settings → SSH certificates: your personal CA (for your personal vault's
/// hosts) and the certificates issued to you.
struct CertificatesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @ObservedObject private var book = AccessBook.shared
    @State private var accountId: String?
    @State private var mine: [IssuedCertificateInfo] = []

    private var accounts: [AccountInfo] { account.active.filter { book.isSupported($0.id) } }

    var body: some View {
        Form {
            if accounts.isEmpty {
                Section { Text("access.none_hint").foregroundColor(.secondary) }
            }
            if accounts.count > 1 {
                Section {
                    Picker("settings.account", selection: $accountId) {
                        ForEach(accounts, id: \.id) { a in Text(verbatim: a.displayName).tag(Optional(a.id)) }
                    }
                }
            }
            if let id = accountId ?? accounts.first?.id {
                CAPanel(accountId: id, teamId: nil, teamName: nil).id(id)
                Section {
                    if mine.isEmpty { Text("certs.mine_empty").foregroundColor(.secondary) }
                    ForEach(mine.prefix(30), id: \.serial) { c in CertificateRow(cert: c) }
                } header: { Text("certs.mine") }
                .task(id: id) { mine = ((try? await model.core.account(accountId: id).myCertificates()) ?? []).sorted { $0.createdAt > $1.createdAt } }
            }
        }
        .navigationTitle("settings.certificates")
    }
}

/// One issued certificate.
struct CertificateRow: View {
    let cert: IssuedCertificateInfo
    var onRevoke: (() -> Void)? = nil
    var onRevokeUser: (() -> Void)? = nil

    var body: some View {
        let now = nowMs()
        let expired = cert.validBefore <= now
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "#\(cert.serial) · \(cert.userEmail ?? cert.userId)").font(.subheadline).lineLimit(1)
            Text(verbatim: String(localized: "ca.cert.detail \(cert.principals.joined(separator: ", ")) \(AccessTexts.purpose(cert.purpose))"))
                .font(.caption)
            Text(verbatim: cert.revokedAt != nil ? String(localized: "ca.cert.revoked")
                 : expired ? String(localized: "ca.cert.expired") : String(localized: "ca.cert.until \(AccessTexts.dateTime(cert.validBefore))"))
                .font(.caption).foregroundColor(cert.revokedAt != nil || expired ? Brand.red : .secondary)
            Text(verbatim: cert.keyId).font(.caption2.monospaced()).foregroundColor(.secondary).lineLimit(1)
            if cert.revokedAt == nil && !expired {
                HStack {
                    if let onRevoke { Button("ca.revoke.serial", role: .destructive, action: onRevoke).buttonStyle(.borderless) }
                    if let onRevokeUser { Button("ca.revoke.user", role: .destructive, action: onRevokeUser).buttonStyle(.borderless) }
                }
                .font(.caption)
            }
        }
    }
}

/// Certificates the CA issued (only valid ones, or all), revoke one or all of a member's.
struct IssuedCertificatesView: View {
    let accountId: String
    let teamId: String?
    @EnvironmentObject private var model: AppModel
    @State private var activeOnly = true
    @State private var list: [IssuedCertificateInfo] = []
    @State private var error: String?

    var body: some View {
        List {
            Toggle("ca.certs.active_only", isOn: $activeOnly)
            if list.isEmpty { Text("ca.certs.empty").foregroundColor(.secondary) }
            ForEach(list, id: \.serial) { c in
                CertificateRow(cert: c, onRevoke: { revoke(.serial(serial: c.serial)) }, onRevokeUser: { revoke(.user(userId: c.userId)) })
            }
            if let error { Text(verbatim: error).foregroundColor(Brand.red) }
        }
        .navigationTitle("ca.certs.title")
        .task(id: activeOnly) { await load() }
    }

    private func load() async {
        do {
            list = try await model.core.account(accountId: accountId).caCertificates(teamId: teamId, userId: nil, activeOnly: activeOnly)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            self.error = userMessage(error)
        }
    }

    private func revoke(_ t: RevokeTarget) {
        Task {
            do {
                _ = try await model.core.account(accountId: accountId).revokeCertificates(teamId: teamId, target: t, reason: nil)
                await load()
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}

/// The team certificates issued to you for a host (the terminal's menu).
struct ConnectionCertificatesView: View {
    let host: SshHost
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var list: [IssuedCertificateInfo]?

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack { Text("conn_details.auth"); Spacer(); Text("conn_details.auth_cert").foregroundColor(.secondary) }
                }
                Section {
                    if let list {
                        if list.isEmpty { Text("certs.none_for_host").foregroundColor(.secondary) }
                        ForEach(list.prefix(5), id: \.serial) { c in CertificateRow(cert: c) }
                    } else {
                        ProgressView()
                    }
                } header: { Text("certs.for_host") }
            }
            .navigationTitle(Text(verbatim: String(localized: "conn_details.title \(host.displayName)")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } } }
            .task {
                guard let a = host.accountId else { list = []; return }
                list = ((try? await model.core.account(accountId: a).myCertificates()) ?? [])
                    .filter { $0.hostId == host.id }.sorted { $0.createdAt > $1.createdAt }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// "Access 42 min" and "Recorded" in the terminal's bar.
struct TerminalAccessPills: View {
    let accountId: String?
    let hostId: String?
    @ObservedObject private var book = AccessBook.shared

    var body: some View {
        HStack(spacing: 4) {
            if case .open(let end)? = book.window(accountId, hostId) {
                Ticking(every: 1) { now in
                    let left = AccessRules.remainingSecs(end, now: now)
                    Text(verbatim: left > 0 ? String(localized: "term.access_window \(AccessTexts.left(left))") : String(localized: "access.bar.ended"))
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(AccessRules.endingSoon(left) ? Brand.amber : Brand.green)
                }
            }
            if book.host(accountId, hostId)?.recordRequired == true { RecordedChip() }
        }
    }
}
