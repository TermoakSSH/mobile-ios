import CoreNFC
import ExternalAccessory
import Foundation
import YubiKit

/// The security keys of this iPhone or iPad through Yubico's YubiKit
/// (yubikit-swift, Apache-2.0): CTAP2 over the FIDO applet (AID
/// A0000006472F0001) of an NFC key (the system's NFC sheet), a YubiKey 5Ci
/// in the Lightning port (External Accessory, `com.yubico.ylp`) or a key in
/// the USB-C port (iOS 16+, CryptoTokenKit smart card). Rp ids are free
/// (`ssh:`), unlike Apple's own security key API, which binds them to the
/// app's associated domains.
final class YubiKitHardware: SecurityKeyHardware, @unchecked Sendable {
    /// What the NFC sheet says while it waits.
    var nfcMessage: () -> String = { "" }
    /// What it says once the key answered.
    var nfcDoneMessage: () -> String = { "" }

    var nfcAvailable: Bool { NFCTagReaderSession.readingAvailable }

    func wiredKeyPresent() -> Bool {
        if lightningKeyPresent { return true }
        return !usbKeys().isEmpty
    }

    /// A YubiKey 5Ci in the Lightning port.
    private var lightningKeyPresent: Bool {
        EAAccessoryManager.shared().connectedAccessories.contains { $0.protocolStrings.contains("com.yubico.ylp") }
    }

    /// The YubiKeys in the USB-C port (smart card slots).
    private func usbKeys() -> [USBSmartCard.YubiKeyDevice] {
        let sem = DispatchSemaphore(value: 0)
        var found: [USBSmartCard.YubiKeyDevice] = []
        Task.detached {
            found = (try? await USBSmartCardConnection.availableDevices()) ?? []
            sem.signal()
        }
        return sem.wait(timeout: .now() + 2) == .success ? found : []
    }

