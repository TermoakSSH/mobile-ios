import TermoakKit
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Remote file browser (SFTP): browse, view, share or save to Files, upload,
/// create folders, rename, delete and change permissions.
struct FilesScreen: View {
    @StateObject private var browser: FileBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var uploading = false
    @State private var newFolder = false
    @State private var renaming: RemoteFile?
    @State private var deleting: RemoteFile?
    @State private var changingPermissions: RemoteFile?
    @State private var showingInfo: RemoteFile?
    @State private var newFile = false
    @State private var goingTo = false
    @State private var moving: RemoteFile?
    /// The folder typed in "Go to" or "Move to".
    @State private var typedPath = ""
    @State private var editingText: EditedText?
    @State private var pickingPhotos = false
    @State private var name = ""
    @State private var preview: URL?
    @State private var sharing: [URL]?
    @State private var saving: [URL]?
    /// Choosing several files (by path) to share, save, move or delete them.
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var deletingSelection = false
    @State private var movingSelection = false
    /// File highlighted with a hardware keyboard (by path).
    @State private var cursor: String?
    @ObservedObject private var keyboard = HardwareKeyboard.shared

    init(core: TermoakCore, title: String, source: FileBrowser.Source) {
        _browser = StateObject(wrappedValue: FileBrowser(core: core, title: title, source: source))
    }

    private var filtered: [RemoteFile] { browser.arranged(query: search) }

    var body: some View {
        // Split in parts: as one expression it is too much for the type checker.
        withAlerts(withDialogs(withSheets(navigation)))
            .task { await browser.open() }
            // The search belongs to the folder: it is cleared when the folder changes.
            .onChange(of: browser.path) { _ in
                search = ""
                cursor = nil
                selected = []
            }
            .onChange(of: browser.downloaded) { file in
                guard let file else { return }
                browser.downloaded = nil
                switch file.purpose {
                case .preview: preview = file.url
                case .share: sharing = file.urls
                case .save: saving = file.urls
                }
            }
            .onDisappear { browser.close() }
    }

