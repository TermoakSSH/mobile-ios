import TermoakKit
import Foundation

/// Where the files come from: SFTP over the phone's SSH connection or SFTP
/// done by the server (for the sessions that live there).
protocol RemoteFileSystem: AnyObject {
    /// Permissions can be changed (only over direct SSH).
    var canChmod: Bool { get }
    func home() async throws -> String
    func list(_ path: String) async throws -> [RemoteFile]
    func download(_ remote: String, to local: URL, progress: TransferListener) async throws
    func upload(_ local: URL, to remote: String, progress: TransferListener) async throws
    func createFolder(_ path: String) async throws
    func rename(_ from: String, to: String) async throws
    func delete(_ path: String, recursive: Bool) async throws
    func setPermissions(_ path: String, mode: UInt32) async throws
    /// Releases the connection if it is our own (not that of an open terminal).
    func close()
}

final class SshFileSystem: RemoteFileSystem {
    let session: SshSession
    /// The connection belongs to the browser (not to a terminal): closed on exit.
    private let own: Bool

    init(session: SshSession, own: Bool) {
        self.session = session
        self.own = own
    }

    var canChmod: Bool { true }
    func home() async throws -> String { try await session.sftpHome() }
    func list(_ path: String) async throws -> [RemoteFile] { try await session.sftpList(path: path) }
    func download(_ remote: String, to local: URL, progress: TransferListener) async throws {
        _ = try await session.sftpDownload(remotePath: remote, localPath: local.path, listener: progress)
    }
    func upload(_ local: URL, to remote: String, progress: TransferListener) async throws {
        _ = try await session.sftpUpload(localPath: local.path, remotePath: remote, listener: progress)
    }
    func createFolder(_ path: String) async throws { try await session.sftpMkdir(path: path, recursive: false) }
    func rename(_ from: String, to: String) async throws { try await session.sftpRename(from: from, to: to) }
    func delete(_ path: String, recursive: Bool) async throws { try await session.sftpRemove(path: path, recursive: recursive) }
    func setPermissions(_ path: String, mode: UInt32) async throws { try await session.sftpChmod(path: path, mode: mode) }
    func close() {
        guard own else { return }
        let s = session
        Task.detached { try? await s.disconnect() }
    }
}

final class ServerFileSystem: RemoteFileSystem {
    let core: TermoakCore
    let hostId: String
    /// The host's account (`nil`: wherever the host is).
    let accountId: String?

    init(core: TermoakCore, hostId: String, accountId: String?) {
        self.core = core
        self.hostId = hostId
        self.accountId = accountId
    }

    var canChmod: Bool { false }
    func home() async throws -> String { try await core.serverSftpHome(hostId: hostId, accountId: accountId) }
    func list(_ path: String) async throws -> [RemoteFile] { try await core.serverSftpList(hostId: hostId, path: path, accountId: accountId) }
    func download(_ remote: String, to local: URL, progress: TransferListener) async throws {
        _ = try await core.serverSftpDownload(hostId: hostId, remotePath: remote, localPath: local.path, listener: progress, accountId: accountId)
    }
    func upload(_ local: URL, to remote: String, progress: TransferListener) async throws {
        _ = try await core.serverSftpUpload(hostId: hostId, localPath: local.path, remotePath: remote, listener: progress, accountId: accountId)
    }
    func createFolder(_ path: String) async throws { try await core.serverSftpMkdir(hostId: hostId, path: path, parents: false, accountId: accountId) }
    func rename(_ from: String, to: String) async throws { try await core.serverSftpRename(hostId: hostId, from: from, to: to, accountId: accountId) }
    func delete(_ path: String, recursive: Bool) async throws { try await core.serverSftpDelete(hostId: hostId, path: path, recursive: recursive, accountId: accountId) }
    func setPermissions(_ path: String, mode: UInt32) async throws {
        throw TermoakError.Invalid(message: String(localized: "files.error.chmod_ssh_only"))
    }
    func close() {}
}

/// An upload or download, with its progress and what became of it.
struct Transfer: Identifiable, Equatable {
    enum Status: Equatable { case waiting, running, done, failed, cancelled }