    func look(nfc: Bool, found: @escaping (Result<SKDevice, SKFailure>) -> Void) -> SKLooking {
        let looking = Looking(found)
        let message = nfcMessage()
        let doneMessage = nfcDoneMessage()
        // A cable: polled (the library's own wait can't be stopped).
        looking.add(Task.detached { [weak self] in
            while !Task.isCancelled {
                if self?.lightningKeyPresent == true {
                    do {
                        let c = try await LightningSmartCardConnection()
                        looking.finish(.success(YubiKeyDevice(c, transport: .wired, label: "YubiKey 5Ci")))
                    } catch {
                        looking.finish(.failure(Self.failure(error)))
                    }
                    return
                }
                if let slot = try? await USBSmartCardConnection.availableDevices().first {
                    do {
                        let c = try await USBSmartCardConnection(slot: slot)
                        looking.finish(.success(YubiKeyDevice(c, transport: .wired, label: slot.name)))
                    } catch {
                        looking.finish(.failure(Self.failure(error)))
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        })
        if nfc {
            looking.add(Task.detached {
                do {
                    let c = try await NFCSmartCardConnection(alertMessage: message)
                    looking.finish(.success(YubiKeyDevice(c, transport: .nfc, label: nil, doneMessage: doneMessage)))
                } catch {
                    looking.finish(.failure(Self.failure(error)))
                }
            })
        }
        return looking
    }

    /// The first key found ends the search; the rest is stopped.
    private final class Looking: SKLooking, @unchecked Sendable {
        private let lock = NSLock()
        private var tasks: [Task<Void, Never>] = []
        private var done = false
        private let found: (Result<SKDevice, SKFailure>) -> Void

        init(_ found: @escaping (Result<SKDevice, SKFailure>) -> Void) { self.found = found }

        func add(_ t: Task<Void, Never>) {
            lock.lock()
            if done { t.cancel() } else { tasks.append(t) }
            lock.unlock()
        }

        func finish(_ r: Result<SKDevice, SKFailure>) {
            lock.lock()
            let first = !done
            done = true
            let rest = tasks
            lock.unlock()
            guard first else {
                if case .success(let d) = r { d.close(success: false) }
                return
            }
            rest.forEach { $0.cancel() }
            found(r)
        }

        func stop() {
            lock.lock()
            done = true
            let all = tasks
            lock.unlock()
            all.forEach { $0.cancel() }
        }
    }

    /// A library error as a security key error.
    static func failure(_ error: Error) -> SKFailure {
        if let f = error as? SKFailure { return f }
        if error is CancellationError { return SKFailure(.cancelled) }
        if let e = error as? SmartCardConnectionError { return connectionFailure(e) }
        if let e = error as? CTAP2.SessionError {
            switch e {
            case .ctapError(let c, _): return SKFailure.ctap(status(c), "\(c)")
            case .connectionError(let c, _): return connectionFailure(c)
            case .timeout: return SKFailure(.timeout)
            case .featureNotSupported: return SKFailure(.unsupported, "the security key cannot do this")
            default: return SKFailure(.failed, "\(e)")
            }
        }
        return SKFailure(.failed, "\(error)")
    }

    private static func connectionFailure(_ e: SmartCardConnectionError) -> SKFailure {
        switch e {
        case .cancelled, .cancelledByUser: return SKFailure(.cancelled)
        case .unsupported: return SKFailure(.unsupported, "this device cannot read security keys this way")
        case .noDevicesFound: return SKFailure(.noDevice)
        case .connectionLost: return SKFailure(.failed, "the security key was disconnected")
        default: return SKFailure(.failed, "\(e)")
        }
    }

    /// The CTAP2 status byte of a CTAP error.
    static func status(_ e: CTAP2.Error) -> UInt8 {
        switch e {
        case .invalidCommand: return 0x01
        case .timeout: return 0x05
        case .invalidCredential: return 0x22
        case .unsupportedAlgorithm: return 0x26
        case .operationDenied: return 0x27
        case .keyStoreFull: return 0x28
        case .unsupportedOption: return 0x2B
        case .invalidOption: return 0x2C
        case .keepaliveCancel: return 0x2D
        case .noCredentials: return 0x2E
        case .userActionTimeout: return 0x2F
        case .pinInvalid: return 0x31
        case .pinBlocked: return 0x32
        case .pinAuthInvalid: return 0x33
        case .pinAuthBlocked: return 0x34
        case .pinNotSet: return 0x35
        case .puatRequired: return 0x36
        case .actionTimeout: return 0x3A
        case .uvBlocked: return 0x3C
        case .vendor(let b), .extension(let b), .unknown(let b): return b
        default: return 0x7F
        }
    }
}

/// One key: its connection and a CTAP2 session on it.
private final class YubiKeyDevice: SKDevice, @unchecked Sendable {
    let transport: SKTransport
    let label: String?
    private let connection: SmartCardConnection
    private var session: CTAP2.Session?
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var ctapCancel: (@Sendable () async -> Void)?
    private var cancelled = false
    private let doneMessage: String

    init(_ connection: SmartCardConnection, transport: SKTransport, label: String?, doneMessage: String = "") {
        self.connection = connection
        self.doneMessage = doneMessage
        self.transport = transport
        self.label = label
    }

    private func ctap() async throws -> CTAP2.Session {
        if let s = session { return s }
        let s = try await CTAP2.Session.makeSession(connection: connection)
        session = s
        return s
    }

    /// Runs `body` and waits for it (the flow's thread blocks; `cancel`
    /// stops it from another one).
    private func blocking<T>(_ body: @escaping () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<T, Error> = .failure(SKFailure(.failed))
        let t = Task {
            do { result = .success(try await body()) } catch { result = .failure(error) }
            sem.signal()
        }
        lock.lock()
        task = t
        let stop = cancelled
        lock.unlock()
        if stop { t.cancel() }
        sem.wait()
        lock.lock()
        task = nil
        ctapCancel = nil
        lock.unlock()
        do { return try result.get() } catch { throw YubiKitHardware.failure(error) }
    }

    private func token(_ s: CTAP2.Session, _ pin: String?, _ permissions: CTAP2.ClientPin.Permission,
                       _ rpId: String?) async throws -> CTAP2.Token? {
        // User verification only with a PIN (keys without built-in
        // verification refuse `uv`).
        guard let pin else { return nil }
        return try await s.getPinUVToken(using: .pin(pin), permissions: permissions, rpId: rpId)
    }

    /// The final answer of a status stream; a touch is announced.
    private func await_<R>(_ stream: CTAP2.StatusStream<R>, touch: @escaping () -> Void) async throws -> R {
        for try await status in stream {
            switch status {
            case .processing: break
            case .waitingForUser(let cancel):
                lock.lock()
                ctapCancel = cancel
                let stop = cancelled
                lock.unlock()
                if stop { await cancel() }
                touch()
            case .finished(let r): return r
            }
        }
        throw SKFailure(.failed, "the security key did not answer")
    }

    func sign(_ r: SKSignInput, pin: String?, touch: @escaping () -> Void) throws -> SKAssertion {
        try blocking {
            let s = try await self.ctap()
            let t = try await self.token(s, pin, .getAssertion, r.application)
            // `up` false only for no-touch-required keys; `uv` never (the PIN token verifies).
            let params = CTAP2.GetAssertion.Parameters(
                rpId: r.application, clientDataHash: r.clientDataHash,
                allowList: [WebAuthn.CredentialDescriptor(id: r.keyHandle)],
                up: r.requirePresence ? nil : false)
            let a = try await self.await_(await s.getAssertion(parameters: params, token: t), touch: touch)
            return SKAssertion(signature: a.signature, authenticatorData: a.authenticatorData.rawData)
        }
    }

    func makeCredential(_ r: SKCreateInput, pin: String?, touch: @escaping () -> Void) throws -> Data {
        try blocking {
            let s = try await self.ctap()
            let t = try await self.token(s, pin, .makeCredential, r.application)
            let params = CTAP2.MakeCredential.Parameters(
                clientDataHash: r.clientDataHash,
                rp: WebAuthn.RelyingParty(id: r.application, name: r.application),
                user: WebAuthn.User(id: r.userId, name: r.userName, displayName: r.userName),
                pubKeyCredParams: [COSE.Algorithm(rawValue: Int(r.coseAlgorithm))],
                rk: r.resident)
            let c = try await self.await_(await s.makeCredential(parameters: params, token: t), touch: touch)
            return c.authenticatorData.rawData
        }
    }

    func listResident(prefix: String, pin: String) throws -> [SKResident] {
        try blocking {
            let s = try await self.ctap()
            guard try await CTAP2.CredentialManagement.isSupported(by: s) else {
                throw SKFailure(.unsupported, "this security key cannot list the keys stored on it")
            }
            // CTAP 2.1 or 2.1-PRE credential management: the library picks the command.
            let t = try await s.getPinUVToken(using: .pin(pin), permissions: .credentialManagement)
            let cm = try await s.credentialManagement(token: t)
            var out: [SKResident] = []
            for rp in try await cm.rps.enumerate() where rp.rp.id.hasPrefix(prefix) {
                for c in try await cm.credentials(for: rp.rpIdHash).enumerate() {
                    let cose: Data
                    switch c.publicKey {
                    case .okp(_, _, _, let x): cose = SKCose.ed25519(x: x)
                    case .ec2(_, _, _, let x, let y): cose = SKCose.p256(x: x, y: y)
                    default: continue
                    }
                    out.append(SKResident(application: rp.rp.id, credentialId: c.credentialId.id, publicKeyCose: cose,
                                          userId: c.user.id, userName: c.user.name))
                }
            }
            return out
        }
    }

    func pinRetries() -> Int? {
        try? blocking { try await self.ctap().getPinRetries().retries }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        let c = ctapCancel
        lock.unlock()
        // CTAP cancel (the key stops waiting for a touch), then the
        // connection closes (an NFC sheet goes away).
        Task {
            if let c { await c() }
            t?.cancel()
            await self.connection.close(error: SKFailure(.cancelled))
        }
    }

    func close(success: Bool) {
        let c = connection
        Task {
            if let nfc = c as? NFCSmartCardConnection {
                await nfc.close(message: success && !self.doneMessage.isEmpty ? self.doneMessage : nil)
            } else {
                await c.close(error: nil)
            }
        }
    }
}
