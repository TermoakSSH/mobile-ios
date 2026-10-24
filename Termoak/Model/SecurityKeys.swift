import Foundation

// FIDO2 security keys (YubiKey, SoloKey...) on this iPhone or iPad
// (docs/SSH-PRO.md in TermoakSSH/core). Three layers, like the desktop app:
//
// - The hardware (`SecurityKeyHardware`, `SKDevice`): YubiKit over NFC,
//   Lightning and USB-C (YubiKitHardware.swift, only in the app).
// - What the user sees (`SecurityKeyUI`): the sheet "Hold your security key
//   near the top of the iPhone", the PIN, "Touch your security key" with the
//   host, user, key and purpose, Cancel (SecurityKeyViews.swift).
// - The flow between them (`SecurityKeyFlow`): one operation at a time,
//   waiting for a key, PIN retries, cancel, and the server's requests that
//   another device answered. It is the engine's `SecurityKeyHandler`
//   through SecurityKeyBridge.swift.
//
// Without the engine's types, so the unit tests compile this file on its own.

/// The security key error codes (core `SkErrorCode`; API `security_key_*`).
enum SKCode: String, CaseIterable, Equatable {
    case required
    case noDevice = "no_device"
    case timeout
    case cancelled
    case notFound = "not_found"
    case pinRequired = "pin_required"
    case pinInvalid = "pin_invalid"
    case wrongKey = "wrong_key"
    case unsupported
    case invalid
    case failed

    /// `security_key_no_device`...
    var apiCode: String { "security_key_" + rawValue }

    /// A code as the API (`security_key_no_device`) or the forwarding
    /// protocol (`no_device`) writes it.
    static func parse(_ code: String) -> SKCode? {
        let c = code.hasPrefix("security_key_") ? String(code.dropFirst("security_key_".count)) : code
        return SKCode(rawValue: c)
    }

    /// The code of an English text of the server or the engine (the
    /// server's session reasons, host tests and `/exec` results carry only
    /// the text), if it is one of theirs (desktop `code_of_message`).
    static func ofMessage(_ message: String) -> SKCode? {
        let m = message.lowercased()
        let patterns: [(String, SKCode)] = [
            ("none of your devices that can use security keys", .noDevice),
            ("no device with a security key is available", .noDevice),
            ("no security key is plugged", .noDevice),
            ("nobody confirmed the security key", .timeout),
            ("security key was not touched in time", .timeout),
            ("security key request was cancelled", .cancelled),
            ("is a security key and none can be used here", .required),
            ("this key is a security key and none can be used", .required),
            ("security key does not have this key", .notFound),
            ("security key needs its pin", .pinRequired),
            ("wrong pin for the security key", .pinInvalid),
            ("security key's signature does not match", .wrongKey),
        ]
        return patterns.first { m.contains($0.0) }?.1
    }

    /// Whether the device's own message is worth showing after the text.
    var showsDetail: Bool { self == .failed || self == .unsupported || self == .invalid }
}

/// An error of the device or the flow.
struct SKFailure: Error, Equatable {
    let code: SKCode
    /// English, from the platform or the library (may be empty).
    let message: String

    init(_ code: SKCode, _ message: String = "") {
        self.code = code
        self.message = message
    }

    /// A wrong PIN that blocked it: asking again is useless.
    var pinBlocked: Bool { code == .pinInvalid && message.contains("blocked") }