    let id = UUID()
    let name: String
    let uploading: Bool
    var done: UInt64 = 0
    var total: UInt64?
    var status: Status = .waiting
    var error: String?

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }

    /// Waiting or running (it can be cancelled; the others can be removed).
    var active: Bool { status == .waiting || status == .running }
}

/// What a download is for.
enum DownloadPurpose: Equatable {
    /// Quick Look.
    case preview
    /// The share sheet.
    case share
    /// "Save to Files" (the system's folder picker).
    case save
}

/// A downloaded file the screen hands to Quick Look, the share sheet or Files.
struct DownloadedFile: Identifiable, Equatable {
    let url: URL
    let purpose: DownloadPurpose
    var id: String { url.path }
}

/// Files picked to upload into a folder; `conflicts`: names that already
/// exist there (replace them or keep both?).
struct UploadRequest: Identifiable {
    let id = UUID()
    let files: [(url: URL, name: String)]
    let folder: String
    let conflicts: [String]
}

/// Receives the engine's progress (background thread) and passes it to the main thread.
private final class ProgressRelay: TransferListener, @unchecked Sendable {
    private let onChange: @Sendable (UInt64, UInt64?) -> Void
    private var last = Date.distantPast

    init(_ onChange: @escaping @Sendable (UInt64, UInt64?) -> Void) {
        self.onChange = onChange
    }

    func onProgress(transferred: UInt64, total: UInt64?) {
        // At most about ten times per second.
        let now = Date()
        guard now.timeIntervalSince(last) > 0.1 || transferred == total else { return }
        last = now
        onChange(transferred, total)
    }
}

/// State of the remote file browser.
@MainActor
final class FileBrowser: ObservableObject {
    enum Source {
        /// Connection of an open terminal.
        case session(SshSession)
        /// Connect from the phone (asking for fingerprint or password if needed).
        case connect(hostId: String, accountId: String?)
        /// SFTP from the server (the host's account).
        case server(hostId: String, accountId: String?)
    }

    let title: String
    @Published private(set) var path = ""
    @Published private(set) var entries: [RemoteFile] = []
    @Published private(set) var loading = true
    @Published var error: String?
    @Published private(set) var transfers: [Transfer] = []
    @Published var prompt: AuthPrompt?
    /// Picked files whose names already exist in the folder: replace them or keep both?
    @Published var uploadAsk: UploadRequest?
    /// A download finished: the screen opens, shares or saves it.
    @Published var downloaded: DownloadedFile?
    @Published var showHidden = UserDefaults.standard.bool(forKey: "sftp_ocultos") {
        didSet { UserDefaults.standard.set(showHidden, forKey: "sftp_ocultos") }
    }
    @Published private(set) var sort = FileSort(rawValue: UserDefaults.standard.string(forKey: "sftp_sort") ?? "") ?? .name
    @Published private(set) var descending = UserDefaults.standard.bool(forKey: "sftp_sort_descending")

    private let core: TermoakCore
    private let source: Source
    private(set) var fileSystem: RemoteFileSystem?
    private var slots = TransferSlots(limit: 2)
    /// Transfers waiting for a slot (resumed when one is free, or cancelled).
    private var turns: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    /// How to start each transfer again (failed or cancelled ones).
    private var retries: [UUID: () -> Void] = [:]
    /// Each start of a transfer (a retry is another one): an earlier start
    /// that ends late (cancelled while the engine finished it) changes nothing.
    private var attempts: [UUID: Int] = [:]

    init(core: TermoakCore, title: String, source: Source) {
        self.core = core
        self.title = title
        self.source = source
    }

    var canChmod: Bool { fileSystem?.canChmod ?? false }

    /// The folder as shown: hidden files as chosen, filtered by `query`,
    /// folders first and in the chosen order.
    func arranged(query: String) -> [RemoteFile] {
        FileListing.arrange(entries, item: { FileListingItem(name: $0.name, dir: $0.kind == .dir, size: $0.size, modified: $0.modified) },
                            sort: sort, descending: descending, showHidden: showHidden, query: query)
    }

