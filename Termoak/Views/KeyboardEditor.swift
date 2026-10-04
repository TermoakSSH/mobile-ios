import SwiftUI

/// "Customize": the bar above the keyboard (which keys and in what order) and
/// the groups of the quick access panel (order, which ones are shown and
/// their keys), with custom keys.
struct KeyboardEditor: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var resetting = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(settings.keyboard.bar) { KeyRow(key: $0) }
                        .onMove { settings.keyboard.bar.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { settings.keyboard.bar.remove(atOffsets: $0) }
                    Button { adding = true } label: { Label("keyboard_editor.add_to_bar", systemImage: "plus.circle") }
                } header: {
                    Text("keyboard_editor.bar.header")
                } footer: {
                    Text("keyboard_editor.bar.footer")
                }

                Section {
                    ForEach(settings.keyboard.groups) { g in
                        NavigationLink { KeyGroupEditor(groupId: g.id) } label: {
                            HStack {
                                Text(g.title)
                                Spacer()
                                if !g.visible { Image(systemName: "eye.slash").foregroundColor(.secondary) }
                                Text(verbatim: "\(g.keys.count)").foregroundColor(.secondary)
                            }
                        }
                    }
                    .onMove { settings.keyboard.groups.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("keyboard_editor.groups.header")
                } footer: {
                    Text("keyboard_editor.groups.footer")
                }

                Section {
                    Button("keyboard_editor.reset", role: .destructive) { resetting = true }
                }
            }
            .navigationTitle("quick_panel.customize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
            .sheet(isPresented: $adding) { KeyPicker() }
            .confirmationDialog("keyboard_editor.reset.title", isPresented: $resetting, titleVisibility: .visible) {
                Button("keyboard_editor.reset.confirm", role: .destructive) { settings.keyboard = .standard }
            } message: {
                Text("keyboard_editor.reset.message")
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// The keys of a group.
private struct KeyGroupEditor: View {
    let groupId: String
    @EnvironmentObject private var settings: AppSettings
    @State private var creating = false

    private var index: Int? { settings.keyboard.groups.firstIndex { $0.id == groupId } }

    var body: some View {
        if let i = index {
            List {
                Section {
                    Toggle("keyboard_editor.group.show", isOn: $settings.keyboard.groups[i].visible)
                    TextField("common.name", text: Binding(
                        get: { settings.keyboard.groups[i].title },
                        set: { settings.keyboard.groups[i].name = $0 }
                    ))
                }
                Section {
                    ForEach(settings.keyboard.groups[i].keys) { k in
                        KeyRow(key: k)
                            .swipeActions(edge: .leading) {
                                if !settings.keyboard.bar.contains(where: { $0.id == k.id }) {
                                    Button { settings.keyboard.bar.append(k) } label: { Label("keyboard_editor.group.to_bar", systemImage: "plus") }
                                        .tint(Brand.green)
                                }
                            }
                    }
                    .onMove { settings.keyboard.groups[i].keys.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { settings.keyboard.groups[i].keys.remove(atOffsets: $0) }
                    Button { creating = true } label: { Label("keyboard_editor.new_key", systemImage: "plus.circle") }
                } header: {
                    Text("keyboard_editor.group.keys")
                } footer: {
                    Text("keyboard_editor.group.footer")
                }
            }
            .navigationTitle(settings.keyboard.groups[i].title)
            .toolbar { EditButton() }
            .sheet(isPresented: $creating) {
                NewKeyView { k in settings.keyboard.groups[i].keys.append(k) }
            }
        }
    }
}

/// Pick a key for the bar (from any group) or create a new one.
private struct KeyPicker: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button { creating = true } label: { Label("keyboard_editor.new_key_ellipsis", systemImage: "plus.circle") }
                }
                ForEach(settings.keyboard.groups) { g in
                    let free = g.keys.filter { k in !settings.keyboard.bar.contains { $0.id == k.id } }
                    if !free.isEmpty {
                        Section(g.title) {
                            ForEach(free) { k in
                                Button {
                                    settings.keyboard.bar.append(k)
                                    dismiss()
                                } label: { KeyRow(key: k) }
                                .foregroundColor(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("keyboard_editor.add_to_bar.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } } }
            .sheet(isPresented: $creating) {
                NewKeyView { k in
                    // Custom keys also go into the custom keys group.
                    if let i = settings.keyboard.groups.firstIndex(where: { $0.id == KeyGroup.customGroupId }) {
                        settings.keyboard.groups[i].keys.append(k)
                    }
                    settings.keyboard.bar.append(k)
                    dismiss()
                }
            }
        }
    }
}

/// Create a custom key: a combination (`ctrl+b`, `esc`, `^C`...), a text
/// and, optionally, Enter at the end.
struct NewKeyView: View {
    let onSave: (ShortcutKey) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var combination = ""
    @State private var text = ""
    @State private var enter = false

    private var steps: Result<[KeyStep], CombinationError> {
        parseCombination(combination).map { steps in
            steps + (text.isEmpty ? [] : [.text(text)]) + (enter ? [.special(.enter)] : [])
        }
    }

    private var isValid: Bool {
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty, case .success(let s) = steps else { return false }
        return !s.isEmpty
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("keyboard_editor.new_key.label_placeholder", text: $label)
                }
                Section {
                    TextField("keyboard_editor.new_key.combination_placeholder", text: $combination)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("keyboard_editor.new_key.combination")
                } footer: {
                    if case .failure(let e) = parseCombination(combination) {
                        Text(e.message).foregroundColor(Brand.red)
                    } else {
                        Text("keyboard_editor.new_key.combination_help")
                    }
                }
                Section {
                    TextField("keyboard_editor.new_key.text_placeholder", text: $text)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("keyboard_editor.new_key.press_enter", isOn: $enter)
                } header: {
                    Text("keyboard_editor.new_key.text")
                }
                if case .success(let s) = steps, !s.isEmpty {
                    Section("keyboard_editor.new_key.sends") {
                        Text(describe(.steps(s))).font(.system(.footnote, design: .monospaced))
                    }
                }
            }
            .navigationTitle("keyboard_editor.new_key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        guard case .success(let s) = steps else { return }
                        onSave(ShortcutKey(id: "custom.\(UUID().uuidString)", label: label.trimmingCharacters(in: .whitespaces), action: .steps(s)))
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}

/// A key in the editor lists: how it looks and what it sends.
private struct KeyRow: View {
    let key: ShortcutKey

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = key.icon { Image(systemName: icon) } else { Text(key.title).lineLimit(1) }
            }
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 30)
            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
            Text(describe(key.action)).font(.footnote).foregroundColor(.secondary).lineLimit(1)
        }
    }
}