    /// A CTAP2 status byte of the device (desktop ctap.rs `map_error`).
    static func ctap(_ status: UInt8, _ text: String = "") -> SKFailure {
        let detail = text.isEmpty ? String(format: "CTAP error 0x%02X", status) : text
        switch status {
        // CTAP2_ERR_NO_CREDENTIALS, CTAP2_ERR_INVALID_CREDENTIAL
        case 0x2E, 0x22: return SKFailure(.notFound, detail)
        // CTAP2_ERR_PUAT_REQUIRED (PIN required), PIN not set
        case 0x36, 0x35: return SKFailure(.pinRequired, detail)
        case 0x31, 0x33: return SKFailure(.pinInvalid, detail)
        // Blocked: the key needs to be removed and connected again (0x34) or reset (0x32).
        case 0x32, 0x34:
            return SKFailure(.pinInvalid, "the PIN is blocked: remove the key and connect it again (or reset it)")
        // User action timeout, action timeout, CTAP1 timeout
        case 0x2F, 0x3A, 0x05: return SKFailure(.timeout, detail)
        // KEEPALIVE_CANCEL, OPERATION_DENIED
        case 0x2D, 0x27: return SKFailure(.cancelled, detail)
        // Unsupported algorithm, option or command; key store full.
        case 0x26, 0x2B, 0x2C, 0x01, 0x28: return SKFailure(.unsupported, detail)
        default: return SKFailure(.failed, detail)
        }
    }
}

/// What a sign request is for and where it goes (what the sheet shows).
struct SKContext: Equatable {
    /// `connect` (this device); the server's: `server_session`, `test`, `server`.
    var purpose: String
    var host: String
    var address: String
    var username: String
    var keyLabel: String
    var device: String?
    var sessionId: String?

    /// The server asked for it (forwarding): another device may answer.
    var forwarded: Bool { !purpose.isEmpty && purpose != "connect" }

    /// "deploy@web1 (10.0.0.5)".
    var target: String {
        let h = host.isEmpty ? address : host
        var s = username.isEmpty ? h : "\(username)@\(h)"
        if !address.isEmpty && address != h { s += " (\(address))" }
        return s
    }

    /// "YubiKey (work) · YubiKey 5C NFC": the key and the device it lives on.
    var keyText: String {
        if let d = device, !d.isEmpty, d != keyLabel { return "\(keyLabel) · \(d)" }
        return keyLabel
    }
}

/// What an operation is for.
enum SKPurpose: Equatable {
    case sign(SKContext)
    /// Making a key on the device (its application).
    case create(application: String)
    /// Reading the keys stored on the device.
    case loadResident

    var forwarded: Bool {
        if case .sign(let c) = self { return c.forwarded }
        return false
    }
}

/// CTAP2 get assertion (`rp id` = `application`, allow list `[keyHandle]`).
struct SKSignInput: Equatable {
    var application: String
    var keyHandle: Data
    /// SHA-256 of `message`: what YubiKit takes.
    var clientDataHash: Data
    /// The SSH data to sign (it identifies a forwarded request).
    var message: Data
    /// CTAP2 `up` (false: a `no-touch-required` key).
    var requirePresence: Bool
    /// The key needs the PIN (`verify-required`).
    var requireVerification: Bool
    var context: SKContext
}

/// The device's assertion: the signature and the authenticator data
/// (flags and counter are read from it by the engine).
struct SKAssertion: Equatable {
    var signature: Data
    var authenticatorData: Data
}

/// CTAP2 make credential.
struct SKCreateInput: Equatable {
    var application: String
    var userId: Data
    var userName: String
    var clientDataHash: Data
    var resident: Bool
    var requireVerification: Bool
    /// -8 EdDSA, -7 ES256.
    var coseAlgorithm: Int64
}

/// A resident credential on the device.
struct SKResident: Equatable {
    var application: String
    var credentialId: Data
    /// COSE public key (CBOR map).
    var publicKeyCose: Data
    var userId: Data
    var userName: String?
}

/// How a key is connected.
enum SKTransport: Equatable {
    case nfc
    /// Lightning (YubiKey 5Ci) or USB-C.
    case wired
}

/// A security key that answered (one NFC tap or one wired connection).
/// Every call blocks the flow's thread; `cancel` comes from another thread.
protocol SKDevice: AnyObject {
    var transport: SKTransport { get }
    /// What it calls itself, if it says.
    var label: String? { get }
    /// `touch` is called when the key waits for a touch.
    func sign(_ request: SKSignInput, pin: String?, touch: @escaping () -> Void) throws -> SKAssertion
    func makeCredential(_ request: SKCreateInput, pin: String?, touch: @escaping () -> Void) throws -> Data
    func listResident(prefix: String, pin: String) throws -> [SKResident]
    /// PIN retries left, if the key says.
    func pinRetries() -> Int?
    /// Stops the operation in progress (CTAP cancel, the connection closed).
    func cancel()
    /// Ends the connection (an NFC sheet says it worked or not).
    func close(success: Bool)
}

