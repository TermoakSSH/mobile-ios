import SwiftUI

/// Each server's output of a command run without terminals: its exit code,
/// and its output when you open it; copy one or share them all.
struct ExecBatchSummary: View {
    @ObservedObject var batch: ExecBatch
    @State private var open: Set<String> = []
    @State private var sharing = false

    var body: some View {
        List {
            Section { header }
            Section {
                ForEach(batch.items) { item in row(item) }
            } footer: {
                Text("snippets.exec.footer")
            }
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $sharing) { ActivityView(items: [batch.report()]) }
        .sheet(item: Binding(get: { batch.prompts.first }, set: { if $0 == nil, let p = batch.prompts.first { batch.promptClosed(p.id) } })) { p in
            AuthPromptView(prompt: p) { batch.promptClosed(p.id) }.interactiveDismissDisabled()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if batch.finished {
                    let all = batch.succeeded == batch.items.count
                    Image(systemName: all ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundColor(all ? Brand.green : Brand.amber)
                } else {
                    ProgressView()
                }
                Text("snippets.exec.summary \(batch.succeeded) \(batch.items.count)").font(.headline)
            }
            Text(verbatim: batch.command)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(3)
            Button { sharing = true } label: { Label("snippets.exec.share_all", systemImage: "square.and.arrow.up") }
                .disabled(!batch.finished)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func row(_ item: ExecBatch.Item) -> some View {
        Button { toggle(item.id) } label: { rowLabel(item) }
            .buttonStyle(.plain)
            .contextMenu {
                if case .done(let o) = item.status {
                    Button { UIPasteboard.general.string = o.combined } label: {
                        Label("snippets.exec.copy_output", systemImage: "doc.on.doc")
                    }
                }
            }
        if open.contains(item.id), case .done(let o) = item.status { output(o) }
    }

    private func rowLabel(_ item: ExecBatch.Item) -> some View {
        HStack(spacing: 12) {
            icon(item.status).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).foregroundColor(.primary).lineLimit(1)
                Text(statusText(item.status)).font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if case .done = item.status {
                Image(systemName: open.contains(item.id) ? "chevron.down" : "chevron.right")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    /// The output (stdout, then stderr in red), scrolling sideways.
    private func output(_ o: ExecOutput) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if o.stdout.isEmpty && o.stderr.isEmpty {
                Text("snippets.exec.no_output").font(.caption).foregroundColor(.secondary)
            }
            if !o.stdout.isEmpty { block(o.stdout, color: .primary) }
            if !o.stderr.isEmpty { block(o.stderr, color: Brand.red) }
            if o.truncated {
                Text("snippets.exec.truncated").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func block(_ text: String, color: Color) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(verbatim: text.hasSuffix("\n") ? String(text.dropLast()) : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(color)
                .textSelection(.enabled)
                .fixedSize()
        }
    }

    private func toggle(_ id: String) {
        if open.contains(id) { open.remove(id) } else { open.insert(id) }
    }

    @ViewBuilder private func icon(_ s: ExecBatch.Status) -> some View {
        switch s {
        case .waiting: Image(systemName: "clock").foregroundColor(.secondary)
        case .connecting, .running: ProgressView().scaleEffect(0.7)
        case .done(let o):
            Image(systemName: o.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(o.succeeded ? Brand.green : Brand.amber)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundColor(Brand.red)
        }
    }

    private func statusText(_ s: ExecBatch.Status) -> String {
        switch s {
        case .waiting: return String(localized: "files.transfer.waiting")
        case .connecting: return String(localized: "terminal.state.connecting")
        case .running: return String(localized: "snippets.exec.running")
        case .done(let o): return ExecBatch.exitText(o) + " · " + String(format: "%.1f s", Double(o.durationMs) / 1000)
        case .failed(let why): return why
        }
    }
}
