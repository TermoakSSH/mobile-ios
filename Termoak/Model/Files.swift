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

    init(core: TermoakCore, hostId: String) {
        self.core = core
        self.hostId = hostId
    }

    var canChmod: Bool { false }
    func home() async throws -> String { try await core.serverSftpHome(hostId: hostId) }
    func list(_ path: String) async throws -> [RemoteFile] { try await core.serverSftpList(hostId: hostId, path: path) }
    func download(_ remote: String, to local: URL, progress: TransferListener) async throws {
        _ = try await core.serverSftpDownload(hostId: hostId, remotePath: remote, localPath: local.path, listener: progress)
    }
    func upload(_ local: URL, to remote: String, progress: TransferListener) async throws {
        _ = try await core.serverSftpUpload(hostId: hostId, localPath: local.path, remotePath: remote, listener: progress)
    }
    func createFolder(_ path: String) async throws { try await core.serverSftpMkdir(hostId: hostId, path: path, parents: false) }
    func rename(_ from: String, to: String) async throws { try await core.serverSftpRename(hostId: hostId, from: from, to: to) }
    func delete(_ path: String, recursive: Bool) async throws { try await core.serverSftpDelete(hostId: hostId, path: path, recursive: recursive) }
    func setPermissions(_ path: String, mode: UInt32) async throws {
        throw TermoakError.Invalid(message: String(localized: "files.error.chmod_ssh_only"))
    }
    func close() {}
}

/// An upload or download in progress.
struct Transfer: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let uploading: Bool
    var done: UInt64 = 0
    var total: UInt64?

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }
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
        case connect(hostId: String)
        /// SFTP from the server.
        case server(hostId: String)
    }

    let title: String
    @Published private(set) var path = ""
    @Published private(set) var entries: [RemoteFile] = []
    @Published private(set) var loading = true
    @Published var error: String?
    @Published private(set) var transfers: [Transfer] = []
    @Published var prompt: AuthPrompt?
    @Published var showHidden = UserDefaults.standard.bool(forKey: "sftp_ocultos") {
        didSet { UserDefaults.standard.set(showHidden, forKey: "sftp_ocultos") }
    }

    private let core: TermoakCore
    private let source: Source
    private(set) var fileSystem: RemoteFileSystem?

    init(core: TermoakCore, title: String, source: Source) {
        self.core = core
        self.title = title
        self.source = source
    }

    var canChmod: Bool { fileSystem?.canChmod ?? false }

    var visible: [RemoteFile] {
        showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
    }

    func open() async {
        guard fileSystem == nil else { return }
        loading = true
        do {
            switch source {
            case .session(let s):
                fileSystem = SshFileSystem(session: s, own: false)
            case .server(let hostId):
                fileSystem = ServerFileSystem(core: core, hostId: hostId)
            case .connect(let hostId):
                let auth = AuthBridge { [weak self] p in
                    Task { @MainActor in self?.prompt = p }
                }
                fileSystem = SshFileSystem(session: try await core.connect(hostId: hostId, auth: auth), own: true)
            }
            let home = try await fileSystem!.home()
            await go(to: home)
        } catch {
            loading = false
            self.error = errorMessage(error)
        }
    }

    func close() {
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
            self.error = errorMessage(error)
        }
    }

    func reload() async { await go(to: path) }

    func goUp() async {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        await go(to: parent.isEmpty ? "/" : parent)
    }

    /// Path of a name inside the current folder.
    func inside(_ name: String) -> String {
        path == "/" ? "/\(name)" : "\(path)/\(name)"
    }

    func createFolder(_ name: String) async {
        await perform { try await $0.createFolder(self.inside(name)) }
    }

    func rename(_ f: RemoteFile, to name: String) async {
        await perform { try await $0.rename(f.path, to: self.inside(name)) }
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
            self.error = errorMessage(error)
        }
        await reload()
    }

    /// Downloads to a temporary folder (to view or share it).
    func download(_ f: RemoteFile) async -> URL? {
        guard let fileSystem else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(f.name)
        do {
            try await transfer(f.name, uploading: false) { p in try await fileSystem.download(f.path, to: target, progress: p) }
            return target
        } catch {
            self.error = errorMessage(error)
            return nil
        }
    }

    /// Uploads a file picked in Files to the current folder.
    func upload(_ local: URL) async {
        guard let fileSystem else { return }
        let access = local.startAccessingSecurityScopedResource()
        defer { if access { local.stopAccessingSecurityScopedResource() } }
        let remote = inside(local.lastPathComponent)
        do {
            try await transfer(local.lastPathComponent, uploading: true) { p in try await fileSystem.upload(local, to: remote, progress: p) }
        } catch {
            self.error = errorMessage(error)
        }
        await reload()
    }

    private func transfer(_ name: String, uploading: Bool, _ action: (TransferListener) async throws -> Void) async throws {
        let t = Transfer(name: name, uploading: uploading)
        transfers.append(t)
        defer { transfers.removeAll { $0.id == t.id } }
        let progress = ProgressRelay { [weak self] done, total in
            Task { @MainActor in
                guard let self, let i = self.transfers.firstIndex(where: { $0.id == t.id }) else { return }
                self.transfers[i].done = done
                self.transfers[i].total = total
            }
        }
        try await action(progress)
    }
}