/// Looking for a key; `stop` ends it (an NFC sheet goes away).
protocol SKLooking: AnyObject {
    func stop()
}

/// The platform's security keys.
protocol SecurityKeyHardware: AnyObject {
    /// This iPhone or iPad can read NFC tags.
    var nfcAvailable: Bool { get }
    /// A key is connected by cable now (Lightning or USB-C).
    func wiredKeyPresent() -> Bool
    /// Looks for a key: wired ones always, NFC too when `nfc` (the system's
    /// NFC sheet). `found` is called once, on any thread.
    func look(nfc: Bool, found: @escaping (Result<SKDevice, SKFailure>) -> Void) -> SKLooking
}

/// What the sheet shows.
enum SKStage: Equatable {
    /// Waiting for a key: hold it near the iPhone (`nfc`) or connect it.
    case insert(nfc: Bool)
    case pin(retry: Bool, retriesLeft: Int?)
    case touch
    /// A key that signs without a touch, or reading the keys on it.
    case working
}

struct SKSheet: Equatable {
    var purpose: SKPurpose
    var stage: SKStage
    /// NFC can be used here (the sheet offers it while waiting).
    var nfcAvailable: Bool
}

/// What the user can do in the sheet.
enum SKUserAction: Equatable {
    case cancel
    /// "Not on this iPhone": a forwarded request is left to another device.
    case notHere
    /// Read the key by NFC now.
    case useNFC
    case pin(String)
}

/// Shows the sheet (called from the flow's thread; the UI hops to the main thread).
protocol SecurityKeyUI: AnyObject {
    func show(_ sheet: SKSheet)
    func hide()
}

/// The flow between the hardware and the sheet. Every entry point blocks
/// its caller (a background thread of the engine) until it ends.
final class SecurityKeyFlow: @unchecked Sendable {
    let hardware: SecurityKeyHardware
    let ui: SecurityKeyUI
    /// How long to wait for a key: connecting from here, and a server's request.
    var localWait: TimeInterval = 60
    var forwardedWait: TimeInterval = 30
    /// Wrong PINs in a row before giving up (the key blocks it after a few more).
    static let pinTries = 3

    private enum Event {
        case found(SKDevice, Int)
        case lookFailed(SKFailure, Int)
        case user(SKUserAction)
        case aborted
    }

    private final class Op {
        let message: Data?
        var events: [Event] = []
        var aborted = false
        /// The device working now (`cancel` reaches it).
        var device: SKDevice?
        var inDevice = false
        /// Cancel or "not here" while the device worked.
        var stopped: SKUserAction?
        /// Which `look` the found devices belong to.
        var generation = 0
        init(message: Data?) { self.message = message }
    }

    private let cond = NSCondition()
    private var busy = false
    private var current: Op?
    private var queue: [Op] = []
    private var active = true
    /// Server requests: request id → message (to know which one is done).
    private var requests: [String: Data] = [:]
    /// Messages of requests already decided (another device answered).
    private var done: [Data: Date] = [:]

    init(hardware: SecurityKeyHardware, ui: SecurityKeyUI) {
        self.hardware = hardware
        self.ui = ui
    }

    // MARK: Entry points

    /// The app is in front (NFC and the sheet need it).
    func setAppActive(_ on: Bool) {
        cond.lock()
        active = on
        cond.unlock()
    }

