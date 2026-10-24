import SwiftUI
import TermoakKit
import UIKit

// MARK: - The sheet over everything

/// The security key sheet: "Hold your security key near the top of the
/// iPhone", the PIN, "Touch your security key" with the host, user, key and
/// purpose, and Cancel. Shown in its own window above everything (the
/// terminal, other sheets), as the flow asks (from any thread).
final class SecurityKeySheetModel: ObservableObject, SecurityKeyUI, @unchecked Sendable {
    weak var flow: SecurityKeyFlow?
    @Published private(set) var sheet: SKSheet?
    /// The PIN typed (cleared every time the PIN is asked).
    @Published var pin = ""
    private var window: UIWindow?

    func show(_ s: SKSheet) {
        DispatchQueue.main.async {
            if case .pin = s.stage, self.sheet?.stage != s.stage { self.pin = "" }
            self.sheet = s
            self.present()
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.sheet = nil
            self.pin = ""
            self.window?.isHidden = true
            self.window = nil
        }
    }

    /// A button of the sheet.
    func act(_ action: SKUserAction) {
        if case .pin = action { pin = "" }
        flow?.userAction(action)
    }

    private func present() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.backgroundColor = .clear
        let host = UIHostingController(rootView: SecurityKeyOverlay(model: self))
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        window = w
    }
}

private struct SecurityKeyOverlay: View {
    @ObservedObject var model: SecurityKeySheetModel

    var body: some View {
        ZStack(alignment: .bottom) {
            if let sheet = model.sheet {
                Color.black.opacity(0.35).ignoresSafeArea()
                SecurityKeyCard(sheet: sheet, pin: $model.pin) { model.act($0) }
                    .padding(12)
                    .frame(maxWidth: 520)
                    .transition(.move(edge: .bottom))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.2), value: model.sheet)
    }
}

/// The card's content for one stage (also drawn by the screenshots).
struct SecurityKeyCard: View {
    let sheet: SKSheet
    @Binding var pin: String
    let act: (SKUserAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundColor(Brand.blue).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.subheadline).foregroundColor(.secondary) }
                }
            }
            details
            if case .pin(let retry, let left) = sheet.stage {
                SecureField("security_keys.sheet.pin_placeholder", text: $pin)
                    .textContentType(.password)
                    .padding(10)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit { if !pin.isEmpty { act(.pin(pin)) } }
                if retry {
                    Text(left.map { String(localized: "security_keys.sheet.pin_wrong_left \($0)") }
                         ?? String(localized: "security_keys.sheet.pin_wrong"))
                        .font(.footnote).foregroundColor(Brand.red)
                }
            }
            buttons
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var icon: String {
        switch sheet.stage {
        case .insert(let nfc): return nfc ? "wave.3.right" : "cable.connector"
        case .pin: return "lock.fill"
        case .touch: return "hand.point.up.left.fill"
        case .working: return "key.fill"
        }
    }

    private var title: String {
        switch sheet.stage {
        case .insert(let nfc):
            return nfc ? String(localized: "security_keys.sheet.nfc_title") : String(localized: "security_keys.sheet.insert_title")
        case .pin: return String(localized: "security_keys.sheet.pin_title")
        case .touch: return String(localized: "security_keys.sheet.touch_title")
        case .working: return String(localized: "security_keys.sheet.working_title")
        }
    }

    private var subtitle: String? {
        switch sheet.stage {
        case .insert(let nfc):
            if sheet.purpose.forwarded { return String(localized: "security_keys.sheet.insert_forwarded") }
            return nfc ? String(localized: "security_keys.sheet.nfc_text") : String(localized: "security_keys.sheet.insert_text")
        case .pin: return String(localized: "security_keys.sheet.pin_text")
        case .touch: return String(localized: "security_keys.sheet.touch_text")
        case .working:
            if case .sign = sheet.purpose { return String(localized: "security_keys.sheet.working_text") }
            return nil
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            line("security_keys.sheet.purpose", securityKeyPurposeText(sheet.purpose))
            switch sheet.purpose {
            case .sign(let c):
                line("security_keys.sheet.host", c.target)
                if !c.keyText.isEmpty { line("security_keys.sheet.key", c.keyText) }
            case .create(let application):
                line("security_keys.sheet.application", application)
            case .loadResident:
                EmptyView()
            }
        }
        .font(.footnote)
    }

    private func line(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).foregroundColor(.secondary).frame(width: 78, alignment: .leading)
            Text(verbatim: value).lineLimit(2)
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            if case .insert(let nfc) = sheet.stage, !nfc, sheet.nfcAvailable {
                Button { act(.useNFC) } label: { Label("security_keys.sheet.use_nfc", systemImage: "wave.3.right") }
                    .buttonStyle(.bordered)
            }
            if case .insert = sheet.stage, sheet.purpose.forwarded {
                Button("security_keys.sheet.not_here") { act(.notHere) }
                    .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
            Button("common.cancel", role: .cancel) { act(.cancel) }
                .buttonStyle(.bordered)
            if case .pin = sheet.stage {
                Button("security_keys.sheet.pin_ok") { act(.pin(pin)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(pin.isEmpty)
            }
        }
        .font(.subheadline)
    }
}

