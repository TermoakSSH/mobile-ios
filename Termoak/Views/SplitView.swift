import TermoakKit
import SwiftUI
import UIKit

// MARK: - Panes

/// The terminal area: the focused terminal or, in the split view of an
/// iPad (regular width), up to four of the open terminals in a grid. The
/// panes are laid out by hand (frames) so a terminal never changes place in
/// the view tree: switching the focus or the focus mode only moves it.
struct PaneArea: View {
    @ObservedObject var focused: TerminalSession
    /// The people button of a pane's banners.
    let onPeople: (TerminalSession) -> Void
    @EnvironmentObject private var sessions: Sessions

    var body: some View {
        let panes = sessions.splitActive ? sessions.paneSessions : []
        let split = panes.contains(where: { $0.id == focused.id })
        let shown = split ? panes : [focused]
        let focusIx = shown.firstIndex(where: { $0.id == focused.id })
        let gap: CGFloat = split ? 6 : 0
        GeometryReader { geo in
            let frames = PaneLayout.frames(count: shown.count, focused: focusIx, focusMode: split && sessions.focusMode,
                                           in: geo.size, spacing: gap)
            ZStack(alignment: .topLeading) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                    PaneView(session: s, split: split, focused: s.id == focused.id) { onPeople(s) }
                        .frame(width: frames[i].width, height: frames[i].height)
                        .position(x: frames[i].midX, y: frames[i].midY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .padding(gap)
    }
}

/// A terminal of the area: in the split view with a small header (title and
/// actions) and a border (accent when focused, orange while it receives the
/// broadcast).
private struct PaneView: View {
    @ObservedObject var session: TerminalSession
    let split: Bool
    let focused: Bool
    let onPeople: () -> Void
    @EnvironmentObject private var sessions: Sessions
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let theme = session.theme
        VStack(spacing: 0) {
            if split { header(theme) }
            SessionStage(session: session, compact: split, onPeople: onPeople)
        }
        .background(theme.backgroundColor)
        .overlay {
            if split {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(borderColor(theme), lineWidth: focused || receives ? 2 : 1)
                    .allowsHitTesting(false)
            }
        }
    }

    private var receives: Bool { sessions.receivesBroadcast(session) }
    private var excluded: Bool { sessions.broadcastActive && !receives }

    private func borderColor(_ theme: TerminalTheme) -> Color {
        if receives { return Color.orange }
        if focused { return SwiftUI.Color(hex: theme.accent) }
        return theme.foregroundColor.opacity(0.15)
    }

    private func header(_ theme: TerminalTheme) -> some View {
        HStack(spacing: 6) {
            Circle().fill(stateColor).frame(width: 7, height: 7)
            if session.persistent { Image(systemName: "icloud").font(.caption2).foregroundColor(.secondary) }
            Text(session.displayTitle)
                .font(.caption.weight(focused ? .semibold : .regular))
                .lineLimit(1)
                .foregroundColor(theme.foregroundColor.opacity(focused ? 1 : 0.7))
            if receives {
                Image(systemName: "dot.radiowaves.left.and.right").font(.caption2).foregroundColor(.orange)
                    .accessibilityLabel("split.broadcast.receives")
            } else if excluded {
                Image(systemName: "speaker.slash").font(.caption2).foregroundColor(.secondary)
                    .accessibilityLabel("split.broadcast.excluded")
            }
            Spacer(minLength: 4)
            Menu { menu } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("split.pane.actions")
        }
        .padding(.leading, 8)
        .frame(height: 28)
        .background(theme.barColor)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .onTapGesture { sessions.focus(session.id) }
    }

    @ViewBuilder private var menu: some View {
        if !focused {
            Button { sessions.focus(session.id) } label: { Label("split.pane.focus", systemImage: "scope") }
        }
        if sessions.focusMode && focused {
            Button { sessions.focusMode = false } label: {
                Label("split.focus_mode.off", systemImage: "arrow.down.right.and.arrow.up.left")
            }
        } else {
            Button {
                sessions.focus(session.id)
                sessions.focusMode = true
            } label: {
                Label("split.focus_mode", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
        if sessions.broadcasting {
            Button { sessions.toggleExcluded(session.id) } label: {
                if sessions.broadcastExcluded.contains(session.id) {
                    Label("split.broadcast.include", systemImage: "dot.radiowaves.left.and.right")
                } else {
                    Label("split.broadcast.exclude", systemImage: "speaker.slash")
                }
            }
        }
        Divider()
        Button { sessions.removePane(session.id) } label: { Label("split.remove_pane", systemImage: "minus.rectangle") }
        Button(role: .destructive) { sessions.close(session.id) } label: {
            Label(session.persistent ? String(localized: "terminal.menu.close_tab_persistent") : String(localized: "common.close"),
                  systemImage: "xmark")
        }
    }

    private var stateColor: Color {
        if session.asleep { return .secondary }
        switch session.state {
        case .connected: return Brand.green
        case .connecting: return Brand.amber
        case .closed: return Brand.red
        }
    }
}

// MARK: - A terminal and what goes over it

/// A terminal with what goes over it: suggestions, sharing banners, the
/// connection card (steps or error), the cursor pad... Each terminal keeps
/// its own connection steps.
struct SessionStage: View {
    @ObservedObject var session: TerminalSession
    /// In a pane of the split view: smaller cards.
    let compact: Bool
    let onPeople: () -> Void
    @EnvironmentObject private var sessions: Sessions
    @EnvironmentObject private var model: AppModel
    /// Connection steps (like Termius' connection screen).
    @State private var steps: [String] = []
    @State private var didConnect = false
    /// The host opened in the editor from the failure card.
    @State private var editingHost: HostEdit?
    @EnvironmentObject private var account: Accounts

    private var theme: TerminalTheme { session.theme }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SwiftTermView(viewport: session.viewport, onTap: { sessions.focus(session.id) })
            CursorSuggestions(session: session)
            ShareBanners(session: session, background: theme.barColor, onPeople: onPeople)
            notice.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let p = session.cursorPad {
                CursorPadView(pad: p, accent: SwiftUI.Color(hex: theme.accent)).padding(16)
            }
            if session.gestureMode == .button && session.cursorByButton {
                // So you know what mode one finger is in.
                Label("terminal.cursor_mode_badge", systemImage: "hand.draw.fill")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundColor(SwiftUI.Color(hex: theme.accent))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
            }
            if compact && session.prompt != nil && sessions.current?.id != session.id {
                // Its password or fingerprint dialog shows when it is focused.
                Button { sessions.focus(session.id) } label: {
                    Label("split.pane.needs_answer", systemImage: "key.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Brand.amber, in: Capsule())
                        .foregroundColor(.black)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { record(session.state) }
        .onChange(of: session.state) { record($0) }
        .sheet(item: $editingHost) { e in
            // "Save & connect" tries again with what was changed.
            HostEditor(original: e.host) { _ in
                steps = []
                session.reconnect()
            }
            .environmentObject(model).environmentObject(account).environmentObject(sessions)
        }
    }

    /// The host of a terminal of this device that you can change (to fix
    /// its address, user or key after a failure).
    private var editableHost: SshHost? {
        guard session is LocalTerminal, let h = host, h.canEdit else { return nil }
        return h
    }

    @ViewBuilder private var editHostButton: some View {
        if let h = editableHost {
            Button { editingHost = HostEdit(host: h) } label: { Label("terminal.edit_host", systemImage: "pencil") }
                .buttonStyle(.bordered)
        }
    }

    private var tileSize: CGFloat { compact ? 44 : 64 }
    private var cardPadding: CGFloat { compact ? 14 : 24 }

    @ViewBuilder private var notice: some View {
        if session.asleep {
            asleepCard
        } else if let room = session.waiting {
            WaitingRoomCard(session: session, room: room, background: theme.barColor) { sessions.close(session.id) }
        } else if let end = session.ended {
            SessionEndedCard(end: end, background: theme.barColor) { sessions.close(session.id) }
        } else {
            connectionNotice
        }
    }

    /// Tab of a server session that has not been attached yet.
    private var asleepCard: some View {
        VStack(spacing: 12) {
            HostTile(name: session.label, os: host?.os, icon: host?.icon, size: tileSize)
            Text(session.displayTitle).font(compact ? Font.headline : Font.title3.weight(.semibold))
            Label("terminal.asleep.label", systemImage: "icloud")
                .font(.subheadline).foregroundColor(.secondary)
            HStack {
                Button { sessions.wake(session) } label: { Label("common.connect", systemImage: "arrow.right.circle") }
                    .buttonStyle(.borderedProminent)
                Button("common.close") { sessions.close(session.id) }.buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
        .padding(cardPadding)
        .background(theme.barColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(cardPadding)
    }

    @ViewBuilder private var connectionNotice: some View {
        switch session.state {
        case .connecting:
            connectionPanel(error: nil)
        case .closed(let reason):
            if !didConnect {
                connectionPanel(error: reason)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("terminal.disconnected").font(.headline)
                    Text(reason).font(.callout).foregroundColor(.secondary)
                    HStack {
                        Button { steps = []; session.reconnect() } label: { Label("common.reconnect", systemImage: "arrow.clockwise") }
                            .buttonStyle(.borderedProminent)
                        editHostButton
                        Button("common.close") { sessions.close(session.id) }.buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.barColor, in: RoundedRectangle(cornerRadius: 16))
                .padding(12)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        case .connected:
            EmptyView()
        }
    }

    private func record(_ state: TerminalState) {
        switch state {
        case .connecting(let m):
            if m != TerminalState.connectingMessage && steps.last != m { steps.append(m) }
        case .connected:
            didConnect = true
        case .closed:
            break
        }
    }

    private var host: SshHost? {
        session.hostId.flatMap { try? model.core.getHost(id: $0, accountId: session.accountId) }
    }

    /// The host, the progress and the steps (or the error, if it never connected).
    private func connectionPanel(error: String?) -> some View {
        // In a small pane only the last steps.
        let shownSteps = compact ? Array(steps.suffix(2)) : steps
        return VStack(spacing: 12) {
            HostTile(name: session.label, os: host?.os, icon: host?.icon, size: tileSize)
            Text(session.label).font(compact ? Font.headline : Font.title3.weight(.semibold))
            Text(host.map { h in (h.settings.username.map { u in "\(u)@" } ?? "") + h.address }
                 ?? (session.persistent ? String(localized: "terminal.server_session_lower") : ""))
                .font(.subheadline).foregroundColor(.secondary)
            if error == nil { ProgressView().progressViewStyle(.linear).padding(.top, 4) }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(shownSteps.enumerated()), id: \.offset) { i, step in
                    HStack(spacing: 10) {
                        if i == shownSteps.count - 1 && error == nil {
                            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "checkmark").font(.caption).foregroundColor(Brand.green).frame(width: 14)
                        }
                        Text(step).font(.footnote).foregroundColor(i == shownSteps.count - 1 ? .primary : .secondary)
                    }
                }
                if let error {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle").foregroundColor(Brand.red)
                        Text(error).font(.callout).lineLimit(compact ? 4 : nil)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if error != nil {
                HStack {
                    Button("common.retry") { steps = []; session.reconnect() }.buttonStyle(.borderedProminent)
                    editHostButton
                    Button("common.close") { sessions.close(session.id) }.buttonStyle(.bordered)
                }
                .padding(.top, 8)
            }
        }
        .padding(cardPadding)
        .background(theme.barColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(cardPadding)
    }
}

// MARK: - Broadcast

/// Orange strip over the panes while what is typed goes to all of them.
struct BroadcastBanner: View {
    @EnvironmentObject private var sessions: Sessions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
            Text("split.broadcast.banner \(sessions.broadcastCount)")
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button { sessions.broadcasting = false } label: {
                Text("split.broadcast.stop")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.white.opacity(0.25), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.orange)
    }
}

// MARK: - Menu and keyboard shortcuts

/// Top bar button of the split view (iPad): split with another open
/// terminal, add panes, focus mode, broadcast input, back to one terminal.
struct SplitMenu: View {
    @ObservedObject var session: TerminalSession
    let accent: Color
    @EnvironmentObject private var sessions: Sessions

    var body: some View {
        Menu {
            let split = sessions.splitActive
            let others = sessions.open.filter { s in split ? !sessions.panes.contains(s.id) : s.id != session.id }
            if split {
                if sessions.panes.count < PaneLayout.maxPanes {
                    Menu {
                        ForEach(others) { s in
                            Button(s.displayTitle) { sessions.addPane(s.id) }
                        }
                        Button { newTerminalInSplit() } label: { Label("split.new_terminal", systemImage: "plus") }
                    } label: {
                        Label("split.add_pane", systemImage: "plus.rectangle.on.rectangle")
                    }
                }
                Button { sessions.toggleFocusMode() } label: {
                    if sessions.focusMode {
                        Label("split.focus_mode.off", systemImage: "arrow.down.right.and.arrow.up.left")
                    } else {
                        Label("split.focus_mode", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
                Button { sessions.toggleBroadcast() } label: {
                    if sessions.broadcasting {
                        Label("split.broadcast.off", systemImage: "speaker.slash")
                    } else {
                        Label("split.broadcast.on", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                Divider()
                Button { sessions.removePane(session.id) } label: { Label("split.remove_pane", systemImage: "minus.rectangle") }
                Button { sessions.exitSplit() } label: { Label("split.single", systemImage: "rectangle") }
            } else {
                Section {
                    ForEach(others) { s in
                        Button(s.displayTitle) { sessions.addPane(s.id) }
                    }
                    Button { newTerminalInSplit() } label: { Label("split.new_terminal", systemImage: "plus") }
                } header: {
                    Text("split.split_with")
                }
            }
        } label: {
            Image(systemName: sessions.splitActive ? "rectangle.split.2x2.fill" : "rectangle.split.2x2")
                .frame(width: 36, height: 40)
                .foregroundColor(sessions.splitActive ? accent : .accentColor)
        }
        .accessibilityLabel("split.title")
    }

    /// Goes to the hosts: the next terminal opened goes next to this one.
    private func newTerminalInSplit() {
        sessions.splitOnNextOpen = true
        sessions.showing = false
    }
}

/// Hardware keyboard shortcuts of the split view (iPad): ⌘⌥ + arrows move the
/// focus, ⌘D adds a pane, ⌘⇧M focus mode and ⌘B broadcast input. Invisible
/// buttons, so they also show in the list of shortcuts (holding ⌘).
struct SplitShortcuts: View {
    /// Off while a sheet covers the terminal.
    var enabled = true
    @EnvironmentObject private var sessions: Sessions

    var body: some View {
        if enabled && sessions.splitAvailable {
            ZStack {
                Button("split.shortcut.left") { sessions.moveFocus(.left) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("split.shortcut.right") { sessions.moveFocus(.right) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("split.shortcut.up") { sessions.moveFocus(.up) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("split.shortcut.down") { sessions.moveFocus(.down) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("split.add_pane") {
                    // Nothing else open: pick a host for the new pane.
                    if !sessions.addPane() && sessions.panes.count < PaneLayout.maxPanes {
                        sessions.splitOnNextOpen = true
                        sessions.showing = false
                    }
                }
                .keyboardShortcut("d", modifiers: .command)
                Button("split.focus_mode") { sessions.toggleFocusMode() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("split.broadcast") { sessions.toggleBroadcast() }
                    .keyboardShortcut("b", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Paste confirmation

/// Before pasting several lines: what is going to be pasted, and "Don't
/// ask again" (also in Settings).
struct PasteConfirmView: View {
    let request: PasteRequest
    /// Terminals it goes to while broadcasting (0: only this one).
    let broadcastCount: Int
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var dontAsk = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(verbatim: PasteCheck.preview(request.text, maxLines: 12))
                            .font(.system(.footnote, design: .monospaced))
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.vertical, 4)
                    }
                } header: {
                    Text("paste.confirm.lines \(PasteCheck.lineCount(request.text))")
                } footer: {
                    if broadcastCount > 1 {
                        Text("paste.confirm.broadcast \(broadcastCount)")
                    } else {
                        Text("paste.confirm.footer")
                    }
                }
                Section {
                    Toggle("paste.confirm.dont_ask", isOn: $dontAsk)
                } footer: {
                    Text("paste.confirm.dont_ask.footer")
                }
            }
            .navigationTitle("paste.confirm.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.paste") {
                        if dontAsk { settings.confirmMultilinePaste = false }
                        let (session, text) = (request.session, request.text)
                        dismiss()
                        session.paste(text)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .modifier(MediumDetent())
    }
}

/// Half-height sheet where available (iOS 16).
struct MediumDetent: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.presentationDetents([.medium, .large])
        } else {
            content
        }
    }
}