    /// Signs an SSH login.
    func sign(_ r: SKSignInput) throws -> SKAssertion {
        if r.context.forwarded {
            cond.lock()
            let front = active
            let decided = done[r.message] != nil
            cond.unlock()
            if decided { throw SKFailure(.cancelled, "another device answered") }
            // Answered at once, so another device (a computer) can still answer.
            guard front else { throw SKFailure(.noDevice, "Termoak is not in front on this device") }
            guard hardware.nfcAvailable || hardware.wiredKeyPresent() else {
                throw SKFailure(.noDevice, "no security key is connected to this device")
            }
        }
        return try run(.sign(r.context), message: r.message, needsPin: r.requireVerification,
                       touch: r.requirePresence) { device, pin, touch in
            try device.sign(r, pin: pin, touch: touch)
        }
    }

    /// Makes a key on the device: its authenticator data.
    func makeCredential(_ r: SKCreateInput) throws -> (authenticatorData: Data, device: String?) {
        var label: String?
        let data = try run(.create(application: r.application), message: nil, needsPin: r.requireVerification,
                           touch: true) { device, pin, touch in
            label = device.label
            return try device.makeCredential(r, pin: pin, touch: touch)
        }
        return (data, label)
    }

    /// The keys stored on the device (needs the PIN).
    func listResident(prefix: String) throws -> [SKResident] {
        try run(.loadResident, message: nil, needsPin: true, touch: false) { device, pin, _ in
            try device.listResident(prefix: prefix, pin: pin ?? "")
        }
    }

    /// The sheet's buttons.
    func userAction(_ action: SKUserAction) {
        cond.lock()
        guard let op = current else {
            cond.unlock()
            return
        }
        var device: SKDevice?
        if op.inDevice, action == .cancel || action == .notHere {
            op.stopped = action
            device = op.device
        } else {
            op.events.append(.user(action))
        }
        cond.broadcast()
        cond.unlock()
        device?.cancel()
    }

    /// A `security_key_request` of the events socket (its id and message).
    func noteRequest(id: String, message: Data) {
        cond.lock()
        requests[id] = message
        if requests.count > 64 { requests.removeAll() }
        cond.unlock()
    }

    /// A `security_key_done`: the request was decided (maybe by another
    /// device), so this device stops asking for it.
    func noteDone(id: String) {
        cond.lock()
        guard let message = requests.removeValue(forKey: id) else {
            cond.unlock()
            return
        }
        let now = Date()
        done = done.filter { now.timeIntervalSince($0.value) < 300 }
        done[message] = now
        var devices: [SKDevice] = []
        for op in queue + [current].compactMap({ $0 }) where op.message == message && !op.aborted {
            op.aborted = true
            op.events.append(.aborted)
            if op.inDevice, let d = op.device { devices.append(d) }
        }
        cond.broadcast()
        cond.unlock()
        devices.forEach { $0.cancel() }
    }

    /// Whether an operation is under way (tests).
    var isBusy: Bool {
        cond.lock()
        defer { cond.unlock() }
        return busy
    }

    // MARK: The flow

    private func run<T>(_ purpose: SKPurpose, message: Data?, needsPin: Bool, touch: Bool,
                        _ work: @escaping (SKDevice, String?, @escaping () -> Void) throws -> T) throws -> T {
        let op = Op(message: message)
        try enter(op)
        defer { leave(op) }
        var pin: String?
        if needsPin { pin = try askPin(op, purpose, retry: false, left: nil) }
        var wrong = 0
        while true {
            let device = try op.device ?? obtainDevice(op, purpose)
            cond.lock()
            op.device = device
            op.inDevice = true
            let early = op.aborted ? SKUserAction.cancel : op.stopped
            cond.unlock()
            if let early {
                device.close(success: false)
                throw early == .notHere ? SKFailure(.noDevice) : SKFailure(.cancelled)
            }
            show(purpose, touch ? .touch : .working)
            let result: Result<T, SKFailure>
            do {
                result = .success(try work(device, pin) { [weak self] in self?.show(purpose, .touch) })
            } catch let f as SKFailure {
                result = .failure(f)
            } catch {
                result = .failure(SKFailure(.failed, "\(error)"))
            }
            cond.lock()
            op.inDevice = false
            let stopped = op.aborted ? SKUserAction.cancel : op.stopped
            cond.unlock()
            if let stopped {
                device.close(success: false)
                throw stopped == .notHere ? SKFailure(.noDevice) : SKFailure(.cancelled)
            }
            switch result {
            case .success(let v):
                device.close(success: true)
                return v
            case .failure(let f) where f.code == .pinRequired && pin == nil:
                release(op, device)
                pin = try askPin(op, purpose, retry: false, left: nil)
            case .failure(let f) where f.code == .pinInvalid && !f.pinBlocked && wrong + 1 < Self.pinTries:
                wrong += 1
                let left = device.pinRetries()
                release(op, device)
                pin = try askPin(op, purpose, retry: true, left: left)
            case .failure(let f):
                device.close(success: false)
                throw f
            }
        }
    }

