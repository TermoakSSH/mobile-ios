import TermoakKit
import SwiftUI
import UIKit

/// What is shared: a session that lives on the server or a terminal of this
/// device (shared through the server, relay, when the first invitation is
/// created).
enum ShareSource {
    case server(sessionId: String)
    case local(LocalTerminal)
}

/// Share a session like Termius: invite by email, team or link, choose what
/// they can do, how long and whether you let them in; see, change and revoke
/// the invitations; stop sharing.
struct ShareSessionView: View {
    let core: TermoakCore
    let source: ShareSource
    let title: String
    @Environment(\.dismiss) private var dismiss

    private enum Target: Hashable {
        case link, people, team
    }

    @State private var target: Target = .link
    @State private var email = ""
    @State private var teams: [Team] = []
    @State private var teamId: String?
    @State private var control = false
    @State private var autoGrant = false
    /// "Limit automatic control to N minutes".
    @State private var limitControl = false
    @State private var controlLimit: UInt32 = 15
    @State private var expiry: ShareExpiry = .day
    /// "Ask me before letting people in": on for links unless changed by hand.
    @State private var askFirst = true
    @State private var askFirstTouched = false
    @State private var working = false
    @State private var error: String?
    @State private var invited: String?
    @State private var created: ShareInvite?
    @State private var copied = false
    @State private var showingActivity = false
    @State private var shares: [SessionShareInfo] = []
    @State private var editing: SessionShareInfo?
    @State private var stopping = false

    private var active: [SessionShareInfo] { shares.filter { $0.active } }

    private var canInvite: Bool {
        switch target {
        case .link: return true
        case .people:
            let e = email.trimmingCharacters(in: .whitespaces)
            return e.contains("@") && e.count > 3
        case .team: return teamId != nil
        }
    }

    /// The link to give: the web one (it explains how to join and opens the
    /// app) or else the app one.
    private var link: URL? {
        guard let created else { return nil }
        return (created.link ?? created.appLink).flatMap { URL(string: $0) }
    }

