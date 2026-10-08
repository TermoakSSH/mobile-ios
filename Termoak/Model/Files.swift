import TermoakKit
import Foundation

/// Where the files come from: SFTP over the phone's SSH connection or SFTP
/// done by the server (for the sessions that live there and the hosts only
/// the server reaches). Both can do the same: read and write whole files,
/// stat and chmod too through the server since engine 0.6.1.
protocol RemoteFileSystem: AnyObject {
    func read(_ path: String, maxBytes: UInt64) async throws -> Data
    func write(_ path: String, data: Data) async throws
    func home() async throws -> String
    func list(_ path: String) async throws -> [RemoteFile]
    /// One file's details (a link: those of what it points to).
    func stat(_ path: String) async throws -> RemoteFile
    /// `cancel`: cancelling it stops the transfer in the engine, which then
    /// throws `TermoakError.Cancelled` (a download leaves no file behind).
    func download(_ remote: String, to local: URL, progress: TransferListener, cancel: TransferHandle) async throws
    func upload(_ local: URL, to remote: String, progress: TransferListener, cancel: TransferHandle) async throws
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

    func home() async throws -> String { try await session.sftpHome() }
    func read(_ path: String, maxBytes: UInt64) async throws -> Data { try await session.sftpRead(path: path, maxBytes: maxBytes) }
    func write(_ path: String, data: Data) async throws { try await session.sftpWrite(path: path, data: data) }
    func list(_ path: String) async throws -> [RemoteFile] { try await session.sftpList(path: path) }
    func stat(_ path: String) async throws -> RemoteFile { try await session.sftpStat(path: path) }
    func download(_ remote: String, to local: URL, progress: TransferListener, cancel: TransferHandle) async throws {
        _ = try await session.sftpDownload(remotePath: remote, localPath: local.path, listener: progress, cancel: cancel)
    }
    func upload(_ local: URL, to remote: String, progress: TransferListener, cancel: TransferHandle) async throws {
        _ = try await session.sftpUpload(localPath: local.path, remotePath: remote, listener: progress, cancel: cancel)
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

    func home() async throws -> String { try await core.serverSftpHome(hostId: hostId, accountId: accountId) }
    func read(_ path: String, maxBytes: UInt64) async throws -> Data {
        try await core.serverSftpRead(hostId: hostId, path: path, maxBytes: maxBytes, accountId: accountId)
    }
    func write(_ path: String, data: Data) async throws {
        _ = try await core.serverSftpWrite(hostId: hostId, path: path, data: data, accountId: accountId)
    }
    func list(_ path: String) async throws -> [RemoteFile] { try await core.serverSftpList(hostId: hostId, path: path, accountId: accountId) }
    func stat(_ path: String) async throws -> RemoteFile { try await core.serverSftpStat(hostId: hostId, path: path, accountId: accountId) }
    func download(_ remote: String, to local: URL, progress: TransferListener, cancel: TransferHandle) async throws {
        _ = try await core.serverSftpDownload(hostId: hostId, remotePath: remote, localPath: local.path, listener: progress,
                                              accountId: accountId, cancel: cancel)
    }
    func upload(_ local: URL, to remote: String, progress: TransferListener, cancel: TransferHandle) async throws {
        _ = try await core.serverSftpUpload(hostId: hostId, localPath: local.path, remotePath: remote, listener: progress,
                                            accountId: accountId, cancel: cancel)
    }
    func createFolder(_ path: String) async throws { try await core.serverSftpMkdir(hostId: hostId, path: path, parents: false, accountId: accountId) }
    func rename(_ from: String, to: String) async throws { try await core.serverSftpRename(hostId: hostId, from: from, to: to, accountId: accountId) }
    func delete(_ path: String, recursive: Bool) async throws { try await core.serverSftpDelete(hostId: hostId, path: path, recursive: recursive, accountId: accountId) }
    func setPermissions(_ path: String, mode: UInt32) async throws {
        try await core.serverSftpChmod(hostId: hostId, path: path, mode: mode, accountId: accountId)
    }
    func close() {}
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

/// Downloaded files the screen hands to Quick Look, the share sheet or
/// Files (several when several were chosen; folders as .zip).
struct DownloadedFile: Identifiable, Equatable {
    let urls: [URL]
    let purpose: DownloadPurpose
    var url: URL { urls[0] }
    var id: String { urls.map(\.path).joined(separator: "|") }

    init(url: URL, purpose: DownloadPurpose) {
        self.init(urls: [url], purpose: purpose)
    }

    init(urls: [URL], purpose: DownloadPurpose) {
        self.urls = urls
        self.purpose = purpose
    }
}

/// The progress of one file of a batch, as part of the whole batch.
private final class BatchListener: TransferListener, @unchecked Sendable {
    private let base: UInt64
    private let total: UInt64
    private let inner: TransferListener

    init(base: UInt64, total: UInt64, inner: TransferListener) {
        self.base = base
        self.total = total
        self.inner = inner
    }

    func onProgress(transferred: UInt64, total _: UInt64?) {
        inner.onProgress(transferred: base + transferred, total: total)
    }
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
    /// The engine's handle of each running start: Cancel stops it there.
    private var handles: [UUID: TransferHandle] = [:]
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

    /// The home folder (for "Go to" `~`).
    private(set) var home = ""

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
            home = try await fileSystem!.home()
            await go(to: home)
        } catch {
            loading = false
            self.error = userMessage(error)
        }
    }