    /// After a PIN error: an NFC tap is over (the key is tapped again after
    /// the PIN); a wired key stays.
    private func release(_ op: Op, _ device: SKDevice) {
        guard device.transport == .nfc else { return }
        device.close(success: false)
        cond.lock()
        op.device = nil
        cond.unlock()
    }

    /// Waits for its turn: one operation at a time.
    private func enter(_ op: Op) throws {
        cond.lock()
        defer { cond.unlock() }
        if let m = op.message, done[m] != nil { throw SKFailure(.cancelled, "another device answered") }
        queue.append(op)
        while (busy || queue.first !== op) && !op.aborted { cond.wait() }
        queue.removeAll { $0 === op }
        if op.aborted {
            cond.broadcast()
            throw SKFailure(.cancelled, "another device answered")
        }
        busy = true
        current = op
    }

    private func leave(_ op: Op) {
        cond.lock()
        // Devices found too late are let go.
        let stray: [SKDevice] = op.events.compactMap { if case .found(let d, _) = $0, d !== op.device { return d } else { return nil } }
        op.events.removeAll()
        busy = false
        current = nil
        cond.broadcast()
        cond.unlock()
        stray.forEach { $0.close(success: false) }
        ui.hide()
    }

    private func show(_ purpose: SKPurpose, _ stage: SKStage) {
        ui.show(SKSheet(purpose: purpose, stage: stage, nfcAvailable: hardware.nfcAvailable))
    }

    /// The next event of `op` (nil at the deadline).
    private func next(_ op: Op, until deadline: Date?) -> Event? {
        cond.lock()
        defer { cond.unlock() }
        while op.events.isEmpty {
            if let deadline {
                if !cond.wait(until: deadline) && op.events.isEmpty { return nil }
            } else {
                cond.wait()
            }
        }
        return op.events.removeFirst()
    }

    private func post(_ op: Op, _ event: Event) {
        cond.lock()
        op.events.append(event)
        cond.broadcast()
        cond.unlock()
    }

    /// A key: one connected by cable at once, or waiting for one (NFC from
    /// here at once; for a server's request NFC when the user asks, so the
    /// system's NFC sheet doesn't jump out by itself).
    private func obtainDevice(_ op: Op, _ purpose: SKPurpose) throws -> SKDevice {
        let forwarded = purpose.forwarded
        var nfc = !forwarded && hardware.nfcAvailable && !hardware.wiredKeyPresent()
        var looking: SKLooking?
        func start() {
            looking?.stop()
            cond.lock()
            op.generation += 1
            let gen = op.generation
            cond.unlock()
            show(purpose, .insert(nfc: nfc))
            looking = hardware.look(nfc: nfc) { [weak self] result in
                switch result {
                case .success(let d): self?.post(op, .found(d, gen))
                case .failure(let f): self?.post(op, .lookFailed(f, gen))
                }
            }
        }
        start()
        defer { looking?.stop() }
        let deadline = Date().addingTimeInterval(forwarded ? forwardedWait : localWait)
        while true {
            guard let event = next(op, until: deadline) else {
                throw SKFailure(.noDevice, "no security key was connected in time")
            }
            switch event {
            case .found(let d, let gen):
                cond.lock()
                let currentGen = op.generation
                cond.unlock()
                if gen == currentGen { return d }
                d.close(success: false)
            case .lookFailed(let f, let gen):
                cond.lock()
                let currentGen = op.generation
                cond.unlock()
                guard gen == currentGen else { continue }
                // The NFC sheet closed by the user: cancelled.
                if f.code == .cancelled { throw f }
                if f.code == .noDevice || f.code == .unsupported || f.code == .timeout || f.code == .failed {
                    // NFC gave up (its sheet times out): keep waiting for a cable.
                    nfc = false
                    start()
                }
            case .user(.cancel), .aborted:
                throw SKFailure(.cancelled)
            case .user(.notHere):
                throw SKFailure(.noDevice, "the user said the security key is not on this device")
            case .user(.useNFC):
                if !nfc && hardware.nfcAvailable {
                    nfc = true
                    start()
                }
            case .user(.pin):
                break
            }
        }
    }

