import SwiftUI
import UIKit

// Hardware keyboard outside the terminal: lists that move with the arrows
// (`KeyCatcher`) and text fields that pass ↑/↓, Esc and Shift+Return on
// (`KeyTextField`). Both are UIKit because SwiftUI on iOS 15 has neither
// list focus nor key events; the keys arrive only while they are the first
// responder, so they never take keys from a text field or the terminal.

/// Invisible view that takes the keyboard focus (with a hardware keyboard
/// attached, while `active` and nothing else has it) and hands the list keys
/// to `onKey`, which returns whether it used them.
struct KeyCatcher: UIViewRepresentable {
    var active: Bool
    var onKey: (NavKey, ModifierKeys) -> Bool

    func makeUIView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.onKey = onKey
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: KeyCatcherView, context: Context) {
        view.onKey = onKey
        view.setActive(active)
    }
}

final class KeyCatcherView: UIView {
    var onKey: ((NavKey, ModifierKeys) -> Bool)?
    private var active = false

    override var canBecomeFirstResponder: Bool { active }

    func setActive(_ value: Bool) {
        let was = active
        active = value
        if value && !was {
            claim()
        } else if !value && isFirstResponder {
            _ = resignFirstResponder()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { claim() }
    }

    /// Takes the focus if nobody has it (a text field or the terminal keep it).
    private func claim() {
        guard active, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.window != nil, !self.isFirstResponder,
                  UIResponder.currentFirstResponder == nil else { return }
            _ = self.becomeFirstResponder()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            if let key = press.key, let nav = NavKey(hidUsage: key.keyCode.rawValue),
               onKey?(nav, ModifierKeys(key.modifierFlags)) == true {
                continue
            }
            rest.insert(press)
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }
}

extension UIResponder {
    private static weak var foundFirstResponder: UIResponder?

    /// The current first responder of the app (`nil`: none).
    static var currentFirstResponder: UIResponder? {
        foundFirstResponder = nil
        UIApplication.shared.sendAction(#selector(captureFirstResponder(_:)), to: nil, from: nil, for: nil)
        return foundFirstResponder
    }

    @objc private func captureFirstResponder(_ sender: Any) {
        UIResponder.foundFirstResponder = self
    }
}

/// A text field for a hardware keyboard: ↑/↓ choose in a list below it,
/// Return submits (Shift+Return separately), Esc closes. It takes the focus
/// when it appears.
struct KeyTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    var onShiftSubmit: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil
    var onArrow: ((_ up: Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> KeyField {
        let field = KeyField()
        field.placeholder = placeholder
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.returnKeyType = .go
        field.clearButtonMode = .whileEditing
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: KeyField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.onEscape = onEscape
        field.onArrow = onArrow
        field.onShiftReturn = onShiftSubmit
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: KeyTextField
        init(_ parent: KeyTextField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}

final class KeyField: UITextField {
    var onEscape: (() -> Void)?
    var onArrow: ((Bool) -> Void)?
    var onShiftReturn: (() -> Void)?
    private var focused = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !focused else { return }
        focused = true
        DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            guard let key = press.key, markedTextRange == nil else {
                rest.insert(press)
                continue
            }
            let plain = key.modifierFlags.intersection([.command, .control, .alternate]).isEmpty
            switch key.keyCode {
            case .keyboardEscape:
                if let onEscape { onEscape(); continue }
            case .keyboardUpArrow where plain:
                if let onArrow { onArrow(true); continue }
            case .keyboardDownArrow where plain:
                if let onArrow { onArrow(false); continue }
            case .keyboardReturnOrEnter where key.modifierFlags.contains(.shift):
                if let onShiftReturn { onShiftReturn(); continue }
            default:
                break
            }
            rest.insert(press)
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }
}

/// Background of a row highlighted with the keyboard.
func keyboardHighlight(_ on: Bool) -> Color? {
    on ? Color.accentColor.opacity(0.18) : nil
}
