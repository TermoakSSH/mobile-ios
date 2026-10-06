import SwiftTerm
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// How the cursor is moved with a finger (Settings). The raw values are
/// persisted (`AppSettings.gestureMode`), so they keep their original values.
enum GestureMode: String, CaseIterable, Identifiable {
    /// Hold and drag; a normal swipe scrolls.
    case hold = "mantener"
    /// One finger moves the cursor; two scroll.
    case oneFinger = "deslizar"
    /// One finger scrolls; two move the cursor.
    case twoFingers = "dosDedos"
    /// A button toggles one finger between moving the cursor and scrolling.
    case button = "boton"
    case off = "desactivados"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hold: return String(localized: "gestures.hold.title")
        case .oneFinger: return String(localized: "gestures.one_finger.title")
        case .twoFingers: return String(localized: "gestures.two_fingers.title")
        case .button: return String(localized: "gestures.button.title")
        case .off: return String(localized: "gestures.off.title")
        }
    }
    var explanation: String {
        switch self {
        case .hold: return String(localized: "gestures.hold.explanation")
        case .oneFinger: return String(localized: "gestures.one_finger.explanation")
        case .twoFingers: return String(localized: "gestures.two_fingers.explanation")
        case .button: return String(localized: "gestures.button.explanation")
        case .off: return String(localized: "gestures.off.explanation")
        }
    }
}

/// Moving the cursor with a finger: it sends arrows, which move the cursor
/// (left/right) or walk the shell history (up/down). Dragging further in the
/// same direction goes faster (three levels).
///
/// - **Hold and drag**: if the finger moves right away, it is a normal
///   scroll; if it is held and then dragged, it sends arrows; if it is held
///   still, SwiftTerm's copy and paste menu appears.
/// - **One finger / two fingers**: swiping with that number of fingers sends
///   arrows and the other one scrolls.
/// - **With a button**: the bar button decides what one finger does.
@MainActor
final class CursorGesture: NSObject, UIGestureRecognizerDelegate {
    private weak var session: TerminalSession?
    private let hold = HoldAndDragGesture()
    private let swipe = UIPanGestureRecognizer()
    private let twoFingers = UIPanGestureRecognizer()
    private var anchor: CGPoint = .zero
    private var direction: SpecialKey?
    /// Distance travelled in the current direction (to go up a level).
    private var travelled: CGFloat = 0
    private var level = 1
    private let impact = UIImpactFeedbackGenerator(style: .light)

    /// Distance per arrow at each level, and the distance travelled from
    /// which the next level starts.
    private let steps: [CGFloat] = [26, 13, 6]
    private let thresholds: [CGFloat] = [80, 190]

