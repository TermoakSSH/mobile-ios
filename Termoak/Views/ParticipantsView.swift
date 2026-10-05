import TermoakKit
import SwiftUI

// What a shared session shows in the terminal: the keyboard bar, the
// owner's requests, the waiting room, the end screens and the people.

/// Over the terminal: who has the keyboard (with Request / Release / Take
/// back), the requests waiting for the owner and short messages.
struct ShareBanners: View {
    @ObservedObject var session: TerminalSession
    let background: Color
    let onPeople: () -> Void

    private var live: Bool {
        session.waiting == nil && session.ended == nil && session.state == .connected && !session.asleep
    }

    var body: some View {
        // Compact, at the top right: the terminal stays readable.
        VStack(alignment: .trailing, spacing: 6) {
            if live {
                keyboardBar
                ForEach(Array(session.requests.prefix(2))) { r in
                    RequestBanner(request: r, session: session, background: background)
                }
                if session.requests.count > 2 {
                    Button(action: onPeople) {
                        Text(String(localized: "share.requests.more \(session.requests.count - 2)"))
                            .font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(background.opacity(0.95), in: Capsule())
                }
            }
            Spacer(minLength: 0)
            if let f = session.flash {
                Text(f)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 10).padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.2), value: session.flash)
        .animation(.easeOut(duration: 0.2), value: session.requests)
    }

