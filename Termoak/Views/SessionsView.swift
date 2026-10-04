import TermoakKit
import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Account
    @EnvironmentObject private var sessions: Sessions

    @State private var list: ServerSessionList?
    @State private var loading = false
    @State private var terminating: ServerSession?
    @State private var error: String?
    @State private var hosts: [String: SshHost] = [:]

    var body: some View {
        NavigationView {
            List {
                if !sessions.open.isEmpty {
                    Section("sessions.section.open_here") {
                        ForEach(sessions.open) { s in
                            OpenSessionRow(session: s) { sessions.show(s.id) }
                            .swipeActions { Button("common.close", role: .destructive) { sessions.close(s.id) } }
                        }
                    }
                }
                if account.loggedIn == true {
                    if let active = list?.active, !active.isEmpty {
                        Section("sessions.section.on_server") {
                            ForEach(active, id: \.id) { s in
                                ServerSessionRow(session: s, host: hosts[s.hostId ?? ""]?.label) { attach(s) }
                                    .swipeActions {
                                        Button("common.terminate", role: .destructive) { terminating = s }
                                    }
                            }
                        }
                    }
                    if let shared = list?.shared, !shared.isEmpty {
                        Section("sessions.section.shared") {
                            ForEach(shared, id: \.id) { s in
                                ServerSessionRow(session: s, host: hosts[s.hostId ?? ""]?.label) { attach(s) }
                            }
                        }
                    }
                    if let recent = list?.recent, !recent.isEmpty {
                        Section("sessions.section.recent") {
                            ForEach(recent.prefix(15), id: \.id) { r in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.title.isEmpty ? (hosts[r.hostId ?? ""]?.label ?? String(localized: "common.session")) : r.title)
                                    Text([r.status, relativeTime(r.endedAt ?? r.createdAt), r.error ?? ""]
                                        .filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if sessions.open.isEmpty && (list.map { $0.active.isEmpty && $0.shared.isEmpty && $0.recent.isEmpty } ?? true) {
                    EmptyState(
                        icon: "terminal",
                        title: String(localized: "sessions.empty.title"),
                        text: account.loggedIn == true
                            ? String(localized: "sessions.empty.text_account")
                            : String(localized: "sessions.empty.text_local")
                    )
                }
            }
            .refreshable { await load() }
            .navigationTitle("nav.sessions")
            .toolbar { MenuButton() }
            .alert("common.error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("common.ok", role: .cancel) {}
            } message: { Text(error ?? "") }
            .confirmationDialog("common.terminate_session.title", isPresented: Binding(get: { terminating != nil }, set: { if !$0 { terminating = nil } }),
                                titleVisibility: .visible) {
                Button("common.terminate", role: .destructive) {
                    guard let s = terminating else { return }
                    Task {
                        do { try await model.core.closeServerSession(sessionId: s.id) } catch { self.error = errorMessage(error) }
                        await load()
                    }
                }
            } message: { Text("common.terminate_session.message") }
        }
        .navigationViewStyle(.stack)
        .task { await load() }
        .onReceive(account.changes) { kind in
            if kind == "session" || kind == "lagged" { Task { await load() } }
        }
    }

    private func attach(_ s: ServerSession) {
        let label = s.title.isEmpty ? (hosts[s.hostId ?? ""]?.label ?? String(localized: "common.session")) : s.title
        sessions.attach(sessionId: s.id, label: label, hostId: s.hostId)
    }

    private func load() async {
        hosts = Dictionary(((try? model.core.listHosts()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard account.loggedIn == true else { return }
        loading = true
        defer { loading = false }
        do {
            list = try await model.core.listServerSessions()
        } catch {
            self.error = errorMessage(error)
        }
    }
}

private struct OpenSessionRow: View {
    @ObservedObject var session: TerminalSession
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: session.persistent ? "icloud" : "iphone").foregroundColor(color).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title ?? session.label).foregroundColor(.primary)
                    Text(text).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var text: String {
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

private struct ServerSessionRow: View {
    let session: ServerSession
    let host: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "icloud").foregroundColor(color).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title.isEmpty ? (host ?? String(localized: "common.session")) : session.title).foregroundColor(.primary)
                    Text(text + " · " + relativeTime(session.createdAt)
                         + (session.viewers.count > 1 ? " · " + String(localized: "sessions.viewers \(session.viewers.count)") : ""))
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
        }
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
