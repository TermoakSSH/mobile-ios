import TermoakKit
import SwiftUI

/// Suggestions like on the desktop: the rest of the command, dimmed right
/// after the cursor, and above the line (or below if it does not fit) a list
/// to pick from with one tap. → on the bar accepts the first one.
struct CursorSuggestions: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var settings: AppSettings

    private let rowHeight: CGFloat = 38

    var body: some View {
        GeometryReader { geo in
            if session.suggestionMode == .cursor, let first = session.suggestions.first, let p = session.cursorPosition() {
                let x = CGFloat(p.column) * p.cell.width
                let y = CGFloat(p.row) * p.cell.height
                if !session.awaitingEcho {
                    Text(first.insert)
                        .font(SwiftUI.Font(settings.terminalFont.ui(settings.fontSize)))
                        .foregroundColor(settings.terminalTheme.foregroundColor.opacity(0.4))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: p.cell.height)
                        .frame(maxWidth: max(0, geo.size.width - x), alignment: .leading)
                        .clipped()
                        .offset(x: x, y: y)
                        .allowsHitTesting(false)
                }
                list(origin: CGPoint(x: x, y: y), cell: p.cell, width: geo.size.width, typed: first.text.count - first.insert.count)
            }
        }
    }

    private func list(origin: CGPoint, cell: CGSize, width: CGFloat, typed: Int) -> some View {
        let rows = Array(session.suggestions.prefix(5))
        let listWidth = min(width - 8, 360)
        let height = CGFloat(rows.count) * rowHeight + 8
        // Aligned with the start of what was typed, without going off the sides.
        let x = min(max(4, origin.x - CGFloat(typed) * cell.width), width - listWidth - 4)
        let above = origin.y - height - 6
        let y = above >= 0 ? above : origin.y + cell.height + 6
        let theme = settings.terminalTheme
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, s in
                Button { session.accept(s) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon(s.source)).font(.system(size: 11, weight: .medium)).opacity(0.55).frame(width: 14)
                        (Text(String(s.text.dropLast(s.insert.count))).foregroundColor(theme.foregroundColor.opacity(0.55))
                            + Text(s.insert).foregroundColor(SwiftUI.Color(hex: theme.accent)))
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 6)
                        Text(s.description).font(.caption2).opacity(0.45).lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: rowHeight)
                    .background(i == 0 ? SwiftUI.Color(hex: theme.accent).opacity(0.12) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("suggestions.accessibility \(s.text)"))
                .accessibilityHint(s.description)
            }
        }
        .padding(.vertical, 4)
        .frame(width: listWidth)
        .foregroundColor(theme.foregroundColor)
        .background(theme.barColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.foregroundColor.opacity(0.15)))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        .offset(x: x, y: y)
    }

    private func icon(_ source: SuggestionSource) -> String {
        switch source {
        case .history: return "clock"
        case .snippet: return "curlybraces"
        case .command: return "terminal"
        }
    }
}
