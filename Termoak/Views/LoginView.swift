import TermoakKit
import SwiftUI

struct LoginView: View {
    let welcome: Bool
    let onFinish: () -> Void

    @EnvironmentObject private var account: Account
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var server = ""
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var needsCode = false
    @State private var busy = false
    @State private var error: String?

    // Email verification (`account.pendingVerification`).
    @State private var emailCode = ""
    @State private var verifyTotp = ""
    @State private var verifyNeedsTotp = false
    /// The "Resend" button waits until then (the server allows one email a minute).
    @State private var resendAt: Date?
    @State private var resent = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !welcome {
                    HStack {
                        Button("common.cancel") { dismiss() }
                        Spacer()
                    }
                }
                Image("Logo")
                    .resizable()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.top, welcome ? 40 : 8)
                Text(verbatim: "Termoak").font(.largeTitle.bold())
                if let pending = account.pendingVerification {
                    verifyStep(email: pending.isEmpty ? email : pending)
                } else {
                    signInForm
                }
            }
            .padding(24)
        }
        .onAppear {
            server = settings.lastServer ?? defaultServer
            email = settings.lastEmail ?? ""
        }
    }

    @ViewBuilder
    private var signInForm: some View {
        Text(needsCode ? String(localized: "login.code_hint") : String(localized: "login.tagline"))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.bottom, 12)

        VStack(spacing: 12) {
            if needsCode {
                LoginField(icon: "number", title: String(localized: "login.code"), text: $code, keyboard: .numberPad)
                Text("login.recovery_hint").font(.caption).foregroundColor(.secondary)
            } else {
                LoginField(icon: "server.rack", title: String(localized: "login.server"), text: $server, keyboard: .URL)
                LoginField(icon: "envelope", title: String(localized: "login.email"), text: $email, keyboard: .emailAddress)
                LoginField(icon: "lock", title: String(localized: "common.password"), text: $password, secure: true)
            }
        }
        errorBanner
        Button(action: logIn) {
            Group {
                if busy {
                    ProgressView().tint(.white)
                } else {
                    Text(needsCode ? String(localized: "login.verify") : String(localized: "common.log_in"))
                }
            }
            .frame(maxWidth: .infinity).frame(height: 30)
        }
        .buttonStyle(.borderedProminent)
        .disabled(busy || server.isEmpty || email.isEmpty || password.isEmpty || (needsCode && code.isEmpty))
        if needsCode {
            Button("login.back") { needsCode = false; code = "" }
        }
        if welcome {
            Button("login.no_server") {
                settings.noServer = true
                onFinish()
            }
            .padding(.top, 24)
        }
        Text("login.no_account")
            .font(.footnote).foregroundColor(.secondary)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error {
            Text(error)
                .font(.callout)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Brand.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// "Check your email": the six-digit code the server emailed to `email`.
    @ViewBuilder
    private func verifyStep(email: String) -> some View {
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
                    }
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            if verifyNeedsTotp {
                LoginField(icon: "number", title: String(localized: "login.code"), text: $verifyTotp, keyboard: .numberPad)
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
        Button { verify(email: email) } label: {
            Group {
                if busy {
                    ProgressView().tint(.white)
                } else {
                    Text("login.verify")
                }
            }
            .frame(maxWidth: .infinity).frame(height: 30)
        }
        .buttonStyle(.borderedProminent)
        .disabled(busy || emailCode.count != 6 || (verifyNeedsTotp && verifyTotp.isEmpty))
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let wait = max(0, Int(ceil((resendAt ?? .distantPast).timeIntervalSince(context.date))))
            Button { resend(email: email) } label: {
                if wait > 0 {
                    Text("login.verify_email.resend_in \(wait)")
                } else {
                    Text("login.verify_email.resend")
                }
            }
            .disabled(busy || wait > 0)
        }
        Button("login.verify_email.different_email") { differentEmail() }
            .padding(.top, 12)
        Text("login.verify_email.spam_hint")
            .font(.footnote).foregroundColor(.secondary)
            .multilineTextAlignment(.center)
    }

    /// The URL of the server the account signed in to.
    private var serverUrl: String {
        account.server ?? server.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func verify(email: String) {
        busy = true
        error = nil
        resent = false
        let url = serverUrl
        let totp = verifyNeedsTotp && !verifyTotp.isEmpty ? verifyTotp : nil
        Task {
            defer { busy = false }
            do {
                try await account.verifyEmail(server: url, email: email, code: emailCode, totpCode: totp)
                settings.lastServer = url
                settings.lastEmail = email
                resetVerification()
                onFinish()
                if !welcome { dismiss() }
            } catch TermoakError.TotpRequired {
                verifyNeedsTotp = true
            } catch TermoakError.TotpInvalid {
                error = String(localized: "login.code_invalid")
            } catch TermoakError.Invalid {
                error = String(localized: "login.verify_email.invalid_code")
            } catch {
                self.error = errorMessage(error)
            }
        }
    }

    private func resend(email: String) {
        busy = true
        error = nil
        resent = false
        let url = serverUrl
        Task {
            defer { busy = false }
            do {
                try await account.resendCode(server: url, email: email)
                resent = true
            } catch {
                // Usually "too many attempts" (HTTP 429): wait before retrying.
                self.error = errorMessage(error)
            }
            resendAt = Date().addingTimeInterval(60)
        }
    }

    private func differentEmail() {
        busy = true
        Task {
            defer { busy = false }
            await account.cancelVerification()
            resetVerification()
            password = ""
            code = ""
            needsCode = false
        }
    }

    private func resetVerification() {
        emailCode = ""
        verifyTotp = ""
        verifyNeedsTotp = false
        resendAt = nil
        resent = false
        error = nil
    }

    private func logIn() {
        busy = true
        error = nil
        let url = server.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        Task {
            defer { busy = false }
            do {
                let done = try await account.logIn(server: url, email: email.trimmingCharacters(in: .whitespaces),
                                                   password: password, code: code.isEmpty ? nil : code)
                settings.lastServer = url
                settings.lastEmail = email
                guard done else {
                    // The account has to verify its email: the code step
                    // (`account.pendingVerification`) takes over. Signing in
                    // may have just emailed a new code.
                    needsCode = false
                    code = ""
                    resendAt = Date().addingTimeInterval(60)
                    return
                }
                onFinish()
                if !welcome { dismiss() }
            } catch TermoakError.TotpRequired {
                needsCode = true
            } catch TermoakError.TotpInvalid {
                error = String(localized: "login.code_invalid")
            } catch {
                self.error = errorMessage(error)
            }
        }
    }
}

private struct LoginField: View {
    let icon: String
    let title: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var secure = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(.secondary).frame(width: 22)
            Group {
                if secure {
                    SecureField(title, text: $text)
                } else {
                    TextField(title, text: $text)
                        .keyboardType(keyboard)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
