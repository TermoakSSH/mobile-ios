import Foundation
import TermoakKit

/// The app's security keys: the flow (SecurityKeys.swift) on YubiKit with
/// the sheet (SecurityKeyViews.swift), as the engine's `SecurityKeyHandler`.
/// Set on the core when the vault opens, before any events socket, so the
/// sockets declare `features=security_keys` and this device answers the
/// server's signature requests (server sessions, host tests, `/exec`).
final class AppSecurityKeys: SecurityKeyHandler, @unchecked Sendable {
    static let shared = AppSecurityKeys()

    let flow: SecurityKeyFlow
    let sheet: SecurityKeySheetModel

    private init() {
        let hardware = YubiKitHardware()
        hardware.nfcMessage = { String(localized: "security_keys.nfc.hold") }
        hardware.nfcDoneMessage = { String(localized: "security_keys.nfc.done") }
        sheet = SecurityKeySheetModel()
        flow = SecurityKeyFlow(hardware: hardware, ui: sheet)
        sheet.flow = flow
    }

    /// The scene went to the background or came back (NFC and the sheet need the app in front).
    func setActive(_ on: Bool) { flow.setAppActive(on) }

    /// `security_key_request` / `security_key_done` of an events socket (the
    /// engine itself answers through `sign`; this only says which request
    /// another device already decided).
    func event(_ event: [String: Any]) {
        guard let id = event["request_id"] as? String else { return }
        switch event["type"] as? String {
        case "security_key_request":
            if let b64 = event["message"] as? String, let message = Data(base64Encoded: b64) {
                flow.noteRequest(id: id, message: message)
            }
        case "security_key_done":
            flow.noteDone(id: id)
        default:
            break
        }
    }

    // MARK: SecurityKeyHandler (a background thread of the engine; may block)

    func sign(request r: SecurityKeySignRequest) throws -> SecurityKeyAssertion {
        let input = SKSignInput(
            application: r.application, keyHandle: r.keyHandle, clientDataHash: r.clientDataHash, message: r.message,
            requirePresence: r.requirePresence, requireVerification: r.requireVerification,
            context: SKContext(purpose: r.purpose, host: r.host, address: r.address, username: r.username,
                               keyLabel: r.keyLabel, device: r.device, sessionId: r.sessionId))
        do {
            let a = try flow.sign(input)
            return SecurityKeyAssertion(signature: a.signature, authenticatorData: a.authenticatorData)
        } catch {
            throw Self.ffiError(error)
        }
    }

    func makeCredential(request r: SecurityKeyCredentialRequest) throws -> SecurityKeyCredential {
        let input = SKCreateInput(application: r.application, userId: r.userId, userName: r.userName,
                                  clientDataHash: r.clientDataHash, resident: r.resident,
                                  requireVerification: r.requireVerification, coseAlgorithm: r.coseAlgorithm)
        do {
            let c = try flow.makeCredential(input)
            return SecurityKeyCredential(authenticatorData: c.authenticatorData, attestationObject: Data())
        } catch {
            throw Self.ffiError(error)
        }
    }

    func listResident(request r: SecurityKeyResidentRequest) throws -> [SecurityKeyResident] {
        do {
            return try flow.listResident(prefix: r.applicationPrefix).map {
                SecurityKeyResident(application: $0.application, credentialId: $0.credentialId,
                                    publicKeyCose: $0.publicKeyCose, userId: $0.userId, userName: $0.userName)
            }
        } catch {
            throw Self.ffiError(error)
        }
    }

    /// The engine's error of a flow failure.
    static func ffiError(_ error: Error) -> SecurityKeyError {
        let f = (error as? SKFailure) ?? SKFailure(.failed, "\(error)")
        let reason = f.message
        switch f.code {
        case .noDevice: return .NoDevice(reason: reason)
        case .timeout: return .Timeout(reason: reason)
        case .cancelled: return .Cancelled(reason: reason)
        case .notFound: return .NotFound(reason: reason)
        case .pinRequired: return .PinRequired(reason: reason)
        case .pinInvalid: return .PinInvalid(reason: reason)
        case .unsupported: return .Unsupported(reason: reason)
        case .required, .wrongKey, .invalid, .failed: return .Failed(reason: reason)
        }
    }
}

// MARK: - Texts

/// The user's text of a security key error code, with the device's own
/// message after it when it adds something (failures, unsupported, a
/// blocked PIN).
func securityKeyText(_ code: SKCode, message: String = "") -> String {
    let text: String
    switch code {
    case .required: text = String(localized: "security_keys.error.required")
    case .noDevice: text = String(localized: "security_keys.error.no_device")
    case .timeout: text = String(localized: "security_keys.error.timeout")
    case .cancelled: text = String(localized: "security_keys.error.cancelled")
    case .notFound: text = String(localized: "security_keys.error.not_found")
    case .pinRequired: text = String(localized: "security_keys.error.pin_required")
    case .pinInvalid: text = String(localized: "security_keys.error.pin_invalid")
    case .wrongKey: text = String(localized: "security_keys.error.wrong_key")
    case .unsupported: text = String(localized: "security_keys.error.unsupported")
    case .invalid: text = String(localized: "security_keys.error.invalid")
    case .failed: text = String(localized: "security_keys.error.failed")
    }
    let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let adds = code.showsDetail || SKFailure(code, detail).pinBlocked
    return adds && !detail.isEmpty ? "\(text) (\(detail))" : text
}

/// A security key error of the engine (`TermoakError.SecurityKey`, code in
/// `apiError`), also the server's (`security_key_*` with its HTTP status),
/// in words; `nil` for other errors.
func securityKeyErrorText(_ error: Error) -> String? {
    guard let e = error as? TermoakError else { return nil }
    if let info = e.apiError, let code = SKCode.parse(info.code), info.code.hasPrefix("security_key_") {
        return securityKeyText(code, message: info.message)
    }
    if case .SecurityKey(let message) = e {
        return securityKeyText(SKCode.ofMessage(message) ?? .failed, message: message)
    }
    return nil
}

/// An English text of the server (session reasons, host tests, `/exec`):
/// the app's text when it is a security key error, else as it came.
func serverErrorText(_ message: String) -> String {
    guard let code = SKCode.ofMessage(message) else { return message }
    return securityKeyText(code)
}

/// A server session's "connecting" message in the app's language when it
/// is the server's "Touch your security key (X) on one of your devices…".
func sessionMessageText(_ message: String) -> String {
    switch SKSessionMessage.parse(message) {
    case .touch(let key?)?: return String(localized: "security_keys.session.touch_key \(key)")
    case .touch(nil)?: return String(localized: "security_keys.session.touch")
    case nil: return message
    }
}

/// What a request is for, in the sheet.
func securityKeyPurposeText(_ purpose: SKPurpose) -> String {
    switch purpose {
    case .sign(let c):
        switch c.purpose {
        case "server_session": return String(localized: "security_keys.purpose.server_session")
        case "test": return String(localized: "security_keys.purpose.test")
        case "server": return String(localized: "security_keys.purpose.server")
        default: return String(localized: "security_keys.purpose.connect")
        }
    case .create: return String(localized: "security_keys.purpose.create")
    case .loadResident: return String(localized: "security_keys.purpose.load")
    }
}