    private var navigation: some View {
        NavigationView {
            VStack(spacing: 0) {
                SearchDismisser(path: browser.path)
                FilesKeyboard(active: keyboard.connected && !covered, shortcuts: !covered,
                              onKey: handleKey, onCommand: command)
                breadcrumbs
                fileList
                if !browser.transfers.isEmpty { transfersBar }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "files.search_prompt")
            .navigationTitle(browser.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if selecting {
                    ToolbarItem(placement: .cancellationAction) { Button(selectAllTitle) { toggleSelectAll() } }
                    ToolbarItem(placement: .confirmationAction) { Button("common.done") { endSelection() } }
                    ToolbarItemGroup(placement: .bottomBar) { selectionActions }
                } else {
                    ToolbarItem(placement: .cancellationAction) { Button("common.close") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { actionsMenu }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var fileList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(filtered, id: \.path) { f in
                    row(f)
                        .listRowBackground(keyboardHighlight(cursor == f.path))
                        .id(f.path)
                }
            }
            .onChange(of: cursor) { path in
                if let path { withAnimation { proxy.scrollTo(path) } }
            }
        }
        .listStyle(.plain)
        .overlay { listOverlay }
        .refreshable { await browser.reload() }
    }

    @ViewBuilder private var listOverlay: some View {
        if browser.loading && browser.entries.isEmpty {
            ProgressView()
        } else if !browser.loading && filtered.isEmpty {
            Group {
                if search.isEmpty {
                    Text("files.empty_folder")
                } else {
                    Text("files.no_match \(search)")
                }
            }
            .foregroundColor(.secondary)
        }
    }

    /// "+": upload, new folder, the order, hidden files and the path.
    private var actionsMenu: some View {
        Menu {
            Button { uploading = true } label: { Label("files.upload", systemImage: "arrow.up.doc") }
            Button { pickingPhotos = true } label: { Label("files.upload_photos", systemImage: "photo.on.rectangle") }
            Button { name = ""; newFolder = true } label: { Label("files.new_folder", systemImage: "folder.badge.plus") }
            if browser.canEdit {
                Button { name = ""; newFile = true } label: { Label("files.new_file", systemImage: "doc.badge.plus") }
            }
            Button { typedPath = browser.path; goingTo = true } label: { Label("files.go_to", systemImage: "arrow.right.circle") }
            Button { startSelection(nil) } label: { Label("files.select", systemImage: "checkmark.circle") }
            Divider()
            sortMenu
            Toggle(isOn: $browser.showHidden) { Label("files.show_hidden", systemImage: "eye") }
            Button { UIPasteboard.general.string = browser.path } label: { Label("common.copy_path", systemImage: "doc.on.doc") }
        } label: { Image(systemName: "plus.circle") }
        .disabled(browser.fileSystem == nil)
        .accessibilityLabel("files.actions")
    }

    /// By name, size or date; the chosen one again turns the order around.
    private var sortMenu: some View {
        Menu {
            ForEach(FileSort.allCases, id: \.self) { by in
                Button { browser.setSort(by) } label: {
                    if browser.sort == by {
                        Label(sortTitle(by), systemImage: browser.descending ? "chevron.down" : "chevron.up")
                    } else {
                        Text(sortTitle(by))
                    }
                }
            }
        } label: {
            Label("files.sort", systemImage: "arrow.up.arrow.down")
        }
    }

    private func sortTitle(_ by: FileSort) -> String {
        switch by {
        case .name: return String(localized: "files.sort.name")
        case .size: return String(localized: "files.sort.size")
        case .date: return String(localized: "files.sort.date")
        }
    }

    private func withSheets<V: View>(_ view: V) -> some View {
        view
            .sheet(item: $browser.prompt) { p in AuthPromptView(prompt: p) { browser.prompt = nil }.interactiveDismissDisabled() }
            .fileImporter(isPresented: $uploading, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                guard case .success(let urls) = r else { return }
                browser.pickedForUpload(urls)
            }
            .sheet(item: Binding(get: { preview.map(IdentifiableURL.init) }, set: { preview = $0?.url })) { u in
                QuickLookPreview(url: u.url) { preview = nil }.ignoresSafeArea()
            }
            .sheet(item: Binding(get: { sharing.map(IdentifiableURLs.init) }, set: { sharing = $0?.urls })) { u in
                ShareSheet(urls: u.urls)
            }
            .sheet(item: Binding(get: { saving.map(IdentifiableURLs.init) }, set: { saving = $0?.urls })) { u in
                SaveToFiles(urls: u.urls) { saving = nil }.ignoresSafeArea()
            }
            .sheet(item: Binding(get: { changingPermissions.map(IdentifiableFile.init) }, set: { changingPermissions = $0?.file })) { e in
                PermissionsEditor(file: e.file) { mode in Task { await browser.setPermissions(e.file, mode: mode) } }
            }
            .sheet(item: Binding(get: { showingInfo.map(IdentifiableFile.init) }, set: { showingInfo = $0?.file })) { e in
                FileInfoView(file: e.file)
            }
            .sheet(item: $editingText) { e in
                TextFileEditor(file: e) { text in try await browser.saveText(text, to: e.path) }
            }
            .sheet(isPresented: $pickingPhotos) {
                PhotoPicker { urls in browser.pickedForUpload(urls) }.ignoresSafeArea()
            }
    }

    private func withDialogs<V: View>(_ view: V) -> some View {
        view
            .confirmationDialog(Text("files.delete.title \(deleting?.name ?? "")"),
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("common.delete", role: .destructive) { if let f = deleting { Task { await browser.delete(f) } } }
            } message: {
                if deleting?.kind == .dir {
                    Text("files.delete.folder_message")
                } else {
                    Text("files.delete.file_message")
                }
            }
            .confirmationDialog(Text("files.delete_selection.title \(selectedFiles.count)"), isPresented: $deletingSelection,
                                titleVisibility: .visible) {
                Button("common.delete", role: .destructive) {
                    let files = selectedFiles
                    endSelection()
                    Task { await browser.delete(files) }
                }
            } message: {
                Text("files.delete_selection.message")
            }
            // Some picked files already exist in the folder.
            .confirmationDialog(Text("files.replace.title \(browser.uploadAsk?.conflicts.count ?? 0)"),
                                isPresented: Binding(get: { browser.uploadAsk != nil }, set: { if !$0 { browser.uploadAsk = nil } }),
                                titleVisibility: .visible) {
                Button("files.replace", role: .destructive) { if let r = browser.uploadAsk { browser.upload(r, replace: true) } }
                Button("files.keep_both") { if let r = browser.uploadAsk { browser.upload(r, replace: false) } }
                Button("common.cancel", role: .cancel) { browser.uploadAsk = nil }
            } message: {
                Text(uploadConflictMessage)
            }
    }

    /// The names that exist ("a.txt, b.txt") and the question.
    private var uploadConflictMessage: String {
        let names = browser.uploadAsk?.conflicts ?? []
        let shown = names.prefix(5).joined(separator: ", ") + (names.count > 5 ? ", …" : "")
        return shown + "\n\n" + String(localized: "files.replace.message")
    }

    private func withAlerts<V: View>(_ view: V) -> some View {
        view
            .textPrompt(Text("files.new_folder"), isPresented: $newFolder, text: $name,
                        placeholder: String(localized: "common.name"), confirm: String(localized: "files.create"),
                        invalid: RemotePaths.invalidName) {
                let n = name
                Task { await browser.createFolder(n) }
            }
            .textPrompt(Text("common.rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                        text: $name, placeholder: String(localized: "common.name"), confirm: String(localized: "common.rename"),
                        invalid: RemotePaths.invalidName) {
                if let f = renaming { let n = name; Task { await browser.rename(f, to: n) } }
            }
            .textPrompt(Text("files.new_file"), isPresented: $newFile, text: $name,
                        placeholder: String(localized: "common.name"), confirm: String(localized: "files.create"),
                        invalid: RemotePaths.invalidName) {
                let n = name
                Task { await browser.createFile(n) }
            }
            .textPrompt(Text("files.go_to"), isPresented: $goingTo, text: $typedPath,
                        placeholder: String(localized: "files.path_placeholder"), message: Text("files.go_to.message"),
                        confirm: String(localized: "common.open")) {
                let p = typedPath
                Task { await browser.goTo(typed: p) }
            }
            .textPrompt(Text("files.move_selection.title \(selectedFiles.count)"), isPresented: $movingSelection, text: $typedPath,
                        placeholder: String(localized: "files.path_placeholder"), message: Text("files.move.message"),
                        confirm: String(localized: "files.move")) {
                let files = selectedFiles
                let p = typedPath
                endSelection()
                Task { await browser.move(files, toFolder: p) }
            }
            .textPrompt(Text("files.move.title \(moving?.name ?? "")"),
                        isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } }), text: $typedPath,
                        placeholder: String(localized: "files.path_placeholder"), message: Text("files.move.message"),
                        confirm: String(localized: "files.move")) {
                if let f = moving { let p = typedPath; Task { await browser.move(f, toFolder: p) } }
            }
            .alert("common.error", isPresented: Binding(get: { browser.error != nil }, set: { if !$0 { browser.error = nil } })) {
                Button("common.ok", role: .cancel) {}
            } message: { Text(browser.error ?? "") }
    }

