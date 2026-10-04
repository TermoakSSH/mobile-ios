import TermoakKit
import Foundation

/// Question pending while connecting (server fingerprint or fields to fill in).
struct AuthPrompt: Identifiable {
    enum Kind {
        case hostKey(host: String, port: UInt32, keyType: String, fingerprint: String)
        case fields(AuthRequest)
    }

    let id = UUID()
    let kind: Kind
    /// Answer: `nil` cancels; the fingerprint is accepted with any array.
    let respond: ([String]?) -> Void
}

/// Bridge between the engine's `AuthHandler` (background thread, blocking)
/// and the UI: publishes the question on the main thread and waits for the answer.
final class AuthBridge: AuthHandler, @unchecked Sendable {
    private let publish: @Sendable (AuthPrompt) -> Void

    init(publish: @escaping @Sendable (AuthPrompt) -> Void) {
        self.publish = publish
    }

    func onHostKey(host: String, port: UInt32, keyType: String, fingerprint: String) -> Bool {
        ask(.hostKey(host: host, port: port, keyType: keyType, fingerprint: fingerprint)) != nil
    }

    func onPrompt(request: AuthRequest) -> [String]? {
        ask(.fields(request))
    }

    private func ask(_ kind: AuthPrompt.Kind) -> [String]? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()
        let prompt = AuthPrompt(kind: kind) { answer in
            box.value = answer
            semaphore.signal()
        }
        DispatchQueue.main.async { self.publish(prompt) }
        semaphore.wait()
        return box.value
    }

    private final class Box: @unchecked Sendable {
        var value: [String]?
    }
}
