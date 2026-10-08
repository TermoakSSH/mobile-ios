import SwiftUI

/// A question with one text field (a name, a path...): an alert with the
/// field on iOS 16 and later; on iOS 15, where an alert can't hold a text
/// field, a small sheet with the same title, field, explanation and buttons.
struct TextPrompt: ViewModifier {
    let title: Text
    @Binding var isPresented: Bool
    @Binding var text: String
    /// Already translated.
    let placeholder: String
    var message: Text?
    /// The confirming button, already translated.
    let confirm: String
    /// The confirming button is disabled for this text.
    var invalid: (String) -> Bool = { _ in false }
    /// Names and paths: no capitals or corrections.
    var plain = true
    let onConfirm: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.alert(title, isPresented: $isPresented) {
                field
                Button("common.cancel", role: .cancel) {}
                Button(confirm, action: onConfirm).disabled(invalid(text))
            } message: {
                if let message { message }
            }
        } else {
            content.sheet(isPresented: $isPresented) {
                TextPromptSheet(prompt: self)
            }
        }
    }

    @ViewBuilder fileprivate var field: some View {
        if plain {
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } else {
            TextField(placeholder, text: $text)
        }
    }
}

/// iOS 15: the prompt as a sheet.
private struct TextPromptSheet: View {
    let prompt: TextPrompt
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool

    var body: some View {
        NavigationView {
            Form {
                Section {
                    prompt.field
                        .focused($typing)
                        .submitLabel(.done)
                        .onSubmit(confirm)
                } footer: {
                    if let message = prompt.message { message }
                }
            }
            .navigationTitle(prompt.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(prompt.confirm, action: confirm).disabled(prompt.invalid(prompt.text))
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { typing = true }
    }

    private func confirm() {
        guard !prompt.invalid(prompt.text) else { return }
        dismiss()
        prompt.onConfirm()
    }
}

extension View {
    /// A question with one text field (see `TextPrompt`).
    func textPrompt(_ title: Text, isPresented: Binding<Bool>, text: Binding<String>, placeholder: String,
                    message: Text? = nil, confirm: String, invalid: @escaping (String) -> Bool = { _ in false },
                    plain: Bool = true, onConfirm: @escaping () -> Void) -> some View {
        modifier(TextPrompt(title: title, isPresented: isPresented, text: text, placeholder: placeholder, message: message,
                            confirm: confirm, invalid: invalid, plain: plain, onConfirm: onConfirm))
    }
}
