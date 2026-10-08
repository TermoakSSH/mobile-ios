import TermoakKit
import SwiftUI
import UIKit

/// The AI over a terminal, in its bottom right corner (the prompt and what
/// is typed stay in view on the left): the "Command failed · Explain · Fix"
/// chip and the card of a command the AI proposes (typed at the prompt,
/// never run). The explanation opens in a sheet. No Esc shortcut here: Esc
/// belongs to the terminal.
struct TerminalAiOverlay: View {
    @ObservedObject var assist: TerminalAssist
    let theme: TerminalTheme
    /// A dangerous command waiting for "Insert anyway".
    @State private var confirming: AiCommandSuggestion?

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Spacer(minLength: 0)
            if let p = assist.proposal {
                AiProposalCard(proposal: p, theme: theme,
                               onType: typeIt, onDismiss: { assist.dismissProposal() })
            } else if let last = assist.failed {
                FailedCommandChip(last: last, theme: theme,
                                  onExplain: { assist.explainFailed() },
                                  onFix: { assist.fixFailed() },
                                  onDismiss: { assist.dismissChip() })
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.easeOut(duration: 0.18), value: assist.proposal)
        .animation(.easeOut(duration: 0.18), value: assist.failed)
        .sheet(item: $assist.explanation) { item in AiExplanationSheet(item: item) }
        .alert("terminal.ai_bar.dangerous_title", isPresented: confirmingShown) {
            Button("terminal.ai_bar.insert_anyway", role: .destructive) {
                confirming = nil
                assist.typeProposal()
            }
            Button("common.cancel", role: .cancel) { confirming = nil }
        } message: {
            Text(verbatim: [confirming?.command, confirming?.explanation].compactMap { $0 }.joined(separator: "\n\n"))
        }
    }

    private var confirmingShown: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private func typeIt(_ s: AiCommandSuggestion) {
        if AiCommandRisk(s.risk).needsConfirmation {
            confirming = s
        } else {
            assist.typeProposal()
        }
    }
}

/// "Command failed (exit 2) · Explain · Fix ×".
private struct FailedCommandChip: View {
    let last: LastCommandInfo
    let theme: TerminalTheme
    let onExplain: () -> Void
    let onFix: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Brand.amber)
            Text(title).font(.footnote.weight(.medium)).lineLimit(1)
            Button(action: onExplain) { Label("terminal.ai_chip.explain", systemImage: "questionmark.bubble") }
                .accessibilityHint(Text("terminal.ai_chip.explain_tooltip"))
            Button(action: onFix) { Label("terminal.ai_chip.fix", systemImage: "wand.and.stars") }
                .accessibilityHint(Text("terminal.ai_chip.fix_tooltip"))
            Button(action: onDismiss) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .accessibilityLabel("terminal.ai_bar.dismiss")
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.barColor, in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.amber.opacity(0.5)))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var title: String {
        if let code = last.exitCode { return String(localized: "terminal.ai_chip.failed_exit \(Int(code))") }
        return String(localized: "terminal.ai_chip.failed")
    }
}

/// The command the AI proposes: asking, ready ("Type it", Copy) with its
/// risk and explanation, typed (review it and press Enter) or an error.
private struct AiProposalCard: View {
    let proposal: AiProposal
    let theme: TerminalTheme
    let onType: (AiCommandSuggestion) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .padding(12)
        .frame(maxWidth: 440, alignment: .leading)
        .background(theme.barColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.foregroundColor.opacity(0.15)))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundColor(SwiftUI.Color(hex: theme.accent))
            Text("terminal.ai.suggested_title").font(.footnote.weight(.semibold))
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(.borderless)
                .accessibilityLabel("terminal.ai_bar.dismiss")
        }
    }

    @ViewBuilder private var content: some View {
        switch proposal.state {
        case .asking:
            HStack(spacing: 8) {
                ProgressView()
                Text(askingText).font(.footnote).foregroundColor(.secondary)
            }
        case .failed(let message):
            Text(message).font(.footnote).foregroundColor(Brand.red)
        case .ready(let s):
            suggestion(s)
            HStack {
                Button { onType(s) } label: { Label("terminal.ai_bar.insert", systemImage: "text.cursor") }
                    .buttonStyle(.borderedProminent)
                Button { UIPasteboard.general.string = s.command } label: { Label("terminal.copy", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered)
            }
            Text("terminal.ai_bar.review").font(.caption2).foregroundColor(.secondary)
        case .typed(let s):
            suggestion(s)
            Text("terminal.ai_bar.typed").font(.caption2).foregroundColor(.secondary)
        }
    }

    private var askingText: String {
        if case .fix = proposal.origin { return String(localized: "terminal.ai_bar.asking_fix") }
        return String(localized: "terminal.ai_bar.asking_request")
    }

    @ViewBuilder private func suggestion(_ s: AiCommandSuggestion) -> some View {
        Text(verbatim: typeableCommand(command: s.command))
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.foregroundColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        RiskBadge(risk: AiCommandRisk(s.risk))
        if !s.explanation.isEmpty {
            Text(verbatim: s.explanation).font(.footnote).foregroundColor(.secondary).lineLimit(4)
        }
    }
}

private struct RiskBadge: View {
    let risk: AiCommandRisk

    var body: some View {
        Label(risk.title, systemImage: risk.symbol)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundColor(color)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var color: SwiftUI.Color {
        switch risk {
        case .read: return Brand.green
        case .write: return Brand.amber
        case .dangerous: return Brand.red
        }
    }
}

/// Why a command failed, in the AI's words (Markdown).
private struct AiExplanationSheet: View {
    let item: AiExplanationItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView { content.padding() }
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.close") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        if let error = item.error {
            Text(error).foregroundColor(Brand.red).frame(maxWidth: .infinity, alignment: .leading)
        } else if let answer = item.answer {
            VStack(alignment: .leading, spacing: 12) {
                Text(markdown(answer)).textSelection(.enabled)
                if let provider = item.provider, !provider.isEmpty {
                    Text("terminal.ai.provider \(provider)").font(.caption).foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("terminal.ai.asking").foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Inline Markdown (bold, code, links), keeping the line breaks.
    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