    // MARK: Hardware keyboard

    /// A sheet, alert or preview covers the list.
    private var covered: Bool {
        let shown: [Bool] = [
            uploading, newFolder, renaming != nil, deleting != nil, changingPermissions != nil, showingInfo != nil,
            preview != nil, sharing != nil, saving != nil, browser.prompt != nil, browser.error != nil,
            browser.uploadAsk != nil, newFile, goingTo, moving != nil, editingText != nil, pickingPhotos,
            selecting, deletingSelection, movingSelection,
        ]
        return shown.contains(true)
    }

    private var highlighted: RemoteFile? { filtered.first { $0.path == cursor } }

    /// ↑/↓ choose, Return or → opens (a folder goes in), ← goes up, Space
    /// previews (Quick Look), Delete deletes after asking, Esc closes.
    private func handleKey(_ key: NavKey, _ modifiers: ModifierKeys) -> Bool {
        switch key {
        case .up, .down, .home, .end, .pageUp, .pageDown:
            cursor = moveHighlight(cursor, in: filtered.map(\.path), key)
        case .enter, .right:
            guard let f = highlighted else { return false }
            open(f)
        case .left:
            guard browser.path != "/" && !browser.path.isEmpty else { return false }
            Task { await browser.goUp() }
        case .space:
            guard let f = highlighted, f.kind != .dir else { return false }
            browser.download(f, for: .preview)
        case .delete:
            guard let f = highlighted else { return false }
            deleting = f
        case .escape:
            dismiss()
        case .menu, .f10:
            return false
        }
        return true
    }

