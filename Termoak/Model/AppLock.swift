import Foundation
import LocalAuthentication
import SwiftUI

/// The app lock (like the desktop's): Face ID, Touch ID or the device
/// passcode to open Termoak, and again after it was in the background for
/// the chosen time. While the app is not active, a cover hides the screen
/// in the app switcher. The terminals keep running underneath.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()

    @Published private(set) var enabled: Bool { didSet { d.set(enabled, forKey: "app_lock") } }
    @Published var delay: LockDelay { didSet { d.set(delay.rawValue, forKey: "app_lock_delay") } }
    /// Locked: the lock screen covers the app.
    @Published private(set) var locked: Bool
    /// The app is not active and the lock is on: cover the screen.
    @Published private(set) var covered = false
    @Published private(set) var error: String?
    @Published private(set) var checking = false

    private let d = UserDefaults.standard
    private var backgroundedAt: Date?

    init() {
        let on = UserDefaults.standard.bool(forKey: "app_lock")
        enabled = on
        delay = LockDelay(rawValue: UserDefaults.standard.integer(forKey: "app_lock_delay")) ?? .immediately
        locked = on
    }

    /// "Face ID", "Touch ID" or "your passcode".
    var method: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return String(localized: "lock.method.passcode")
        }
    }

    /// The device has a passcode (or biometrics): the lock can be used.
    var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if backgroundedAt == nil { backgroundedAt = Date() }
            covered = enabled
        case .inactive:
            covered = enabled
        case .active:
            covered = false
            if LockPolicy.shouldLock(enabled: enabled, delay: delay, backgroundedAt: backgroundedAt, now: Date()) {
                locked = true
            }
            backgroundedAt = nil
            if locked { unlock() }
        @unknown default:
            break
        }
    }

    /// Asks for Face ID / Touch ID / the passcode and opens the app. Without
    /// a passcode on the device any more, the app opens (never shut out).
    func unlock() {
        guard locked, !checking else { return }
        guard available else {
            locked = false
            return
        }
        checking = true
        error = nil
        Task {
            let ok = await verify(reason: String(localized: "lock.reason_open"))
            checking = false
            if ok { locked = false }
        }
    }

    func lockNow() {
        guard enabled else { return }
        locked = true
    }

    /// Turning it on asks once, to check it works; turning it off too (so
    /// whoever has the unlocked phone can't just switch it off).
    func setEnabled(_ on: Bool) {
        guard on != enabled, !checking else { return }
        guard available else {
            if !on { enabled = false }
            return
        }
        checking = true
        error = nil
        Task {
            let ok = await verify(reason: String(localized: "lock.reason_enable"))
            checking = false
            if ok { enabled = on }
        }
    }

    private func verify(reason: String) async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let e as LAError where e.code == .userCancel || e.code == .appCancel || e.code == .systemCancel {
            error = String(localized: "lock.canceled")
            return false
        } catch {
            self.error = String(localized: "lock.failed")
            return false
        }
    }
}
