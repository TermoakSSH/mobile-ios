import TermoakKit
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
    @State private var name = ""
    @State private var preview: URL?
    @State private var sharing: URL?
    /// File highlighted with a hardware keyboard (by path).
    @State private var cursor: String?
    @ObservedObject private var keyboard = HardwareKeyboard.shared

    init(core: TermoakCore, title: String, source: FileBrowser.Source) {
        _browser = StateObject(wrappedValue: FileBrowser(core: core, title: title, source: source))
    }

    private var filtered: [RemoteFile] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? browser.visible : browser.visible.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                SearchDismisser(path: browser.path)
                FilesKeyboard(active: keyboard.connected && !covered, shortcuts: !covered,
                              onKey: handleKey, onCommand: command)
                breadcrumbs
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
                .overlay {
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
                .refreshable { await browser.reload() }
                if !browser.transfers.isEmpty { transfersBar }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "files.search_prompt")
            .navigationTitle(browser.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { uploading = true } label: { Label("files.upload", systemImage: "arrow.up.doc") }
                        Button { name = ""; newFolder = true } label: { Label("files.new_folder", systemImage: "folder.badge.plus") }
                        Divider()
                        Toggle(isOn: $browser.showHidden) { Label("files.show_hidden", systemImage: "eye") }
                        Button { UIPasteboard.general.string = browser.path } label: { Label("common.copy_path", systemImage: "doc.on.doc") }
                    } label: { Image(systemName: "plus.circle") }
                    .disabled(browser.fileSystem == nil)
                    .accessibilityLabel("files.actions")
                }
            }
        }
        .navigationViewStyle(.stack)
        .task { await browser.open() }
        // The search belongs to the folder: it is cleared when the folder changes.
        .onChange(of: browser.path) { _ in
            search = ""
            cursor = nil
        }
        .onDisappear { browser.close() }
        .sheet(item: $browser.prompt) { p in AuthPromptView(prompt: p) { browser.prompt = nil }.interactiveDismissDisabled() }
        .fileImporter(isPresented: $uploading, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            guard case .success(let urls) = r else { return }
            Task { for u in urls { await browser.upload(u) } }
        }
        .sheet(item: Binding(get: { preview.map(IdentifiableURL.init) }, set: { preview = $0?.url })) { u in
            QuickLookPreview(url: u.url) { preview = nil }.ignoresSafeArea()
        }
        .sheet(item: Binding(get: { sharing.map(IdentifiableURL.init) }, set: { sharing = $0?.url })) { u in
            ShareSheet(url: u.url)
        }
        .alert("files.new_folder", isPresented: $newFolder) {
            TextField("common.name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("common.cancel", role: .cancel) {}
            Button("files.create") { let n = name; Task { await browser.createFolder(n) } }
        }
        .alert("common.rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("common.name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("common.cancel", role: .cancel) {}
            Button("common.rename") {
                if let f = renaming { let n = name; Task { await browser.rename(f, to: n) } }
            }
        }
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
        .sheet(item: Binding(get: { changingPermissions.map(IdentifiableFile.init) }, set: { changingPermissions = $0?.file })) { e in
            PermissionsEditor(file: e.file) { mode in Task { await browser.setPermissions(e.file, mode: mode) } }
        }
        .alert("common.error", isPresented: Binding(get: { browser.error != nil }, set: { if !$0 { browser.error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: { Text(browser.error ?? "") }
    }

    // MARK: Hardware keyboard

    /// A sheet, alert or preview covers the list.
    private var covered: Bool {
        uploading || newFolder || renaming != nil || deleting != nil || changingPermissions != nil
            || preview != nil || sharing != nil || browser.prompt != nil || browser.error != nil
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
            Task { preview = await browser.download(f) }
        case .delete:
            guard let f = highlighted else { return false }
            deleting = f
        case .escape:
            dismiss()
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

    private func row(_ f: RemoteFile) -> some View {
        Button { open(f) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon(f))
                    .font(.title3)
                    .foregroundColor(f.kind == .dir ? Brand.blue : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.name).lineLimit(1).foregroundColor(.primary)
                    Text(detail(f)).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if f.kind == .dir { Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary) }
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
                Button { Task { preview = await browser.download(f) } } label: { Label("files.view", systemImage: "eye") }
                Button { Task { sharing = await browser.download(f) } } label: {
                    Label("files.share", systemImage: "square.and.arrow.up")
                }
            }
            Button { name = f.name; renaming = f } label: { Label("common.rename", systemImage: "pencil") }
            if browser.canChmod {
                Button { changingPermissions = f } label: { Label("common.permissions", systemImage: "lock") }
            }
            Button { UIPasteboard.general.string = f.path } label: { Label("common.copy_path", systemImage: "doc.on.doc") }
            Button(role: .destructive) { deleting = f } label: { Label("common.delete", systemImage: "trash") }
        }
    }

    private func open(_ f: RemoteFile) {
        switch f.kind {
        case .dir, .symlink:
            // A link may point to a folder: try to enter it.
            Task {
                await browser.go(to: f.path)
                if f.kind == .symlink, browser.path != f.path { preview = await browser.download(f) }
            }
        default:
            Task { preview = await browser.download(f) }
        }
    }

    private var transfersBar: some View {
        VStack(spacing: 6) {
            ForEach(browser.transfers) { t in
                HStack(spacing: 10) {
                    Image(systemName: t.uploading ? "arrow.up.circle" : "arrow.down.circle").foregroundColor(Brand.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.name).font(.caption).lineLimit(1)
                        if let fr = t.fraction { ProgressView(value: fr) } else { ProgressView().progressViewStyle(.linear) }
                    }
                    Text(ByteCountFormatter.string(fromByteCount: Int64(t.done), countStyle: .file))
                        .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(.bar)
    }

    private func icon(_ f: RemoteFile) -> String {
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
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Unix permissions with checkboxes (owner, group, others) and in octal.
private struct PermissionsEditor: View {
    let file: RemoteFile
    let save: (UInt32) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: UInt32 = 0o644

    private var classes: [(String, Int)] {
        [(String(localized: "files.perm.owner"), 6), (String(localized: "files.perm.group"), 3), (String(localized: "files.perm.others"), 0)]
    }
    private var rights: [(String, UInt32)] {
        [(String(localized: "files.perm.read"), 4), (String(localized: "files.perm.write"), 2), (String(localized: "files.perm.execute"), 1)]
    }

    var body: some View {
        NavigationView {
            Form {
                ForEach(classes, id: \.0) { name, shift in
                    Section(name) {
                        ForEach(rights, id: \.0) { right, bit in
                            let mask = bit << UInt32(shift)
                            Toggle(right, isOn: Binding(
                                get: { mode & mask != 0 },
                                set: { mode = $0 ? mode | mask : mode & ~mask }
                            ))
                        }
                    }
                }
                Section {
                    HStack {
                        Text("files.perm.octal")
                        Spacer()
                        Text(String(mode, radix: 8)).font(.body.monospacedDigit()).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) { Button("common.save") { save(mode); dismiss() } }
            }
        }
        .onAppear { mode = (file.mode ?? 0o644) & 0o777 }
    }
}
