import XCTest

/// FIDO2 security keys (Termoak/Model/SecurityKeys.swift, core
/// docs/SSH-PRO.md): the flow between a fake device and a scripted sheet
/// (sign, cancel stops the device, PIN required and retries, a blocked
/// PIN, a server's request in the background or without a reader, "not on
/// this iPhone", one operation at a time, a request another device
/// decided) and the error codes and texts.
final class SecurityKeysTests: XCTestCase {
    // MARK: Fakes

    final class FakeDevice: SKDevice {
        let transport: SKTransport
        let label: String? = "YubiKey 5C NFC"
        /// What each call does, in order (the last one repeats).
        var script: [Result<Void, SKFailure>]
        /// A call waits for `cancel` (a key waiting for a touch).
        var blocks = false
        private let lock = NSLock()
        private let unblock = DispatchSemaphore(value: 0)
        private(set) var pins: [String?] = []
        private(set) var calls = 0
        private(set) var cancelled = false
        private(set) var closed: [Bool] = []
        var retries: Int? = 7
        let started = DispatchSemaphore(value: 0)

        init(_ transport: SKTransport = .wired, script: [Result<Void, SKFailure>] = [.success(())]) {
            self.transport = transport
            self.script = script
        }

        private func step(_ pin: String?, _ touch: () -> Void) throws {
            lock.lock()
            pins.append(pin)
            let r = script.count > 1 ? script.removeFirst() : script[0]
            calls += 1
            lock.unlock()
            started.signal()
            touch()
            if blocks {
                unblock.wait()
                throw SKFailure(.cancelled, "keepalive cancel")
            }
            try r.get()
        }

        func sign(_ request: SKSignInput, pin: String?, touch: @escaping () -> Void) throws -> SKAssertion {
            try step(pin, touch)
            return SKAssertion(signature: Data([1, 2, 3]), authenticatorData: Data(repeating: 0, count: 37))
        }

        func makeCredential(_ request: SKCreateInput, pin: String?, touch: @escaping () -> Void) throws -> Data {
            try step(pin, touch)
            return Data([9])
        }

        func listResident(prefix: String, pin: String) throws -> [SKResident] {
            try step(pin) {}
            return [SKResident(application: "ssh:", credentialId: Data([1]), publicKeyCose: Data([2]), userId: Data(), userName: "openssh")]
        }

        func pinRetries() -> Int? { retries }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
            unblock.signal()
        }

