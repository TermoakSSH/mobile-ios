import SwiftUI

/// The app's keyboard shortcuts, by section (like Android's list and the
/// desktop's Help → Keyboard shortcuts). From the terminal's menu, ⌘/ and
/// Settings; on an iPad, holding ⌘ also lists those of the screen.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// A shortcut: the keys and what they do.
    private struct Item: Identifiable {
        let keys: String
        let title: String
        var id: String { keys + title }
    }

    var body: some View {
        NavigationView {
            List {
                Section { Text("shortcuts.intro").font(.footnote).foregroundColor(.secondary) }
                section("shortcuts.section.terminal", terminal)
                section("shortcuts.section.split", split)
                section("shortcuts.section.app", app)
                section("shortcuts.section.files", files)
                section("shortcuts.section.mouse", mouse)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("shortcuts.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func section(_ title: LocalizedStringKey, _ items: [Item]) -> some View {
        Section(title) {
            ForEach(items) { item in row(item) }
        }
    }

    private func row(_ item: Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: item.title)
            Spacer(minLength: 8)
            Text(verbatim: item.keys)
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func t(_ key: String.LocalizationValue) -> String { String(localized: key) }

    private var terminal: [Item] {
        [
            Item(keys: "⌘T  ⌘K", title: t("shortcut.quick_connect")),
            Item(keys: "⌘W", title: t("shortcut.close_tab")),
            Item(keys: "⌘⇧]  ⌃⇥", title: t("shortcut.next_tab")),
            Item(keys: "⌘⇧[  ⌃⇧⇥", title: t("shortcut.previous_tab")),
            Item(keys: "⌘1 … ⌘9", title: t("shortcuts.tab_number")),
            Item(keys: "⌘C  ⌘V", title: t("shortcuts.copy_paste")),
            Item(keys: "⌘F", title: t("shortcut.find")),
            Item(keys: "⌘G  ⌘⇧G", title: t("shortcuts.find_next_previous")),
            Item(keys: "⌘+  ⌘-", title: t("shortcuts.text_size")),
            Item(keys: "⌘0", title: t("shortcut.zoom_reset")),
            Item(keys: "⌘.  ⌃[", title: t("shortcut.send_escape")),
            Item(keys: "⌘I", title: t("copilot.title")),
            Item(keys: "⌘/", title: t("shortcuts.title")),
        ]
    }

    private var split: [Item] {
        [
            Item(keys: "⌘D", title: t("split.add_pane")),
            Item(keys: "⌘⌥←↑↓→", title: t("shortcuts.split_focus")),
            Item(keys: "⌘⇧M", title: t("split.focus_mode")),
            Item(keys: "⌘B", title: t("split.broadcast")),
        ]
    }

    private var app: [Item] {
        [
            Item(keys: "⌘1  ⌘2  ⌘3", title: t("shortcuts.home_tabs")),
            Item(keys: "⌘N", title: t("common.new_host")),
            Item(keys: "⌘F", title: t("shortcuts.search_hosts")),
            Item(keys: "↑ ↓  ↩", title: t("shortcuts.lists")),
            Item(keys: "⌘,", title: t("shortcut.settings")),
            Item(keys: "⌃⌘H", title: t("desktop.home")),
            Item(keys: "⌃⌘S", title: t("desktop.sidebar.toggle")),
            Item(keys: "⌃⇧⇞  ⌃⇧⇟", title: t("shortcuts.move_tab")),
        ]
    }

    private var files: [Item] {
        [
            Item(keys: "⌘R", title: t("files.shortcut.refresh")),
            Item(keys: "⌘↑  ←", title: t("files.parent_folder")),
            Item(keys: "⌘⇧N", title: t("files.new_folder")),
            Item(keys: "⌘U", title: t("files.upload")),
            Item(keys: "⌘⇧.", title: t("files.show_hidden")),
            Item(keys: "␣", title: t("files.view")),
            Item(keys: "⌫", title: t("common.delete")),
        ]
    }

    private var mouse: [Item] {
        [
            Item(keys: "", title: t("shortcuts.mouse_wheel")),
            Item(keys: "", title: t("shortcuts.mouse_select")),
            Item(keys: "", title: t("shortcuts.mouse_shift")),
            Item(keys: "", title: t("shortcuts.pinch")),
        ]
    }
}