    /// Leaving the browser: the waiting and running transfers stop (in the
    /// engine too) and our own connection closes.
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

    /// Deletes several files and folders (the first error is shown; the
    /// others are still tried).
    func delete(_ files: [RemoteFile]) async {
        await perform { fs in
            var first: Error?
            for f in files {
                do { try await fs.delete(f.path, recursive: f.kind == .dir) } catch { if first == nil { first = error } }
            }
            if let first { throw first }
        }
    }

    /// Moves several files and folders into another folder.
    func move(_ files: [RemoteFile], toFolder typed: String) async {
        guard let folder = TextFiles.resolve(typed, current: path, home: home) else { return }
        await perform { fs in
            var first: Error?
            for f in files {
                let target = RemotePaths.child(folder, f.name)
                guard target != f.path else { continue }
                do { try await fs.rename(f.path, to: target) } catch { if first == nil { first = error } }
            }
            if let first { throw first }
        }
    }

    /// "Go to…": a typed path (absolute, `~/…` or inside this folder).
    func goTo(typed: String) async {
        guard let target = TextFiles.resolve(typed, current: path, home: home) else { return }
        await go(to: target)
    }

    /// An empty file in this folder.
    func createFile(_ name: String) async {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !entries.contains(where: { $0.name == n }) else {
            error = String(localized: "files.new_file.exists \(n)")
            return
        }
        await perform { try await $0.write(self.inside(n), data: Data()) }
    }

    /// Moves a file or folder into another folder (typed like in "Go to").
    func move(_ f: RemoteFile, toFolder typed: String) async {
        guard let folder = TextFiles.resolve(typed, current: path, home: home) else { return }
        let target = RemotePaths.child(folder, f.name)
        guard target != f.path else { return }
        await perform { try await $0.rename(f.path, to: target) }
    }

    /// The text of a file to edit; `nil` (and the reason in `error`) if it
    /// is too big or not text.
    func readText(_ f: RemoteFile) async -> String? {
        guard let fileSystem else { return nil }
        if f.size > TextFiles.maxBytes {
            error = String(localized: "files.edit.too_big")
            return nil
        }
        do {
            let data = try await fileSystem.read(f.path, maxBytes: TextFiles.maxBytes)
            guard let text = TextFiles.decode(data) else {
                error = String(localized: "files.edit.not_text")
                return nil
            }
            return text
        } catch {
            self.error = userMessage(error)
            return nil
        }
    }

