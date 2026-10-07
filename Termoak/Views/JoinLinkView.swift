import TermoakKit
import SwiftUI
import UIKit

/// Join a shared session with an invitation link: what it offers (who
/// shares it, what you can do, whether the owner lets you in) and with which
/// name you join. Signed in to that server, you join with your account.
struct JoinLinkView: View {
    /// Known when opened from a link; `nil` to paste one.
    let link: JoinLink?
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @AppStorage("share.guest_name") private var savedName = ""
    @State private var text = ""
    @State private var current: JoinLink?
    @State private var info: LinkInvite?
    @State private var loading = false
    @State private var error: String?
    @State private var name = ""
    /// Signed in to that server but joining as a guest anyway.
    @State private var asGuest = false

    /// Signed in to the server of the link.
    private var signedIn: Bool {
        guard account.loggedIn == true, let current else { return false }
        return JoinLink.sameServer(account.server, current.server)
    }

    var body: some View {
        NavigationView {
            Form {
                if link == nil {
                    Section {
                        TextField("join.link_placeholder", text: $text)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit(check)
                        Button {
                            if let s = UIPasteboard.general.string {
                                text = s
                                check()
                            }
                        } label: {
                            Label("common.paste", systemImage: "doc.on.clipboard")
                        }
                    } header: {
                        Text("join.link_header")
                    } footer: {
                        Text("join.link_footer")
                    }
                }
                if loading {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundColor(Brand.red)
                    }
                }
                if let info, let current {
                    details(info, current)
                    Section {
                        if signedIn && !asGuest {
                            Label(String(localized: "join.as_account \(account.user ?? "")"), systemImage: "person.crop.circle.fill")
                            Button("join.as_guest_instead") { asGuest = true }
                        } else {
                            TextField("share.join.name", text: $name)
                                .textContentType(.name)
                                .submitLabel(.join)
                                .onSubmit(join)
                        }
                    } header: {
                        Text("join.who")
                    } footer: {
                        if signedIn && !asGuest {
                            Text("join.account_footer")
                        } else {
                            Text("join.name_footer")
                        }
                    }
                    Section {
                        Button(action: join) {
                            HStack {
                                Spacer()
                                Text("join.join").bold()
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("join.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            .onAppear {
                if name.isEmpty { name = savedName }
                if let link, current == nil { load(link) }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func details(_ info: LinkInvite, _ link: JoinLink) -> some View {
        Section {
            HStack(spacing: 12) {
                ParticipantAvatar(name: info.owner, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: info.title.isEmpty ? String(localized: "common.session") : info.title)
                        .font(.headline)
                    if !info.owner.isEmpty {
                        Text(String(localized: "join.info.owner \(info.owner)"))
                            .font(.subheadline).foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            Label(info.access.shareLabel, systemImage: info.access == .control ? "keyboard" : "eye")
            if info.requireApproval {
                Label("join.info.approval", systemImage: "hourglass")
            }
            if info.participants > 0 {
                Label(String(localized: "join.info.inside \(Int(info.participants))"), systemImage: "person.2")
            }
            if let e = info.expiresAt {
                Label(String(localized: "share.expires \(relativeTime(e))"), systemImage: "clock")
            }
            Label(URL(string: link.server)?.host ?? link.server, systemImage: "server.rack")
                .foregroundColor(.secondary)
        }
    }

    private func check() {
        guard let l = JoinLink.parse(text) else {
            info = nil
            current = nil
            error = String(localized: "join.invalid_link")
            return
        }
        load(l)
    }

    private func load(_ l: JoinLink) {
        current = l
        info = nil
        error = nil
        loading = true
        asGuest = false
        Task {
            defer { loading = false }
            do {
                info = try await linkInviteInfo(serverUrl: l.server, token: l.token)
            } catch {
                self.error = userMessage(error)
            }
        }
    }

    private func join() {
        guard let current, info != nil else { return }
        let mode: ServerTerminal.JoinMode
        if signedIn && !asGuest {
            mode = .account
        } else {
            let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            savedName = n
            mode = .guest(name: n.isEmpty ? nil : n)
        }
        model.join(current, mode: mode, title: info?.title ?? "")
    }
}
