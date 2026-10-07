import SwiftTerm
import UIKit

/// Trackpad and mouse on an iPad (SwiftTerm handles clicks, links under the
/// pointer and the drags of a program that takes the mouse):
/// - **Scroll** (two fingers, wheel): the history as usual; when the program
///   asked for mouse reports (vim, tmux, htop with the mouse on) the wheel
///   goes to it, and in the alternate screen without them (less, man) it
///   sends ↑/↓ like xterm's alternate scroll.
/// - **Click and drag** selects text (⌘C copies it), unless the program
///   takes the mouse; with Shift it always selects.
/// - **Secondary click**: the copy and paste menu, or the right button for a
///   program that takes the mouse (Shift: the menu).
@MainActor
final class TerminalPointer: NSObject, UIGestureRecognizerDelegate {
    private weak var view: TerminalView?
    private let wheel = UIPanGestureRecognizer()
    private let drag = UIPanGestureRecognizer()
    private let secondary = UITapGestureRecognizer()
    /// Scroll not yet turned into whole lines.
    private var pendingScroll: CGFloat = 0
    /// Where the selection drag started (buffer position).
    private var anchor: Position?

    /// Touch types of fingers and the pencil (not the pointer).
    static let directTouches = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                NSNumber(value: UITouch.TouchType.pencil.rawValue)]

    init(view: TerminalView) {
        self.view = view
        super.init()
        let pointer = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        wheel.addTarget(self, action: #selector(scrolled(_:)))
        // Only scroll events (trackpad, wheel), no touches.
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        wheel.delegate = self
        drag.addTarget(self, action: #selector(dragged(_:)))
        drag.allowedTouchTypes = pointer
        drag.maximumNumberOfTouches = 1
        drag.delegate = self
        secondary.addTarget(self, action: #selector(secondaryClick(_:)))
        secondary.buttonMaskRequired = .secondary
        secondary.allowedTouchTypes = pointer
        secondary.delegate = self
        view.addGestureRecognizer(wheel)
        view.addGestureRecognizer(drag)
        view.addGestureRecognizer(secondary)
        // Clicking and dragging selects instead of scrolling (the trackpad's
        // two-finger scroll still scrolls: that is not a touch).
        view.panGestureRecognizer.allowedTouchTypes = TerminalPointer.directTouches
    }

    /// The program asked for mouse reports.
    private var reportsMouse: Bool {
        guard let view else { return false }
        return view.allowMouseReporting && view.getTerminal().mouseMode != .off
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let view else { return false }
        if g === wheel { return reportsMouse || view.getTerminal().isCurrentBufferAlternate }
        if g === drag { return !reportsMouse || g.modifierFlags.contains(.shift) }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === wheel
    }

    // MARK: Actions

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        guard let view else { return }
        switch g.state {
        case .began:
            pendingScroll = 0
        case .changed:
            pendingScroll += g.translation(in: view).y
            g.setTranslation(.zero, in: view)
            let height = TerminalViewport.cellSize(of: view).height
            let lines = Int(pendingScroll / height)
            guard lines != 0 else { return }
            pendingScroll -= CGFloat(lines) * height
            // Content moving down: back in the history (wheel up).
            let up = lines > 0
            let count = min(abs(lines), 20)
            let t = view.getTerminal()
            if reportsMouse {
                let p = cell(at: g.location(in: view), screen: true)
                let flags = g.modifierFlags
                let button = t.encodeButton(button: up ? 4 : 5, release: false, shift: flags.contains(.shift),
                                            meta: flags.contains(.alternate), control: flags.contains(.control))
                for _ in 0..<count { t.sendEvent(buttonFlags: button, x: p.col, y: p.row) }
            } else if t.isCurrentBufferAlternate {
                let key: SpecialKey = up ? .up : .down
                let bytes = key.bytes(ctrl: false, alt: false, appCursor: t.applicationCursor)
                view.send(Array(Array(repeating: bytes, count: count).joined()))
            }
        default:
            pendingScroll = 0
        }
    }

    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        guard let view else { return }
        let p = cell(at: g.location(in: view), screen: false)
        switch g.state {
        case .began:
            anchor = p
            _ = view.becomeFirstResponder()
        case .changed:
            guard let anchor else { return }
            let forward = (p.row, p.col) >= (anchor.row, anchor.col)
            let (from, to) = forward ? (anchor, p) : (p, anchor)
            // The cell under the pointer is included.
            view.setSelectionRange(start: from, end: Position(col: to.col + 1, row: to.row))
        default:
            anchor = nil
        }
    }

    @objc private func secondaryClick(_ g: UITapGestureRecognizer) {
        guard let view, g.state == .ended else { return }
        let point = g.location(in: view)
        if reportsMouse && !g.modifierFlags.contains(.shift) {
            let t = view.getTerminal()
            let p = cell(at: point, screen: true)
            let flags = g.modifierFlags
            for release in [false, true] {
                let button = t.encodeButton(button: 2, release: release, shift: false,
                                            meta: flags.contains(.alternate), control: flags.contains(.control))
                t.sendEvent(buttonFlags: button, x: p.col, y: p.row)
            }
        } else {
            view.showStandardContextMenu(at: point)
        }
    }

    /// Cell under `point` (in the view's coordinates): on the screen (for
    /// mouse reports) or in the buffer with the history (for the selection).
    private func cell(at point: CGPoint, screen: Bool) -> Position {
        guard let view else { return Position(col: 0, row: 0) }
        let size = TerminalViewport.cellSize(of: view)
        let t = view.getTerminal()
        let col = min(max(0, Int(point.x / size.width)), max(0, t.cols - 1))
        if screen {
            let row = Int((point.y - view.contentOffset.y) / size.height)
            return Position(col: col, row: min(max(0, row), max(0, t.rows - 1)))
        }
        let last = max(0, Int(view.contentSize.height / size.height) - 1)
        return Position(col: col, row: min(max(0, Int(point.y / size.height)), last))
    }
}