    /// Sorts by `by`; the same one again turns the order around.
    func setSort(_ by: FileSort) {
        (sort, descending) = FileListing.nextSort(current: sort, descending: descending, chosen: by)
        UserDefaults.standard.set(sort.rawValue, forKey: "sftp_sort")
        UserDefaults.standard.set(descending, forKey: "sftp_sort_descending")
    }

    func open() async {
        guard fileSystem == nil else { return }
        loading = true
        do {
            switch source {
            case .session(let s):
                fileSystem = SshFileSystem(session: s, own: false)
            case .server(let hostId, let accountId):
                fileSystem = ServerFileSystem(core: core, hostId: hostId, accountId: accountId)
            case .connect(let hostId, let accountId):
                let auth = AuthBridge { [weak self] p in
                    Task { @MainActor in self?.prompt = p }
                }
                fileSystem = SshFileSystem(session: try await core.connect(hostId: hostId, auth: auth, accountId: accountId), own: true)
            }
            let home = try await fileSystem!.home()
            await go(to: home)
        } catch {
            loading = false
            self.error = userMessage(error)
        }
    }

    /// Leaving the browser: the waiting and running transfers stop (a
    /// running one may still finish in the engine) and our own connection
    /// closes.
    func close() {
        for t in transfers where t.active { cancel(t.id) }
        fileSystem?.close()
    }

    func go(to newPath: String) async {
        guard let fileSystem else { return }
        loading = true
        defer { loading = false }
        do {
            entries = try await fileSystem.list(newPath)
            path = newPath
        } catch {
            self.error = userMessage(error)
        }
    }

    func reload() async { await go(to: path) }

    func goUp() async {
        guard path != "/" else { return }
        await go(to: RemotePaths.parent(path))
    }

    /// Path of a name inside the current folder.
    func inside(_ name: String) -> String {
        RemotePaths.child(path.isEmpty ? "/" : path, name)
    }

    func createFolder(_ name: String) async {
        await perform { try await $0.createFolder(self.inside(name.trimmingCharacters(in: .whitespaces))) }
    }

    func rename(_ f: RemoteFile, to name: String) async {
        let target = RemotePaths.child(RemotePaths.parent(f.path), name.trimmingCharacters(in: .whitespaces))
        await perform { try await $0.rename(f.path, to: target) }
    }

    func delete(_ f: RemoteFile) async {
        await perform { try await $0.delete(f.path, recursive: f.kind == .dir) }
    }

    func setPermissions(_ f: RemoteFile, mode: UInt32) async {
        await perform { try await $0.setPermissions(f.path, mode: mode) }
    }

    private func perform(_ action: @escaping (RemoteFileSystem) async throws -> Void) async {
        guard let fileSystem else { return }
        do {
            try await action(fileSystem)
        } catch {
            self.error = userMessage(error)
        }
        await reload()
    }

    // MARK: Transfers

    /// Downloads a file to a temporary folder; when it is there, `downloaded`
    /// hands it to the screen (Quick Look, share sheet or Files).
    func download(_ f: RemoteFile, for purpose: DownloadPurpose) {
        guard let fileSystem else { return }
        let t = Transfer(name: f.name, uploading: false)
        add(t) { [weak self] listener in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(RemotePaths.uploadName(f.name))
            try await fileSystem.download(f.path, to: target, progress: listener)
            guard let self, self.status(t.id) == .running else {
                try? FileManager.default.removeItem(at: folder)
                return
            }
            self.downloaded = DownloadedFile(url: target, purpose: purpose)
        }
    }

    /// Files picked in Files to upload to the folder on screen: if some
    /// names already exist there, asks first (`uploadAsk`); otherwise they go up.
    func pickedForUpload(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let files = urls.map { (url: $0, name: RemotePaths.uploadName($0.lastPathComponent)) }
        let existing = Set(entries.map(\.name))
        let request = UploadRequest(files: files, folder: path, conflicts: files.map(\.name).filter { existing.contains($0) })
        if request.conflicts.isEmpty {
            upload(request, replace: true)
        } else {
            uploadAsk = request
        }
    }

