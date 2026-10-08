import TermoakKit
import SwiftUI

/// Public information of a server (`/info`), to show before signing in.
struct ServerDetails: Equatable {
    let url: String
    let name: String
    let version: String
    let registrationOpen: Bool
    /// `preprod` on a test server (`nil` in production).
    let environment: String?
    let termsUrl: String?
    let privacyUrl: String?
    let vaults: Bool
    let insecure: Bool

    init(url: String, json: String) throws {
        guard let data = json.data(using: .utf8),
              let v = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TermoakError.Invalid(message: String(localized: "login.server.not_termoak"))
        }
        self.url = url
        name = (v["name"] as? String) ?? "Termoak"
        version = (v["version"] as? String) ?? "?"
        registrationOpen = (v["registration"] as? String) == "open"
        environment = (v["environment"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        termsUrl = v["terms_url"] as? String
        privacyUrl = v["privacy_url"] as? String
        vaults = ((v["features"] as? [String: Any])?["vaults"] as? Bool) ?? false
        insecure = url.hasPrefix("http://")
    }
}

/// Signing in or creating an account, on the official server (no address
/// to type) or on your own. Used as the welcome screen and to add more
/// accounts. Accounts that wait for their email code resume here.
struct LoginView: View {
    let welcome: Bool
    /// An account to sign in again (prefilled) or to finish verifying.
    var resume: AccountInfo? = nil
    /// A `termoak://invite` link: sign up on its server with its code.
    var inviteLink: InviteLink? = nil
    let onFinish: () -> Void

    @EnvironmentObject private var account: Accounts
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private enum Step: Equatable {
        case start
        case custom
        case signIn
        case signUp
        case verify(accountId: String, email: String)
    }

    @State private var step: Step = .start
    /// The server chosen (`nil`: the official one).
    @State private var custom: ServerDetails?
    @State private var official: ServerDetails?
    @State private var serverText = ""
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var invite = ""
    /// What the invitation of `inviteLink` offers (team, email, expiry).
    @State private var invitation: InviteInfo?
    @State private var acceptTerms = false
    @State private var totp = ""
    @State private var needsTotp = false
    @State private var busy = false
    @State private var error: String?

    // Email verification.
    @State private var emailCode = ""
    @State private var verifyTotp = ""
    @State private var verifyNeedsTotp = false
    /// The "Resend" button waits until then (the server allows one email a minute).
    @State private var resendAt: Date?
    @State private var resent = false

    private var choice: ServerChoice {
        custom.map { .custom(url: $0.url) } ?? .official
    }

    private var officialHost: String {
        officialServerUrl().replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }

    /// The server's details for the forms (the official one's are loaded
    /// when needed).
    private var details: ServerDetails? { custom ?? official }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                topBar
                Image("Logo")
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.top, welcome && step == .start ? 40 : 4)
                switch step {
                case .start: startStep
                case .custom: customStep
                case .signIn: signInStep
                case .signUp: signUpStep
                case .verify(let id, let mail): verifyStep(accountId: id, email: mail)
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: start)
    }

    // MARK: Steps

    @ViewBuilder private var topBar: some View {
        HStack {
            if step != .start && resume == nil {
                Button { back() } label: { Label("login.back", systemImage: "chevron.left") }
            } else if !welcome {
                Button("common.cancel") { dismiss() }
            }
            Spacer()
        }
        .frame(minHeight: 24)
    }

    /// The official server first, then creating an account and your own server.
    @ViewBuilder private var startStep: some View {
        Text(verbatim: "Termoak").font(.largeTitle.bold())
        Text("login.tagline")
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.bottom, 12)
        Button { go(.signIn, server: nil) } label: {
            VStack(spacing: 2) {
                Text("login.official.sign_in").font(.headline)
                Text(verbatim: officialHost).font(.caption).opacity(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.borderedProminent)
        Button { go(.signUp, server: nil) } label: {
            Text("login.official.sign_up").font(.headline).frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.bordered)
        Button { step = .custom; error = nil } label: {
            Label("login.custom.link", systemImage: "server.rack")
        }
        .padding(.top, 8)
        if welcome && account.list.isEmpty {
            Button("login.no_server") {
                settings.noServer = true
                onFinish()
            }
            .padding(.top, 24)
            .foregroundColor(.secondary)
        }
    }

    /// Your own server: its address, checked with `/info`.
    @ViewBuilder private var customStep: some View {
        Text("login.custom.title").font(.title2.bold())
        Text("login.custom.hint")
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
        LoginField(icon: "server.rack", title: String(localized: "login.server"), text: $serverText, keyboard: .URL)
            .onSubmit(checkServer)
            .onChange(of: serverText) { _ in custom = nil }
        errorBanner
        if let c = custom {
            serverCard(c)
            Button { go(.signIn, server: c) } label: {
                Text("common.log_in").frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            Button { go(.signUp, server: c) } label: {
                Group {
                    if c.registrationOpen { Text("login.sign_up") } else { Text("login.sign_up_invite") }
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.bordered)
        } else {
            Button(action: checkServer) {
                Group {
                    if busy { ProgressView().tint(.white) } else { Text("login.custom.continue") }
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || serverText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// Name, version, registration and environment of a server.
    private func serverCard(_ c: ServerDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").foregroundColor(Brand.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: c.name).font(.headline)
                    Text(verbatim: c.url).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Text("login.server.version \(c.version)").font(.subheadline).foregroundColor(.secondary)
            Group {
                if c.registrationOpen { Text("login.server.registration_open") } else { Text("login.server.registration_closed") }
            }
            .font(.subheadline).foregroundColor(.secondary)
            if let env = c.environment {
                Label(String(localized: "login.server.environment \(env)"), systemImage: "flask")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.amber)
            }
            if c.insecure {
                Label("login.server.insecure", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundColor(Brand.red)
            }
            if !c.vaults {
                Text("login.server.no_vaults").font(.caption).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    /// The server the forms are for.
    @ViewBuilder private var serverHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: custom == nil ? "checkmark.seal" : "server.rack")
            Text(verbatim: custom.map { $0.url.replacingOccurrences(of: "https://", with: "") } ?? officialHost)
        }
        .font(.subheadline)
        .foregroundColor(.secondary)
        if let env = details?.environment {
            Label(String(localized: "login.server.environment \(env)"), systemImage: "flask")
                .font(.caption.weight(.semibold))
                .foregroundColor(Brand.amber)
        }
    }

    @ViewBuilder private var signInStep: some View {
        Text("login.sign_in.title").font(.title2.bold())
        serverHeader
        if needsTotp {
            Text("login.code_hint")
                .font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        VStack(spacing: 12) {
            if needsTotp {
                // Six digits or a recovery code (xxxx-xxxx, letters too): a text keyboard.
                LoginField(icon: "number", title: String(localized: "login.code"), text: $totp, keyboard: .asciiCapable,
                           contentType: .oneTimeCode)
                Text("login.recovery_hint").font(.caption).foregroundColor(.secondary)
            } else {
                LoginField(icon: "envelope", title: String(localized: "login.email"), text: $email, keyboard: .emailAddress,
                           contentType: .username)
                LoginField(icon: "lock", title: String(localized: "common.password"), text: $password, secure: true,
                           contentType: .password, onSubmit: signIn)
            }
        }
        errorBanner
        Button(action: signIn) {
            Group {
                if busy {
                    ProgressView().tint(.white)
                } else if needsTotp {
                    Text("login.verify")
                } else {
                    Text("common.log_in")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.borderedProminent)
        .disabled(busy || email.isEmpty || password.isEmpty || (needsTotp && totp.isEmpty))
        if needsTotp {
            Button("login.back") { needsTotp = false; totp = "" }
        } else {
            Button("login.forgot_password") { openForgotPassword() }
                .font(.footnote)
            if resume == nil {
                Button { go(.signUp, server: custom) } label: { Text("login.no_account_yet") }
                    .font(.footnote)
            }
        }
    }

    @ViewBuilder private var signUpStep: some View {
        Text("login.sign_up.title").font(.title2.bold())
        serverHeader
        VStack(spacing: 12) {
            LoginField(icon: "person", title: String(localized: "login.name"), text: $name, contentType: .name)
            LoginField(icon: "envelope", title: String(localized: "login.email"), text: $email, keyboard: .emailAddress,
                       contentType: .username)
            LoginField(icon: "lock", title: String(localized: "login.new_password"), text: $password, secure: true,
                       contentType: .newPassword)
            if custom.map({ !$0.registrationOpen }) == true || inviteLink != nil {
                LoginField(icon: "ticket", title: String(localized: "login.invite"), text: $invite, keyboard: .asciiCapable)
            }
            if let invitation { inviteCard(invitation) }
        }
        if let terms = details?.termsUrl {
            Toggle(isOn: $acceptTerms) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("login.terms.accept").font(.callout)
                    HStack(spacing: 12) {
                        Button("login.terms.link") { if let u = URL(string: terms) { openURL(u) } }
                        if let privacy = details?.privacyUrl {
                            Button("login.privacy.link") { if let u = URL(string: privacy) { openURL(u) } }
                        }
                    }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 4)
        }
        errorBanner
        Button(action: signUp) {
            Group {
                if busy { ProgressView().tint(.white) } else { Text("login.sign_up.action") }
            }
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.borderedProminent)
        .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || email.isEmpty || password.count < 8
                  || (details?.termsUrl != nil && !acceptTerms)
                  || (custom.map { !$0.registrationOpen } == true && invite.trimmingCharacters(in: .whitespaces).isEmpty))
        Text("login.password_rules").font(.caption).foregroundColor(.secondary)
        Button { go(.signIn, server: custom) } label: { Text("login.have_account") }
            .font(.footnote)
    }

    /// "You will join the team “Ops”. Only for ana@example.com. Expires on…"
    private func inviteCard(_ i: InviteInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let team = i.team {
                Text("login.invite.join_team \(team)")
            } else {
                Text("login.invite.valid")
            }
            if let mail = i.email { Text("login.invite.only_for \(mail)") }
            if let exp = i.expiresAt {
                Text("login.invite.expires \(Date(timeIntervalSince1970: TimeInterval(exp) / 1000).formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .font(.footnote)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Brand.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var errorBanner: some View {
        if let error {
            Text(error)
                .font(.callout)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Brand.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// "Check your email": the six-digit code the server emailed.
    @ViewBuilder private func verifyStep(accountId: String, email: String) -> some View {
        Image(systemName: "envelope.badge")
            .font(.system(size: 34))
            .foregroundColor(Brand.blue)
        Text("login.verify_email.title").font(.title2.bold())
        Text("login.verify_email.sent \(email)")
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.bottom, 12)

        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "envelope.open").foregroundColor(.secondary).frame(width: 22)
                TextField(String(localized: "login.verify_email.code"), text: $emailCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(.title3, design: .monospaced))
                    // Pasted codes may come as "123 456" or "123-456".
                    .onChange(of: emailCode) { value in
                        let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                        if digits != value { emailCode = digits }
                        // The sixth digit sends it (like Android), unless a
                        // two-step code is still missing.
                        if digits == value && digits.count == 6 {
                            autoVerify(accountId, digits)
                        }
                    }
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            if verifyNeedsTotp {
                LoginField(icon: "number", title: String(localized: "login.code"), text: $verifyTotp, keyboard: .asciiCapable,
                           contentType: .oneTimeCode)
                Text("login.code_hint").font(.caption).foregroundColor(.secondary)
                Text("login.recovery_hint").font(.caption).foregroundColor(.secondary)
            }
        }
        if resent && error == nil {
            Text("login.verify_email.resent")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        errorBanner
        Button { verify(accountId) } label: {
            Group {
                if busy { ProgressView().tint(.white) } else { Text("login.verify") }
            }
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.borderedProminent)
        .disabled(busy || emailCode.count != 6 || (verifyNeedsTotp && verifyTotp.isEmpty))
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let wait = max(0, Int(ceil((resendAt ?? .distantPast).timeIntervalSince(context.date))))
            Button { resend(accountId) } label: {
                if wait > 0 {
                    Text("login.verify_email.resend_in \(wait)")
                } else {
                    Text("login.verify_email.resend")
                }
            }
            .disabled(busy || wait > 0)
        }
        Button("login.verify_email.different_email") { differentEmail(accountId) }
            .padding(.top, 12)
        // The account waits for its code ("Enter the email code" in the vault).
        Button("login.verify_email.later_button") { done() }
            .disabled(busy)
        Text("login.verify_email.later")
            .font(.footnote).foregroundColor(.secondary)
            .multilineTextAlignment(.center)
        Text("login.verify_email.spam_hint")
            .font(.footnote).foregroundColor(.secondary)
            .multilineTextAlignment(.center)
    }

    // MARK: Actions

    private func start() {
        if let link = inviteLink {
            startInvite(link)
            return
        }
        guard let r = resume else {
            if email.isEmpty { email = UserDefaults.standard.string(forKey: Self.lastEmailKey) ?? "" }
            return
        }
        email = r.email
        if !r.official {
            serverText = r.serverUrl
            Task {
                if let json = try? await serverInfo(url: r.serverUrl) {
                    custom = try? ServerDetails(url: r.serverUrl, json: json)
                }
                // Without its /info the account's own address is used.
                if custom == nil { custom = try? ServerDetails(url: r.serverUrl, json: "{}") }
            }
        }
        if r.status == .unverified {
            step = .verify(accountId: r.id, email: r.email)
        } else {
            step = .signIn
        }
    }

    /// A `termoak://invite` link: the sign-up form of its server with the
    /// code filled in, and what the invitation is for.
    private func startInvite(_ link: InviteLink) {
        guard step == .start, invite.isEmpty else { return }
        invite = link.token
        let isOfficial = JoinLink.sameServer(link.server, officialServerUrl())
        if isOfficial {
            go(.signUp, server: nil)
        } else {
            serverText = link.server
            step = .signUp
            Task {
                if let json = try? await serverInfo(url: link.server) {
                    custom = try? ServerDetails(url: link.server, json: json)
                }
                if custom == nil { custom = try? ServerDetails(url: link.server, json: "{}") }
            }
        }
        Task {
            do {
                let info = try await inviteInfo(url: link.server, token: link.token)
                invitation = info
                if email.isEmpty, let mail = info.email { email = mail }
            } catch {
                self.error = userMessage(error)
            }
        }
    }

    private func back() {
        error = nil
        needsTotp = false
        switch step {
        case .signIn, .signUp: step = custom == nil ? .start : .custom
        default: step = .start
        }
    }

    /// To a form, for the official server (`nil`) or your own.
    private func go(_ s: Step, server: ServerDetails?) {
        error = nil
        custom = server
        step = s
        if server == nil && official == nil {
            let url = officialServerUrl()
            Task {
                if let json = try? await serverInfo(url: url) { official = try? ServerDetails(url: url, json: json) }
            }
        }
    }

    /// Checks the address with `/info` and shows what the server says.
    private func checkServer() {
        let typed = serverText.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let url = try canonicalServerUrl(url: typed)
                let json = try await serverInfo(url: url)
                let d = try ServerDetails(url: url, json: json)
                // The official server typed by hand is the official one.
                custom = url == officialServerUrl() ? nil : d
                if url == officialServerUrl() {
                    official = d
                    step = .signIn
                }
            } catch {
                self.error = String(localized: "login.server.unreachable \(userMessage(error))")
            }
        }
    }

    private func openForgotPassword() {
        let base = custom?.url ?? officialServerUrl()
        if let u = URL(string: "\(base)/forgot-password") { openURL(u) }
    }

    private func signIn() {
        busy = true
        error = nil
        let mail = email.trimmingCharacters(in: .whitespaces)
        let code = needsTotp && !totp.isEmpty ? totp : nil
        Task {
            defer { busy = false }
            do {
                let info = try await account.signIn(server: choice, email: mail, password: password, totp: code)
                UserDefaults.standard.set(mail, forKey: Self.lastEmailKey)
                finishOrVerify(info)
            } catch TermoakError.TotpRequired {
                needsTotp = true
            } catch TermoakError.TotpInvalid {
                error = String(localized: "login.code_invalid")
            } catch {
                self.error = userMessage(error)
            }
        }
    }

    private func signUp() {
        busy = true
        error = nil
        let mail = email.trimmingCharacters(in: .whitespaces)
        let code = invite.trimmingCharacters(in: .whitespaces)
        Task {
            defer { busy = false }
            do {
                let info = try await account.signUp(server: choice, email: mail,
                                                    name: name.trimmingCharacters(in: .whitespaces),
                                                    password: password, invite: code.isEmpty ? nil : code,
                                                    acceptTerms: details?.termsUrl != nil && acceptTerms)
                UserDefaults.standard.set(mail, forKey: Self.lastEmailKey)
                finishOrVerify(info)
            } catch {
                self.error = userMessage(error)
            }
        }
    }

    /// Signed in; or the email still has to be verified with its code.
    private func finishOrVerify(_ info: AccountInfo) {
        if info.status == .unverified {
            password = ""
            resendAt = Date().addingTimeInterval(60)
            step = .verify(accountId: info.id, email: info.email)
            return
        }
        done()
    }

    private func done() {
        onFinish()
        if !welcome { dismiss() }
    }

    /// The last email signed in with (prefilled next time, like Android).
    static let lastEmailKey = "last_login_email"

    /// Sends the code once its sixth digit is typed or pasted.
    private func autoVerify(_ accountId: String, _ code: String) {
        guard !busy, !verifyNeedsTotp, code.count == 6 else { return }
        verify(accountId)
    }

    private func verify(_ accountId: String) {
        busy = true
        error = nil
        resent = false
        let totp = verifyNeedsTotp && !verifyTotp.isEmpty ? verifyTotp : nil
        Task {
            defer { busy = false }
            do {
                _ = try await account.verify(accountId, code: emailCode, totp: totp)
                done()
            } catch TermoakError.TotpRequired {
                verifyNeedsTotp = true
            } catch TermoakError.TotpInvalid {
                error = String(localized: "login.code_invalid")
            } catch TermoakError.Invalid {
                error = String(localized: "login.verify_email.invalid_code")
            } catch {
                self.error = userMessage(error)
            }
        }
    }

    private func resend(_ accountId: String) {
        busy = true
        error = nil
        resent = false
        Task {
            defer { busy = false }
            do {
                try await account.resendCode(accountId)
                resent = true
            } catch {
                // Usually "too many attempts" (HTTP 429): wait before retrying.
                self.error = userMessage(error)
            }
            resendAt = Date().addingTimeInterval(60)
        }
    }

    /// Drops the unverified account to start again with another email.
    private func differentEmail(_ accountId: String) {
        busy = true
        Task {
            defer { busy = false }
            _ = try? await account.signOut(accountId, discard: true)
            emailCode = ""
            verifyTotp = ""
            verifyNeedsTotp = false
            resendAt = nil
            resent = false
            error = nil
            password = ""
            step = .start
        }
    }
}

struct LoginField: View {
    let icon: String
    let title: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var secure = false
    /// For autofill and password managers (`.username`, `.password`,
    /// `.newPassword`, `.oneTimeCode`...).
    var contentType: UITextContentType? = nil
    var onSubmit: (() -> Void)? = nil
    /// A password shown as text (the eye button).
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(.secondary).frame(width: 22)
            if secure {
                passwordField
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye").foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(revealed ? Text("login.password.hide") : Text("login.password.show"))
            } else {
                TextField(title, text: $text)
                    .keyboardType(keyboard)
                    .textContentType(contentType)
                    .textInputAutocapitalization(keyboard == .default && contentType != .username ? .words : .never)
                    .autocorrectionDisabled()
                    .onSubmit { onSubmit?() }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var passwordField: some View {
        if revealed {
            TextField(title, text: $text)
                .textContentType(contentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { onSubmit?() }
        } else {
            SecureField(title, text: $text)
                .textContentType(contentType)
                .onSubmit { onSubmit?() }
        }
    }
}