    private func command(_ c: FilesKeyboard.Command) {
        switch c {
        case .refresh: Task { await browser.reload() }
        case .up: Task { await browser.goUp() }
        case .newFolder:
            guard browser.fileSystem != nil else { return }
            name = ""
            newFolder = true
        case .upload:
            guard browser.fileSystem != nil else { return }
            uploading = true
        case .hidden: browser.showHidden.toggle()
        case .close: dismiss()
        }
    }

    /// Current path: one button per folder to jump to it.
    private var breadcrumbs: some View {
        let parts = browser.path.split(separator: "/").map(String.init)
        return HStack(spacing: 4) {
            Button { Task { await browser.goUp() } } label: { Image(systemName: "arrow.up").frame(width: 32, height: 30) }
                .disabled(browser.path == "/" || browser.path.isEmpty)
                .accessibilityLabel("files.parent_folder")
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        Button { Task { await browser.go(to: "/") } } label: { Text(verbatim: "/") }
                            .accessibilityIdentifier("sftp-root")
                        ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                            Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                            Button(p) { Task { await browser.go(to: "/" + parts[0...i].joined(separator: "/")) } }
                                .id(i)
                        }
                    }
                    .font(.subheadline)
                    .padding(.trailing, 8)
                }
                .onChange(of: browser.path) { _ in reader.scrollTo(parts.count - 1, anchor: .trailing) }
            }
            if browser.loading { ProgressView().scaleEffect(0.7) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: Selection

    /// The chosen files, in the order of the list.
    private var selectedFiles: [RemoteFile] { filtered.filter { selected.contains($0.path) } }

    private var selectAllTitle: String {
        !filtered.isEmpty && selected.count == filtered.count ? String(localized: "hosts.select.none") : String(localized: "hosts.select.all")
    }

    private func toggleSelectAll() {
        selected = selected.count == filtered.count ? [] : Set(filtered.map(\.path))
    }

    private func startSelection(_ f: RemoteFile?) {
        selected = f.map { [$0.path] } ?? []
        withAnimation { selecting = true }
    }

    private func endSelection() {
        withAnimation { selecting = false }
        selected = []
    }

    private func toggle(_ f: RemoteFile) {
        if selected.contains(f.path) { selected.remove(f.path) } else { selected.insert(f.path) }
    }

    /// Bottom bar while selecting: share or save them (folders as .zip),
    /// move them, delete them.
    @ViewBuilder private var selectionActions: some View {
        let none = selected.isEmpty
        Button { browser.downloadMany(selectedFiles, for: .share); endSelection() } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(none)
        .accessibilityLabel(Text("files.share"))
        Spacer()
        Button { browser.downloadMany(selectedFiles, for: .save); endSelection() } label: {
            Image(systemName: "folder")
        }
        .disabled(none)
        .accessibilityLabel(Text("files.save_to_files"))
        Spacer()
        Button { typedPath = browser.path; movingSelection = true } label: { Image(systemName: "arrow.right.square") }
            .disabled(none)
            .accessibilityLabel(Text("files.move_to"))
        Spacer()
        Text("files.selected \(selected.count)").font(.footnote).foregroundColor(.secondary)
        Spacer()
        Button(role: .destructive) { deletingSelection = true } label: { Image(systemName: "trash") }
            .disabled(none)
            .accessibilityLabel(Text("common.delete"))
    }

    private func row(_ f: RemoteFile) -> some View {
        Button { if selecting { toggle(f) } else { open(f) } } label: {
            HStack(spacing: 12) {
                if selecting {
                    Image(systemName: selected.contains(f.path) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(selected.contains(f.path) ? .accentColor : .secondary)
                }
                Image(systemName: icon(f))
                    .font(.title3)
                    .foregroundColor(f.kind == .dir ? Brand.blue : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.name).lineLimit(1).foregroundColor(.primary)
                    Text(detail(f)).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if f.kind == .dir && !selecting { Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sftp-\(f.name)")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleting = f } label: { Label("common.delete", systemImage: "trash") }
            Button { name = f.name; renaming = f } label: { Label("common.rename", systemImage: "pencil") }.tint(.orange)
        }
        .contextMenu {
            if f.kind != .dir {
                Button { browser.download(f, for: .preview) } label: { Label("files.view", systemImage: "eye") }
                Button { browser.download(f, for: .share) } label: {
                    Label("files.share", systemImage: "square.and.arrow.up")
                }
                Button { browser.download(f, for: .save) } label: {
                    Label("files.save_to_files", systemImage: "folder")
                }
            }
            if f.kind == .dir {
                Button { browser.downloadMany([f], for: .share) } label: {
                    Label("files.share_zip", systemImage: "square.and.arrow.up")
                }
                Button { browser.downloadMany([f], for: .save) } label: {
                    Label("files.save_zip", systemImage: "folder")
                }
            }
            Button { startSelection(f) } label: { Label("files.select", systemImage: "checkmark.circle") }
            if f.kind == .file && browser.canEdit {
                Button { edit(f) } label: { Label("files.edit", systemImage: "square.and.pencil") }
            }
            Button { showingInfo = f } label: { Label("files.info", systemImage: "info.circle") }
            Button { name = f.name; renaming = f } label: { Label("common.rename", systemImage: "pencil") }
            Button { typedPath = browser.path; moving = f } label: { Label("files.move_to", systemImage: "folder") }
            if browser.canChmod {
                Button { changingPermissions = f } label: { Label("common.permissions", systemImage: "lock") }
            }
            Button { UIPasteboard.general.string = f.path } label: { Label("common.copy_path", systemImage: "doc.on.doc") }
            Button(role: .destructive) { deleting = f } label: { Label("common.delete", systemImage: "trash") }
        }
    }

    /// Opens a text file in the editor (read whole, up to 1 MiB).
    private func edit(_ f: RemoteFile) {
        Task {
            if let text = await browser.readText(f) {
                editingText = EditedText(path: f.path, name: f.name, text: text)
            }
        }
    }

    private func open(_ f: RemoteFile) {
        switch f.kind {
        case .dir, .symlink:
            // A link may point to a folder: try to enter it.
            Task {
                await browser.go(to: f.path)
                if f.kind == .symlink, browser.path != f.path { browser.download(f, for: .preview) }
            }
        default:
            browser.download(f, for: .preview)
        }
    }

    /// The transfers: progress, and Cancel while they wait or run (Cancel
    /// all with several); Retry and Remove once they failed or were cancelled.
    private var transfersBar: some View {
        ScrollView {
            VStack(spacing: 6) {
                if browser.activeTransfers >= 2 { cancelAllRow }
                ForEach(browser.transfers) { t in
                    TransferRow(transfer: t,
                                onCancel: { browser.cancel(t.id) },
                                onRetry: { browser.retry(t.id) },
                                onDismiss: { browser.dismiss(t.id) })
                }
            }
            .padding(10)
        }
        .frame(maxHeight: 170)
        .fixedSize(horizontal: false, vertical: true)
        .background(.bar)
    }

    private var cancelAllRow: some View {
        HStack {
            Text("files.transfer.active \(browser.activeTransfers)").font(.caption).foregroundColor(.secondary)
            Spacer(minLength: 0)
            Button("files.transfer.cancel_all", role: .destructive) { browser.cancelAll() }
                .font(.caption)
                .buttonStyle(.borderless)
        }
    }

    private func icon(_ f: RemoteFile) -> String { fileIcon(f) }

    private func detail(_ f: RemoteFile) -> String {
        var parts: [String] = []
        if f.kind == .file { parts.append(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file)) }
        if let m = f.modified {
            parts.append(Date(timeIntervalSince1970: TimeInterval(m)).formatted(date: .abbreviated, time: .shortened))
        }
        if !f.modeString.isEmpty { parts.append(f.modeString) }
        return parts.joined(separator: " · ")
    }
}

/// SF Symbol of a file by its kind and extension.
func fileIcon(_ f: RemoteFile) -> String {
    switch f.kind {
    case .dir: return "folder.fill"
    case .symlink: return "arrow.triangle.turn.up.right.diamond"
    case .other: return "questionmark.square"
    case .file:
        switch (f.name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tgz", "xz", "bz2", "tar", "7z": return "doc.zipper"
        case "sh", "py", "rb", "js", "ts", "go", "rs", "c", "h", "swift", "kt", "java", "php": return "chevron.left.forwardslash.chevron.right"
        case "log", "txt", "md", "conf", "cfg", "ini", "yml", "yaml", "json", "toml", "xml", "env": return "doc.text"
        default: return "doc"
        }
    }
}

/// Hardware keyboard in the files: the keys of `KeyCatcher` (not while
/// searching: it is inside `.searchable`) and the ⌘ shortcuts.
struct FilesKeyboard: View {
    enum Command { case refresh, up, newFolder, upload, hidden, close }

    let active: Bool
    let shortcuts: Bool
    let onKey: (NavKey, ModifierKeys) -> Bool
    let onCommand: (Command) -> Void
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        ZStack {
            KeyCatcher(active: active && !isSearching, onKey: onKey)
                .frame(width: 0, height: 0)
            if shortcuts {
                ShortcutLayer {
                    ShortcutButton(title: String(localized: "files.shortcut.refresh"), key: "r") { onCommand(.refresh) }
                    ShortcutButton(title: String(localized: "files.parent_folder"), key: .upArrow) { onCommand(.up) }
                    ShortcutButton(title: String(localized: "files.new_folder"), key: "n", modifiers: [.command, .shift]) {
                        onCommand(.newFolder)
                    }
                    ShortcutButton(title: String(localized: "files.upload"), key: "u") { onCommand(.upload) }
                    ShortcutButton(title: String(localized: "files.show_hidden"), key: ".", modifiers: [.command, .shift]) {
                        onCommand(.hidden)
                    }
                    ShortcutButton(title: String(localized: "common.close"), key: "w") { onCommand(.close) }
                }
            }
        }
        .frame(height: 0)
        .accessibilityHidden(true)
    }
}

/// When the folder changes the search is closed (text and keyboard). It has to
/// be inside the view with `.searchable` to be able to close it.
private struct SearchDismisser: View {
    let path: String
    @Environment(\.dismissSearch) private var dismissSearch

    var body: some View {
        Color.clear.frame(height: 0).onChange(of: path) { _ in dismissSearch() }
    }
}

private struct IdentifiableURLs: Identifiable {
    let urls: [URL]
    var id: String { urls.map(\.path).joined(separator: "|") }
}

private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct IdentifiableFile: Identifiable {
    let file: RemoteFile
    var id: String { file.path }
}

/// iOS preview (text, images, PDF, video...), with its share button. Inside a
/// sheet it has no close button: one is added.
private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        let button = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { _ in context.coordinator.onClose() })
        button.accessibilityIdentifier = "close-preview"
        ql.navigationItem.leftBarButtonItem = button
        return UINavigationController(rootViewController: ql)
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url, onClose: onClose) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        let onClose: () -> Void
        init(url: URL, onClose: @escaping () -> Void) {
            self.url = url
            self.onClose = onClose
        }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