    init(session: TerminalSession) {
        self.session = session
        super.init()
        let view = session.view
        hold.addTarget(self, action: #selector(changed(_:)))
        hold.delegate = self
        swipe.addTarget(self, action: #selector(changed(_:)))
        swipe.maximumNumberOfTouches = 1
        swipe.delegate = self
        twoFingers.addTarget(self, action: #selector(changed(_:)))
        twoFingers.minimumNumberOfTouches = 2
        twoFingers.maximumNumberOfTouches = 2
        twoFingers.delegate = self
        view.addGestureRecognizer(hold)
        view.addGestureRecognizer(swipe)
        view.addGestureRecognizer(twoFingers)
        // The copy menu (SwiftTerm's long press) and scrolling wait until
        // they know it is not this gesture, so they never fire together.
        for g in view.gestureRecognizers ?? [] where g is UILongPressGestureRecognizer {
            g.require(toFail: hold)
        }
        view.panGestureRecognizer.require(toFail: hold)
        configure(.hold, cursorByButton: false)
    }

    private var mode: GestureMode = .hold
    private var cursorByButton = false
    /// Off while the terminal is zoomed to the owner's size (read-only
    /// guest): one finger pans and two pinch, there is no cursor to move.
    var suspended = false {
        didSet { if suspended != oldValue { configure(mode, cursorByButton: cursorByButton) } }
    }

    /// `cursorByButton`: in button mode, whether the cursor is active.
    func configure(_ mode: GestureMode, cursorByButton: Bool) {
        self.mode = mode
        self.cursorByButton = cursorByButton
        let effective: GestureMode = suspended ? .off : mode
        let oneFinger = effective == .oneFinger || (effective == .button && cursorByButton)
        // Not disabled: failing immediately, the menu and scrolling (which
        // wait for it to fail) keep working.
        hold.active = effective == .hold
        swipe.isEnabled = oneFinger
        twoFingers.isEnabled = effective == .twoFingers
        guard let scroll = session?.view.panGestureRecognizer else { return }
        scroll.minimumNumberOfTouches = oneFinger ? 2 : 1
        scroll.maximumNumberOfTouches = effective == .twoFingers ? 1 : Int.max
    }

    @objc private func changed(_ g: UIGestureRecognizer) {
        guard let session, let view = g.view else { return }
        let point = g.location(in: view.superview)
        switch g.state {
        case .began:
            // Measured from where the finger went down, not from where the
            // gesture was recognized (a few points later).
            if let h = g as? HoldAndDragGesture {
                anchor = view.convert(h.start, to: view.superview)
            } else if let p = g as? UIPanGestureRecognizer {
                let t = p.translation(in: view.superview)
                anchor = CGPoint(x: point.x - t.x, y: point.y - t.y)
            } else {
                anchor = point
            }
            direction = nil
            travelled = 0
            level = 1
            impact.prepare()
            impact.impactOccurred(intensity: 0.5)
        case .changed:
            move(to: point, session: session)
        default:
            session.cursorPad = nil
        }
    }

    private func move(to point: CGPoint, session: TerminalSession) {
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        let horizontal = abs(dx) >= abs(dy)
        let delta = horizontal ? dx : dy
        guard abs(delta) >= steps[level - 1] else {
            if session.cursorPad == nil && hypot(dx, dy) > 6 {
                session.cursorPad = CursorPad(direction: direction ?? (horizontal ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down)), level: level)
            }
            return
        }
        let newDirection: SpecialKey = horizontal ? (delta < 0 ? .left : .right) : (delta < 0 ? .up : .down)
        if newDirection != direction {
            direction = newDirection
            travelled = 0
            level = 1
            impact.impactOccurred()
        }
        var remaining = abs(delta)
        while remaining >= steps[level - 1] {
            let step = steps[level - 1]
            session.arrow(newDirection)
            remaining -= step
            travelled += step
            if horizontal { anchor.x += delta < 0 ? -step : step } else { anchor.y += delta < 0 ? -step : step }
            let newLevel = travelled >= thresholds[1] ? 3 : (travelled >= thresholds[0] ? 2 : 1)
            if newLevel != level {
                level = newLevel
                impact.impactOccurred(intensity: 0.8)
            }
        }
        // The other axis does not accumulate: that way it can be corrected without changing direction.
        if horizontal { anchor.y = point.y } else { anchor.x = point.x }
        session.cursorPad = CursorPad(direction: newDirection, level: level)
    }

    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // No conflict with SwiftTerm's taps (cursor, links); there is one with
        // scrolling and the menu (see `require(toFail:)`).
        !(other is UIPanGestureRecognizer) && !(other is UILongPressGestureRecognizer)
    }
}

/// Hold and then drag. It fails if the finger moves before `delay` (it is a
/// scroll) or if it stays still longer than `stillLimit` (it gives way to the
/// copy menu). That way it never overlaps with either of them.
final class HoldAndDragGesture: UIGestureRecognizer {
    var active = true
    var delay: TimeInterval = 0.3
    var stillLimit: TimeInterval = 0.6
    var tolerance: CGFloat = 10
    /// Where the finger went down (in the view).
    private(set) var start: CGPoint = .zero
    private var startTime: TimeInterval = 0
    private var timer: Timer?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard active, touches.count == 1, numberOfTouches <= 1, let t = touches.first else {
            state = .failed
            return
        }
        start = t.location(in: view)
        startTime = t.timestamp
        timer = Timer.scheduledTimer(withTimeInterval: stillLimit, repeats: false) { [weak self] _ in
            guard let self, self.state == .possible else { return }
            self.state = .failed
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first else { return }
        switch state {
        case .possible:
            let p = t.location(in: view)
            guard hypot(p.x - start.x, p.y - start.y) > tolerance else { return }
            timer?.invalidate()
            state = t.timestamp - startTime < delay ? .failed : .began
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = (state == .began || state == .changed) ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    override func reset() {
        timer?.invalidate()
        timer = nil
    }
}

/// Translucent pad shown while dragging: the active arrow in the theme color
/// and with one, two or three chevrons depending on the speed.
struct CursorPadView: View {
    let pad: CursorPad
    let accent: SwiftUI.Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .frame(width: 96, height: 96)
            arrow(.up).offset(y: -30)
            arrow(.down).offset(y: 30)
            arrow(.left).offset(x: -30)
            arrow(.right).offset(x: 30)
        }
        .animation(.easeOut(duration: 0.12), value: pad)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func arrow(_ d: SpecialKey) -> some View {
        let active = pad.direction == d
        let rotation: Double = [.right: 0, .down: 90, .left: 180, .up: 270][d] ?? 0
        HStack(spacing: -5) {
            ForEach(0..<(active ? pad.level : 1), id: \.self) { _ in
                Image(systemName: "chevron.right").font(.system(size: 15, weight: .bold))
            }
        }
        .rotationEffect(.degrees(rotation))
        .foregroundColor(active ? accent : .secondary.opacity(0.6))
        .frame(width: 34, height: 26)
    }
}
