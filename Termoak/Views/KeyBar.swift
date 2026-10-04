import TermoakKit
import Combine
import UIKit

/// Key bar above the system keyboard (the terminal's `inputAccessoryView`):
/// the keys the phone keyboard lacks, in the order set in "Customize", and on
/// the right the grid button that opens the quick access panel. If chosen in
/// Settings, while typing the suggestions to complete the line appear at the
/// start (without changing the height, so the terminal is not resized).
/// It is UIKit so that a tap is a key press and a swipe scrolls the bar, and
/// to repeat arrows and delete while they are held down.
@MainActor
final class KeyBar: UIInputView {
    private weak var session: TerminalSession?
    private let settings: AppSettings
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let suggestionStack = UIStackView()
    private let separator = UIView()
    private let panelButton = UIButton(type: .custom)
    /// Button gesture mode: one finger moves the cursor or scrolls.
    private let gestureButton = UIButton(type: .custom)
    private var scrollWithoutButton: NSLayoutConstraint!
    private var scrollWithButton: NSLayoutConstraint!
    private var buttons: [(key: ShortcutKey, button: UIButton)] = []
    private var theme: TerminalTheme
    private var subscriptions: Set<AnyCancellable> = []
    private var repeater: Timer?
    private var didRepeat = false
    private let height: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 50 : 44