    /// Saves an edited file (whole); throws so the editor stays open.
    func saveText(_ text: String, to path: String) async throws {
        guard let fileSystem else { return }
        try await fileSystem.write(path, data: Data(text.utf8))
        await reload()
    }

    func setPermissions(_ f: RemoteFile, mode: UInt32) async {
        await perform { try await $0.setPermissions(f.path, mode: mode) }
    }

    /// The details of a file as they are now (for Info; a link: those of
    /// what it points to). `nil` if they can't be read.
    func stat(_ f: RemoteFile) async -> RemoteFile? {
        try? await fileSystem?.stat(f.path)
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
        add(t) { [weak self] listener, cancel in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(RemotePaths.uploadName(f.name))
            do {
                try await fileSystem.download(f.path, to: target, progress: listener, cancel: cancel)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
            guard let self, self.status(t.id) == .running else {
                try? FileManager.default.removeItem(at: folder)
                return
            }
            self.downloaded = DownloadedFile(url: target, purpose: purpose)
        }
    }

    /// Downloads several files and folders (folders whole, walking them) as
    /// one transfer into a temporary folder; `downloaded` then hands them
    /// over, each folder as a .zip.
    func downloadMany(_ files: [RemoteFile], for purpose: DownloadPurpose) {
        guard let fileSystem, !files.isEmpty else { return }
        let title = files.count == 1 ? files[0].name : String(localized: "files.items \(files.count)")
        let t = Transfer(name: title, uploading: false)
        add(t) { [weak self] listener, cancel in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                try await self?.downloadBatch(t.id, files, into: folder, from: fileSystem, purpose: purpose,
                                              listener: listener, cancel: cancel)
            } catch {
                // Cancelled or failed: nothing half-downloaded stays behind.
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
    }

    /// The work of `downloadMany`: walks the folders, downloads every file
    /// (stopping when cancelled) and zips the folders.
    private func downloadBatch(_ id: UUID, _ files: [RemoteFile], into folder: URL, from fileSystem: RemoteFileSystem,
                               purpose: DownloadPurpose, listener: TransferListener, cancel: TransferHandle) async throws {
        var plan: [DownloadStep] = []
        var tops: [(file: RemoteFile, local: URL)] = []
        for f in files {
            let local = folder.appendingPathComponent(RemotePaths.uploadName(f.name), isDirectory: f.kind == .dir)
            tops.append((f, local))
            if f.kind == .dir {
                try await FileBrowser.walk(fileSystem, f.path, into: local, plan: &plan, cancel: cancel)
            } else {
                plan.append(DownloadStep(remote: f.path, local: local, size: f.size))
            }
        }
        let total = plan.reduce(0) { $0 + $1.size }
        var base: UInt64 = 0
        for step in plan {
            guard status(id) == .running, !cancel.isCancelled() else { throw TermoakError.Cancelled(message: "") }
            try await fileSystem.download(step.remote, to: step.local,
                                          progress: BatchListener(base: base, total: total, inner: listener), cancel: cancel)
            base += step.size
        }
        let urls = try tops.map { $0.file.kind == .dir ? try FileBrowser.zip($0.local) : $0.local }
        guard status(id) == .running else { throw TermoakError.Cancelled(message: "") }
        downloaded = DownloadedFile(urls: urls, purpose: purpose)
    }

    /// One file to download of a batch.
    private struct DownloadStep {
        let remote: String
        let local: URL
        let size: UInt64
    }

    /// The files inside a remote folder (and its folders), with where each
    /// one goes; empty folders are created here. Links and special files are
    /// left out.
    private static func walk(_ fs: RemoteFileSystem, _ remote: String, into local: URL, plan: inout [DownloadStep],
                             cancel: TransferHandle) async throws {
        if cancel.isCancelled() { throw TermoakError.Cancelled(message: "") }
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        for e in try await fs.list(remote) where e.name != "." && e.name != ".." {
            let target = local.appendingPathComponent(RemotePaths.uploadName(e.name), isDirectory: e.kind == .dir)
            switch e.kind {
            case .dir: try await walk(fs, e.path, into: target, plan: &plan, cancel: cancel)
            case .file: plan.append(DownloadStep(remote: e.path, local: target, size: e.size))
            default: continue
            }
        }
    }

    /// A folder as a .zip next to it (iOS zips it for "uploading" a folder).
    private static func zip(_ folder: URL) throws -> URL {
        let target = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".zip")
        var coordination: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordination) { zipped in
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: zipped, to: target)
            } catch {
                failure = error
            }
        }
        if let e = coordination ?? failure { throw e }
        return target
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
            // A cancelled upload leaves what was written on the host: a new
            // file is removed then (one being replaced is already cut).
            let isNew = !taken.contains(name)
            taken.insert(name)
            let remote = RemotePaths.child(request.folder.isEmpty ? "/" : request.folder, name)
            add(Transfer(name: name, uploading: true)) { [weak self] listener, cancel in
                let access = local.startAccessingSecurityScopedResource()
                defer { if access { local.stopAccessingSecurityScopedResource() } }
                do {
                    try await fileSystem.upload(local, to: remote, progress: listener, cancel: cancel)
                } catch {
                    if isNew && FileBrowser.isCancelled(error) {
                        try? await fileSystem.delete(remote, recursive: false)
                    }
                    if let self, self.path == request.folder { await self.reload() }
                    throw error
                }
                if let self, self.path == request.folder { await self.reload() }
            }
        }
    }

    /// Cancels a waiting or running transfer: a running one is stopped in
    /// the engine too (its `TransferHandle`), so it ends at once.
    func cancel(_ id: UUID) {
        guard let i = transfers.firstIndex(where: { $0.id == id }), transfers[i].cancel() else { return }
        handles.removeValue(forKey: id)?.cancel()
        jobs[id]?.cancel()
        jobs[id] = nil
        release(id)
    }

    /// Cancels every waiting and running transfer.
    func cancelAll() {
        for t in transfers where t.active { cancel(t.id) }
    }

    var activeTransfers: Int { Transfer.activeCount(transfers) }

    func retry(_ id: UUID) {
        guard let run = retries[id], let i = transfers.firstIndex(where: { $0.id == id }), transfers[i].retry() else { return }
        run()
    }

    /// The engine's `Cancelled` (a `TransferHandle` was cancelled).
    nonisolated static func isCancelled(_ error: Error) -> Bool {
        if case TermoakError.Cancelled = error { return true }
        return false
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

    private func add(_ t: Transfer, _ action: @escaping (TransferListener, TransferHandle) async throws -> Void) {
        transfers.append(t)
        let run = { [weak self] in self?.start(t.id, action) }
        retries[t.id] = { run() }
        run()
    }

    /// Runs a transfer in its turn, with progress, and leaves it done,
    /// failed or cancelled.
    private func start(_ id: UUID, _ action: @escaping (TransferListener, TransferHandle) async throws -> Void) {
        let attempt = (attempts[id] ?? 0) + 1
        attempts[id] = attempt
        let handle = TransferHandle()
        handles[id] = handle
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
                try await action(listener, handle)
                guard current() else { return }
                self.set(id) { $0.finish(error: nil, cancelled: false) }
                self.handles[id] = nil
                self.retries[id] = nil
                self.release(id)
                // Done ones leave the list after a moment.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self.transfers.removeAll { $0.id == id && $0.status == .done }
            } catch {
                guard current() else { return }
                // Cancelled in the engine (not here): shown as cancelled, not as an error.
                let cancelled = FileBrowser.isCancelled(error) || handle.isCancelled()
                let why = userMessage(error)
                self.set(id) { $0.finish(error: why, cancelled: cancelled) }
                self.handles[id] = nil
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
