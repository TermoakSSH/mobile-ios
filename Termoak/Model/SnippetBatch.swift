import Combine
import Foundation

/// A snippet sent to several terminals at once (several servers, or every
/// open terminal): each one gets it as soon as it is connected, and the
/// summary says how it went for each.
@MainActor
final class SnippetBatch: ObservableObject {
    enum Status: Equatable {
        case connecting
        /// A password, passphrase or fingerprint to answer in its terminal.
        case waitingForYou
        case sent
        case failed(String)
        case skipped(String)

        var finished: Bool {
            switch self {
            case .connecting, .waitingForYou: return false
            case .sent, .failed, .skipped: return true
            }
        }
    }

    struct Item: Identifiable {
        let id: UUID
        let name: String
        var status: Status
    }

    @Published private(set) var items: [Item] = []
    let run: Bool
    private let text: String
    private var watching: [UUID: AnyCancellable] = [:]

    var sentCount: Int { items.filter { $0.status == .sent }.count }
    var finished: Bool { items.allSatisfy { $0.status.finished } }
    /// Some terminal waits for a password or a fingerprint.
    var needsYou: Bool { items.contains { $0.status == .waitingForYou } }

    init(text: String, run: Bool, terminals: [TerminalSession]) {
        self.text = text
        self.run = run
        items = terminals.map { Item(id: $0.id, name: $0.displayTitle, status: .connecting) }
        for t in terminals { start(t) }
    }

    private func start(_ t: TerminalSession) {
        if t.asleep {
            set(t.id, .skipped(String(localized: "snippets.send.status.not_connected")))
            return
        }
        if case .closed = t.state {
            set(t.id, .skipped(String(localized: "snippets.send.status.not_connected")))
            return
        }
        if t.state == .connected {
            deliver(to: t)
            return
        }
        // Until it connects (or fails); a dialog waiting for you is said.
        let id = t.id
        watching[id] = t.$state.combineLatest(t.$prompt.map { $0 != nil })
            .receive(on: RunLoop.main)
            .sink { [weak self, weak t] state, asking in
                guard let self, let t else { return }
                switch state {
                case .connected:
                    self.watching[id] = nil
                    // A moment for the shell to show its prompt.
                    Task { @MainActor [weak self, weak t] in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        guard let self, let t else { return }
                        self.deliver(to: t)
                    }
                case .closed(let reason):
                    self.watching[id] = nil
                    self.set(id, .failed(reason))
                case .connecting:
                    self.set(id, asking ? .waitingForYou : .connecting)
                }
            }
    }

    private func deliver(to t: TerminalSession) {
        let ok = run ? t.runHere(text) : t.pasteHere(text)
        if ok {
            set(t.id, .sent)
        } else if !t.canWrite {
            set(t.id, .skipped(String(localized: "snippets.send.status.read_only")))
        } else {
            set(t.id, .failed(String(localized: "snippets.send.status.not_connected")))
        }
    }

    private func set(_ id: UUID, _ status: Status) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].status != status else { return }
        // Once sent (or failed), it stays so.
        guard !items[i].status.finished else { return }
        items[i].status = status
    }
}
