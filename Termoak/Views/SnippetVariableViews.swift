import SwiftUI
import TermoakKit

/// The fields of a snippet's variables: text with its default, a picker for
/// a select, a masked field (with show) for a secret, and the host's
/// built-ins when the target has no host.
struct SnippetFieldsSection: View {
    @Binding var fields: [SnipField]
    @State private var shown: Set<String> = []

    var body: some View {
        Section {
            ForEach(fields.indices, id: \.self) { i in field(i) }
        } header: {
            Text("snippets.send.variables")
        } footer: {
            if fields.contains(where: { $0.variable.kind == .secret }) { Text("snippets.vars.secret_hint") }
        }
    }

    @ViewBuilder private func field(_ i: Int) -> some View {
        let v = fields[i].variable
        let value = Binding(get: { fields[i].value }, set: { fields[i].value = $0 })
        switch v.kind {
        case .select:
            Picker(selection: value) {
                ForEach(v.options, id: \.self) { Text(verbatim: $0).tag($0) }
            } label: { Text(verbatim: v.label) }
        case .secret:
            HStack {
                if shown.contains(v.key) {
                    TextField(String(localized: "snippets.vars.secret_label \(v.label)"), text: value)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    SecureField(String(localized: "snippets.vars.secret_label \(v.label)"), text: value)
                }
                Button {
                    if shown.contains(v.key) { shown.remove(v.key) } else { shown.insert(v.key) }
                } label: { Image(systemName: shown.contains(v.key) ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("snippets.vars.show_secret"))
            }
        case .builtin:
            VStack(alignment: .leading, spacing: 2) {
                TextField(String(localized: "snippets.vars.builtin_label \(v.label)"), text: value)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("snippets.vars.builtin_hint").font(.caption).foregroundColor(.secondary)
            }
        case .prompt:
            TextField(v.label, text: value)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }
}

/// The variables and the issues of a script, as it is typed (the editor).
struct SnippetTemplateSection: View {
    let script: String

    var body: some View {
        let t = parseSnippet(script: script)
        if !t.issues.isEmpty {
            Section {
                ForEach(Array(t.issues.enumerated()), id: \.offset) { _, issue in
                    Label {
                        Text(verbatim: SnippetEngine.issueText(issue, script: script)).font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Brand.red)
                    }
                }
            } header: {
                Text("snippets.issue.title \(t.issues.count)").foregroundColor(Brand.red)
            } footer: {
                Text("snippets.issue.fix_first")
            }
        }
        let vars = SnippetEngine.vars(t.variables)
        if !vars.isEmpty {
            Section("snippets.vars.title") {
                ForEach(Array(vars.enumerated()), id: \.offset) { _, v in
                    Text(verbatim: SnippetEngine.variableText(v)).font(.footnote)
                }
            }
        }
    }
}

/// Values for a snippet before using it in a terminal (this one, or every
/// open one): its prompts, with the built-ins of the terminal's host.
struct SnippetRunForm: View {
    let snippet: Snippet
    let run: Bool
    /// The host of the terminal (or of the only one), for its built-ins and
    /// the values remembered for it; `nil`: no host.
    let hostId: String?
    let accountId: String?
    /// Every target has a host (else the host built-ins are asked).
    let everyTargetHasHost: Bool
    /// The values chosen, and the variables they are for.
    let use: ([String: String], [SnipVar]) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var fields: [SnipField] = []
    @State private var vars: [SnipVar] = []
    @State private var missing: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text(verbatim: snippet.script).font(.system(.footnote, design: .monospaced)).lineLimit(6)
                }
                SnippetFieldsSection(fields: $fields)
                if let missing { Text("snippets.run.missing_value \(missing)").foregroundColor(Brand.red) }
            }
            .navigationTitle(snippet.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(run ? String(localized: "common.run") : String(localized: "common.paste")) {
                        switch SnippetVars.values(fields) {
                        case .failure(let m): missing = m.label
                        case .success(let values):
                            SnippetEngine.remember(model.core, snippet: snippet, hostId: hostId, values: values, vars: vars)
                            use(values, vars)
                            dismiss()
                        }
                    }
                }
            }
        }
        .onAppear {
            vars = SnippetEngine.prompts(snippet.script, everyTargetHasHost: everyTargetHasHost)
            fields = SnippetVars.fields(vars, remembered: SnippetEngine.remembered(model.core, snippet: snippet, hostId: hostId))
        }
    }
}
