import TermoakKit
import Foundation
import Security

/// Opens the local vault. The key is generated the first time and stored in
/// the Keychain (this device only); the data lives in Application Support.
@MainActor
final class LocalVault: ObservableObject {
    @Published private(set) var core: TermoakCore?
    @Published private(set) var error: String?

    func open() {
        guard core == nil else { return }
        do {
            let dir = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask,
                     appropriateFor: nil, create: true)
                .appendingPathComponent("Termoak", isDirectory: true)
            let key = try Keychain.vaultKey()
            let core = try TermoakCore(dataDir: dir.path, vaultKeyB64: key)
            #if DEBUG
            Self.seedTestHost(core)
            #endif
            self.core = core
        } catch {
            self.error = errorMessage(error)
        }
    }

    #if DEBUG
    /// Only for the UI tests (never reaches the .ipa, which is Release):
    /// `TERMOAK_TEST_HOST` = `address:port:user` and
    /// `TERMOAK_TEST_KEY` = private key create the host "test".
    private static func seedTestHost(_ core: TermoakCore) {
        let env = ProcessInfo.processInfo.environment
        guard let target = env["TERMOAK_TEST_HOST"], let pem = env["TERMOAK_TEST_KEY"],
              (try? core.listHosts().contains { $0.label == "test" }) == false else { return }
        let parts = target.split(separator: ":").map(String.init)
        guard parts.count == 3 else { return }
        let wait = DispatchSemaphore(value: 0)
        Task.detached {
            defer { wait.signal() }
            guard let key = try? await core.importKey(label: "test", privateKey: pem, passphrase: nil,
                                                      storePassphrase: false, syncMode: nil) else { return }
            var host = SshHost(label: "test", address: parts[0])
            host.settings.port = UInt32(parts[1])
            host.settings.username = parts[2]
            host.settings.keyId = key.id
            _ = try? core.saveHost(host: host, password: .keep)
        }
        wait.wait()
    }
    #endif
}

enum Keychain {
    private static let service = "com.termoak"
    private static let account = "vault-key"

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain: error \(status)" }
    }

    static func vaultKey() throws -> String {
        if let existing = try read() { return existing }
        let new = generateVaultKey()
        try save(new)
        return new
    }

    private static func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Failure(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    private static func save(_ key: String) throws {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(key.utf8),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }
}
