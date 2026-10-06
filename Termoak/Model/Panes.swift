import CoreGraphics

/// Split view on the iPad: several of the open terminals side by side in a
/// grid (like the desktop's workspaces), one of them focused, an optional
/// focus mode (the focused pane big, the others small) and broadcast input.
/// Only the pure layout and navigation logic lives here; the state is in
/// `Sessions` and the views in `SplitView.swift`.
enum PaneLayout {
    /// Most panes on screen (a 2 × 2 grid).
    static let maxPanes = 4

    /// Panes per row, from top to bottom: 2 side by side, 3 as 2 + 1, 4 as
    /// 2 × 2... The columns are `ceil(sqrt(n))` and the leftover cells are
    /// taken from the last rows, so the wider rows are on top.
    static func gridRows(_ n: Int) -> [Int] {
        guard n > 0 else { return [] }
        var cols = 1
        while cols * cols < n { cols += 1 }
        let rows = (n + cols - 1) / cols
        let base = n / rows
        let extra = n % rows
        return (0..<rows).map { $0 < extra ? base + 1 : base }
    }

    /// Row and column of pane `ix` in the grid of `n` panes.
    static func position(_ n: Int, _ ix: Int) -> (row: Int, col: Int)? {
        var start = 0
        for (row, count) in gridRows(n).enumerated() {
            if ix < start + count { return (row, ix - start) }
            start += count
        }
        return nil
    }

    enum Direction {
        case left, right, up, down
    }

    /// Pane reached from `from` moving in `dir` in the grid of `n` panes,
    /// wrapping around at the edges. Up and down pick the pane of the other
    /// row whose horizontal centre is closest (rows can have different widths).
    static func neighbor(_ n: Int, from: Int, _ dir: Direction) -> Int? {
        guard n >= 2, from >= 0, from < n, let here = position(n, from) else { return nil }
        let (row, col) = (here.row, here.col)
        let rows = gridRows(n)
        var starts: [Int] = []
        var acc = 0
        for c in rows {
            starts.append(acc)
            acc += c
        }
        switch dir {
        case .left, .right:
            let count = rows[row]
            if count < 2 {
                // Alone in its row: left and right walk the whole list.
                return dir == .left ? (from + n - 1) % n : (from + 1) % n
            }
            let next = dir == .left ? (col + count - 1) % count : (col + 1) % count
            return starts[row] + next
        case .up, .down:
            guard rows.count >= 2 else { return nil }
            let target = dir == .up ? (row + rows.count - 1) % rows.count : (row + 1) % rows.count
            let centre = (Double(col) + 0.5) / Double(rows[row])
            let count = rows[target]
            return starts[target] + min(Int((centre * Double(count)).rounded(.down)), count - 1)
        }
    }

    /// Focus mode: the focused pane on the left and the others in a column,
    /// so the arrows just walk the list.
    static func neighborInFocusMode(_ n: Int, from: Int, _ dir: Direction) -> Int? {
        guard n >= 2, from >= 0, from < n else { return nil }
        switch dir {
        case .left, .up: return (from + n - 1) % n
        case .right, .down: return (from + 1) % n
        }
    }

    /// Index to focus after closing pane `closed` of `n` (before closing)
    /// when `focused` had the focus.
    static func focusAfterClose(_ n: Int, focused: Int, closed: Int) -> Int? {
        guard n > 1 else { return nil }
        let left = n - 1
        if focused > closed { return focused - 1 }
        if focused == closed { return min(closed, left - 1) }
        return focused
    }

    /// Frames of `n` panes in `size`: the grid or, in focus mode, the
    /// focused pane big on the left and the others in a column on the right.
    static func frames(count n: Int, focused: Int?, focusMode: Bool, in size: CGSize, spacing: CGFloat) -> [CGRect] {
        guard n > 0 else { return [] }
        let w = max(size.width, 0)
        let h = max(size.height, 0)
        if n == 1 { return [CGRect(x: 0, y: 0, width: w, height: h)] }
        if focusMode, let f = focused, f >= 0, f < n {
            let big = ((w - spacing) * 0.7).rounded()
            let side = max(w - spacing - big, 0)
            let others = n - 1
            let cell = max((h - spacing * CGFloat(others - 1)) / CGFloat(others), 0)
            var frames: [CGRect] = []
            var slot = 0
            for i in 0..<n {
                if i == f {
                    frames.append(CGRect(x: 0, y: 0, width: big, height: h))
                } else {
                    frames.append(CGRect(x: big + spacing, y: CGFloat(slot) * (cell + spacing), width: side, height: cell))
                    slot += 1
                }
            }
            return frames
        }
        let rows = gridRows(n)
        let rowHeight = max((h - spacing * CGFloat(rows.count - 1)) / CGFloat(rows.count), 0)
        var frames: [CGRect] = []
        for (r, count) in rows.enumerated() {
            let cellWidth = max((w - spacing * CGFloat(count - 1)) / CGFloat(count), 0)
            for c in 0..<count {
                frames.append(CGRect(x: CGFloat(c) * (cellWidth + spacing), y: CGFloat(r) * (rowHeight + spacing),
                                     width: cellWidth, height: rowHeight))
            }
        }
        return frames
    }
}