    /// Uploads a request: replacing the files with the same name, or with a
    /// free name ("a (1).txt").
    func upload(_ request: UploadRequest, replace: Bool) {
        uploadAsk = nil
        guard let fileSystem else { return }
        var taken = Set(entries.map(\.name))
        for (local, picked) in request.files {
            let name = replace ? picked : RemotePaths.freeName(picked, taken: taken)
            taken.insert(name)
            let remote = RemotePaths.child(request.folder.isEmpty ? "/" : request.folder, name)
            add(Transfer(name: name, uploading: true)) { [weak self] listener in
                let access = local.startAccessingSecurityScopedResource()
                defer { if access { local.stopAccessingSecurityScopedResource() } }
                try await fileSystem.upload(local, to: remote, progress: listener)
                if let self, self.path == request.folder { await self.reload() }
            }
        }
    }

    /// Cancels a waiting or running transfer. A running one stops here at
    /// once, but the engine may finish it in the background (its async calls
    /// can't be cancelled yet).
    func cancel(_ id: UUID) {
        guard let i = transfers.firstIndex(where: { $0.id == id }), transfers[i].active else { return }
        transfers[i].status = .cancelled
        jobs[id]?.cancel()
        jobs[id] = nil
        release(id)
    }

    func retry(_ id: UUID) {
        guard let run = retries[id], let i = transfers.firstIndex(where: { $0.id == id }), !transfers[i].active else { return }
        transfers[i].status = .waiting
        transfers[i].done = 0
        transfers[i].error = nil
        run()
    }

    /// Removes a finished, failed or cancelled transfer from the list.
    func dismiss(_ id: UUID) {
        transfers.removeAll { $0.id == id && !$0.active }
        retries[id] = nil
        attempts[id] = nil
    }

    private func status(_ id: UUID) -> Transfer.Status? {
        transfers.first { $0.id == id }?.status
    }

    private func set(_ id: UUID, _ change: (inout Transfer) -> Void) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[i])
    }

    private func add(_ t: Transfer, _ action: @escaping (TransferListener) async throws -> Void) {
        transfers.append(t)
        let run = { [weak self] in self?.start(t.id, action) }
        retries[t.id] = { run() }
        run()
    }

    /// Runs a transfer in its turn, with progress, and leaves it done,
    /// failed or cancelled.
    private func start(_ id: UUID, _ action: @escaping (TransferListener) async throws -> Void) {
        let attempt = (attempts[id] ?? 0) + 1
        attempts[id] = attempt
        jobs[id] = Task { [weak self] in
            guard let self else { return }
            await self.waitTurn(id)
            guard self.status(id) == .waiting, !Task.isCancelled else { return }
            self.set(id) { $0.status = .running }
            let listener = ProgressRelay { [weak self] done, total in
                Task { @MainActor in
                    guard let self, self.attempts[id] == attempt else { return }
                    self.set(id) { t in
                        guard t.status == .running else { return }
                        t.done = done
                        t.total = total ?? t.total
                    }
                }
            }
            /// Still this start's transfer, and running.
            @MainActor func current() -> Bool { self.attempts[id] == attempt && self.status(id) == .running }
            do {
                try await action(listener)
                guard current() else { return }
                self.set(id) { t in
                    t.status = .done
                    t.done = t.total ?? t.done
                }
                self.retries[id] = nil
                self.release(id)
                // Done ones leave the list after a moment.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self.transfers.removeAll { $0.id == id && $0.status == .done }
            } catch {
                guard current() else { return }
                let why = userMessage(error)
                self.set(id) { t in
                    t.status = .failed
                    t.error = why
                }
                self.release(id)
            }
            self.jobs[id] = nil
        }
    }

    /// Waits until fewer than two transfers run.
    private func waitTurn(_ id: UUID) async {
        if slots.enqueue(id) { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            turns[id] = c
        }
    }

    /// A transfer ended or was cancelled: its slot (or place in the queue)
    /// goes to the next ones.
    private func release(_ id: UUID) {
        if let waiting = turns.removeValue(forKey: id) { waiting.resume() }
        for next in slots.finish(id) {
            turns.removeValue(forKey: next)?.resume()
        }
    }
}