        func close(success: Bool) {
            lock.lock()
            closed.append(success)
            lock.unlock()
        }
    }

    final class FakeHardware: SecurityKeyHardware {
        var nfcAvailable = true
        var wired = false
        /// The devices handed out by `look`, in order (none left: never found).
        var devices: [FakeDevice] {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
        private var stored: [FakeDevice] = []
        private(set) var looks: [Bool] = []
        private let lock = NSLock()

        final class Looking: SKLooking {
            var stopped = false
            func stop() { stopped = true }
        }

        func wiredKeyPresent() -> Bool { wired }

        func look(nfc: Bool, found: @escaping (Result<SKDevice, SKFailure>) -> Void) -> SKLooking {
            lock.lock()
            looks.append(nfc)
            // A tapped key only answers an NFC look; a key in the port, any look.
            let i = stored.firstIndex { nfc || $0.transport == .wired }
            let d = i.map { stored.remove(at: $0) }
            lock.unlock()
            if let d { DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { found(.success(d)) } }
            return Looking()
        }
    }

    /// Answers the sheet as a person would.
    final class ScriptUI: SecurityKeyUI {
        weak var flow: SecurityKeyFlow?
        var onShow: (SKSheet, SecurityKeyFlow) -> Void = { _, _ in }
        private let lock = NSLock()
        private(set) var shown: [SKSheet] = []
        private(set) var hides = 0

        func show(_ sheet: SKSheet) {
            lock.lock()
            shown.append(sheet)
            lock.unlock()
            if let flow { DispatchQueue.global().async { self.onShow(sheet, flow) } }
        }

        func hide() {
            lock.lock()
            hides += 1
            lock.unlock()
        }

        var stages: [SKStage] {
            lock.lock()
            defer { lock.unlock() }
            return shown.map(\.stage)
        }
    }

    /// A value set from another thread.
    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ v: T) { stored = v }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private func make(_ hw: FakeHardware) -> (SecurityKeyFlow, ScriptUI) {
        let ui = ScriptUI()
        let flow = SecurityKeyFlow(hardware: hw, ui: ui)
        flow.localWait = 2
        flow.forwardedWait = 0.5
        ui.flow = flow
        return (flow, ui)
    }

    private func request(purpose: String = "connect", verify: Bool = false, message: Data = Data([7])) -> SKSignInput {
        SKSignInput(application: "ssh:", keyHandle: Data([1]), clientDataHash: Data(repeating: 3, count: 32), message: message,
                    requirePresence: true, requireVerification: verify,
                    context: SKContext(purpose: purpose, host: "web1", address: "10.0.0.5", username: "deploy",
                                       keyLabel: "YubiKey", device: "YubiKey 5C", sessionId: nil))
    }

    private func failure(_ body: () throws -> Any) -> SKFailure? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? SKFailure
        }
    }

    // MARK: The flow

    func testSignsWithAWiredKey() throws {
        let hw = FakeHardware()
        hw.wired = true
        let device = FakeDevice()
        hw.devices = [device]
        let (flow, ui) = make(hw)
        let a = try flow.sign(request())
        XCTAssertEqual(a.signature, Data([1, 2, 3]))
        XCTAssertEqual(hw.looks, [false], "a key in the port: no NFC sheet")
        XCTAssertTrue(ui.stages.contains(.touch))
        XCTAssertEqual(device.closed, [true])
        XCTAssertEqual(device.pins, [nil], "no PIN, so no user verification")
        XCTAssertEqual(ui.hides, 1)
        XCTAssertFalse(flow.isBusy)
    }

    func testFromHereStartsNFCAtOnce() throws {
        let hw = FakeHardware()
        hw.devices = [FakeDevice(.nfc)]
        let (flow, _) = make(hw)
        _ = try flow.sign(request())
        XCTAssertEqual(hw.looks, [true])
    }

    func testCancelStopsTheDevice() {
        let hw = FakeHardware()
        hw.wired = true
        let device = FakeDevice()
        device.blocks = true
        hw.devices = [device]
        let (flow, ui) = make(hw)
        ui.onShow = { sheet, flow in if sheet.stage == .touch { flow.userAction(.cancel) } }
        let f = failure { try flow.sign(self.request()) }
        XCTAssertEqual(f?.code, .cancelled)
        XCTAssertTrue(device.cancelled, "Cancel reaches the key (it stops waiting for a touch)")
        XCTAssertEqual(device.closed, [false])
    }

    func testPinAskedFirstAndAgainWhenWrong() throws {
        let hw = FakeHardware()
        hw.wired = true
        let device = FakeDevice(script: [.failure(.ctap(0x31)), .success(())])
        device.retries = 6
        hw.devices = [device]
        let (flow, ui) = make(hw)
        let answers = Box(["1111", "2222"])
        ui.onShow = { sheet, flow in
            if case .pin = sheet.stage { flow.userAction(.pin(answers.value.removeFirst())) }
        }
        _ = try flow.sign(request(verify: true))
        XCTAssertEqual(device.pins, ["1111", "2222"])
        XCTAssertTrue(ui.stages.contains(.pin(retry: false, retriesLeft: nil)))
        XCTAssertTrue(ui.stages.contains(.pin(retry: true, retriesLeft: 6)))
    }

    func testPinRequiredByTheKeyThenRetried() throws {
        let hw = FakeHardware()
        hw.wired = true
        let device = FakeDevice(script: [.failure(.ctap(0x36)), .success(())])
        hw.devices = [device]
        let (flow, ui) = make(hw)
        ui.onShow = { sheet, flow in if case .pin = sheet.stage { flow.userAction(.pin("123456")) } }
        _ = try flow.makeCredential(SKCreateInput(application: "ssh:", userId: Data(count: 32), userName: "openssh",
                                                  clientDataHash: Data(count: 32), resident: true,
                                                  requireVerification: false, coseAlgorithm: -8))
        XCTAssertEqual(device.pins, [nil, "123456"])
    }

    func testANFCKeyIsTappedAgainAfterThePin() throws {
        let hw = FakeHardware()
        let first = FakeDevice(.nfc, script: [.failure(.ctap(0x36))])
        let second = FakeDevice(.nfc)
        hw.devices = [first, second]
        let (flow, ui) = make(hw)
        ui.onShow = { sheet, flow in if case .pin = sheet.stage { flow.userAction(.pin("1234")) } }
        _ = try flow.sign(request())
        XCTAssertEqual(first.closed, [false], "the first tap ends")
        XCTAssertEqual(second.pins, ["1234"])
        XCTAssertEqual(hw.looks, [true, true])
    }

    func testABlockedPinIsNotAskedAgain() {
        let hw = FakeHardware()
        hw.wired = true
        let device = FakeDevice(script: [.failure(.ctap(0x32))])
        hw.devices = [device]
        let (flow, ui) = make(hw)
        ui.onShow = { sheet, flow in if case .pin = sheet.stage { flow.userAction(.pin("0000")) } }
        let f = failure { try flow.sign(self.request(verify: true)) }
        XCTAssertEqual(f?.code, .pinInvalid)
        XCTAssertTrue(f?.pinBlocked == true)
        XCTAssertEqual(device.calls, 1)
    }

    func testThreeWrongPinsStop() {
        let hw = FakeHardware()
        hw.wired = true
        let device = FakeDevice(script: [.failure(.ctap(0x31))])
        hw.devices = [device]
        let (flow, ui) = make(hw)
        ui.onShow = { sheet, flow in if case .pin = sheet.stage { flow.userAction(.pin("0000")) } }
        let f = failure { try flow.sign(self.request(verify: true)) }
        XCTAssertEqual(f?.code, .pinInvalid)
        XCTAssertEqual(device.calls, SecurityKeyFlow.pinTries)
    }

    func testAServerRequestInTheBackgroundIsNoDevice() {
        let hw = FakeHardware()
        hw.wired = true
        let (flow, ui) = make(hw)
        flow.setAppActive(false)
        let f = failure { try flow.sign(self.request(purpose: "server_session")) }
        XCTAssertEqual(f?.code, .noDevice)
        XCTAssertTrue(ui.shown.isEmpty, "nothing shown: another device may answer")
    }

    func testAServerRequestWithoutAnyReaderIsNoDevice() {
        let hw = FakeHardware()
        hw.nfcAvailable = false
        let (flow, ui) = make(hw)
        let f = failure { try flow.sign(self.request(purpose: "test")) }
        XCTAssertEqual(f?.code, .noDevice)
        XCTAssertTrue(ui.shown.isEmpty)
    }

    func testAServerRequestNotOnThisIPhone() {
        let hw = FakeHardware()
        let (flow, ui) = make(hw)
        ui.onShow = { sheet, flow in if sheet.stage == .insert(nfc: false) { flow.userAction(.notHere) } }
        let f = failure { try flow.sign(self.request(purpose: "server_session")) }
        XCTAssertEqual(f?.code, .noDevice)
        XCTAssertEqual(hw.looks, [false], "a server's request does not open the NFC sheet by itself")
        XCTAssertTrue(ui.shown.first?.purpose.forwarded == true)
    }

    func testAServerRequestReadByNFCWhenAsked() throws {
        let hw = FakeHardware()
        let (flow, ui) = make(hw)
        flow.forwardedWait = 3
        let asked = Box(false)
        ui.onShow = { sheet, flow in
            if sheet.stage == .insert(nfc: false), !asked.value {
                asked.value = true
                hw.devices = [FakeDevice(.nfc)]
                flow.userAction(.useNFC)
            }
        }
        _ = try flow.sign(request(purpose: "server"))
        XCTAssertEqual(hw.looks, [false, true])
    }

    func testNoKeyInTimeIsNoDevice() {
        let hw = FakeHardware()
        let (flow, _) = make(hw)
        let f = failure { try flow.sign(self.request(purpose: "server_session")) }
        XCTAssertEqual(f?.code, .noDevice)
    }

    func testOneOperationAtATime() throws {
        let hw = FakeHardware()
        hw.wired = true
        let first = FakeDevice()
        first.blocks = true
        let second = FakeDevice()
        hw.devices = [first, second]
        let (flow, _) = make(hw)
        let done = DispatchGroup()
        let r0 = Box<SKCode?>(nil), r1 = Box<SKCode?>(nil)
        done.enter()
        DispatchQueue.global().async {
            r0.value = self.failure { try flow.sign(self.request(message: Data([1]))) }?.code
            done.leave()
        }
        XCTAssertEqual(first.started.wait(timeout: .now() + 2), .success)
        done.enter()
        DispatchQueue.global().async {
            r1.value = self.failure { try flow.sign(self.request(message: Data([2]))) }?.code
            done.leave()
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(second.calls, 0, "the second waits for the first")
        XCTAssertEqual(hw.looks.count, 1)
        flow.userAction(.cancel)
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(r0.value, .cancelled)
        XCTAssertNil(r1.value, "then the second signs")
        XCTAssertEqual(second.calls, 1)
    }

    func testARequestDecidedElsewhereStops() {
        let hw = FakeHardware()
        hw.wired = true
        let device = FakeDevice()
        device.blocks = true
        hw.devices = [device]
        let (flow, ui) = make(hw)
        let message = Data([0xAB, 0xCD])
        flow.noteRequest(id: "r1", message: message)
        let f = Box<SKFailure?>(nil)
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global().async {
            f.value = self.failure { try flow.sign(self.request(purpose: "server_session", message: message)) }
            done.leave()
        }
        XCTAssertEqual(device.started.wait(timeout: .now() + 2), .success)
        flow.noteDone(id: "r1")
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(f.value?.code, .cancelled)
        XCTAssertTrue(device.cancelled)
        XCTAssertEqual(ui.hides, 1, "the sheet goes away")
        // The same request asked again later (it was decided): at once.
        XCTAssertEqual(failure { try flow.sign(self.request(purpose: "server_session", message: message)) }?.code, .cancelled)
    }

    func testAQueuedRequestDecidedElsewhereIsDropped() {
        let hw = FakeHardware()
        hw.wired = true
        let first = FakeDevice()
        first.blocks = true
        let other = FakeDevice()
        hw.devices = [first, other]
        let (flow, _) = make(hw)
        let done = DispatchGroup()
        let second = Box<SKFailure?>(nil)
        done.enter()
        DispatchQueue.global().async {
            _ = self.failure { try flow.sign(self.request(message: Data([1]))) }
            done.leave()
        }
        XCTAssertEqual(first.started.wait(timeout: .now() + 2), .success)
        let m = Data([5, 5])
        flow.noteRequest(id: "r2", message: m)
        done.enter()
        DispatchQueue.global().async {
            second.value = self.failure { try flow.sign(self.request(purpose: "test", message: m)) }
            done.leave()
        }
        Thread.sleep(forTimeInterval: 0.2)
        flow.noteDone(id: "r2")
        Thread.sleep(forTimeInterval: 0.2)
        flow.userAction(.cancel)
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(second.value?.code, .cancelled)
        XCTAssertEqual(other.calls, 0, "dropped without touching any key")
    }

    func testResidentKeysNeedThePin() throws {
        let hw = FakeHardware()
        hw.wired = true
        let device = FakeDevice()
        hw.devices = [device]
        let (flow, ui) = make(hw)
        ui.onShow = { sheet, flow in if case .pin = sheet.stage { flow.userAction(.pin("1234")) } }
        let list = try flow.listResident(prefix: "ssh:")
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(device.pins, ["1234"])
        XCTAssertEqual(ui.shown.first?.purpose, .loadResident)
    }

    func testCancelWhileAskingThePin() {
        let hw = FakeHardware()
        hw.wired = true
        hw.devices = [FakeDevice()]
        let (flow, ui) = make(hw)
        ui.onShow = { sheet, flow in if case .pin = sheet.stage { flow.userAction(.cancel) } }
        XCTAssertEqual(failure { try flow.sign(self.request(verify: true)) }?.code, .cancelled)
    }

    // MARK: Codes and texts

    func testCtapStatuses() {
        XCTAssertEqual(SKFailure.ctap(0x2E).code, .notFound)
        XCTAssertEqual(SKFailure.ctap(0x22).code, .notFound)
        XCTAssertEqual(SKFailure.ctap(0x36).code, .pinRequired)
        XCTAssertEqual(SKFailure.ctap(0x35).code, .pinRequired)
        XCTAssertEqual(SKFailure.ctap(0x31).code, .pinInvalid)
        XCTAssertFalse(SKFailure.ctap(0x31).pinBlocked)
        XCTAssertTrue(SKFailure.ctap(0x34).pinBlocked)
        XCTAssertEqual(SKFailure.ctap(0x2F).code, .timeout)
        XCTAssertEqual(SKFailure.ctap(0x2D).code, .cancelled)
        XCTAssertEqual(SKFailure.ctap(0x27).code, .cancelled)
        XCTAssertEqual(SKFailure.ctap(0x26).code, .unsupported)
        XCTAssertEqual(SKFailure.ctap(0x7F).code, .failed)
        XCTAssertEqual(SKFailure.ctap(0x7F).message, "CTAP error 0x7F")
    }

    func testCodes() {
        XCTAssertEqual(SKCode.parse("security_key_no_device"), .noDevice)
        XCTAssertEqual(SKCode.parse("pin_invalid"), .pinInvalid)
        XCTAssertNil(SKCode.parse("auth_failed"))
        XCTAssertEqual(SKCode.noDevice.apiCode, "security_key_no_device")
        XCTAssertTrue(SKCode.failed.showsDetail)
        XCTAssertFalse(SKCode.timeout.showsDetail)
    }

    func testServerTextsAreRecognized() {
        XCTAssertEqual(SKCode.ofMessage("None of your devices that can use security keys is online"), .noDevice)
        XCTAssertEqual(SKCode.ofMessage("Nobody confirmed the security key in time"), .timeout)
        XCTAssertEqual(SKCode.ofMessage("the security key request was cancelled"), .cancelled)
        XCTAssertEqual(SKCode.ofMessage("wrong PIN for the security key"), .pinInvalid)
        XCTAssertEqual(SKCode.ofMessage("the security key's signature does not match this key"), .wrongKey)
        XCTAssertNil(SKCode.ofMessage("Connection refused"))
    }

    func testTheSessionTouchMessage() {
        XCTAssertEqual(SKSessionMessage.parse("Touch your security key (YubiKey 5C) on one of your devices…"), .touch(key: "YubiKey 5C"))
        XCTAssertEqual(SKSessionMessage.parse("Touch your security key on one of your devices…"), .touch(key: nil))
        XCTAssertNil(SKSessionMessage.parse("Connecting to web1…"))
    }

    func testWhatTheSheetShows() {
        let c = request().context
        XCTAssertEqual(c.target, "deploy@web1 (10.0.0.5)")
        XCTAssertEqual(c.keyText, "YubiKey · YubiKey 5C")
        XCTAssertFalse(c.forwarded)
        var s = c
        s.purpose = "server_session"
        XCTAssertTrue(s.forwarded)
        s.host = ""
        s.username = ""
        XCTAssertEqual(s.target, "10.0.0.5")
    }

    func testCoseKeys() {
        let x = Data(repeating: 0x11, count: 32)
        let ed = SKCose.ed25519(x: x)
        XCTAssertEqual(Array(ed.prefix(10)), [0xA4, 0x01, 0x01, 0x03, 0x27, 0x20, 0x06, 0x21, 0x58, 0x20])
        XCTAssertEqual(ed.count, 10 + 32)
        let ec = SKCose.p256(x: x, y: Data(repeating: 0x22, count: 32))
        XCTAssertEqual(Array(ec.prefix(10)), [0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20])
        XCTAssertEqual(ec.count, 10 + 32 + 3 + 32)
    }
}
