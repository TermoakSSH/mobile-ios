import TermoakKit
import SwiftUI
import UIKit

/// Two-step verification of one account (any signed-in one, through its
/// `AccountHandle`): its state and recovery codes left; turn it on (QR code
/// or secret for the authenticator app, a code to confirm, then the recovery
/// codes shown once) or off (password and a code).
struct TwoFactorView: View {
    let accountId: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.openURL) private var openURL

    @State private var status: TwoFactorStatus?
    @State private var setup: TwoFactorSetup?
    @State private var code = ""
    @State private var password = ""
    @State private var recoveryCodes: [String] = []
    @State private var disabling = false
    @State private var busy = false
    @State private var error: String?
    @State private var copied = false
    @State private var sharingCodes = false

    private var info: AccountInfo? { account.account(accountId) }

    var body: some View {
        Form {
            stateSection
            if !recoveryCodes.isEmpty {
                recoverySection
            } else if let setup {
                setupSections(setup)
            } else if status?.enabled == true {
                disableSection
            } else if status != nil {
                enableSection
            }
            if let error {
                Section { Text(error).foregroundColor(Brand.red) }
            }
            webSection
        }
        .navigationTitle("two_factor.title")
        .sheet(isPresented: $sharingCodes) { ActivityView(items: [recoveryCodes.joined(separator: "\n")]) }
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(Text("two_factor.turn_off_confirm"), isPresented: $disabling, titleVisibility: .visible) {
            Button("two_factor.turn_off", role: .destructive, action: disable)
        }
        .task { await load() }
    }

    // MARK: Sections

    private var stateSection: some View {
        Section {
            HStack {
                Label("settings.two_factor", systemImage: "lock.shield")
                Spacer()
                if let status {
                    Chip(status.enabled ? String(localized: "settings.two_factor.on") : String(localized: "settings.two_factor.off"),
                         status.enabled ? Brand.green : Brand.amber)
                } else {
                    ProgressView()
                }
            }
            if let status, status.enabled {
                Text("two_factor.codes_left \(Int(status.recoveryCodesLeft))")
                    .font(.footnote).foregroundColor(.secondary)
            }
        } header: {
            if account.list.count > 1, let info { Text(verbatim: info.displayLabel) }
        } footer: {
            Text("two_factor.explain")
        }
    }

    private var enableSection: some View {
        Section {
            Button(action: startSetup) {
                HStack {
                    Label("two_factor.turn_on", systemImage: "lock.shield")
                    Spacer()
                    if busy { ProgressView() }
                }
            }
            .disabled(busy)
        }
    }

    @ViewBuilder private func setupSections(_ s: TwoFactorSetup) -> some View {
        Section {
            HStack {
                Spacer()
                TwoFactorQr(text: s.otpauthUrl)
                    .frame(width: 200, height: 200)
                Spacer()
            }
            .padding(.vertical, 8)
            if let url = URL(string: s.otpauthUrl) {
                Button { openURL(url) } label: { Label("two_factor.open_app", systemImage: "arrow.up.forward.app") }
            }
            HStack {
                Text(verbatim: s.secret)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button { UIPasteboard.general.string = s.secret } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("two_factor.copy_secret"))
            }
        } header: {
            Text("two_factor.step_scan")
        } footer: {
            Text("two_factor.scan_footer")
        }
        Section {
            TextField("login.code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(.body, design: .monospaced))
            Button(action: enable) {
                HStack {
                    Text("two_factor.confirm")
                    Spacer()
                    if busy { ProgressView() }
                }
            }
            .disabled(busy || code.trimmingCharacters(in: .whitespaces).count < 6)
            Button("common.cancel", role: .cancel) {
                setup = nil
                code = ""
            }
        } header: {
            Text("two_factor.step_code")
        }
    }

    private var recoverySection: some View {
        Section {
            ForEach(recoveryCodes, id: \.self) { c in
                Text(verbatim: c).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            Button {
                UIPasteboard.general.string = recoveryCodes.joined(separator: "\n")
                copied = true
            } label: {
                Label(copied ? String(localized: "two_factor.copied") : String(localized: "two_factor.copy_codes"),
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            Button { sharingCodes = true } label: { Label("two_factor.share_codes", systemImage: "square.and.arrow.up") }
            Button("common.done") {
                recoveryCodes = []
                copied = false
            }
        } header: {
            Text("two_factor.recovery_title")
        } footer: {
            Text("two_factor.recovery_footer")
        }
    }

    private var disableSection: some View {
        Section {
            SecureField("common.password", text: $password)
                .textContentType(.password)
            TextField("login.code", text: $code)
                .keyboardType(.asciiCapable)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(role: .destructive) { disabling = true } label: {
                HStack {
                    Text("two_factor.turn_off")
                    Spacer()
                    if busy { ProgressView() }
                }
            }
            .disabled(busy || password.isEmpty || code.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("two_factor.turn_off")
        } footer: {
            Text("two_factor.turn_off_footer")
        }
    }

    @ViewBuilder private var webSection: some View {
        if let server = info?.serverUrl, let url = URL(string: "\(server)/app/account") {
            Section {
                Button { openURL(url) } label: { Label("settings.web_account", systemImage: "arrow.up.right.square") }
            }
        }
    }

    // MARK: Actions

    /// The account's own engine calls (not only the current account's).
    private func handle() throws -> AccountHandle {
        try model.core.account(accountId: accountId)
    }

    private func load() async {
        do {
            status = try await handle().twoFactorStatus()
        } catch {
            self.error = userMessage(error)
        }
    }

    private func startSetup() {
        run {
            setup = try await handle().setupTwoFactor()
            code = ""
        }
    }

    private func enable() {
        let c = code.trimmingCharacters(in: .whitespaces)
        run {
            recoveryCodes = try await handle().enableTwoFactor(code: c)
            setup = nil
            code = ""
            await load()
        }
    }

    private func disable() {
        let p = password, c = code.trimmingCharacters(in: .whitespaces)
        run {
            try await handle().disableTwoFactor(password: p, code: c)
            password = ""
            code = ""
            await load()
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await action()
            } catch TermoakError.TotpInvalid {
                error = String(localized: "login.code_invalid")
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}

/// Settings and an account's page: two-step verification of that account,
/// On with the recovery codes left or Off; it opens the page that turns it
/// on or off.
struct TwoFactorRow: View {
    let accountId: String
    @EnvironmentObject private var model: AppModel
    @State private var status: TwoFactorStatus?

    var body: some View {
        NavigationLink { TwoFactorView(accountId: accountId) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("settings.two_factor", systemImage: "lock.shield")
                    if let tf = status {
                        Text(tf.enabled ? String(localized: "two_factor.codes_left \(Int(tf.recoveryCodesLeft))")
                                        : String(localized: "two_factor.off_hint"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
                if let tf = status {
                    Chip(tf.enabled ? String(localized: "settings.two_factor.on") : String(localized: "settings.two_factor.off"),
                         tf.enabled ? Brand.green : Brand.amber)
                }
            }
        }
        // Again when coming back from its page (it may have changed).
        .onAppear { Task { await load() } }
    }

    private func load() async {
        status = try? await model.core.account(accountId: accountId).twoFactorStatus()
    }
}

/// A QR code drawn from the engine's modules (black on white, with its quiet
/// zone).
private struct TwoFactorQr: View {
    let text: String

    var body: some View {
        if let qr = qrCode(text: text) {
            TwoFactorQrShape(size: Int(qr.size), modules: qr.modules)
                .fill(Color.black)
                .padding(12)
                .background(Color.white)
                .accessibilityLabel(Text("two_factor.qr"))
        } else {
            Image(systemName: "qrcode").font(.largeTitle).foregroundColor(.secondary)
        }
    }
}

private struct TwoFactorQrShape: Shape {
    let size: Int
    let modules: [Bool]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard size > 0, modules.count >= size * size else { return p }
        let cell = min(rect.width, rect.height) / CGFloat(size)
        for y in 0..<size {
            for x in 0..<size where modules[y * size + x] {
                p.addRect(CGRect(x: rect.minX + CGFloat(x) * cell, y: rect.minY + CGFloat(y) * cell, width: cell, height: cell))
            }
        }
        return p
    }
}
