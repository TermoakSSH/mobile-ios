import SwiftTerm
import UIKit

/// Finger gestures of a terminal that SwiftTerm doesn't have: pinch to
/// change the text size (every terminal follows, like Android) and a tap on
/// a link (`https://…` written by any program) to open it. SwiftTerm only
/// opens a link on a click while the pointer hovers it, which a finger can't
/// do.
@MainActor
final class TerminalTouches: NSObject, UIGestureRecognizerDelegate {
    private weak var session: TerminalSession?
    private let pinch = UIPinchGestureRecognizer()
    private let tap = UITapGestureRecognizer()
    /// Text size when the pinch started.
    private var startSize: Double = AppSettings.defaultFontSize

    init(session: TerminalSession) {
        self.session = session
        super.init()
        let view = session.view
        pinch.addTarget(self, action: #selector(pinched(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)
        tap.addTarget(self, action: #selector(tapped(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        // Fingers only: a mouse or trackpad click is SwiftTerm's.
        tap.allowedTouchTypes = TerminalPointer.directTouches
        // A double tap selects a word: then it is not a tap on a link.
        for g in view.gestureRecognizers ?? [] {
            if let t = g as? UITapGestureRecognizer, t !== tap, t.numberOfTapsRequired >= 2 {
                tap.require(toFail: t)
            }
        }
        view.addGestureRecognizer(tap)
    }

    /// Off while the terminal is zoomed to a wider owner's size (the
    /// viewport's own pinch zooms then).
    var pinchEnabled = true {
        didSet { pinch.isEnabled = pinchEnabled }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard let session else { return }
        let settings = session.settings
        switch g.state {
        case .began:
            startSize = settings.fontSize
        case .changed:
            let size = FontPinch.size(start: startSize, scale: Double(g.scale),
                                      minimum: AppSettings.minFontSize, maximum: AppSettings.maxFontSize)
            if size != settings.fontSize { settings.fontSize = size }
        default:
            break
        }
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, let session, let url = link(at: g.location(in: session.view), in: session) else { return }
        UIApplication.shared.open(url)
    }

    /// The link written at a point of the terminal view, if any. Not while
    /// the program takes the taps as clicks (vim, tmux with the mouse on)
    /// or text is selected.
    private func link(at point: CGPoint, in session: TerminalSession) -> URL? {
        let view = session.view
        let t = view.getTerminal()
        guard t.mouseMode == .off || !view.allowMouseReporting, (view.getSelection() ?? "").isEmpty else { return nil }
        let cell = TerminalViewport.cellSize(of: view)
        let row = Int((point.y - view.contentOffset.y) / cell.height)
        let column = Int(point.x / cell.width)
        guard row >= 0, row < t.rows, column >= 0, column < t.cols else { return nil }
        // The whole logical line: a long link wraps onto the next rows.
        var first = row
        while first > 0, let line = t.getLine(row: first), line.isWrapped { first -= 1 }
        var last = row
        while last + 1 < t.rows, let next = t.getLine(row: last + 1), next.isWrapped { last += 1 }
        var text = ""
        for r in first...last {
            guard let line = t.getLine(row: r) else { return nil }
            // One character per column, so the column is found in the text.
            var part = String(line.translateToString(trimRight: false).prefix(t.cols))
            if part.count < t.cols { part += String(repeating: " ", count: t.cols - part.count) }
            text += part
        }
        let index = (row - first) * t.cols + column
        return TerminalLinks.link(in: text, at: index).flatMap { URL(string: $0) }
    }

    // MARK: UIGestureRecognizerDelegate

    /// Together with the terminal's scrolling, selection and cursor gestures.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
