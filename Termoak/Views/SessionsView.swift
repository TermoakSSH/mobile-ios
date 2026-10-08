import TermoakKit
import SwiftUI

/// Connections tab: the terminals open on this device (tap to go back to
/// one, swipe to disconnect it) and, with an account, the AI tasks and the
/// sessions that live on the server.
struct ConnectionsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @EnvironmentObject private var sessions: Sessions
    @EnvironmentObject private var router: HomeRouter

    /// Server sessions of every signed-in account.
    @State private var lists: [AccountSessionList] = []
    @State private var terminating: AccountSession?
    @State private var closingAll = false
    @State private var error: String?
    @State private var hosts: [String: SshHost] = [:]
    /// One of your server sessions being shared (invitations sheet).
    @State private var sharing: SharingItem?
    /// One of your server sessions whose activity (who typed) is on screen.
    @State private var activity: SharingItem?

    private var serverEmpty: Bool {
        lists.allSatisfy { $0.list.active.isEmpty && $0.list.shared.isEmpty && $0.list.recent.isEmpty }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    if account.loggedIn == true {
                        NavigationLink { AiView() } label: { AiTasksRow(pending: account.pendingApprovals) }
                    }
                    Button { model.joining = JoinSheetItem(link: nil) } label: { JoinLinkRow() }
                        .buttonStyle(.plain)
                }
                if sessions.open.isEmpty && serverEmpty {
                    Section {
                        EmptyState(
                            icon: "terminal",
                            title: String(localized: "sessions.empty.title"),
                            text: account.loggedIn == true
                                ? String(localized: "sessions.empty.text_account")
                                : String(localized: "sessions.empty.text_local"),
                            action: String(localized: "connections.empty.action")
                        ) { router.tab = .vault }
                        .listRowBackground(Color.clear)
                    }
                }
                if !sessions.open.isEmpty {
                    Section("sessions.section.open_here") {
                        ForEach(sessions.open) { s in
                            OpenSessionRow(session: s, host: s.hostId.flatMap { hosts[itemKey(s.accountId, $0)] }) { sessions.show(s.id) }
                                .swipeActions {
                                    Button(role: .destructive) { sessions.close(s.id) } label: {
                                        Label("connections.disconnect", systemImage: "xmark.circle")
                                    }
                                }
                                .contextMenu {
                                    Button { sessions.show(s.id) } label: { Label("common.open", systemImage: "terminal") }
                                    Button(role: .destructive) { sessions.close(s.id) } label: {
                                        Label("connections.disconnect", systemImage: "xmark.circle")
                                    }
                                }
                        }
                    }
                }
                ForEach(lists) { item in
                    serverSections(item)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await load() }
            .navigationTitle("nav.connections")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if !sessions.open.isEmpty {
                        Menu {
                            Button(role: .destructive) { closingAll = true } label: {
                                Label("connections.disconnect_all", systemImage: "xmark.circle")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .alert("common.error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("common.ok", role: .cancel) {}
            } message: { Text(error ?? "") }
            .confirmationDialog("common.terminate_session.title", isPresented: Binding(get: { terminating != nil }, set: { if !$0 { terminating = nil } }),
                                titleVisibility: .visible) {
                Button("common.terminate", role: .destructive) {
                    guard let s = terminating else { return }
                    let api = model.core.api(for: s.accountId)
                    Task {
                        do { try await api.closeServerSession(sessionId: s.session.id) } catch { self.error = userMessage(error) }
                        await load()
                    }
                }
            } message: { Text("common.terminate_session.message") }
            .sheet(item: $sharing) { item in
                ShareSessionView(core: model.core, source: .server(sessionId: item.id, accountId: item.accountId), title: item.title)
            }
            .sheet(item: $activity) { item in
                SessionActivityView(core: model.core.api(for: item.accountId), sessionId: item.id, title: item.title)
            }
            .confirmationDialog("connections.disconnect_all.title", isPresented: $closingAll, titleVisibility: .visible) {
                Button("connections.disconnect_all", role: .destructive) { sessions.closeAll() }
            } message: { Text("connections.disconnect_all.message") }
        }
        .navigationViewStyle(.stack)
        .task { await load() }
        .onReceive(account.changes) { kind in
            if kind == "session" || kind == "lagged" { Task { await load() } }
        }
        .onChange(of: sessions.open.count) { _ in
            Task { await load() }
        }
    }

    /// Sections of one account's server sessions (the account's email in
    /// their titles when there are several).
    @ViewBuilder private func serverSections(_ item: AccountSessionList) -> some View {
        let list = item.list
        let accountId = item.accountId
        let several = lists.count > 1
        let canShare = accountId == account.current?.id
        if !list.active.isEmpty {
            Section {
                ForEach(list.active, id: \.id) { s in
                    ServerSessionRow(session: s, host: host(s.hostId, accountId)) { attach(s, accountId: accountId) }
                        .swipeActions {
                            Button("common.terminate", role: .destructive) { terminating = AccountSession(accountId: accountId, session: s) }
                            if canShare {
                                Button { share(s, accountId: accountId) } label: { Label("share.menu.share", systemImage: "person.badge.plus") }
                                    .tint(Brand.blue)
                            }
                        }
                        .contextMenu {
                            Button { attach(s, accountId: accountId) } label: { Label("common.open", systemImage: "terminal") }
                            if canShare {
                                Button { share(s, accountId: accountId) } label: { Label("share.menu.share", systemImage: "person.badge.plus") }
                            }
                            Button { showActivity(id: s.id, title: label(s, accountId), accountId: accountId) } label: {
                                Label("activity.menu", systemImage: "clock.arrow.circlepath")
                            }
                            Button(role: .destructive) { terminating = AccountSession(accountId: accountId, session: s) } label: {
                                Label("common.terminate", systemImage: "power")
                            }
                        }
                }
            } header: {
                sectionTitle(String(localized: "sessions.section.on_server"), item, several)
            }
        }
        if !list.shared.isEmpty {
            Section {
                ForEach(list.shared, id: \.id) { s in
                    ServerSessionRow(session: s, host: nil, shared: true) { attach(s, owner: false, accountId: accountId) }
                }
            } header: {
                sectionTitle(String(localized: "sessions.section.shared"), item, several)
            }
        }
        if !list.recent.isEmpty {
            Section {
                ForEach(list.recent.prefix(15), id: \.id) { r in
                    let title = r.title.isEmpty ? (host(r.hostId, accountId)?.label ?? String(localized: "common.session")) : r.title
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: title)
                            Text([recentStatusTitle(r.status), relativeTime(r.endedAt ?? r.createdAt), r.error ?? ""]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if r.recording {
                            Image(systemName: "record.circle").foregroundColor(.secondary)
                                .accessibilityLabel(Text("activity.recorded"))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if r.recording { showActivity(id: r.id, title: title, accountId: accountId) } }
                    .contextMenu {
                        if r.recording {
                            Button { showActivity(id: r.id, title: title, accountId: accountId) } label: {
                                Label("activity.menu", systemImage: "clock.arrow.circlepath")
                            }
                        }
                    }
                }
            } header: {
                sectionTitle(String(localized: "sessions.section.recent"), item, several)
            }
        }
    }

    /// Status of a finished session (`connecting`, `running`, `closed` or
    /// `failed`), translated when known.
    private func recentStatusTitle(_ status: String) -> String {
        switch status {
        case "connecting": return String(localized: "sessions.status.connecting")
        case "running": return String(localized: "sessions.status.running")
        case "closed": return String(localized: "sessions.status.closed")
        case "failed": return String(localized: "sessions.status.failed")
        default: return status
        }
    }

    private func sectionTitle(_ title: String, _ item: AccountSessionList, _ several: Bool) -> Text {
        several ? Text(verbatim: "\(title) · \(item.email)") : Text(verbatim: title)
    }

    private func host(_ hostId: String?, _ accountId: String) -> SshHost? {
        hostId.flatMap { hosts[itemKey(accountId, $0)] }
    }

    private func attach(_ s: ServerSession, owner: Bool = true, accountId: String) {
        let label = s.title.isEmpty ? (host(s.hostId, accountId)?.label ?? String(localized: "common.session")) : s.title
        // The host of a session shared with you is the owner's, not yours.
        sessions.attach(sessionId: s.id, label: label, hostId: owner ? s.hostId : nil, owner: owner, accountId: accountId)
    }

    private func share(_ s: ServerSession, accountId: String) {
        sharing = SharingItem(id: s.id, title: label(s, accountId), accountId: accountId)
    }

    private func label(_ s: ServerSession, _ accountId: String) -> String {
        s.title.isEmpty ? (host(s.hostId, accountId)?.label ?? String(localized: "common.session")) : s.title
    }

    /// Who typed in one of your sessions (open or closed).
    private func showActivity(id: String, title: String, accountId: String) {
        activity = SharingItem(id: id, title: title, accountId: accountId)
    }

    private func load() async {
        let everywhere = ItemFilter(accountIds: nil, vaultIds: nil, includeDevice: true)
        hosts = Dictionary(((try? model.core.listHosts(filter: everywhere)) ?? []).map { ($0.key, $0) },
                           uniquingKeysWith: { a, _ in a })
        var out: [AccountSessionList] = []
        for a in account.list where a.status == .active {
            do {
                let list = try await model.core.account(accountId: a.id).listServerSessions()
                out.append(AccountSessionList(accountId: a.id, email: a.email, list: list))
            } catch {
                self.error = userMessage(error)
            }
        }
        lists = out
    }
}