/// System share sheet (includes "Save to Files").
private struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Unix permissions with checkboxes (owner, group, others, and the setuid,
/// setgid and sticky bits) and in octal, which can also be typed. The bits
/// the file has are kept: only what you change changes.
private struct PermissionsEditor: View {
    let file: RemoteFile
    let save: (UInt32) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: UInt32 = 0o644
    @State private var octal = "644"

    private var classes: [(String, Int)] {
        [(String(localized: "files.perm.owner"), 6), (String(localized: "files.perm.group"), 3), (String(localized: "files.perm.others"), 0)]
    }
    private var rights: [(String, UInt32)] {
        [(String(localized: "files.perm.read"), 4), (String(localized: "files.perm.write"), 2), (String(localized: "files.perm.execute"), 1)]
    }
    private var specials: [(String, UInt32)] {
        [(String(localized: "files.perm.setuid"), 0o4000), (String(localized: "files.perm.setgid"), 0o2000),
         (String(localized: "files.perm.sticky"), 0o1000)]
    }

    private var valid: Bool { RemotePaths.parseOctal(octal) != nil }

    var body: some View {
        NavigationView {
            Form {
                ForEach(classes, id: \.0) { name, shift in
                    Section(name) {
                        ForEach(rights, id: \.0) { right, bit in toggle(right, bit << UInt32(shift)) }
                    }
                }
                Section("files.perm.special") {
                    ForEach(specials, id: \.0) { title, bit in toggle(title, bit) }
                }
                Section {
                    HStack {
                        Text("files.perm.octal")
                        Spacer()
                        TextField("", text: $octal)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospacedDigit())
                            .foregroundColor(valid ? .secondary : Brand.red)
                            .frame(maxWidth: 120)
                            .accessibilityLabel(Text("files.perm.octal"))
                    }
                } footer: {
                    if !valid { Text("files.perm.octal_invalid").foregroundColor(Brand.red) }
                }
            }
            .onChange(of: octal) { text in
                if let m = RemotePaths.parseOctal(text) { mode = m }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") { save(mode); dismiss() }.disabled(!valid)
                }
            }
        }
        .onAppear {
            mode = RemotePaths.editableMode(file.mode)
            octal = RemotePaths.octal(mode)
        }
    }

    private func toggle(_ title: String, _ mask: UInt32) -> some View {
        Toggle(title, isOn: Binding(
            get: { mode & mask != 0 },
            set: { on in
                mode = on ? mode | mask : mode & ~mask
                octal = RemotePaths.octal(mode)
            }
        ))
    }
}

