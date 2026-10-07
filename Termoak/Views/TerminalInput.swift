import GameController
import SwiftTerm
import UIKit

extension ModifierKeys {
    init(_ flags: UIKeyModifierFlags) {
        var m: ModifierKeys = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.alternate) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        self = m
    }
}

/// SwiftTerm's view as the app uses it:
/// - its paste (edit menu, ⌘V) goes through the session, which may ask
///   before pasting several lines;
/// - the keys of a hardware keyboard send what `HardwareKeyMap` says
///   (Ctrl and Option as Meta, xterm arrows and function keys with
///   modifiers, ⌘. as Esc...), and they repeat while held. Plain characters,
///   dead keys and the ⌘ shortcuts go on to the text system and SwiftTerm.
///   With the kitty keyboard protocol turned on by a program, or while
///   text is being composed, SwiftTerm handles every key.
final class TermoakTerminalView: TerminalView {
    var onPaste: (() -> Void)?
    /// Option sends Esc + the key (Meta); off, it types the layout's
    /// characters (Settings).
    var optionAsMeta = true {
        didSet { optionAsMetaKey = optionAsMeta }
    }

    private var repeater: Timer?
    /// Changes when a repeat stops (a timer of an earlier key does nothing).
    private var repeatGeneration = 0

    override func paste(_ sender: Any?) {
        if let onPaste {
            onPaste()
        } else {
            super.paste(sender)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopKeyRepeat()
        if presses.contains(where: { $0.key != nil }) { HardwareKeyboard.shared.keyPressed() }
        let terminal = getTerminal()
        guard terminal.keyboardEnhancementFlags.isEmpty, markedTextRange == nil else {
            super.pressesBegan(presses, with: event)
            return
        }
        var toSystem = Set<UIPress>()
        var toNext = Set<UIPress>()
        for press in presses {
            guard let key = press.key,
                  let hardwareKey = HardwareKey(hidUsage: key.keyCode.rawValue, characters: key.characters,
                                                charactersIgnoringModifiers: key.charactersIgnoringModifiers)
            else {
                toSystem.insert(press)
                continue
            }
            let options = KeyEncodingOptions(applicationCursor: terminal.applicationCursor, optionAsMeta: optionAsMeta,
                                             stickyControl: controlModifier, stickyAlt: metaModifier)
            switch HardwareKeyMap.result(for: hardwareKey, modifiers: ModifierKeys(key.modifierFlags), options: options) {
            case .system:
                toSystem.insert(press)
            case .ignore:
                toNext.insert(press)
            case .send(let bytes):
                // The key bar's Ctrl and Alt were used by this key.
                if controlModifier { controlModifier = false }
                if metaModifier { metaModifier = false }
                send(bytes)
                startKeyRepeat(bytes, usage: key.keyCode.rawValue)
            case .scrollPage(let up):
                if up { scrollUp(lines: terminal.rows) } else { scrollDown(lines: terminal.rows) }
            }
        }
        if !toSystem.isEmpty { super.pressesBegan(toSystem, with: event) }
        if !toNext.isEmpty { next?.pressesBegan(toNext, with: event) }
    }

    // SwiftTerm's `pressesEnded` cannot be overridden (it is not `open`); it
    // passes the release on to the viewport, which calls `keysReleased`.
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopKeyRepeat()
        super.pressesCancelled(presses, with: event)
    }

    override func resignFirstResponder() -> Bool {
        stopKeyRepeat()
        return super.resignFirstResponder()
    }

    /// A key was released (from `TerminalViewport.pressesEnded`).
    func keysReleased() {
        stopKeyRepeat()
    }

    // MARK: Key repeat

    /// Like a keyboard: after a pause the key repeats until it is released.
    private func startKeyRepeat(_ bytes: [UInt8], usage: Int) {
        stopKeyRepeat()
        let generation = repeatGeneration
        let started = Date()
        let first = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.repeatGeneration == generation else { return }
                let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.repeatTick(bytes, usage: usage, generation: generation, started: started) }
                }
                self.repeater = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        repeater = first
        RunLoop.main.add(first, forMode: .common)
    }

    private func repeatTick(_ bytes: [UInt8], usage: Int, generation: Int, started: Date) {
        guard repeatGeneration == generation, isFirstResponder, window != nil else {
            stopKeyRepeat()
            return
        }
        // Safety net if a release got lost: after two seconds the game
        // controller framework must still see the key down.
        if Date().timeIntervalSince(started) > 2, HardwareKeyboard.shared.isPressed(usage) == false {
            stopKeyRepeat()
            return
        }
        send(bytes)
    }

    private func stopKeyRepeat() {
        repeatGeneration &+= 1
        repeater?.invalidate()
        repeater = nil
    }
}

/// Whether a hardware keyboard is attached (the key bar hides then, unless
/// chosen otherwise in Settings). The game controller framework reports
/// keyboards (iOS 14); a key press from one also counts.
@MainActor
final class HardwareKeyboard: ObservableObject {
    static let shared = HardwareKeyboard()

    @Published private(set) var connected: Bool
    private var observers: [NSObjectProtocol] = []

    private init() {
        connected = GCKeyboard.coalesced != nil
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { _ in
                Task { @MainActor in HardwareKeyboard.shared.update(true) }
            },
            center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { _ in
                Task { @MainActor in HardwareKeyboard.shared.update(GCKeyboard.coalesced != nil) }
            },
        ]
    }

    private func update(_ value: Bool) {
        if connected != value { connected = value }
    }

    /// A press came from a physical keyboard.
    func keyPressed() {
        update(true)
    }

    /// Whether the key with HID usage `usage` is held down (`nil`: unknown).
    func isPressed(_ usage: Int) -> Bool? {
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return nil }
        return input.button(forKeyCode: GCKeyCode(rawValue: usage))?.isPressed
    }
}
