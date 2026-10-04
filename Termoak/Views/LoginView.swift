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
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Brand.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                }
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
            .padding(24)
        }
        .onAppear {
            server = settings.lastServer ?? defaultServer
            email = settings.lastEmail ?? ""
        }
    }

    private func logIn() {
        busy = true
        error = nil
        let url = server.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        Task {
            defer { busy = false }
            do {
                try await account.logIn(server: url, email: email.trimmingCharacters(in: .whitespaces),
                                        password: password, code: code.isEmpty ? nil : code)
                settings.lastServer = url
                settings.lastEmail = email
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
