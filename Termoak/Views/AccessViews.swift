import TermoakKit
import SwiftUI
import Combine

// Teams security on the iPhone and iPad (0.7 phase 4d, TEAMS-SECURITY.md
// §13.2): the Access screen, Request access, the terminal's "Approval
// needed" card, the host chips with the countdown, the 2FA banner and the
// Authentication picker.

/// What the Access screen opens with (a tapped notification).
struct AccessFocus: Identifiable, Equatable {
    var requestId: String?
    var mine: Bool
    var decide: AccessDecision?
    var id: String { "\(requestId ?? "-")/\(mine)/\(String(describing: decide))" }
}

/// The current time (ms), ticking every second.
struct Ticking<Content: View>: View {
    var every: TimeInterval = 1
    @ViewBuilder let content: (Int64) -> Content
    @State private var now = nowMs()

    var body: some View {
        content(now)
            .onReceive(Timer.publish(every: every, on: .main, in: .common).autoconnect()) { _ in now = nowMs() }
    }
}

// MARK: - Chips

/// "Until 15:42 · 42 min" (amber in the last five minutes), "Waiting for
/// approval", "Approval needed".
struct AccessWindowChip: View {
    let window: HostWindow

    var body: some View {
        switch window {
        case .open(let end):
            Ticking(every: 1) { now in
                let left = AccessRules.remainingSecs(end, now: now)
                chip(String(localized: "access.chip.open \(AccessTexts.clock(end)) \(AccessTexts.left(left))"),
                     AccessRules.endingSoon(left) ? Brand.amber : Brand.green)
            }
        case .pending:
            chip(String(localized: "access.chip.pending"), Brand.amber)
        case .needed:
            chip(String(localized: "access.chip.needed"), .secondary)
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(verbatim: text)
            .font(.caption2.weight(.semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct RecordedChip: View {
    var body: some View {
        Text(verbatim: "● " + String(localized: "access.recorded"))
            .font(.caption2.weight(.semibold)).foregroundColor(Brand.red)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Brand.red.opacity(0.15), in: Capsule())
    }
}

struct ConnectOnlyBadge: View {
    var body: some View {
        Text("vaults.connect_only_badge")
            .font(.caption2.weight(.semibold)).foregroundColor(Brand.amber)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Brand.amber.opacity(0.15), in: Capsule())
    }
}

/// The access chips of a host row (nothing when none applies).
struct HostAccessChips: View {
    let host: SshHost
    @EnvironmentObject private var account: Accounts
    @ObservedObject private var book = AccessBook.shared

    var body: some View {
        let gates = account.gates(host.accountId, host.vaultId)
        let recorded = gates.recorded || book.host(host.accountId, host.id)?.recordRequired == true
        HStack(spacing: 4) {
            if let w = book.window(host.accountId, host.id) { AccessWindowChip(window: w) }
            if recorded { RecordedChip() }
            if host.access == .connectOnly { ConnectOnlyBadge() }
        }
        .task(id: host.key) {
            if let a = host.accountId, gates.accessRules { await book.ask(a, host.id) }
        }
    }
}

// MARK: - 2FA banner

/// Teams that require two-step verification from you: before the deadline
/// or blocked (their vaults hidden), with a link to set it up.
struct Team2faBanner: View {
    var onSetup: () -> Void
    @ObservedObject private var book = AccessBook.shared

    var body: some View {
        let all = book.team2faAll
        if !all.isEmpty {
            let blocked = all.filter { $0.req.blocked }
            let shown = blocked.isEmpty ? all : blocked
            let teams = shown.map(\.req.teamName).joined(separator: ", ")
            let color = blocked.isEmpty ? Brand.amber : Brand.red
            VStack(alignment: .leading, spacing: 6) {
                Label(blocked.isEmpty ? String(localized: "team_2fa.title \(teams)") : String(localized: "team_2fa.blocked_title \(teams)"),
                      systemImage: "exclamationmark.shield.fill")
                    .font(.subheadline.weight(.semibold)).foregroundColor(color)
                Text(verbatim: blocked.isEmpty
                     ? String(localized: "team_2fa.detail \(AccessTexts.date(shown.map(\.req.deadline).min() ?? 0))")
                     : String(localized: "team_2fa.blocked_detail"))
                    .font(.caption).foregroundColor(.secondary)
                Button("team_2fa.setup", action: onSetup).font(.caption.weight(.semibold))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Authentication picker

/// "Authentication" of a host or group: the group's (or password and key)
/// or "Team certificate"; a later version's value is kept. Says what is
/// inherited and warns when the vault's owner has no CA.
struct AuthPicker: View {
    @Binding var auth: String?
    let inherited: EffectiveAuth
    let certificates: Bool
    var enabled = true

    var body: some View {
        Picker("auth_field.label", selection: $auth) {
            Text("auth_field.inherit").tag(String?.none)
            Text("auth_field.team_certificate").tag(String?.some(AccessRules.teamCertificate))
            if let a = auth, a != AccessRules.teamCertificate {
                Text(verbatim: String(localized: "auth_field.other \(a)")).tag(String?.some(a))
            }
        }
        .disabled(!enabled)
        Text(verbatim: hint).font(.caption).foregroundColor(.secondary)
        if (auth ?? inherited.auth) == AccessRules.teamCertificate && !certificates {
            Text("auth_field.no_ca").font(.caption).foregroundColor(Brand.red)
        }
    }

    private var hint: String {
        if auth == AccessRules.teamCertificate { return String(localized: "auth_field.team_hint") }
        if auth != nil { return String(localized: "auth_field.other_hint") }
        if inherited.teamCertificate, let g = inherited.fromGroup { return String(localized: "auth_field.inherited \(g)") }
        return String(localized: "auth_field.keys_hint")
    }
}

// MARK: - Request access

/// "Request access to web1": how long (up to the policy's maximum), why,
/// and for what (this host, or every host its policy covers).
struct RequestAccessSheet: View {
    let accountId: String
    let hostId: String?
    let hostLabel: String
    let need: AccessNeed
    /// The names of the policy's group and vault (to offer them).
    var groupName: String?
    var vaultName: String?
    var onSent: (AccessRequestInfo) -> Void = { _ in }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 60
    @State private var reason = ""
    @State private var target = "host"
    @State private var busy = false
    @State private var error: String?

    private var choices: [Int] { AccessRules.durationChoices(need.maxMinutes) }
    private var problem: AccessRequestProblem? { AccessRules.requestProblem(minutes: minutes, max: need.maxMinutes, reason: reason) }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text(verbatim: String(localized: "access.request.message \(AccessTexts.duration(need.maxMinutes))"))
                    if !need.canRequest { Text("access.request.cannot").foregroundColor(Brand.red) }
                }
                Section {
                    Picker("access.request.duration", selection: $minutes) {
                        ForEach(choices, id: \.self) { m in Text(verbatim: AccessTexts.duration(m)).tag(m) }
                    }
                    TextField("access.request.reason_placeholder", text: $reason, axis: .vertical)
                        .lineLimit(2...5)
                    if problem == .reasonLong { Text("access.request.error.reason_long").font(.caption).foregroundColor(Brand.red) }
                } header: { Text("access.request.reason") }
                if need.targetKind != "host", need.targetId != nil {
                    Section {
                        Picker("access.request.scope", selection: $target) {
                            Text(verbatim: String(localized: "access.request.scope_host \(hostLabel)")).tag("host")
                            Text(need.targetKind == "group" ? LocalizedStringKey("access.request.scope_group") : LocalizedStringKey("access.request.scope_vault")).tag(need.targetKind)
                        }
                        .pickerStyle(.inline)
                    }
                }
                Section {
                    Text("access.request.after").font(.footnote).foregroundColor(.secondary)
                }
                if let error { Section { Text(verbatim: error).foregroundColor(Brand.red) } }
            }
            .navigationTitle(Text(verbatim: String(localized: "access.request.title \(hostLabel)")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("access.request.send") { send() }.disabled(busy || problem != nil || !need.canRequest)
                }
            }
            .onAppear { minutes = choices.first(where: { $0 >= 60 }) ?? choices.last ?? 60 }
        }
        .navigationViewStyle(.stack)
    }

    private func send() {
        guard let h = try? model.core.account(accountId: accountId) else { return }
        let kind = AccessTargetKind.of(target)
        let id = target == "host" ? (hostId ?? need.hostId ?? "") : (need.targetId ?? "")
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let r = try await h.createAccessRequest(targetKind: kind, targetId: id, minutes: UInt32(minutes),
                                                        reason: reason.trimmingCharacters(in: .whitespacesAndNewlines))
                AccessBook.shared.remember(accountId, r)
                if let hostId { await AccessBook.shared.ask(accountId, hostId, force: true) }
                onSent(r)
                dismiss()
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}

// MARK: - The terminal's card

/// A terminal that needs an approved window: Request access, then "Waiting
/// for approval" with Cancel request; it connects by itself when the window
/// opens.
struct TerminalAccessCard: View {
    let accountId: String?
    let hostId: String?
    let hostLabel: String
    let need: AccessNeed
    var onClose: () -> Void

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var book = AccessBook.shared
    @State private var asking = false

    private var access: HostAccessInfo? { book.host(accountId, hostId) }
    private var pendingId: String? { access?.pending?.id ?? need.pending }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: pendingId != nil ? "hourglass" : "lock.badge.clock")
                .font(.system(size: 40)).foregroundColor(Brand.amber)
            Text(pendingId != nil ? LocalizedStringKey("access.card.pending_title") : LocalizedStringKey("access.card.title")).font(.title3.weight(.semibold))
            Text(verbatim: pendingId != nil ? String(localized: "access.card.pending_text")
                 : String(localized: "access.card.text \(AccessTexts.duration(Int(access?.maxMinutes ?? UInt32(need.maxMinutes))))"))
                .font(.subheadline).multilineTextAlignment(.center).foregroundColor(.secondary)
            Text("access.card.auto").font(.caption).multilineTextAlignment(.center).foregroundColor(.secondary)
            if pendingId != nil { ProgressView() }
            HStack(spacing: 12) {
                Button("common.close", action: onClose).buttonStyle(.bordered)
                if let id = pendingId {
                    Button("access.request.cancel_request") { cancel(id) }.buttonStyle(.borderedProminent)
                } else if access?.canRequest ?? need.canRequest, accountId != nil {
                    Button("access.request.button") { asking = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
        .padding()
        .task { if let accountId, let hostId { await book.ask(accountId, hostId, force: true) } }
        .sheet(isPresented: $asking) {
            if let accountId {
                RequestAccessSheet(accountId: accountId, hostId: hostId, hostLabel: hostLabel, need: access?.need ?? need) { _ in
                    Task { await model.sessions.checkWaiting(accountId) }
                }
                .environmentObject(model)
            }
        }
    }

    private func cancel(_ id: String) {
        guard let accountId, let h = try? model.core.account(accountId: accountId) else { return }
        Task {
            if let r = try? await h.cancelAccessRequest(requestId: id) { book.remember(accountId, r) }
            if let hostId { await book.ask(accountId, hostId, force: true) }
        }
    }
}

// MARK: - The Access screen

/// Temporary access (as the desktop's Access section): requests waiting
/// for your decision (approve with a shorter window and a note, deny with a
/// reason), open windows you can end, recent decisions, and your own
/// requests (cancel, end). Read again on every `access_request` event. A
/// notification's Approve/Deny only opens the confirmation here.
struct AccessView: View {
    var focus: AccessFocus? = nil

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @ObservedObject private var book = AccessBook.shared
    @State private var tab = 0
    @State private var approving: (String, AccessRequestInfo)?
    @State private var denying: (String, AccessRequestInfo)?
    @State private var revoking: (String, AccessRequestInfo)?
    @State private var error: String?

    private var accounts: [AccountInfo] { account.active.filter { book.isSupported($0.id) } }

    var body: some View {
        Ticking(every: 1) { now in
            List {
                if accounts.isEmpty {
                    Section {
                        Text("access.none_title").font(.headline)
                        Text("access.none_hint").foregroundColor(.secondary)
                    }
                } else {
                    Section {
                        Picker("access.title", selection: $tab) {
                            Text(verbatim: String(localized: "access.waiting") + (book.waitingCount > 0 ? " (\(book.waitingCount))" : "")).tag(0)
                            Text("access.mine").tag(1)
                        }
                        .pickerStyle(.segmented)
                    }
                    if tab == 0 { approvalsSections(now) } else { mineSection(now) }
                }
                if let error { Section { Text(verbatim: error).foregroundColor(Brand.red) } }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("access.title")
        .refreshable { await reload() }
        .task {
            if focus?.mine == true { tab = 1 }
            await reload()
            openFocus()
        }
        .sheet(isPresented: Binding(get: { approving != nil }, set: { if !$0 { approving = nil } })) {
            if let pick = approving {
                let (a, r) = pick
                ApproveSheet(request: r) { minutes, note in
                    act(a) { h in try await h.approveAccessRequest(requestId: r.id, minutes: minutes < Int(r.minutes) ? UInt32(minutes) : nil,
                                                                   reason: note.isEmpty ? nil : note) }
                }
            }
        }
        .sheet(isPresented: Binding(get: { denying != nil }, set: { if !$0 { denying = nil } })) {
            if let pick = denying {
                let (a, r) = pick
                ReasonSheet(title: String(localized: "access.deny.title"), message: summary(r), confirm: String(localized: "access.deny.ok")) { reason in
                    act(a) { h in try await h.denyAccessRequest(requestId: r.id, reason: reason.isEmpty ? nil : reason) }
                }
            }
        }
        .sheet(isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            if let pick = revoking {
                let (a, r) = pick
                ReasonSheet(title: String(localized: "access.revoke.title"), message: String(localized: "access.revoke.hint"),
                            confirm: String(localized: "access.revoke.ok")) { reason in
                    act(a) { h in try await h.revokeAccessRequest(requestId: r.id, reason: reason.isEmpty ? nil : reason) }
                }
            }
        }
    }

    @ViewBuilder private func approvalsSections(_ now: Int64) -> some View {
        let waiting = accounts.flatMap { a in (book.approvals[a.id] ?? []).filter { $0.status == .pending && $0.canDecide }.map { (a.id, $0) } }
        let active = accounts.flatMap { a in (book.approvals[a.id] ?? []).filter { $0.isActive(now) && $0.canDecide }.map { (a.id, $0) } }
        let recent = accounts.flatMap { a in (book.approvals[a.id] ?? []).filter { $0.status != .pending && !($0.isActive(now) && $0.canDecide) }.map { (a.id, $0) } }.prefix(15)
        Section {
            if waiting.isEmpty { Text("access.waiting_empty").foregroundColor(.secondary) }
            ForEach(waiting, id: \.1.id) { a, r in
                AccessRequestRow(request: r, now: now, accountName: accountName(a))
                HStack {
                    Spacer()
                    Button("access.deny.button") { denying = (a, r) }.buttonStyle(.bordered)
                    Button("access.approve.button") { approving = (a, r) }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("approve-\(r.id)")
                }
            }
        } header: { Text("access.waiting") }
        Section {
            if active.isEmpty { Text("access.active_empty").foregroundColor(.secondary) }
            ForEach(active, id: \.1.id) { a, r in
                AccessRequestRow(request: r, now: now, accountName: accountName(a))
                    .swipeActions { Button("access.revoke.button", role: .destructive) { revoking = (a, r) } }
                Button("access.revoke.button", role: .destructive) { revoking = (a, r) }
            }
        } header: { Text("access.active") }
        if !recent.isEmpty {
            Section {
                ForEach(Array(recent), id: \.1.id) { a, r in AccessRequestRow(request: r, now: now, accountName: accountName(a)) }
            } header: { Text("access.recent") }
        }
    }

    @ViewBuilder private func mineSection(_ now: Int64) -> some View {
        let mine = accounts.flatMap { a in (book.mine[a.id] ?? []).map { (a.id, $0) } }
        Section {
            if mine.isEmpty { Text("access.mine_empty").foregroundColor(.secondary) }
            ForEach(mine, id: \.1.id) { a, r in
                AccessRequestRow(request: r, now: now, accountName: accountName(a), mine: true)
                if r.status == .pending || r.isActive(now) {
                    Button(r.isActive(now) ? LocalizedStringKey("access.end.button") : LocalizedStringKey("access.request.cancel_request"), role: .destructive) {
                        act(a) { h in try await h.cancelAccessRequest(requestId: r.id) }
                    }
                }
            }
        } header: { Text("access.mine") }
    }

    private func accountName(_ id: String) -> String? {
        accounts.count > 1 ? account.list.first { $0.id == id }?.displayName : nil
    }

    private func summary(_ r: AccessRequestInfo) -> String {
        String(localized: "access.summary \(r.requester) \(AccessTexts.targetLabel(r)) \(AccessTexts.duration(Int(r.minutes))) \(r.reason)")
    }

    private func reload() async {
        for a in accounts { await book.refresh(a.id) }
    }

    private func openFocus() {
        guard let f = focus, let id = f.requestId else { return }
        for a in accounts {
            if let r = (book.approvals[a.id] ?? []).first(where: { $0.id == id && $0.status == .pending && $0.canDecide }) {
                switch f.decide {
                case .approve?: approving = (a.id, r)
                case .deny?: denying = (a.id, r)
                case nil: break
                }
                return
            }
            if (book.mine[a.id] ?? []).contains(where: { $0.id == id }) { tab = 1 }
        }
    }

    private func act(_ accountId: String, _ call: @escaping (AccountHandle) async throws -> AccessRequestInfo) {
        guard let h = try? model.core.account(accountId: accountId) else { return }
        error = nil
        Task {
            do {
                _ = try await call(h)
                await book.onEvent(accountId)
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}

/// A request: what, who, how long, why, its state, window and decision.
struct AccessRequestRow: View {
    let request: AccessRequestInfo
    let now: Int64
    var accountName: String? = nil
    var mine = false

    var body: some View {
        let r = request
        let key = r.statusKey(now)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: AccessTexts.targetLabel(r)).font(.headline).lineLimit(1)
                Spacer()
                Text(verbatim: AccessTexts.status(key))
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(key == .pending ? Brand.amber : key == .active ? Brand.green : key == .denied || key == .revoked ? Brand.red : .secondary)
            }
            if !mine || accountName != nil {
                Text(verbatim: [mine ? nil : r.requester, accountName].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
            }
            Text(verbatim: "“\(r.reason)”").font(.subheadline)
            Text(verbatim: String(localized: "access.asked_for \(AccessTexts.duration(Int(r.minutes)))")
                 + (r.status == .pending ? " · " + String(localized: "access.waits_until \(AccessTexts.clock(r.expiresAt))") : ""))
                .font(.caption).foregroundColor(.secondary)
            if key == .active, let end = r.endsAt {
                let left = AccessRules.remainingSecs(end, now: now)
                Label(String(localized: "access.window.until \(AccessTexts.clock(end)) \(AccessTexts.left(left))"), systemImage: "timer")
                    .font(.caption).foregroundColor(AccessRules.endingSoon(left) ? Brand.amber : Brand.green)
            }
            if let who = r.decidedByName, !who.isEmpty, r.status != .pending {
                let note = r.decisionReason ?? ""
                Text(verbatim: note.isEmpty ? String(localized: "access.decided_by \(who)") : String(localized: "access.decision_note \(who) \(note)"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Approve: the request, the window (as asked or shorter; it starts now) and a note.
struct ApproveSheet: View {
    let request: AccessRequestInfo
    var onApprove: (Int, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 0
    @State private var note = ""

    var body: some View {
        let choices = AccessRules.durationChoices(max(Int(request.minutes), 1))
        NavigationView {
            Form {
                Section {
                    Text(verbatim: String(localized: "access.summary \(request.requester) \(AccessTexts.targetLabel(request)) \(AccessTexts.duration(Int(request.minutes))) \(request.reason)"))
                }
                Section {
                    Picker("access.approve.window", selection: $minutes) {
                        ForEach(choices, id: \.self) { m in Text(verbatim: AccessTexts.duration(m)).tag(m) }
                    }
                } footer: { Text("access.approve.window_hint") }
                Section {
                    TextField("access.approve.note_placeholder", text: $note)
                } header: { Text("access.approve.note") }
            }
            .navigationTitle("access.approve.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("access.approve.ok") { onApprove(minutes, note.trimmingCharacters(in: .whitespaces)); dismiss() }
                }
            }
            .onAppear { minutes = choices.last ?? Int(request.minutes) }
        }
        .navigationViewStyle(.stack)
    }
}

/// Deny or end a window: a text and an optional reason the requester sees.
struct ReasonSheet: View {
    let title: String
    let message: String
    let confirm: String
    var onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""

    var body: some View {
        NavigationView {
            Form {
                Section { Text(verbatim: message) }
                Section {
                    TextField("access.deny.reason_placeholder", text: $reason)
                } header: { Text("access.deny.reason") }
            }
            .navigationTitle(Text(verbatim: title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .destructive) { onConfirm(reason.trimmingCharacters(in: .whitespaces)); dismiss() } label: { Text(verbatim: confirm) }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