    private func askPin(_ op: Op, _ purpose: SKPurpose, retry: Bool, left: Int?) throws -> String {
        show(purpose, .pin(retry: retry, retriesLeft: left))
        while true {
            guard let event = next(op, until: nil) else { continue }
            switch event {
            case .user(.pin(let p)):
                if p.isEmpty { throw SKFailure(.pinRequired) }
                return p
            case .user(.cancel), .aborted:
                throw SKFailure(.cancelled)
            case .user(.notHere):
                throw SKFailure(.noDevice)
            case .found(let d, _):
                d.close(success: false)
            case .user(.useNFC), .lookFailed:
                break
            }
        }
    }
}

/// COSE public keys (CBOR maps) from raw ones: the resident key listing
/// gives parsed keys and the engine reads COSE.
enum SKCose {
    /// OKP / EdDSA / Ed25519 with its 32-byte public key.
    static func ed25519(x: Data) -> Data {
        var out = Data()
        head(&out, 5, 4)
        int(&out, 1); int(&out, 1)    // kty OKP
        int(&out, 3); int(&out, -8)   // alg EdDSA
        int(&out, -1); int(&out, 6)   // crv Ed25519
        int(&out, -2); bytes(&out, x)
        return out
    }

    /// EC2 / ES256 / P-256 with its coordinates.
    static func p256(x: Data, y: Data) -> Data {
        var out = Data()
        head(&out, 5, 5)
        int(&out, 1); int(&out, 2)    // kty EC2
        int(&out, 3); int(&out, -7)   // alg ES256
        int(&out, -1); int(&out, 1)   // crv P-256
        int(&out, -2); bytes(&out, x)
        int(&out, -3); bytes(&out, y)
        return out
    }

    private static func head(_ out: inout Data, _ major: UInt8, _ n: UInt64) {
        let m = major << 5
        switch n {
        case 0...23: out.append(m | UInt8(n))
        case 24...0xff: out.append(contentsOf: [m | 24, UInt8(n)])
        default:
            out.append(m | 25)
            out.append(contentsOf: [UInt8((n >> 8) & 0xff), UInt8(n & 0xff)])
        }
    }

    private static func int(_ out: inout Data, _ v: Int64) {
        if v >= 0 { head(&out, 0, UInt64(v)) } else { head(&out, 1, UInt64(-1 - v)) }
    }

    private static func bytes(_ out: inout Data, _ b: Data) {
        head(&out, 2, UInt64(b.count))
        out.append(b)
    }
}

/// A server session's "connecting" message: "Touch your security key (X)
/// on one of your devices…" (translated by the app), or `nil` for any
/// other message.
enum SKSessionMessage: Equatable {
    case touch(key: String?)

    static func parse(_ message: String) -> SKSessionMessage? {
        guard message.hasPrefix("Touch your security key") else { return nil }
        let rest = message.dropFirst("Touch your security key".count).drop { $0 == " " }
        if rest.hasPrefix("("), let close = rest.firstIndex(of: ")") {
            let key = String(rest[rest.index(after: rest.startIndex)..<close])
            return .touch(key: key.isEmpty ? nil : key)
        }
        return .touch(key: nil)
    }
}