/// The server sessions of one account.
private struct AccountSessionList: Identifiable {
    let accountId: String
    let email: String
    let list: ServerSessionList
    var id: String { accountId }
}

/// One of your server sessions in the invitations sheet.
private struct SharingItem: Identifiable {
    let id: String
    let title: String
    let accountId: String?
}

/// "Join with link": open a session someone shared with an invitation link.
private struct JoinLinkRow: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "link")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(Brand.blue, in: RoundedRectangle(cornerRadius: 10.4, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("connections.join_link").font(.headline)
                Text("connections.join_link.subtitle").font(.subheadline).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Entry to the AI tasks, with the approvals that are waiting.
private struct AiTasksRow: View {
    let pending: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(Color.purple, in: RoundedRectangle(cornerRadius: 10.4, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("connections.ai_tasks").font(.headline)
                Text("connections.ai_tasks.subtitle").font(.subheadline).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if pending > 0 {
                Text(verbatim: "\(pending)").font(.caption.bold()).foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Brand.red, in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}

/// A terminal open on this device: host, status and how long it has been
/// connected.
private struct OpenSessionRow: View {
    @ObservedObject var session: TerminalSession
    let host: SshHost?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                HostIcon(label: session.label, os: host?.os, color: host?.color, icon: host?.icon, size: 42)
                    .overlay(alignment: .bottomTrailing) { statusBadge.offset(x: 4, y: 4) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title ?? session.label).font(.headline).foregroundColor(.primary).lineLimit(1)
                    Text(verbatim: address).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                    Label {
                        Text(verbatim: statusText)
                    } icon: {
                        Image(systemName: session.persistent ? "icloud" : "iphone")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let since = session.connectedAt, !session.asleep {
                    Text(since, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `user@address` of the host, or "server session".
    private var address: String {
        if let host {
            return (host.settings.username.map { "\($0)@" } ?? "") + host.address
        }
        return session.persistent ? String(localized: "terminal.server_session_lower") : ""
    }

    @ViewBuilder private var statusBadge: some View {
        if session.asleep {
            Image(systemName: "icloud.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 16, height: 16)
                .background(Color.gray, in: Circle())
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
        } else {
            Circle()
                .fill(color)
                .frame(width: 13, height: 13)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
        }
    }

    private var statusText: String {
        if session.asleep { return String(localized: "sessions.row.asleep") }
        switch session.state {
        case .connected:
            return session.persistent ? String(localized: "sessions.row.connected_server") : String(localized: "sessions.row.connected_local")
        case .connecting(let m): return m
        case .closed(let m): return m
        }
    }

    private var color: Color {
        switch session.state {
        case .connected: return Brand.green
        case .connecting: return Brand.amber
        case .closed: return Brand.red
        }
    }
}

/// A session that lives on the server (yours or shared with you).
private struct ServerSessionRow: View {
    let session: ServerSession
    let host: SshHost?
    /// Shared with you: who shares it and what you can do.
    var shared = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                HostIcon(label: host.map { $0.label.isEmpty ? $0.address : $0.label } ?? session.title,
                         os: host?.os, color: host?.color, icon: host?.icon, size: 42)
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(color)
                            .frame(width: 13, height: 13)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                            .offset(x: 4, y: 4)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title.isEmpty ? (host?.label ?? String(localized: "common.session")) : session.title)
                        .font(.headline).foregroundColor(.primary).lineLimit(1)
                    if shared {
                        Text(verbatim: sharedText)
                            .font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                    }
                    Text(text + " · " + relativeTime(session.createdAt)
                         + (people > 1 ? " · " + String(localized: "sessions.viewers \(people)") : ""))
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: shared ? "person.2" : "icloud").foregroundColor(.secondary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// People inside (servers before 0.3 only report sockets).
    private var people: Int {
        session.participants.isEmpty ? session.viewers.count : session.participants.filter { !$0.waiting }.count
    }

    /// "Ana · Can request control".
    private var sharedText: String {
        let access = session.access.shareLabel
        guard let owner = session.sharedBy, !owner.isEmpty else { return access }
        return String(localized: "sessions.shared_by \(owner)") + " · " + access
    }

    private var text: String {
        switch session.state {
        case .running: return String(localized: "sessions.state.running")
        case .connecting(let m): return m
        case .hostOffline: return String(localized: "sessions.state.host_offline")
        case .closed(_, let reason): return reason ?? String(localized: "sessions.state.closed")
        }
    }

    private var color: Color {
        switch session.state {
        case .running: return Brand.green
        case .connecting, .hostOffline: return Brand.amber
        case .closed: return Brand.red
        }
    }
}