/// A transfer in the bar: what, how far, and what can be done with it.
private struct TransferRow: View {
    let transfer: Transfer
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transfer.uploading ? "arrow.up.circle" : "arrow.down.circle").foregroundColor(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name).font(.caption).lineLimit(1)
                if transfer.status == .running {
                    if let fr = transfer.fraction { ProgressView(value: fr) } else { ProgressView().progressViewStyle(.linear) }
                }
                Text(statusText).font(.caption2.monospacedDigit()).foregroundColor(transfer.status == .failed ? Brand.red : .secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            buttons
        }
    }

    @ViewBuilder private var buttons: some View {
        if transfer.active {
            Button(action: onCancel) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("common.cancel"))
        } else if transfer.status != .done {
            Button(action: onRetry) { Image(systemName: "arrow.clockwise.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("common.retry"))
            Button(action: onDismiss) { Image(systemName: "trash.circle").foregroundColor(.secondary) }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("files.dismiss"))
        }
    }

    private var tint: Color {
        switch transfer.status {
        case .failed: return Brand.red
        case .done: return Brand.green
        case .cancelled: return .secondary
        default: return Brand.blue
        }
    }

    private var statusText: String {
        let size = { (n: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
        switch transfer.status {
        case .waiting: return String(localized: "files.transfer.waiting")
        case .running:
            guard let total = transfer.total else { return size(transfer.done) }
            return String(localized: "files.transfer.progress \(size(transfer.done)) \(size(total))")
        case .done:
            return transfer.uploading ? String(localized: "files.transfer.uploaded") : String(localized: "files.transfer.downloaded")
        case .failed: return transfer.error ?? String(localized: "files.transfer.failed")
        case .cancelled: return String(localized: "files.transfer.cancelled")
        }
    }
}

/// Everything known about a file: kind, exact size, date, permissions in
/// both forms, owner and group, path.
private struct FileInfoView: View {
    let file: RemoteFile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: fileIcon(file)).font(.title2).foregroundColor(Brand.blue)
                        Text(file.name).font(.headline).lineLimit(2)
                    }
                }
                Section { details }
            }
            .navigationTitle("files.info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
        }
    }

    @ViewBuilder private var details: some View {
        line("files.info.kind", kindTitle)
        if file.kind != .dir {
            line("files.info.size", "\(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)) (\(file.size))")
        }
        if let m = file.modified {
            line("files.info.modified", Date(timeIntervalSince1970: TimeInterval(m)).formatted(date: .long, time: .standard))
        }
        if !file.modeString.isEmpty || file.mode != nil {
            line("common.permissions", [file.modeString, file.mode.map { RemotePaths.octal($0) } ?? ""]
                .filter { !$0.isEmpty }.joined(separator: "  "), mono: true)
        }
        if file.owner != nil || file.group != nil {
            line("files.info.owner", [file.owner, file.group].compactMap { $0 }.joined(separator: ":"))
        }
        line("files.info.path", file.path, mono: true)
    }

    private var kindTitle: String {
        switch file.kind {
        case .dir: return String(localized: "files.kind.folder")
        case .file: return String(localized: "files.kind.file")
        case .symlink: return String(localized: "files.kind.link")
        case .other: return String(localized: "files.kind.other")
        }
    }

    private func line(_ label: LocalizedStringKey, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .font(mono ? .system(.body, design: .monospaced) : .body)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

/// "Save to Files": the system's folder picker with a copy of the file.
private struct SaveToFiles: UIViewControllerRepresentable {
    let urls: [URL]
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onDone() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onDone() }
    }
}