// MARK: - Keychain: new key, load resident keys, details

/// A new key made inside a security key (it never leaves it).
struct NewSecurityKeyView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var algorithm: SecurityKeyAlgorithm = .ed25519
    @State private var resident = false
    @State private var verify = false
    @State private var noTouch = false
    @State private var application = "ssh:"
    @State private var user = ""
    @State private var device = ""
    @State private var place: ItemPlace = .device
    @State private var advanced = false
    @State private var busy = false
    @State private var error: String?

    private var applicationOk: Bool {
        let a = application.trimmingCharacters(in: .whitespaces)
        return a.hasPrefix("ssh:") && a.count <= 128
    }

    private var userOk: Bool { user.utf8.count <= 32 }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField(String(localized: "keychain.sk.name_placeholder"), text: $name)
                    Picker("common.type", selection: $algorithm) {
                        Text("keychain.sk.type_ed25519").tag(SecurityKeyAlgorithm.ed25519)
                        Text("keychain.sk.type_ecdsa").tag(SecurityKeyAlgorithm.ecdsaP256)
                    }
                } footer: { Text("keychain.sk.new_intro") }
                Section {
                    Toggle("keychain.sk.resident_label", isOn: $resident)
                    Toggle("keychain.sk.verify_label", isOn: $verify)
                } footer: {
                    if resident { Text("keychain.sk.resident_hint") }
                }
                Section {
                    TextField(String(localized: "keychain.sk.device_placeholder"), text: $device)
                } header: { Text("keychain.sk.device_label") }
                Section {
                    DisclosureGroup(isExpanded: $advanced) {
                        Toggle("keychain.sk.no_touch_label", isOn: $noTouch)
                        if noTouch {
                            Text("keychain.sk.no_touch_hint").font(.footnote).foregroundColor(.secondary)
                            Text("keychain.sk.no_touch_warning").font(.footnote).foregroundColor(Brand.amber)
                        }
                        TextField("keychain.sk.application", text: $application)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text(LocalizedStringKey(applicationOk ? "keychain.sk.application_hint" : "keychain.sk.application_invalid"))
                            .font(.footnote).foregroundColor(applicationOk ? .secondary : Brand.red)
                        TextField(String(localized: "keychain.sk.user_label"), text: $user)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text(LocalizedStringKey(userOk ? "keychain.sk.user_hint" : "keychain.sk.user_too_long"))
                            .font(.footnote).foregroundColor(userOk ? .secondary : Brand.red)
                    } label: { Text("keychain.sk.advanced") }
                }
                if !account.list.isEmpty { PlacePicker(place: $place) }
                if let error { Text(error).foregroundColor(Brand.red) }
            }
            .navigationTitle("keychain.sk.new_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("keychain.sk.create", action: create).disabled(busy || !applicationOk || !userOk)
                }
            }
        }
        .onAppear { place = account.defaultPlace }
    }

    private func create() {
        busy = true
        error = nil
        let label = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? String(localized: "keychain.sk.badge") : name.trimmingCharacters(in: .whitespaces)
        let options = SecurityKeyOptions(
            algorithm: algorithm,
            application: application.trimmingCharacters(in: .whitespaces) == "ssh:" ? nil : application.trimmingCharacters(in: .whitespaces),
            user: user.trimmingCharacters(in: .whitespaces).isEmpty ? nil : user.trimmingCharacters(in: .whitespaces),
            resident: resident, verifyRequired: verify, noTouchRequired: noTouch,
            device: device.trimmingCharacters(in: .whitespaces).isEmpty ? nil : String(device.trimmingCharacters(in: .whitespaces).prefix(64)))
        let p = account.list.isEmpty ? ItemPlace.device : place
        Task {
            defer { busy = false }
            do {
                _ = try await model.core.createSecurityKey(
                    label: label, options: options, comment: "\(label) (Termoak)",
                    syncMode: account.list.isEmpty ? nil : (p.accountId == nil ? .deviceOnly : .synced),
                    accountId: p.accountId, vaultId: p.vaultId, handler: AppSecurityKeys.shared)
                account.rememberPlace(p)
                account.sync()
                dismiss()
            } catch {
                // Cancelled in the sheet: nothing to say.
                if skCode(error) == .cancelled { return }
                self.error = String(localized: "keychain.sk.failed \(userMessage(error))")
            }
        }
    }
}

