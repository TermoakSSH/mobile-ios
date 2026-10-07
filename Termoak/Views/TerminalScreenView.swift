import TermoakKit
import SwiftTerm
import SwiftUI
import UIKit

/// Open terminals in full screen, with tabs. On an iPad with room (regular
/// width) several of them can be side by side (`PaneArea`); in a narrow
/// window only the focused one is shown.
struct TerminalScreenView: View {
    @EnvironmentObject private var sessions: Sessions
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var splitAvailable: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
    }

    var body: some View {
        Group {
            if let session = sessions.current {
                // Not rebuilt when the focus changes: the panes stay where they are.
                TerminalContent(session: session)
                    .onAppear { UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn }
                    .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            } else {
                Color.clear.onAppear { sessions.showing = false }
            }
        }
        .onAppear { sessions.splitAvailable = splitAvailable }
        .onChange(of: splitAvailable) { sessions.splitAvailable = $0 }
    }
}

private struct TerminalContent: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var sessions: Sessions
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
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
    /// Rightward drag of the copilot (to close it).
    @State private var copilotDrag: CGFloat = 0
    /// The keyboard on screen came up with the phone copilot open (its box
    /// or a sheet opened from it), not for the terminal.
    @State private var copilotKeyboard = false
    /// ⌘F: the find bar.
    @State private var finding = false
    /// ⌘K / ⌘T: connect to a host in a new tab.
    @State private var quickConnect = false
    /// ⌘,: the settings in a sheet.
    @State private var showingSettings = false

    /// On a tablet (or a big phone in landscape) the panel goes on the side.
    private var side: Bool { sizeClass == .regular }
    private var theme: TerminalTheme { session.theme }
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
        .background(SplitShortcuts(enabled: shortcutsEnabled))
        .background(TerminalShortcuts(session: session, enabled: shortcutsEnabled,
                                      onQuickConnect: { quickConnect = true },
                                      onFind: { finding = true },
                                      onSettings: { showingSettings = true }))
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
                SessionActivityView(core: model.core.api(for: session.accountId), sessionId: id, title: session.title ?? session.label)
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
            SnippetVariablesForm(snippet: e.snippet, run: e.action.run) { text in
                use(text, e.action)
            }
        }
        .sheet(isPresented: $quickConnect) {
            QuickConnectView { host, strict in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { sessions.connect(host, strict: strict) }
            }
            .environmentObject(model)
            .environmentObject(account)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(closable: true)
                .environmentObject(model)
                .environmentObject(account)
                .environmentObject(sessions)
                .environmentObject(settings)
                .environmentObject(model.tunnels)
        }
        .sheet(item: $sessions.pasteRequest) { r in
            PasteConfirmView(request: r, broadcastCount: sessions.receivesBroadcast(r.session) ? sessions.broadcastCount : 0)
                .environmentObject(settings)
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
        .onChange(of: settings.optionAsMeta) { _ in sessions.applyAppearance() }
        .onChange(of: session.id) { _ in finding = false }
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
    }

    /// Nothing covers the terminal: its keyboard shortcuts are on (SwiftUI
    /// keeps them active under the sheets it presents).
    private var shortcutsEnabled: Bool {
        session.prompt == nil && !customizing && !showingPeople && !sharing && !showingActivity && !showingFiles
            && tunnelsHost == nil && filling == nil && sessions.pasteRequest == nil && !terminating
            && !quickConnect && !showingSettings
    }

    /// A snippet from the quick panel: here (and in the panes while
    /// broadcasting) or in every open terminal.
    private func use(_ text: String, _ action: SnippetAction) {
        if action.everywhere {
            let n = sessions.sendToAll(text, run: action.run)
            session.showFlash(String(localized: "snippets.sent_to_open \(n)"))
        } else if action.run {
            session.run(text)
        } else {
            session.paste(text)
        }
    }

    /// The terminal with its bars, and the quick panel or the copilot on the
    /// side (tablet).
    private var terminalArea: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar
                tabs
                if finding {
                    TerminalFindBar(session: session) { finding = false }
                        .id(session.id)
                }
                if sessions.broadcastActive {
                    BroadcastBanner()
                }
                // One terminal, or several side by side on an iPad.
                PaneArea(focused: session) { s in
                    sessions.focus(s.id)
                    showingPeople = true
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
        // A new conversation view for each tab (as before the split view).
        .id(session.id)
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
            onFill: { sn, action in filling = SnippetChoice(snippet: sn, action: action) },
            onSendAll: { text, run in use(text, SnippetAction(run: run, everywhere: true)) }
        )
        .id(session.id)
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
                Image(systemName: "chevron.down").font(.headline).frame(width: 40, height: 40).contentShape(Rectangle()).hoverEffect()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title ?? session.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Button { session.pasteClipboard() } label: {
                Image(systemName: "doc.on.clipboard").frame(width: 36, height: 40).contentShape(Rectangle()).hoverEffect()
            }
            .accessibilityLabel("common.paste")
            if sessions.splitAvailable {
                SplitMenu(session: session, accent: SwiftUI.Color(hex: theme.accent))
            }
            if !side {
                Button { toggleKeyboard() } label: { Image(systemName: "keyboard").frame(width: 36, height: 40).contentShape(Rectangle()).hoverEffect() }
                    .accessibilityLabel("terminal.keyboard")
            }
            if session.gestureMode == .button {
                Button { session.toggleGestures() } label: {
                    Image(systemName: session.cursorByButton ? "hand.draw.fill" : "hand.draw")
                        .frame(width: 36, height: 40).contentShape(Rectangle()).hoverEffect()
                        .foregroundColor(session.cursorByButton ? SwiftUI.Color(hex: theme.accent) : .accentColor)
                }
                .accessibilityLabel("common.move_cursor")
                .accessibilityValue(session.cursorByButton ? Text("common.on") : Text("common.off"))
            }
            if showsPeopleButton {
                Button { showingPeople = true } label: {
                    peopleIcon.frame(width: 40, height: 40).contentShape(Rectangle()).hoverEffect()
                }
                .accessibilityLabel("share.participants.title")
            }
            Button { toggleCopilot() } label: {
                Image(systemName: "sparkles")
                    .frame(width: 36, height: 40).contentShape(Rectangle()).hoverEffect()
                    .foregroundColor(sessions.copilotOpen ? SwiftUI.Color(hex: theme.accent) : .accentColor)
            }
            .keyboardShortcut("i", modifiers: .command)
            .accessibilityLabel("copilot.title")
            Button { togglePanel() } label: {
                Image(systemName: side ? "sidebar.trailing" : "square.grid.2x2")
                    .frame(width: 36, height: 40).contentShape(Rectangle()).hoverEffect()
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
            } label: { Image(systemName: "ellipsis.circle").frame(width: 40, height: 40).contentShape(Rectangle()).hoverEffect() }
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
                            inPane: sessions.splitActive && sessions.panes.contains(s.id),
                            onTap: { sessions.show(s.id) }, onClose: { sessions.close(s.id) })
                }
                Button { sessions.showing = false } label: {
                    Image(systemName: "plus").frame(width: 32, height: 30).contentShape(Rectangle()).hoverEffect()
                }
                .accessibilityLabel("terminal.open_another")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .background(theme.barColor)
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

    /// SFTP over this terminal's connection, or from the server if the
    /// session lives there.
    private var filesSource: FileBrowser.Source? {
        if let local = session as? LocalTerminal, let c = local.connection { return .session(c) }
        if session is ServerTerminal, session.isOwner, let h = session.hostId { return .server(hostId: h, accountId: session.accountId) }
        return nil
    }

    private var host: SshHost? {
        session.hostId.flatMap { try? model.core.getHost(id: $0, accountId: session.accountId) }
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
    /// On screen in the split view.
    var inPane = false
    let onTap: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if inPane { Image(systemName: "rectangle.split.2x1").font(.caption2).foregroundColor(.secondary) }
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
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .hoverEffect(.highlight)
        .onTapGesture(perform: onTap)
        // Secondary click (trackpad, mouse) or a long press.
        .contextMenu {
            Button(action: onTap) { Label("shortcut.show_tab", systemImage: "terminal") }
            Button(role: .destructive, action: onClose) {
                Label(session.persistent ? String(localized: "terminal.menu.close_tab_persistent") : String(localized: "common.close"),
                      systemImage: "xmark")
            }
        }
    }

    private var color: SwiftUI.Color {
        switch session.state {
        case .connected: return Brand.green
        case .connecting: return Brand.amber
        case .closed: return Brand.red
        }
    }
}

/// The terminal of a session, in its viewport (which zooms it when a
/// read-only guest keeps the owner's size). A tap focuses it (split view).
struct SwiftTermView: UIViewRepresentable {
    let viewport: TerminalViewport
    var onTap: (() -> Void)?

    func makeUIView(context: Context) -> TerminalViewport {
        viewport.onTap = onTap
        return viewport
    }

    func updateUIView(_ uiView: TerminalViewport, context: Context) {
        uiView.onTap = onTap
    }
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
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
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
    let action: SnippetAction
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
                        Button("common.cancel") { respond(nil) }.keyboardShortcut(.cancelAction)
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