    /// Guests: read-only or with the keyboard. Owner: someone else types.
    @ViewBuilder private var keyboardBar: some View {
        if !session.isOwner {
            bar {
                if session.canWrite {
                    Image(systemName: "keyboard.fill").foregroundColor(Brand.green)
                    Text("share.bar.you_have_control").font(.caption.weight(.semibold))
                    Button("share.release_control") { session.releaseControl() }
                        .font(.caption.weight(.semibold))
                } else {
                    Image(systemName: "eye.fill").foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("share.bar.view_only").font(.caption.weight(.semibold))
                        if let d = session.driverName, !d.isEmpty {
                            Text(String(localized: "share.driver.someone \(d)"))
                                .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                    if session.access == .control {
                        if session.requestedControl {
                            Text("share.bar.requested").font(.caption2).foregroundColor(.secondary)
                            Button("share.cancel_request") { session.releaseControl() }
                                .font(.caption.weight(.semibold))
                        } else {
                            Button("share.request_control") { session.requestControl() }
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
        } else if session.driverId != nil {
            bar {
                Image(systemName: "keyboard").foregroundColor(Brand.amber)
                Text(String(localized: "share.driver.someone \(session.driverName ?? String(localized: "share.someone"))"))
                    .font(.caption.weight(.semibold)).lineLimit(1)
                Button("share.take_back") { session.act(.takeControl) }
                    .font(.caption.weight(.semibold))
            }
        }
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(background.opacity(0.95), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }
}

/// Owner: someone waits to be let in or asks for the keyboard.
private struct RequestBanner: View {
    let request: ShareRequest
    let session: TerminalSession
    let background: Color

    var body: some View {
        HStack(spacing: 10) {
            ParticipantAvatar(name: request.participant.name, size: 28)
            Group {
                if request.kind == .join {
                    Text(String(localized: "share.request.join \(request.participant.name)"))
                } else {
                    Text(String(localized: "share.request.control \(request.participant.name)"))
                }
            }
            .font(.caption.weight(.medium))
            .lineLimit(2)
            Spacer(minLength: 4)
            Button {
                session.act(request.kind == .join ? OwnerAction.allowJoin(request.participant.id) : .grantControl(request.participant.id))
            } label: {
                if request.kind == .join { Text("share.allow") } else { Text("share.give_control") }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("share.deny") {
                session.act(request.kind == .join ? OwnerAction.denyJoin(request.participant.id) : .denyControl(request.participant.id))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(background.opacity(0.97), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Brand.amber.opacity(0.5)))
    }
}

/// Guest: waiting for the owner to let you in.
struct WaitingRoomCard: View {
    @ObservedObject var session: TerminalSession
    let room: WaitingRoom
    let background: Color
    let onLeave: () -> Void
    @AppStorage("share.guest_name") private var savedName = ""
    @State private var name = ""

    private var linkGuest: Bool { (session as? ServerTerminal)?.isLinkGuest == true }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "hourglass")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Text("share.waiting.title").font(.title3.weight(.semibold))
            Group {
                if room.owner.isEmpty {
                    Text("share.waiting.text_anonymous")
                } else {
                    Text(String(localized: "share.waiting.text \(room.owner)"))
                }
            }
            .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            if !room.title.isEmpty {
                Label(room.title, systemImage: "terminal").font(.footnote)
            }
            ProgressView().padding(.vertical, 4)
            if linkGuest {
                HStack {
                    TextField("share.join.name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.name)
                        .submitLabel(.done)
                        .onSubmit(rename)
                    Button("share.waiting.rename", action: rename)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Button("share.waiting.leave", role: .cancel, action: onLeave)
                .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: 420)
        .background(background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(24)
        .onAppear { name = savedName }
    }

    private func rename() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        savedName = n
        session.setGuestName(n)
    }
}

/// Guest: the server sent you away (revoked, kicked, expired...).
struct SessionEndedCard: View {
    let end: ShareEnd
    let background: Color
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: end.icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(end.code == "session_ended" ? .secondary : Brand.red)
                .frame(width: 64, height: 64)
                .background((end.code == "session_ended" ? Color.secondary : Brand.red).opacity(0.15), in: Circle())
            Text(end.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(end.text).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            Button("common.close", action: onClose)
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: 420)
        .background(background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(24)
    }
}

/// The people in a shared session: who has the keyboard, who asked for it,
/// who waits to come in, and the owner's actions.
struct ParticipantsSheet: View {
    @ObservedObject var session: TerminalSession
    /// The owner can invite more people from here.
    let canShare: Bool
    let onShare: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var stopping = false
    @State private var blocking: SessionParticipant?

    private var inside: [SessionParticipant] { session.participants.filter { !$0.waiting } }
    private var waiting: [SessionParticipant] { session.participants.filter { $0.waiting } }

    var body: some View {
        NavigationView {
            List {
                if session.isOwner && !waiting.isEmpty {
                    Section {
                        ForEach(waiting, id: \.id) { p in
                            HStack(spacing: 12) {
                                ParticipantAvatar(name: p.name, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: p.name).font(.body.weight(.medium)).lineLimit(1)
                                    Text(verbatim: subtitle(p)).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Button("share.allow") { session.act(.allowJoin(p.id)) }
                                    .buttonStyle(.borderedProminent).controlSize(.small)
                                Button("share.deny") { session.act(.denyJoin(p.id)) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    } header: {
                        Text("share.participants.waiting")
                    }
                }
                Section {
                    if inside.isEmpty {
                        Text("share.participants.empty").foregroundColor(.secondary)
                    }
                    ForEach(inside, id: \.id) { p in row(p) }
                } header: {
                    Text("share.participants.inside")
                } footer: {
                    if let d = session.driverName, session.driverId != nil {
                        Text(String(localized: "share.driver.someone \(d)"))
                    } else if !session.participants.isEmpty {
                        Text("share.driver.owner")
                    }
                }
                if session.isOwner {
                    Section {
                        if session.driverId != nil {
                            Button { session.act(.takeControl) } label: {
                                Label("share.take_back", systemImage: "keyboard")
                            }
                        }
                        if canShare {
                            Button(action: onShare) { Label("share.invite_people", systemImage: "person.badge.plus") }
                        }
                        if session.shareAttached && !session.others.isEmpty {
                            Button(role: .destructive) { stopping = true } label: {
                                Label("share.stop", systemImage: "stop.circle")
                            }
                        }
                    }
                } else {
                    Section {
                        if session.canWrite {
                            Button { session.releaseControl() } label: {
                                Label("share.release_control", systemImage: "keyboard.chevron.compact.down")
                            }
                        } else if session.access == .control {
                            if session.requestedControl {
                                Button { session.releaseControl() } label: {
                                    Label("share.cancel_request", systemImage: "xmark.circle")
                                }
                            } else {
                                Button { session.requestControl() } label: {
                                    Label("share.request_control", systemImage: "hand.raised")
                                }
                            }
                        } else {
                            Label("share.view_only_hint", systemImage: "eye")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("share.participants.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
            .confirmationDialog("share.stop.title", isPresented: $stopping, titleVisibility: .visible) {
                Button("share.stop", role: .destructive) { session.act(.stopSharing) }
            } message: {
                Text("share.stop.message")
            }
            .confirmationDialog("share.kick_block.title",
                                isPresented: Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } }),
                                titleVisibility: .visible, presenting: blocking) { p in
                Button("share.kick_block", role: .destructive) { session.act(.kick(p.id, block: true)) }
            } message: { p in
                Text(String(localized: "share.kick_block.message \(p.name)"))
            }
        }
        .navigationViewStyle(.stack)
    }

    private func row(_ p: SessionParticipant) -> some View {
        HStack(spacing: 12) {
            ParticipantAvatar(name: p.name, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: p.name).font(.body.weight(.medium)).lineLimit(1)
                    if p.you { Text("share.participants.you").font(.caption).foregroundColor(.secondary) }
                }
                Text(verbatim: subtitle(p)).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if p.requestedControl {
                Chip(String(localized: "share.participants.requested"), Brand.amber)
            }
            if p.isDriver {
                Image(systemName: "keyboard.fill")
                    .foregroundColor(Brand.green)
                    .accessibilityLabel(Text("share.participants.driver"))
            }
            if session.isOwner && p.kind != .owner && !p.you {
                ownerMenu(p)
            }
        }
        .padding(.vertical, 2)
    }

    private func ownerMenu(_ p: SessionParticipant) -> some View {
        Menu {
            if p.requestedControl {
                Button { session.act(.grantControl(p.id)) } label: { Label("share.give_control", systemImage: "keyboard") }
                Button { session.act(.denyControl(p.id)) } label: { Label("share.deny_request", systemImage: "hand.raised.slash") }
            } else if p.access == .control && !p.isDriver {
                Button { session.act(.grantControl(p.id)) } label: { Label("share.give_control", systemImage: "keyboard") }
            }
            if p.isDriver {
                Button { session.act(.takeControl) } label: { Label("share.take_back", systemImage: "arrow.uturn.backward") }
            }
            Divider()
            Button(role: .destructive) { session.act(.kick(p.id, block: false)) } label: {
                Label("share.kick", systemImage: "person.fill.xmark")
            }
            Button(role: .destructive) { blocking = p } label: {
                Label("share.kick_block", systemImage: "nosign")
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3)
        }
        .accessibilityLabel(Text("share.participants.actions"))
    }

    /// "Can request control · Guest · 2 devices · 5 min ago".
    private func subtitle(_ p: SessionParticipant) -> String {
        var parts: [String] = [p.kind == .owner ? String(localized: "share.access.owner") : p.access.shareLabel]
        if p.kind == .guest { parts.append(String(localized: "share.participants.guest")) }
        if p.devices > 1 { parts.append(String(localized: "share.participants.devices \(Int(p.devices))")) }
        let since = relativeTime(p.since)
        if !since.isEmpty && !p.waiting { parts.append(since) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Toasts of the whole app

/// Requests to join or for the keyboard of your sessions, and sessions
/// shared with you, over any screen.
struct ShareToasts: View {
    @ObservedObject var notices: ShareNotices

    var body: some View {
        VStack(spacing: 8) {
            ForEach(notices.toasts) { t in
                ShareToastRow(toast: t) { notices.dismiss(t.id) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: notices.toasts)
    }
}

private struct ShareToastRow: View {
    let toast: ShareToast
    let dismiss: () -> Void
    @EnvironmentObject private var sessions: Sessions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ParticipantAvatar(name: toast.name, size: 34)
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { actions }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("common.close"))
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }

    private var message: String {
        let title = toast.title.isEmpty ? String(localized: "common.session") : toast.title
        let name = toast.name.isEmpty ? String(localized: "share.someone") : toast.name
        switch toast.kind {
        case .join: return String(localized: "share.toast.join \(name) \(title)")
        case .control: return String(localized: "share.toast.control \(name) \(title)")
        case .shared: return String(localized: "share.toast.shared \(name) \(title)")
        }
    }

    @ViewBuilder private var actions: some View {
        if toast.kind != .shared, let p = toast.participantId,
           let tab = sessions.tab(forSession: toast.sessionId), tab.shareAttached, tab.isOwner {
            Button {
                tab.act(toast.kind == .join ? OwnerAction.allowJoin(p) : .grantControl(p))
                dismiss()
            } label: {
                if toast.kind == .join { Text("share.allow") } else { Text("share.give_control") }
            }
            .buttonStyle(.borderedProminent)
            Button("share.deny") {
                tab.act(toast.kind == .join ? OwnerAction.denyJoin(p) : .denyControl(p))
                dismiss()
            }
            .buttonStyle(.bordered)
        } else {
            Button("common.open") {
                sessions.openSession(toast.sessionId, title: toast.title, owner: toast.kind != .shared)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
