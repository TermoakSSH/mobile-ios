import TermoakKit
import SwiftTerm
import SwiftUI
import UIKit

/// Open terminals in full screen, with tabs.
struct TerminalScreenView: View {
    @EnvironmentObject private var sessions: Sessions
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        if let session = sessions.current {
            TerminalContent(session: session)
                .id(session.id)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn }
                .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        } else {
            Color.clear.onAppear { sessions.showing = false }
        }
    }
}

private struct TerminalContent: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var sessions: Sessions
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Account
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var terminating = false
    /// People in the shared session.
    @State private var showingPeople = false
    /// Invitations (share sheet).
    @State private var sharing = false
    /// Who typed in this server session (owner).
    @State private var showingActivity = false
    @State private var customizing = false
    @State private var filling: SnippetChoice?
    @State private var showingFiles = false
    @State private var tunnelsHost: SshHost?
    /// Height of the keyboard with the bar: the panel takes the same (no jumps).
    @AppStorage("alto_teclado") private var keyboardHeight: Double = 320
    /// Connection steps (like Termius' connection screen).
    @State private var steps: [String] = []
    @State private var didConnect = false
    /// Rightward drag of the copilot (to close it).
    @State private var copilotDrag: CGFloat = 0
    /// The keyboard on screen came up with the phone copilot open (its box
    /// or a sheet opened from it), not for the terminal.
    @State private var copilotKeyboard = false

    /// On a tablet (or a big phone in landscape) the panel goes on the side.
    private var side: Bool { sizeClass == .regular }
    private var theme: TerminalTheme { settings.terminalTheme }
    /// The keyboard goes over the terminal instead of shrinking it: on a
    /// phone, while the copilot covers it (and until the copilot's keyboard
    /// has gone, so closing it does not resize the terminal twice).
    private var keyboardOverTerminal: Bool { !side && (sessions.copilotOpen || copilotKeyboard) }

    var body: some View {
        ZStack {
            terminalArea
                // The terminal makes room for its own keyboard (it gets fewer
                // rows); the phone copilot's keyboard goes over it instead:
                // the terminal keeps its size (no resize sent to the server,
                // nothing reflowed) and only the copilot moves up.
                .ignoresSafeArea(.keyboard, edges: keyboardOverTerminal ? .bottom : [])
            if sessions.copilotOpen && !side {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { sessions.copilotOpen = false }
                    .transition(.opacity)
            }
            // Laid out above the keyboard, so its box to write in is never under it.
            phoneCopilot
        }
        .background(theme.backgroundColor.ignoresSafeArea())
        .background((sessions.quickPanelOpen && !side ? theme.barColor : theme.backgroundColor).ignoresSafeArea())
        .overlay(alignment: .top) { ShareToasts(notices: sessions.notices) }
        .preferredColorScheme(theme.isLight ? .light : .dark)
        .animation(.easeOut(duration: 0.2), value: sessions.quickPanelOpen)
        .animation(.easeOut(duration: 0.2), value: settings.sidePanel)
        .animation(.easeOut(duration: 0.22), value: sessions.copilotOpen)
        .sheet(item: $session.prompt) { p in
            AuthPromptView(prompt: p) { session.prompt = nil }.interactiveDismissDisabled()
        }
        .sheet(isPresented: $customizing) { KeyboardEditor().environmentObject(settings) }
        .sheet(isPresented: $showingPeople) {
            ParticipantsSheet(session: session, canShare: canShare) {
                // One sheet after the other.
                showingPeople = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sharing = true }
            }
        }
        .sheet(isPresented: $sharing) {
            if let source = shareSource {
                ShareSessionView(core: model.core, source: source, title: session.title ?? session.label)
            }
        }
        .sheet(isPresented: $showingActivity) {
            if let id = activitySessionId {
                SessionActivityView(core: model.core, sessionId: id, title: session.title ?? session.label)
            }
        }
        .fullScreenCover(isPresented: $showingFiles) {
            if let f = filesSource {
                FilesScreen(core: model.core, title: session.label, source: f)
            }
        }
        .sheet(item: Binding(get: { tunnelsHost.map(SelectedHost.init) }, set: { tunnelsHost = $0?.host })) { e in
            TunnelsView(host: e.host).environmentObject(model)
        }
        .sheet(item: $filling) { e in
            SnippetVariablesForm(snippet: e.snippet, run: e.run) { text in
                if e.run { session.run(text) } else { session.paste(text) }
            }
        }
        .confirmationDialog("common.terminate_session.title", isPresented: $terminating, titleVisibility: .visible) {
            Button("common.terminate", role: .destructive) {
                (session as? ServerTerminal)?.terminate()
                sessions.close(session.id)
            }
        } message: {
            Text("common.terminate_session.message")
        }
        .onChange(of: settings.fontSize) { _ in sessions.applyAppearance() }
        .onChange(of: settings.terminalThemeId) { _ in sessions.applyAppearance() }
        .onChange(of: settings.fontId) { _ in sessions.applyAppearance() }
        .onChange(of: settings.keyboard) { _ in sessions.applyKeyboard() }
        .onChange(of: sessions.copilotOpen) { open in
            // On a phone it covers the terminal: hide the keyboard and the quick panel.
            guard open, !side else { return }
            sessions.quickPanelOpen = false
            _ = session.view.resignFirstResponder()
        }
        .onChange(of: sessions.quickPanelOpen) { open in
            guard open else { return }
            if side {
                // The bar's grid button shows the side panel.
                sessions.quickPanelOpen = false
                settings.sidePanel = true
            } else {
                _ = session.view.resignFirstResponder()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { n in
            copilotKeyboard = sessions.copilotOpen && !side && !session.view.isFirstResponder
            guard session.view.isFirstResponder else { return }
            if let frame = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, frame.height > 150 {
                keyboardHeight = frame.height
            }
            // Touching the terminal with the panel open goes back to the keyboard.
            sessions.quickPanelOpen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            copilotKeyboard = false
        }
        .onAppear { record(session.state) }
        .onChange(of: session.state) { record($0) }
    }

    /// The terminal with its bars, and the quick panel or the copilot on the
    /// side (tablet).
    private var terminalArea: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar
                tabs
                ZStack(alignment: .topLeading) {
                    SwiftTermView(viewport: session.viewport)
                    CursorSuggestions(session: session)
                    ShareBanners(session: session, background: theme.barColor) { showingPeople = true }
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
                }
                if sessions.quickPanelOpen && !side {
                    GeometryReader { geo in
                        panel.frame(height: max(220, keyboardHeight - geo.safeAreaInsets.bottom))
                    }
                    .frame(height: max(220, keyboardHeight - bottomInset))
                    .transition(.move(edge: .bottom))
                }
            }
            if side && settings.sidePanel && !sessions.copilotOpen {
                Divider().overlay(theme.foregroundColor.opacity(0.15))
                panel.frame(width: 340)
                    .transition(.move(edge: .trailing))
            }
            if side && sessions.copilotOpen {
                // On a tablet the copilot goes on the side (instead of the quick panel).
                Divider().overlay(theme.foregroundColor.opacity(0.15))
                copilotPanel.frame(width: 380)
                    .transition(.move(edge: .trailing))
            }
        }
    }

    private var copilotPanel: some View {
        CopilotPanel(copilot: sessions.copilot(for: session), session: session) {
            sessions.copilotOpen = false
        }
    }

    /// On a phone the copilot slides in from the right (85 % of the width) and
    /// closes by dragging it to the right, with the X or by tapping outside.
    @ViewBuilder private var phoneCopilot: some View {
        if sessions.copilotOpen && !side {
            GeometryReader { geo in
                copilotPanel
                    .frame(width: geo.size.width * 0.85)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            .offset(x: copilotDrag)
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { v in
                        guard abs(v.translation.width) > abs(v.translation.height) else { return }
                        copilotDrag = max(0, v.translation.width)
                    }
                    .onEnded { v in
                        if copilotDrag > 90 || (copilotDrag > 0 && v.predictedEndTranslation.width > 240) {
                            sessions.copilotOpen = false
                        }
                        withAnimation(.easeOut(duration: 0.2)) { copilotDrag = 0 }
                    }
            )
            .transition(.move(edge: .trailing))
        }
    }

    private func toggleCopilot() {
        sessions.copilotOpen.toggle()
    }

    private var bottomInset: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.safeAreaInsets.bottom ?? 0
    }

    private var panel: some View {
        QuickPanel(
            session: session,
            side: side,
            onKeyboard: {
                sessions.quickPanelOpen = false
                _ = session.view.becomeFirstResponder()
            },
            onCustomize: { customizing = true },
            onFill: { sn, run in filling = SnippetChoice(snippet: sn, run: run) }
        )
    }

    /// Grid button: opens or closes the panel.
    private func togglePanel() {
        if side && sessions.copilotOpen {
            // They share the side: the quick panel replaces the copilot.
            sessions.copilotOpen = false
            settings.sidePanel = true
        } else if side {
            settings.sidePanel.toggle()
        } else if sessions.quickPanelOpen {
            sessions.quickPanelOpen = false
            _ = session.view.becomeFirstResponder()
        } else {
            sessions.quickPanelOpen = true
        }
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            Button { sessions.showing = false } label: {
                Image(systemName: "chevron.down").font(.headline).frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title ?? session.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Button { if let t = UIPasteboard.general.string { session.paste(t) } } label: {
                Image(systemName: "doc.on.clipboard").frame(width: 36, height: 40)
            }
            .accessibilityLabel("common.paste")
            if !side {
                Button { toggleKeyboard() } label: { Image(systemName: "keyboard").frame(width: 36, height: 40) }
                    .accessibilityLabel("terminal.keyboard")
            }
            if session.gestureMode == .button {
                Button { session.toggleGestures() } label: {
                    Image(systemName: session.cursorByButton ? "hand.draw.fill" : "hand.draw")
                        .frame(width: 36, height: 40)
                        .foregroundColor(session.cursorByButton ? SwiftUI.Color(hex: theme.accent) : .accentColor)
                }
                .accessibilityLabel("common.move_cursor")
                .accessibilityValue(session.cursorByButton ? Text("common.on") : Text("common.off"))
            }
            if showsPeopleButton {
                Button { showingPeople = true } label: {
                    peopleIcon.frame(width: 40, height: 40)
                }
                .accessibilityLabel("share.participants.title")
            }
            Button { toggleCopilot() } label: {
                Image(systemName: "sparkles")
                    .frame(width: 36, height: 40)
                    .foregroundColor(sessions.copilotOpen ? SwiftUI.Color(hex: theme.accent) : .accentColor)
            }
            .keyboardShortcut("i", modifiers: .command)
            .accessibilityLabel("copilot.title")
            Button { togglePanel() } label: {
                Image(systemName: side ? "sidebar.trailing" : "square.grid.2x2")
                    .frame(width: 36, height: 40)
                    .foregroundColor((side ? settings.sidePanel && !sessions.copilotOpen : sessions.quickPanelOpen) ? SwiftUI.Color(hex: theme.accent) : .accentColor)
            }
            .accessibilityLabel("common.quick_panel")
            Menu {
                Button { UIPasteboard.general.string = session.screenText() } label: {
                    Label("terminal.menu.copy_screen", systemImage: "doc.on.doc")
                }
                Button { settings.changeFontSize(1) } label: { Label("common.font_larger", systemImage: "textformat.size.larger") }
                Button { settings.changeFontSize(-1) } label: { Label("common.font_smaller", systemImage: "textformat.size.smaller") }
                if canShare {
                    Button { sharing = true } label: { Label("share.menu.share", systemImage: "person.badge.plus") }
                }
                if showsPeopleButton {
                    Button { showingPeople = true } label: { Label("share.participants.title", systemImage: "person.2") }
                }
                if activitySessionId != nil {
                    Button { showingActivity = true } label: { Label("activity.menu", systemImage: "clock.arrow.circlepath") }
                }
                Divider()
                if filesSource != nil {
                    Button { showingFiles = true } label: { Label("common.files_sftp", systemImage: "folder") }
                }
                if let h = host {
                    Button { tunnelsHost = h } label: { Label("common.tunnels", systemImage: "point.3.connected.trianglepath.dotted") }
                }
                Divider()
                Button { session.reconnect() } label: { Label("common.reconnect", systemImage: "arrow.clockwise") }
                if session is ServerTerminal && session.isOwner {
                    Button(role: .destructive) { terminating = true } label: {
                        Label("terminal.menu.terminate_server", systemImage: "power")
                    }
                }
                Button { sessions.close(session.id) } label: {
                    Label(session.persistent ? String(localized: "terminal.menu.close_tab_persistent") : String(localized: "common.close"),
                          systemImage: "xmark")
                }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 40, height: 40) }
            .accessibilityLabel("terminal.more")
            .accessibilityIdentifier("terminal-menu")
        }
        .padding(.horizontal, 4)
        .background(theme.barColor)
    }

    /// Your session on the server (not a relay of a terminal of this
    /// device): its activity says who typed.
    private var activitySessionId: String? {
        guard session is ServerTerminal, session.isOwner, account.loggedIn == true else { return nil }
        return session.shareSessionId
    }

    private var subtitle: String {
        if session.asleep { return String(localized: "terminal.subtitle.asleep") }
        switch session.state {
        case .connecting(let m): return m
        case .connected:
            if !session.isOwner {
                return session.canWrite ? String(localized: "share.bar.you_have_control") : session.access.shareLabel
            }
            return session.persistent ? String(localized: "terminal.subtitle.server") : String(localized: "terminal.subtitle.local")
        case .closed: return session.ended?.title ?? String(localized: "terminal.disconnected")
        }
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sessions.open) { s in
                    TabChip(session: s, selected: s.id == session.id,
                            onTap: { sessions.show(s.id) }, onClose: { sessions.close(s.id) })
                }
                Button { sessions.showing = false } label: {
                    Image(systemName: "plus").frame(width: 32, height: 30)
                }
                .accessibilityLabel("terminal.open_another")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .background(theme.barColor)
    }

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

    // ----- Live sharing -----

    /// The participants button: server sessions (yours or shared with you)
    /// and terminals of this device that are shared.
    private var showsPeopleButton: Bool {
        guard !session.asleep, session.ended == nil else { return false }
        return session is ServerTerminal || session.shareAttached
    }

    /// People icon with how many others are inside (and a dot for requests).
    private var peopleIcon: some View {
        let others = session.others.count
        return ZStack(alignment: .topTrailing) {
            Image(systemName: others > 0 ? "person.2.fill" : "person.2")
                .foregroundColor(others > 0 ? SwiftUI.Color(hex: theme.accent) : .accentColor)
            if !session.requests.isEmpty {
                Circle().fill(Brand.red).frame(width: 8, height: 8).offset(x: 4, y: -2)
            } else if others > 0 {
                Text(verbatim: "\(others)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(SwiftUI.Color(hex: theme.accent), in: Capsule())
                    .offset(x: 8, y: -6)
            }
        }
    }

    /// Yours, connected and signed in: it can be shared from here.
    private var canShare: Bool {
        guard account.loggedIn == true, session.isOwner, session.state == .connected else { return false }
        if let server = session as? ServerTerminal { return server.sessionId != nil && server.link == nil }
        return session is LocalTerminal
    }

    private var shareSource: ShareSource? {
        if let server = session as? ServerTerminal, let id = server.sessionId { return .server(sessionId: id) }
        if let local = session as? LocalTerminal { return .local(local) }
        return nil
    }

    /// Tab of a server session that has not been attached yet.
    private var asleepCard: some View {
        VStack(spacing: 12) {
            HostTile(name: session.label, os: host?.os, size: 64)
            Text(session.title ?? session.label).font(.title3.weight(.semibold))
            Label("terminal.asleep.label", systemImage: "icloud")
                .font(.subheadline).foregroundColor(.secondary)
            HStack {
                Button { sessions.wake(session) } label: { Label("common.connect", systemImage: "arrow.right.circle") }
                    .buttonStyle(.borderedProminent)
                Button("common.close") { sessions.close(session.id) }.buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .background(theme.barColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(24)
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

    /// SFTP over this terminal's connection, or from the server if the
    /// session lives there.
    private var filesSource: FileBrowser.Source? {
        if let local = session as? LocalTerminal, let c = local.connection { return .session(c) }
        if session is ServerTerminal, session.isOwner, let h = session.hostId { return .server(hostId: h) }
        return nil
    }

    private var host: SshHost? {
        session.hostId.flatMap { try? model.core.getHost(id: $0) }
    }

    /// The host, the progress and the steps (or the error, if it never connected).
    private func connectionPanel(error: String?) -> some View {
        VStack(spacing: 12) {
            HostTile(name: session.label, os: host?.os, size: 64)
            Text(session.label).font(.title3.weight(.semibold))
            Text(host.map { h in (h.settings.username.map { u in "\(u)@" } ?? "") + h.address }
                 ?? (session.persistent ? String(localized: "terminal.server_session_lower") : ""))
                .font(.subheadline).foregroundColor(.secondary)
            if error == nil { ProgressView().progressViewStyle(.linear).padding(.top, 4) }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(spacing: 10) {
                        if i == steps.count - 1 && error == nil {
                            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "checkmark").font(.caption).foregroundColor(Brand.green).frame(width: 14)
                        }
                        Text(step).font(.footnote).foregroundColor(i == steps.count - 1 ? .primary : .secondary)
                    }
                }
                if let error {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle").foregroundColor(Brand.red)
                        Text(error).font(.callout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if error != nil {
                HStack {
                    Button("common.retry") { steps = []; session.reconnect() }.buttonStyle(.borderedProminent)
                    Button("common.close") { sessions.close(session.id) }.buttonStyle(.bordered)
                }
                .padding(.top, 8)
            }
        }
        .padding(24)
        .background(theme.barColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(24)
    }

    private func toggleKeyboard() {
        if sessions.quickPanelOpen {
            sessions.quickPanelOpen = false
            _ = session.view.becomeFirstResponder()
        } else if session.view.isFirstResponder {
            _ = session.view.resignFirstResponder()
        } else {
            _ = session.view.becomeFirstResponder()
        }
    }
}

private struct TabChip: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let onTap: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if session.persistent { Image(systemName: "icloud").font(.caption2).foregroundColor(.secondary) }
            if !session.others.isEmpty { Image(systemName: "person.2.fill").font(.caption2).foregroundColor(.secondary) }
            Circle().fill(session.asleep ? SwiftUI.Color.secondary : color).frame(width: 7, height: 7)
            Text(session.title ?? session.label).font(.footnote).lineLimit(1).frame(maxWidth: 140)
            Button(action: onClose) { Image(systemName: "xmark").font(.caption2).foregroundColor(.secondary) }
                .buttonStyle(.plain)
                .accessibilityLabel("common.close")
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(selected ? Color.white.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var color: SwiftUI.Color {
        switch session.state {
        case .connected: return Brand.green
        case .connecting: return Brand.amber
        case .closed: return Brand.red
        }
    }
}

/// The SwiftTerm view of the active session.
/// The terminal of a session, in its viewport (which zooms it when a
/// read-only guest keeps the owner's size).
private struct SwiftTermView: UIViewRepresentable {
    let viewport: TerminalViewport

    func makeUIView(context: Context) -> TerminalViewport { viewport }
    func updateUIView(_ uiView: TerminalViewport, context: Context) {}
}

/// Values for a snippet's variables (`{{name}}`) before using it.
private struct SnippetVariablesForm: View {
    let snippet: Snippet
    let run: Bool
    let use: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    var body: some View {
        NavigationView {
            Form {
                ForEach(snippetVariables(script: snippet.script), id: \.self) { name in
                    TextField(name, text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(snippet.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(run ? String(localized: "common.run") : String(localized: "common.paste")) {
                        use((try? renderSnippet(script: snippet.script, values: values)) ?? snippet.script)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SnippetChoice: Identifiable {
    let snippet: Snippet
    let run: Bool
    var id: String { snippet.id }
}

/// Dialog for the server's fingerprint or for passwords and codes.
struct AuthPromptView: View {
    let prompt: AuthPrompt
    let onClose: () -> Void

    @State private var answers: [String] = []

    var body: some View {
        NavigationView {
            Form { content }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("common.cancel") { respond(nil) }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isHostKey ? String(localized: "auth.trust") : String(localized: "common.ok")) { respond(answers) }
                    }
                }
        }
        .onAppear {
            if case .fields(let req) = prompt.kind {
                answers = Array(repeating: "", count: req.fields.count)
            }
        }
    }

    private var isHostKey: Bool {
        if case .hostKey = prompt.kind { return true }
        return false
    }

    private var title: String {
        switch prompt.kind {
        case .hostKey: return String(localized: "auth.unknown_server")
        case .fields(let req):
            switch req.kind {
            case .password: return String(localized: "common.password")
            case .passphrase: return String(localized: "auth.passphrase")
            case .keyboardInteractive: return req.title.isEmpty ? String(localized: "auth.authentication") : req.title
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch prompt.kind {
        case let .hostKey(host, _, keyType, fingerprint):
            Section {
                Text("auth.host_key.message \(host)")
                HStack {
                    Text("common.type")
                    Spacer()
                    Text(keyType).foregroundColor(.secondary)
                }
                Text(fingerprint)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
        case .fields(let req):
            if !req.instructions.isEmpty {
                Section { Text(req.instructions) }
            }
            Section(req.host) {
                ForEach(Array(req.fields.enumerated()), id: \.offset) { i, field in
                    if i < answers.count {
                        if field.echo {
                            TextField(field.text, text: $answers[i])
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField(field.text, text: $answers[i])
                                .onSubmit { respond(answers) }
                        }
                    }
                }
            }
        }
    }

    private func respond(_ value: [String]?) {
        prompt.respond(value)
        onClose()
    }
}