/// A text file open in the editor.
struct EditedText: Identifiable {
    let id = UUID()
    let path: String
    let name: String
    let text: String
}

/// A plain text editor for a remote file: Save writes it whole; closing with
/// changes asks first.
private struct TextFileEditor: View {
    let file: EditedText
    let save: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var saving = false
    @State private var error: String?
    @State private var discarding = false

    private var changed: Bool { text != file.text }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let error {
                    Text(error).font(.footnote).foregroundColor(Brand.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { if changed { discarding = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: write) {
                        if saving { ProgressView() } else { Text("common.save") }
                    }
                    .disabled(!changed || saving)
                    .keyboardShortcut("s", modifiers: .command)
                }
            }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled(changed)
        .onAppear { text = file.text }
        .confirmationDialog("files.edit.discard", isPresented: $discarding, titleVisibility: .visible) {
            Button("files.edit.discard_action", role: .destructive) { dismiss() }
        }
    }

    private func write() {
        saving = true
        error = nil
        let value = text
        Task {
            defer { saving = false }
            do {
                try await save(value)
                dismiss()
            } catch {
                self.error = userMessage(error)
            }
        }
    }
}

/// Photos and videos from the library to upload (PHPicker: no permission
/// needed). Each one is copied to a temporary file with its name first.
private struct PhotoPicker: UIViewControllerRepresentable {
    let onPicked: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 0
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked, close: { dismiss() }) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([URL]) -> Void
        let close: () -> Void
        init(onPicked: @escaping ([URL]) -> Void, close: @escaping () -> Void) {
            self.onPicked = onPicked
            self.close = close
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            close()
            guard !results.isEmpty else { return }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let group = DispatchGroup()
            let lock = NSLock()
            var urls: [(Int, URL)] = []
            for (i, r) in results.enumerated() {
                let provider = r.itemProvider
                guard let type = provider.registeredTypeIdentifiers.first else { continue }
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                    defer { group.leave() }
                    // The file only exists during this call: copy it.
                    guard let url else { return }
                    let base = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
                    let ext = url.pathExtension
                    let name = RemotePaths.uploadName(ext.isEmpty ? base : "\(base).\(ext)")
                    let target = folder.appendingPathComponent("\(i)", isDirectory: true).appendingPathComponent(name)
                    try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard (try? FileManager.default.copyItem(at: url, to: target)) != nil else { return }
                    lock.lock()
                    urls.append((i, target))
                    lock.unlock()
                }
            }
            group.notify(queue: .main) { [onPicked] in
                onPicked(urls.sorted { $0.0 < $1.0 }.map(\.1))
            }
        }
    }
}