/// The security key code of an engine error, if it is one.
func skCode(_ error: Error) -> SKCode? {
    guard let e = error as? TermoakError else { return nil }
    if let info = e.apiError, info.code.hasPrefix("security_key_") { return SKCode.parse(info.code) }
    if case .SecurityKey(let m) = e { return SKCode.ofMessage(m) }
    return nil
}

/// Loads the keys stored on a security key (resident keys), like `ssh-keygen -K`.
struct LoadResidentKeysView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @Environment(\.dismiss) private var dismiss
    @State private var verify = false
    @State private var device = ""
    @State private var place: ItemPlace = .device
    @State private var busy = false
    @State private var result: String?
    @State private var error: String?

    var body: some View {
        NavigationView {
            Form {
                Section { Text("keychain.sk.load_intro").font(.footnote) }
                Section {
                    Toggle("keychain.sk.load_verify", isOn: $verify)
                } footer: { Text("keychain.sk.load_verify_hint") }
                Section {
                    TextField(String(localized: "keychain.sk.device_placeholder"), text: $device)
                } header: { Text("keychain.sk.device_label") }
                if !account.list.isEmpty { PlacePicker(place: $place) }
                if let result { Text(result).foregroundColor(Brand.green) }
                if let error { Text(error).foregroundColor(Brand.red) }
            }
            .navigationTitle("keychain.sk.load_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey(result == nil ? "common.cancel" : "common.done")) { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("keychain.sk.load_action", action: load).disabled(busy)
                }
            }
        }
        .onAppear { place = account.defaultPlace }
    }

    private func load() {
        busy = true
        error = nil
        result = nil
        let p = account.list.isEmpty ? ItemPlace.device : place
        let name = device.trimmingCharacters(in: .whitespaces)
        Task {
            defer { busy = false }
            do {
                let keys = try await model.core.importResidentSecurityKeys(
                    applicationPrefix: nil, verifyRequired: verify, device: name.isEmpty ? nil : String(name.prefix(64)),
                    syncMode: account.list.isEmpty ? nil : (p.accountId == nil ? .deviceOnly : .synced),
                    accountId: p.accountId, vaultId: p.vaultId, handler: AppSecurityKeys.shared)
                account.rememberPlace(p)
                account.sync()
                result = keys.isEmpty ? String(localized: "keychain.sk.loaded_none")
                    : String(localized: "keychain.sk.loaded \(keys.count)")
            } catch {
                if skCode(error) == .cancelled { return }
                self.error = String(localized: "keychain.sk.load_failed \(userMessage(error))")
            }
        }
    }
}

/// "Security key" badge of a key row.
struct SecurityKeyBadge: View {
    var body: some View {
        Text("keychain.sk.badge")
            .font(.caption2.weight(.semibold))
            .foregroundColor(Brand.blue)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Brand.blue.opacity(0.12), in: Capsule())
    }
}

/// A security key's details in its page: application, touch, PIN,
/// resident, the device it lives on (editable) and the authorized_keys line.
struct SecurityKeyDetailSection: View {
    let key: SshKey
    let info: SecurityKeyInfo
    @Binding var device: String
    let editable: Bool
    let onCopied: (String) -> Void

    private var line: String { securityKeyAuthorizedKeysLine(publicKey: key.publicKey, info: info) }

    var body: some View {
        Section {
            row("keychain.sk.application", info.application)
            row("keychain.sk.touch", info.touchRequired ? String(localized: "keychain.sk.touch_required")
                : String(localized: "keychain.sk.touch_not_required"))
            row("keychain.sk.pin", info.verifyRequired ? String(localized: "keychain.sk.pin_required")
                : String(localized: "keychain.sk.pin_not_required"))
            if info.resident { row("keychain.sk.resident", String(localized: "keychain.sk.resident_yes")) }
            if let u = info.user, !u.isEmpty, info.resident { row("keychain.sk.user_label", u) }
            TextField(String(localized: "keychain.sk.device_placeholder"), text: $device)
                .disabled(!editable)
            if !info.touchRequired {
                Text("keychain.sk.no_touch_warning").font(.footnote).foregroundColor(Brand.amber)
            }
        } header: {
            Text("keychain.sk.badge")
        } footer: {
            Text("keychain.sk.handle_note")
        }
        Section {
            Text(verbatim: line).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).lineLimit(8)
            Button {
                UIPasteboard.general.string = line
                onCopied(String(localized: "keychain.sk.line_copied"))
            } label: { Label("keychain.sk.copy_line", systemImage: "doc.on.doc") }
        } header: {
            Text("keychain.sk.authorized_keys")
        } footer: {
            Text("keychain.sk.authorized_hint")
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(verbatim: value).foregroundColor(.secondary)
        }
    }
}
