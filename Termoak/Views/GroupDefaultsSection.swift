import TermoakKit
import SwiftUI

/// A group's defaults for the hosts inside it (and its subgroups), like the
/// desktop's group settings: user, port, credential, keep-alive, TERM, agent
/// forwarding and recording. A host's own value wins; empty means "not set
/// here".
struct GroupDefaultsSection: View {
    @Binding var settings: HostSettings
    /// Identities and keys a host of the group can use (its vault and This device).
    let identities: [SshIdentity]
    let keys: [SshKey]

    var body: some View {
        Section {
            TextField("host_editor.username", text: username)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("host_editor.port", text: number(\.port, max: 65535))
                .keyboardType(.numberPad)
            credentialPicker
            HStack {
                Text("host_editor.keepalive")
                Spacer()
                TextField(text: number(\.keepaliveSecs, max: 86400), prompt: Text(verbatim: "30")) { Text("host_editor.keepalive") }
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
            }
            HStack {
                Text("host_editor.term")
                Spacer()
                TextField(text: text(\.term), prompt: Text(verbatim: "xterm-256color")) { Text("host_editor.term") }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
            choice("host_editor.agent_forwarding", \.agentForwarding)
            choice("host_editor.record_sessions", \.recordSessions)
        } header: {
            Text("groups.defaults")
        } footer: {
            Text("groups.defaults.footer")
        }
    }

    private var username: Binding<String> { text(\.username) }

    private func text(_ path: WritableKeyPath<HostSettings, String?>) -> Binding<String> {
        Binding(get: { settings[keyPath: path] ?? "" }, set: { value in
            let t = value.trimmingCharacters(in: .whitespaces)
            settings[keyPath: path] = t.isEmpty ? nil : t
        })
    }

    private func number(_ path: WritableKeyPath<HostSettings, UInt32?>, max: UInt32) -> Binding<String> {
        Binding(get: { settings[keyPath: path].map(String.init) ?? "" }, set: { value in
            let n = UInt32(value.filter(\.isNumber)).map { min($0, max) }
            // Port 0 is no port; keep-alive 0 is "off".
            settings[keyPath: path] = n == 0 && path == \HostSettings.port ? nil : n
        })
    }

    /// Inherit (nothing set), On or Off.
    private func choice(_ title: LocalizedStringKey, _ path: WritableKeyPath<HostSettings, Bool?>) -> some View {
        Picker(title, selection: Binding(get: { settings[keyPath: path] }, set: { settings[keyPath: path] = $0 })) {
            Text("groups.defaults.not_set").tag(Bool?.none)
            Text("groups.defaults.on").tag(Bool?.some(true))
            Text("groups.defaults.off").tag(Bool?.some(false))
        }
    }

    /// None, one of the identities or one of the keys.
    private var credentialPicker: some View {
        Picker("groups.defaults.credential", selection: credential) {
            Text("groups.defaults.not_set").tag("")
            ForEach(identities, id: \.id) { Text(verbatim: "\($0.label) (\($0.username))").tag("identity:" + $0.id) }
            ForEach(keys, id: \.id) { Text(verbatim: "\($0.label) · \($0.algorithm)").tag("key:" + $0.id) }
        }
    }

    private var credential: Binding<String> {
        Binding(get: {
            if let i = settings.identityId { return "identity:" + i }
            if let k = settings.keyId { return "key:" + k }
            return ""
        }, set: { value in
            settings.identityId = value.hasPrefix("identity:") ? String(value.dropFirst("identity:".count)) : nil
            settings.keyId = value.hasPrefix("key:") ? String(value.dropFirst("key:".count)) : nil
        })
    }
}