    var body: some View {
        NavigationView {
            Form {
                inviteSection
                optionsSection
                Section {
                    Button(action: invite) {
                        HStack {
                            Spacer()
                            if working {
                                ProgressView()
                            } else if target == .link {
                                Text("share.create_link").bold()
                            } else {
                                Text("share.invite").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canInvite || working)
                } footer: {
                    if let error {
                        Text(error).foregroundColor(Brand.red)
                    } else if let invited {
                        Text(invited).foregroundColor(Brand.green)
                    }
                }
                if let link {
                    linkSection(link)
                }
                activeSection
                if !active.isEmpty || isSharedHere {
                    Section {
                        Button(role: .destructive) { stopping = true } label: {
                            Label("share.stop", systemImage: "stop.circle")
                        }
                    } footer: {
                        Text("share.stop.footer")
                    }
                }
            }
            .navigationTitle("share.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
            .sheet(item: Binding(get: { editing.map(EditItem.init) }, set: { editing = $0?.share })) { item in
                ShareEditView(share: item.share, save: { changes in
                    guard let backend = currentBackend else { return }
                    _ = try await backend.update(item.share.id, changes)
                    await reload()
                }, revoke: { revoke(item.share) })
            }
            .sheet(isPresented: $showingActivity) {
                if let link { ActivityView(items: [link]) }
            }
            .confirmationDialog("share.stop.title", isPresented: $stopping, titleVisibility: .visible) {
                Button("share.stop", role: .destructive) { stopSharing() }
            } message: {
                Text("share.stop.message")
            }
            .onChange(of: target) { t in
                if !askFirstTouched { askFirst = t == .link }
                invited = nil
                error = nil
            }
            .task {
                await reload()
                teams = (try? await core.listTeams()) ?? []
                if teamId == nil { teamId = teams.first?.id }
            }
        }
        .navigationViewStyle(.stack)
    }

    // ----- Sections -----

    private var inviteSection: some View {
        Section {
            Picker("share.invite.target", selection: $target) {
                Text("share.target.link").tag(Target.link)
                Text("share.target.people").tag(Target.people)
                Text("share.target.team").tag(Target.team)
            }
            .pickerStyle(.segmented)
            switch target {
            case .link:
                Text("share.invite.link_hint").font(.footnote).foregroundColor(.secondary)
            case .people:
                TextField("share.invite.email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { if canInvite { invite() } }
            case .team:
                if teams.isEmpty {
                    Text("share.invite.no_teams").foregroundColor(.secondary)
                } else {
                    Picker("share.target.team", selection: $teamId) {
                        ForEach(teams, id: \.id) { t in
                            Text(verbatim: t.name).tag(t.id as String?)
                        }
                    }
                }
            }
        } header: {
            Text(verbatim: title)
        }
    }

    private var optionsSection: some View {
        Section {
            Picker("share.permission", selection: $control) {
                Text("share.permission.view").tag(false)
                Text("share.permission.control").tag(true)
            }
            if control {
                Toggle("share.auto_grant", isOn: $autoGrant)
                if autoGrant {
                    ControlLimitRows(on: $limitControl, minutes: $controlLimit)
                }
            }
            Toggle("share.ask_first", isOn: Binding(get: { askFirst }, set: { askFirst = $0; askFirstTouched = true }))
            Picker("share.expiry", selection: $expiry) {
                ForEach(ShareExpiry.allCases) { e in Text(e.title).tag(e) }
            }
        } footer: {
            if control {
                Text("share.permission.control_footer")
            } else {
                Text("share.permission.view_footer")
            }
        }
    }

    private func linkSection(_ url: URL) -> some View {
        Section {
            Text(verbatim: url.absoluteString)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
            Button {
                UIPasteboard.general.string = url.absoluteString
                copied = true
            } label: {
                if copied {
                    Label("share.link.copied", systemImage: "checkmark")
                } else {
                    Label("share.link.copy", systemImage: "doc.on.doc")
                }
            }
            shareButton(url)
            if let app = created?.appLink, app != url.absoluteString {
                Button {
                    UIPasteboard.general.string = app
                } label: {
                    Label("share.link.copy_app", systemImage: "app.badge")
                }
            }
        } header: {
            Text("share.link.header")
        } footer: {
            Text("share.link.footer")
        }
    }

    @ViewBuilder private func shareButton(_ url: URL) -> some View {
        if #available(iOS 16.0, *) {
            ShareLink(item: url) { Label("share.link.share", systemImage: "square.and.arrow.up") }
        } else {
            Button { showingActivity = true } label: { Label("share.link.share", systemImage: "square.and.arrow.up") }
        }
    }

    private var activeSection: some View {
        Section {
            if active.isEmpty {
                Text("share.active.empty").foregroundColor(.secondary)
            }
            ForEach(active, id: \.id) { s in
                Button { editing = s } label: { ShareRow(share: s) }
                    .swipeActions {
                        Button("share.revoke", role: .destructive) { revoke(s) }
                    }
            }
        } header: {
            Text("share.active.header")
        }
    }

    // ----- Actions -----

    /// The terminal of this device is already shared (relay).
    private var isSharedHere: Bool {
        if case .local(let t) = source { return t.shared != nil }
        return false
    }

    /// Where the invitations are, if there are any yet.
    private var currentBackend: ShareBackend? {
        switch source {
        case .server(let id): return .server(core, sessionId: id)
        case .local(let t): return t.shared.map { ShareBackend.relay($0) }
        }
    }

    /// Same, sharing the local terminal first if needed.
    private func backend() async throws -> ShareBackend {
        switch source {
        case .server(let id): return .server(core, sessionId: id)
        case .local(let t): return .relay(try await t.shareWithPeople())
        }
    }

    private func invite() {
        let t: ShareTarget
        switch target {
        case .link: t = .link
        case .people: t = .user(email: email.trimmingCharacters(in: .whitespaces))
        case .team:
            guard let teamId else { return }
            t = .team(teamId: teamId)
        }
        let options = ShareOptions(control: control, expiresInMinutes: expiry.minutes,
                                   requireApproval: askFirst, autoGrant: control && autoGrant,
                                   controlMinutes: control && autoGrant && limitControl ? controlLimit : nil)
        let kind = target
        let who = kind == .team ? teams.first(where: { $0.id == teamId })?.name ?? "" : email.trimmingCharacters(in: .whitespaces)
        working = true
        error = nil
        invited = nil
        Task {
            defer { working = false }
            do {
                let b = try await backend()
                let inv = try await b.invite(t, options)
                if kind == .link {
                    created = inv
                    copied = false
                } else {
                    email = ""
                    invited = String(localized: "share.invited \(who)")
                }
                await reload()
            } catch {
                self.error = errorMessage(error)
            }
        }
    }

    private func reload() async {
        guard let b = currentBackend else {
            shares = []
            return
        }
        do {
            shares = try await b.list()
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func revoke(_ s: SessionShareInfo) {
        guard let b = currentBackend else { return }
        Task {
            do {
                try await b.revoke(s.id)
            } catch {
                self.error = errorMessage(error)
            }
            await reload()
        }
    }

    private func stopSharing() {
        switch source {
        case .server(let id):
            Task {
                do {
                    _ = try await core.stopSharingServerSession(sessionId: id)
                } catch {
                    self.error = errorMessage(error)
                }
                created = nil
                await reload()
            }
        case .local(let t):
            // The relay stops: the guests leave, the terminal stays open here.
            t.act(.stopSharing)
            created = nil
            shares = []
        }
    }
}

private struct EditItem: Identifiable {
    let share: SessionShareInfo
    var id: String { share.id }
}

/// An invitation: who it is for and what it allows.
private struct ShareRow: View {
    let share: SessionShareInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: share.icon)
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: share.targetName).foregroundColor(.primary).lineLimit(1)
                Text(verbatim: details).font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if share.participants > 0 {
                Label {
                    Text(verbatim: "\(share.participants)")
                } icon: {
                    Image(systemName: "person.fill")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
    }

    private var details: String {
        var parts = [share.control ? String(localized: "share.permission.control") : String(localized: "share.permission.view")]
        if let e = share.expiresAt {
            parts.append(String(localized: "share.expires \(relativeTime(e))"))
        }
        if share.requireApproval { parts.append(String(localized: "share.row.asks_first")) }
        if share.control && share.autoGrant {
            if let m = share.controlMinutes {
                parts.append(String(localized: "share.row.auto_grant_limited \(Int(m))"))
            } else {
                parts.append(String(localized: "share.row.auto_grant"))
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// "Limit automatic control to N minutes" and, when on, how many.
private struct ControlLimitRows: View {
    @Binding var on: Bool
    @Binding var minutes: UInt32

    var body: some View {
        Toggle(String(localized: "share.control_limit \(Int(minutes))"), isOn: $on)
        if on {
            Picker("share.control_limit.time", selection: $minutes) {
                ForEach(controlLimits, id: \.self) { m in
                    Text(controlDurationTitle(m)).tag(m)
                }
            }
        }
    }
}

/// Changes an invitation live (whoever uses it gets the change at once).
private struct ShareEditView: View {
    let share: SessionShareInfo
    let save: (ShareChanges) async throws -> Void
    let revoke: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var control = false
    @State private var askFirst = false
    @State private var autoGrant = false
    @State private var limitControl = false
    @State private var controlLimit: UInt32 = 15
    /// `nil`: keep the current expiry.
    @State private var expiry: ShareExpiry?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: share.icon).foregroundColor(.accentColor).frame(width: 28)
                        Text(verbatim: share.targetName)
                    }
                    if share.participants > 0 {
                        Text(String(localized: "share.edit.inside \(Int(share.participants))")).foregroundColor(.secondary)
                    }
                }
                Section {
                    Picker("share.permission", selection: $control) {
                        Text("share.permission.view").tag(false)
                        Text("share.permission.control").tag(true)
                    }
                    if control {
                        Toggle("share.auto_grant", isOn: $autoGrant)
                        if autoGrant {
                            ControlLimitRows(on: $limitControl, minutes: $controlLimit)
                        }
                    }
                    Toggle("share.ask_first", isOn: $askFirst)
                    Picker("share.expiry", selection: $expiry) {
                        if let e = share.expiresAt {
                            Text(String(localized: "share.expires \(relativeTime(e))")).tag(ShareExpiry?.none)
                        } else {
                            Text("share.expiry.never").tag(ShareExpiry?.none)
                        }
                        ForEach(ShareExpiry.allCases) { e in
                            Text(e.title).tag(ShareExpiry?.some(e))
                        }
                    }
                } footer: {
                    if let error {
                        Text(error).foregroundColor(Brand.red)
                    } else if share.control && !control {
                        Text("share.edit.view_footer")
                    }
                }
                Section {
                    Button("share.revoke", role: .destructive) {
                        revoke()
                        dismiss()
                    }
                }
            }
            .navigationTitle("share.edit.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save", action: apply).disabled(working)
                }
            }
            .onAppear {
                control = share.control
                askFirst = share.requireApproval
                autoGrant = share.autoGrant
                limitControl = share.controlMinutes != nil
                controlLimit = share.controlMinutes ?? 15
            }
        }
    }

    private func apply() {
        // Without automatic grants the limit goes too.
        let limit: UInt32? = control && autoGrant && limitControl ? controlLimit : nil
        let changes = ShareChanges(
            control: control != share.control ? control : nil,
            expiresInMinutes: expiry?.minutes,
            noExpiry: expiry == .never,
            requireApproval: askFirst != share.requireApproval ? askFirst : nil,
            autoGrant: (control && autoGrant) != share.autoGrant ? (control && autoGrant) : nil,
            controlMinutes: limit != share.controlMinutes ? limit : nil,
            noControlLimit: limit == nil && share.controlMinutes != nil
        )
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await save(changes)
                dismiss()
            } catch {
                self.error = errorMessage(error)
            }
        }
    }
}
