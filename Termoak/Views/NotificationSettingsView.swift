import TermoakKit
import SwiftUI
import UIKit
import UserNotifications

/// Settings → Notifications (0.7): per signed-in account, whether its
/// server can send push notifications to an iPhone (APNs), which kinds this
/// device wants, notifying while the app is open, and a test.
struct NotificationSettingsView: View {
    @EnvironmentObject private var account: Accounts
    @ObservedObject private var push = Push.shared
    @Environment(\.openURL) private var openURL
    @State private var error: String?
    @State private var testing: String?
    @State private var tested: String?

    var body: some View {
        Form {
            if !Push.enabled {
                Section { Text("push.settings.not_in_build").foregroundColor(.secondary) }
            }
            if push.authorization == .denied {
                Section {
                    Text("push.settings.denied").foregroundColor(.secondary)
                    Button("push.settings.open_ios_settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }
            if account.active.isEmpty {
                Section { Text("push.settings.no_accounts").foregroundColor(.secondary) }
            }
            ForEach(account.active, id: \.id) { info in
                Section {
                    rows(info.id)
                } header: {
                    Text(verbatim: info.displayLabel)
                }
            }
            if let error {
                Section { Text(verbatim: error).foregroundColor(.red) }
            }
        }
        .navigationTitle("push.settings.title")
        .task { await push.refresh() }
    }

    @ViewBuilder
    private func rows(_ id: String) -> some View {
        if let st = push.statuses[id] {
            if !st.serverApns {
                Text("push.settings.server_no_apns").foregroundColor(.secondary)
            } else {
                HStack {
                    Text("push.settings.status")
                    Spacer()
                    Text(st.registered && st.platform == "apns" ? "push.settings.on" : "push.settings.waiting")
                        .foregroundColor(.secondary)
                }
                ForEach(st.kinds, id: \.self) { kind in
                    Toggle(isOn: kindBinding(id, kind)) { Text(Self.label(kind)) }
                }
                Toggle(isOn: whenOnlineBinding(id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("push.settings.when_online")
                        Text("push.settings.when_online_hint").font(.caption).foregroundColor(.secondary)
                    }
                }
                Button("push.settings.test") { test(id) }
                    .disabled(testing != nil || !st.registered)
                if tested == id {
                    Text("push.settings.test_sent").font(.caption).foregroundColor(.secondary)
                }
            }
        } else if push.unknown.contains(id) {
            Text("push.settings.server_unknown").foregroundColor(.secondary)
        } else {
            ProgressView()
        }
    }

    private func kindBinding(_ id: String, _ kind: String) -> Binding<Bool> {
        Binding(
            get: { push.statuses[id]?.preferences.kinds[kind] ?? true },
            set: { on in
                guard var prefs = push.statuses[id]?.preferences else { return }
                prefs.kinds[kind] = on
                save(id, prefs)
            })
    }

    private func whenOnlineBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { push.statuses[id]?.preferences.whenOnline ?? false },
            set: { on in
                guard var prefs = push.statuses[id]?.preferences else { return }
                prefs.whenOnline = on
                save(id, prefs)
            })
    }

    private func save(_ id: String, _ prefs: PushPreferences) {
        Task {
            do {
                try await push.setPreferences(id, prefs)
                error = nil
            } catch {
                self.error = errorMessage(error)
            }
        }
    }

    private func test(_ id: String) {
        testing = id
        Task {
            defer { testing = nil }
            do {
                try await push.sendTest(id)
                tested = id
                error = nil
            } catch {
                self.error = errorMessage(error)
            }
        }
    }

    /// The name of a kind (the server's `kinds`; an unknown one as it comes).
    static func label(_ kind: String) -> String {
        switch kind {
        case "ai_approval": return String(localized: "push.kind.ai_approval")
        case "ai_finished": return String(localized: "push.kind.ai_finished")
        case "session_shared": return String(localized: "push.kind.session_shared")
        case "session_prompt": return String(localized: "push.kind.session_prompt")
        case "join_request": return String(localized: "push.kind.join_request")
        case "control_request": return String(localized: "push.kind.control_request")
        case "team_added": return String(localized: "push.kind.team_added")
        case "security_key_request": return String(localized: "push.kind.security_key_request")
        case "access_request": return String(localized: "push.kind.access_request")
        case "access_decided": return String(localized: "push.kind.access_decided")
        default: return kind
        }
    }
}