    init(session: TerminalSession, settings: AppSettings) {
        self.session = session
        self.settings = settings
        theme = settings.terminalTheme
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: height), inputViewStyle: .default)
        autoresizingMask = .flexibleWidth
        build()
        reload()
        applyTheme(theme)
        session.$ctrl.combineLatest(session.$alt)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.paintModifiers() }
            .store(in: &subscriptions)
        session.$suggestions
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] s in
                // In the bar only if chosen in Settings.
                self?.showSuggestions(self?.session?.suggestionMode == .bar ? s : [])
            }
            .store(in: &subscriptions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: height) }

    private func build() {
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.delaysContentTouches = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        suggestionStack.axis = .horizontal
        suggestionStack.spacing = 6
        suggestionStack.alignment = .center
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: height - 18).isActive = true
        stack.addArrangedSubview(suggestionStack)
        stack.addArrangedSubview(separator)
        suggestionStack.isHidden = true
        separator.isHidden = true

        panelButton.setImage(UIImage(systemName: "square.grid.2x2", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)), for: .normal)
        panelButton.layer.cornerRadius = 8
        panelButton.accessibilityLabel = String(localized: "common.quick_panel")
        panelButton.translatesAutoresizingMaskIntoConstraints = false
        panelButton.addAction(UIAction { [weak self] _ in self?.session?.onOpenPanel?() }, for: .touchUpInside)

        gestureButton.setImage(UIImage(systemName: "hand.draw", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)), for: .normal)
        gestureButton.layer.cornerRadius = 8
        gestureButton.accessibilityLabel = String(localized: "common.move_cursor")
        gestureButton.translatesAutoresizingMaskIntoConstraints = false
        gestureButton.addAction(UIAction { [weak self] _ in self?.session?.toggleGestures() }, for: .touchUpInside)

        addSubview(scroll)
        addSubview(panelButton)
        addSubview(gestureButton)
        scrollWithoutButton = scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor)
        scrollWithButton = scroll.leadingAnchor.constraint(equalTo: gestureButton.trailingAnchor, constant: 2)
        NSLayoutConstraint.activate([
            gestureButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            gestureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            gestureButton.widthAnchor.constraint(equalToConstant: 40),
            gestureButton.heightAnchor.constraint(equalToConstant: height - 10),
            panelButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            panelButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            panelButton.widthAnchor.constraint(equalToConstant: 40),
            panelButton.heightAnchor.constraint(equalToConstant: height - 10),
            scrollWithoutButton,
            scroll.trailingAnchor.constraint(equalTo: panelButton.leadingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: height - 10),
        ])
    }

    /// Recreates the keys (after "Customize").
    func reload() {
        buttons.forEach { $0.button.removeFromSuperview() }
        buttons = settings.keyboard.bar.map { key in
            let b = button(for: key)
            stack.addArrangedSubview(b)
            return (key, b)
        }
        paintModifiers()
    }

    func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        backgroundColor = theme.barUIColor
        separator.backgroundColor = UIColor(hex: theme.foreground).withAlphaComponent(0.2)
        panelButton.backgroundColor = theme.keyUIColor
        panelButton.tintColor = UIColor(hex: theme.accent)
        paintModifiers()
        paintGestureButton()
    }

    /// Shows the gesture button only in that mode, highlighted when one
    /// finger moves the cursor.
    func paintGestureButton() {
        let visible = session?.gestureMode == .button
        let active = session?.cursorByButton ?? false
        gestureButton.isHidden = !visible
        scrollWithButton.isActive = visible
        scrollWithoutButton.isActive = !visible
        let accent = UIColor(hex: theme.accent)
        gestureButton.backgroundColor = active ? accent.withAlphaComponent(0.35) : theme.keyUIColor
        gestureButton.tintColor = accent
        gestureButton.setImage(UIImage(systemName: active ? "hand.draw.fill" : "hand.draw",
                                       withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)), for: .normal)
        gestureButton.accessibilityValue = active ? String(localized: "common.on") : String(localized: "common.off")
    }

    private func button(for key: ShortcutKey) -> UIButton {
        let b = UIButton(type: .custom)
        if let icon = key.icon {
            b.setImage(UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)), for: .normal)
            b.accessibilityLabel = key.title
        } else {
            b.setTitle(key.title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        }
        b.layer.cornerRadius = 8
        b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 11, bottom: 0, right: 11)
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        b.heightAnchor.constraint(equalToConstant: height - 10).isActive = true
        b.addAction(UIAction { [weak self] _ in self?.touchDown(key) }, for: .touchDown)
        b.addAction(UIAction { [weak self] _ in self?.touchUp(key, inside: true) }, for: .touchUpInside)
        for event: UIControl.Event in [.touchUpOutside, .touchCancel, .touchDragExit] {
            b.addAction(UIAction { [weak self] _ in self?.touchUp(key, inside: false) }, for: event)
        }
        return b
    }

    // ----- Suggestions -----

    private func showSuggestions(_ list: [CommandSuggestion]) {
        suggestionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for s in list { suggestionStack.addArrangedSubview(chip(for: s)) }
        let any = !list.isEmpty
        suggestionStack.isHidden = !any
        separator.isHidden = !any
        if any { scroll.setContentOffset(.zero, animated: false) }
    }

    private func chip(for s: CommandSuggestion) -> UIButton {
        let accent = UIColor(hex: theme.accent)
        let textColor = UIColor(hex: theme.foreground)
        let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        let typed = String(s.text.dropLast(s.insert.count))
        let title = NSMutableAttributedString(string: typed, attributes: [.font: font, .foregroundColor: textColor.withAlphaComponent(0.55)])
        title.append(NSAttributedString(string: s.insert, attributes: [.font: font, .foregroundColor: accent]))
        let b = UIButton(type: .custom)
        b.setAttributedTitle(title, for: .normal)
        b.titleLabel?.lineBreakMode = .byTruncatingHead
        let icon: String
        switch s.source {
        case .history: icon = "clock"
        case .snippet: icon = "curlybraces"
        case .command: icon = "terminal"
        }
        b.setImage(UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)), for: .normal)
        b.tintColor = textColor.withAlphaComponent(0.55)
        b.imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
        b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 10)
        b.backgroundColor = accent.withAlphaComponent(0.14)
        b.layer.cornerRadius = 8
        b.layer.borderWidth = 1
        b.layer.borderColor = accent.withAlphaComponent(0.45).cgColor
        b.heightAnchor.constraint(equalToConstant: height - 10).isActive = true
        b.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        b.accessibilityLabel = String(localized: "suggestions.accessibility \(s.text)")
        b.accessibilityHint = s.description
        b.addAction(UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            self?.session?.accept(s)
        }, for: .touchUpInside)
        return b
    }

    private func paintModifiers() {
        let accent = UIColor(hex: theme.accent)
        for (key, b) in buttons {
            let active: Bool
            switch key.action {
            case .modifier(.ctrl): active = session?.ctrl ?? false
            case .modifier(.alt): active = session?.alt ?? false
            default: active = false
            }
            b.backgroundColor = active ? accent.withAlphaComponent(0.35) : theme.keyUIColor
            b.tintColor = accent
            b.setTitleColor(accent, for: .normal)
        }
    }

    // ----- Key presses -----

    private func touchDown(_ key: ShortcutKey) {
        didRepeat = false
        repeater?.invalidate()
        guard key.repeats else { return }
        // Held down: it repeats after a pause, like a keyboard.
        repeater = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.didRepeat = true
                self.session?.press(key)
                self.repeater = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.session?.press(key) }
                }
            }
        }
    }

    private func touchUp(_ key: ShortcutKey, inside: Bool) {
        repeater?.invalidate()
        repeater = nil
        if inside && !didRepeat {
            UIDevice.current.playInputClick()
            session?.press(key)
        }
    }
}

extension KeyBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
