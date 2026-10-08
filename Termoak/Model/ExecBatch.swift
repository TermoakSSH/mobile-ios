import TermoakKit
import Foundation

/// A command run on several servers without terminals (the engine's `exec`
/// over a connection from this device), collecting each one's output: like
/// the desktop's "Run on…" with per-host results. A few run at once; a
/// password, passphrase or fingerprint to answer waits in `prompts`.
@MainActor
final class ExecBatch: ObservableObject {
    enum Status: Equatable {
        case waiting
        case connecting
        case running
        case done(ExecOutput)
        case failed(String)

        var finished: Bool {
            switch self {
            case .done, .failed: return true
            default: return false
            }
        }
    }

    struct Item: Identifiable {
        /// The host's `SshHost.key`.
        let id: String
        let name: String
        var status: Status
    }

    @Published private(set) var items: [Item] = []
    /// Questions while connecting, answered one at a time.
    @Published private(set) var prompts: [AuthPrompt] = []

    let command: String
    private let core: TermoakCore
    /// How many servers at once.
    private let limit = 4
    /// Seconds a command may take on each server.
    private let timeout: UInt32 = 120

    var finished: Bool { items.allSatisfy { $0.status.finished } }
    var succeeded: Int {
        items.filter { if case .done(let o) = $0.status { return o.succeeded } else { return false } }.count
    }

    init(core: TermoakCore, command: String, hosts: [SshHost]) {
        self.core = core
        self.command = command
        items = hosts.map { Item(id: $0.key, name: $0.displayName, status: .waiting) }
        Task { await runAll(hosts) }
    }

    /// A question was answered or dismissed.
    func promptClosed(_ id: UUID) {
        prompts.removeAll { $0.id == id }
    }

    private func runAll(_ hosts: [SshHost]) async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for host in hosts {
                if running >= limit {
                    await group.next()
                    running -= 1
                }
                group.addTask { await self.run(host) }
                running += 1
            }
        }
    }

    private func run(_ host: SshHost) async {
        set(host.key, .connecting)
        let auth = AuthBridge { [weak self] p in
            Task { @MainActor in self?.prompts.append(p) }
        }
        do {
            let session = try await core.connect(hostId: host.id, auth: auth, accountId: host.accountId, keyChanged: auth)
            set(host.key, .running)
            defer { Task.detached { try? await session.disconnect() } }
            let r = try await session.exec(command: command, timeoutSecs: timeout)
            set(host.key, .done(ExecOutput(stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode, signal: r.exitSignal,
                                           timedOut: r.timedOut, truncated: r.truncated, durationMs: r.durationMs)))
        } catch {
            set(host.key, .failed(userMessage(error)))
        }
    }

    private func set(_ id: String, _ status: Status) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = status
    }

    /// Every server's output, to copy or share.
    func report() -> String {
        ExecReport.text(items.map { item in
            switch item.status {
            case .done(let o): return (item.name, ExecBatch.exitText(o), o)
            case .failed(let why): return (item.name, why, nil)
            default: return (item.name, String(localized: "snippets.exec.status.not_run"), nil)
            }
        })
    }

    /// "exit 0", "signal KILL", "timed out after 120 s".
    static func exitText(_ o: ExecOutput) -> String {
        if o.timedOut { return String(localized: "snippets.exec.timed_out") }
        if let s = o.signal { return String(localized: "snippets.exec.signal \(s)") }
        return String(localized: "snippets.exec.exit \(o.exitCode.map(String.init) ?? "?")")
    }
}
