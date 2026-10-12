import SwiftUI
import TermoakKit

/// Demo mode: takes the app to the screen of `-TermoakDemoScene` once it has
/// loaded (DemoMode.swift). The screens that belong to a view (the files, the
/// host editor, the AI task) open themselves through the hooks below.
@MainActor
enum DemoDirector {
    /// The hosts screen already opened the scene's sheet (only once).
    private static var hostsSceneDone = false

    private static var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// After the launch (the Root's task, once the accounts are loaded).
    static func start(_ model: AppModel) async {
        guard DemoMode.isOn else { return }
        let sessions = model.sessions
        func host(_ id: String) -> SshHost? { try? model.core.getHost(id: id, accountId: nil) }
        switch DemoMode.scene {
        case .hosts, .files, .editor, .vaults:
            break
        case .ai:
            // The desktop layout shows the AI section instead (DesktopShell).
            if !pad { model.showingAi = true }
        case .terminal:
            await pause(0.5)
            if let h = host("h-web-1") { sessions.connect(h, strict: false) }
        case .themes:
            await pause(0.5)
            if let h = host("h-web-2") { sessions.connect(h, strict: false) }
            await pause(1.5)
            // The phone's panel takes the keyboard's place; the iPad's is on the side.
            if pad { hideKeyboard(sessions) } else { sessions.quickPanelOpen = true }
        case .split:
            await pause(0.5)
            let hosts = ["h-web-1", "h-web-2", "h-db-primary", "h-monitoring"].compactMap(host)
            sessions.openLocal(hosts, split: true)
            await pause(1.5)
            sessions.broadcasting = true
            // htop keeps the keys to itself: out of the broadcast.
            if let top = sessions.open.first(where: { $0.hostId == "h-web-2" }) { sessions.toggleExcluded(top.id) }
            hideKeyboard(sessions)
        case .copilot:
            await pause(0.5)
            guard let h = host("h-web-1") else { return }
            sessions.connect(h, strict: false)
            await pause(1.5)
            guard let s = sessions.current else { return }
            sessions.copilotOpen = true
            let copilot = sessions.copilot(for: s)
            copilot.draft = DemoData.copilotPrompt
            copilot.send(from: s)
        }
    }

    private static func hideKeyboard(_ sessions: Sessions) {
        sessions.open.forEach { _ = $0.view.resignFirstResponder() }
    }

    /// The section the desktop layout starts on.
    static var desktopSection: DesktopSection? {
        guard DemoMode.isOn else { return nil }
        return DemoMode.scene == .ai ? .ai : .hosts
    }

    /// The sheet the hosts screen opens by itself: the files or the editor
    /// of web-1 (`files`: true for the files).
    static func hostsScene(_ core: TermoakCore) -> (files: Bool, host: SshHost)? {
        guard DemoMode.isOn, !hostsSceneDone, DemoMode.scene == .files || DemoMode.scene == .editor,
              let host = try? core.getHost(id: "h-web-1", accountId: nil) else { return nil }
        hostsSceneDone = true
        return (DemoMode.scene == .files, host)
    }
}

/// The AI scene: the task waiting for approvals opens by itself.
struct DemoTaskLink: View {
    let accountId: String?
    @State private var active = false

    var body: some View {
        if DemoMode.isOn && DemoMode.scene == .ai {
            NavigationLink(isActive: $active) {
                TaskView(taskId: DemoData.diskTask, accountId: accountId)
            } label: {
                EmptyView()
            }
            .opacity(0)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { active = true }
            }
        }
    }
}

extension FileBrowser {
    /// The files scene: two transfers running and one waiting.
    func startDemoTransfers() {
        guard DemoMode.isOn, DemoMode.scene == .files, transfers.isEmpty else { return }
        if let dump = entries.first(where: { $0.name.hasPrefix("db-dump") }) { download(dump, for: .save) }
        let name = "release-2.4.2.tar.gz"
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? Data("demo".utf8).write(to: local)
        upload(UploadRequest(files: [(url: local, name: name)], folder: path, conflicts: []), replace: true)
        if let report = entries.first(where: { $0.name == "traffic-report.pdf" }) { download(report, for: .save) }
    }
}
