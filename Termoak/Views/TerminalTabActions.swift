import SwiftUI

/// "Rename tab": a name for the tab, empty for the automatic one again
/// (the program's title or the host's name), like the desktop.
struct TabRenameAlert: ViewModifier {
    @Binding var session: TerminalSession?
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .textPrompt(Text("terminal.tab.rename_title"),
                        isPresented: Binding(get: { session != nil }, set: { if !$0 { session = nil } }), text: $name,
                        placeholder: String(localized: "terminal.tab.rename_placeholder"), message: Text("terminal.tab.rename_hint"),
                        confirm: String(localized: "common.save"), plain: false) {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                session?.customTitle = trimmed.isEmpty ? nil : trimmed
            }
            .onChange(of: session?.id) { _ in name = session?.customTitle ?? "" }
    }
}

extension View {
    /// The rename alert of a tab (`session`: the tab being renamed).
    func tabRenameAlert(_ session: Binding<TerminalSession?>) -> some View {
        modifier(TabRenameAlert(session: session))
    }
}

/// The tab actions of the desktop: Rename, Duplicate and Close other tabs.
struct TabExtraActions: View {
    let session: TerminalSession
    let onRename: () -> Void
    @EnvironmentObject private var sessions: Sessions

    var body: some View {
        Button(action: onRename) { Label("terminal.tab.rename", systemImage: "pencil") }
        if sessions.canDuplicate(session) {
            Button { sessions.duplicate(session.id) } label: {
                Label("terminal.tab.duplicate", systemImage: "plus.square.on.square")
            }
        }
        if sessions.open.count > 1 {
            Button { sessions.closeOthers(session.id) } label: {
                Label("terminal.tab.close_others", systemImage: "xmark.square")
            }
        }
    }
}
