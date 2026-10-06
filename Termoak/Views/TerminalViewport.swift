import CoreText
import SwiftTerm
import UIKit

/// Columns and rows of a terminal.
struct TermSize: Equatable {
    var cols: Int
    var rows: Int
}

/// Holds the terminal view of a session. Normally the terminal takes all the
/// space (and its columns and rows follow it). A read-only guest instead
/// keeps the owner's columns and rows (`follow`): if they do not fit, the
/// terminal is zoomed out until the whole of it is in view; pinch to zoom in
/// and drag to move around.
@MainActor
final class TerminalViewport: UIScrollView, UIScrollViewDelegate {
    let terminal: TerminalView

    /// Size to keep (`nil`: the terminal takes the size of the viewport).
    var follow: TermSize? {
        didSet {
            guard follow != oldValue else { return }
            zoomedIn = false
            laidOut = nil
            setNeedsLayout()
            // Right away: the output that comes next is drawn at that size.
            layoutIfNeeded()
        }
    }

    /// What the current layout was made for (scrolling and zooming also lay
    /// out the view; only a new size, font or `follow` change it).
    private struct Layout: Equatable {
        var size: CGSize
        var follow: TermSize?
        var cell: CGSize
    }

    private var laidOut: Layout?
    /// A tap anywhere on the terminal (the split view focuses its pane). It
    /// does not get in the way of the terminal's own gestures.
    var onTap: (() -> Void)?
    private let tapDelegate = SimultaneousTaps()
    /// Zoom with the whole terminal in view.
    private var fitScale: CGFloat = 1
    /// Zoomed in by hand (kept when the space changes, e.g. the key bar).
    private var zoomedIn = false
    /// Undoing the zoom (also after `follow` went back to `nil`).
    private var resetting = false

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.frame)
        delegate = self
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = true
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
        bouncesZoom = true
        scrollsToTop = false
        addSubview(terminal)
        apply()
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = tapDelegate
        addGestureRecognizer(tap)
    }

    @objc private func tapped() {
        onTap?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let layout = Layout(size: bounds.size, follow: follow, cell: cellSize())
        guard layout != laidOut else { return }
        laidOut = layout
        apply()
    }

    /// Lays the terminal out: at the viewport's size, or at the size to
    /// follow zoomed to fit.
    private func apply() {
        let previous = zoomScale
        let keepZoom = zoomedIn
        // Measured at the real size, without zoom.
        minimumZoomScale = 1
        maximumZoomScale = 1
        resetting = true
        zoomScale = 1
        resetting = false
        terminal.transform = .identity
        guard let follow, follow.cols > 0, follow.rows > 0, bounds.width > 0, bounds.height > 0 else {
            isScrollEnabled = false
            pinchGestureRecognizer?.isEnabled = false
            terminal.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
            contentOffset = .zero
            terminal.isScrollEnabled = true
            fitScale = 1
            return
        }
        let cell = cellSize()
        // Half a cell more so SwiftTerm's rounding down gives exactly those.
        let size = CGSize(width: (CGFloat(follow.cols) + 0.5) * cell.width,
                          height: (CGFloat(follow.rows) + 0.5) * cell.height)
        terminal.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        fitScale = min(1, bounds.width / size.width, bounds.height / size.height)
        minimumZoomScale = fitScale
        maximumZoomScale = max(2, fitScale * 4)
        isScrollEnabled = true
        pinchGestureRecognizer?.isEnabled = true
        let scale = keepZoom ? min(max(previous, fitScale), maximumZoomScale) : fitScale
        setZoomScale(scale, animated: false)
        zoomChanged()
        if !zoomedIn { contentOffset = .zero }
    }

    /// Size of a cell with the terminal's font, as SwiftTerm measures it.
    private func cellSize() -> CGSize {
        let font = terminal.font
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let ct = font as CTFont
        let height = ceil(ceil(CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)) * scale) / scale
        let width = ("W" as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: max(1, (width * scale).rounded() / scale), height: max(1, height))
    }

    private func zoomChanged() {
        zoomedIn = follow != nil && zoomScale > fitScale + 0.001
        // Zoomed in, a drag moves around; with all of it in view it scrolls
        // the terminal's history as usual.
        terminal.isScrollEnabled = !zoomedIn
        // Centered when it is narrower than the screen.
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        terminal.center = CGPoint(x: contentSize.width / 2 + dx, y: contentSize.height / 2)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        follow != nil || resetting ? terminal : nil
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !resetting else { return }
        zoomChanged()
    }
}

/// Lets the viewport's tap be recognized together with the terminal's
/// gestures. (A separate object: the scroll view is already the delegate of
/// its own pan and pinch.)
private final class SimultaneousTaps: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
