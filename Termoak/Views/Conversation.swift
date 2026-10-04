import TermoakKit
import SwiftUI

/// A piece of the conversation with the AI (in the AI section and in the copilot).
enum Turn: Identifiable {
    case user(Int, String)
    case assistant(Int, String)
    case reasoning(Int, String)
    case tool(Int, callId: String, name: String, input: String, output: String?, error: Bool)

    var id: Int {
        switch self {
        case .user(let i, _), .assistant(let i, _), .reasoning(let i, _), .tool(let i, _, _, _, _, _): return i
        }
    }
}

/// Removes the `<context>…</context>` blocks at the start of a user message
/// (the one the server adds and the one with the terminal screen).
func stripContext(_ text: String) -> String {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    while t.hasPrefix("<context>"), let end = t.range(of: "</context>") {
        t = String(t[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return t
}

func truncate(_ text: String, _ maximum: Int) -> String {
    text.count > maximum ? String(text.prefix(maximum)) + "…" : text
}

/// Summary of a tool's input: the command if there is one; otherwise, the JSON.
func inputSummary(_ input: Any?) -> String {
    if let o = input as? [String: Any] {
        if let c = o["command"] as? String { return c }
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) {
            return truncate(String(decoding: d, as: UTF8.self), 300)
        }
    }
    return (input as? String) ?? ""
}

/// The conversation comes from the task's messages (`rawJson`).
func turns(_ task: AiTask) -> [Turn] {
    guard let data = task.rawJson.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let messages = root["messages"] as? [[String: Any]] else { return [] }
    var out: [Turn] = []
    var tools: [String: Int] = [:]
    for m in messages {
        let isUser = (m["role"] as? String ?? "") == "user"
        var text = ""
        func flush() {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            if isUser {
                let clean = stripContext(t)
                if !clean.isEmpty { out.append(.user(out.count, clean)) }
            } else if !t.isEmpty {
                out.append(.assistant(out.count, t))
            }
        }
        for p in (m["content"] as? [[String: Any]]) ?? [] {
            switch p["type"] as? String {
            case "text":
                text += p["text"] as? String ?? ""
            case "reasoning":
                flush()
                let r = (p["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !r.isEmpty { out.append(.reasoning(out.count, r)) }
            case "tool_call":
                flush()
                let callId = p["id"] as? String ?? ""
                tools[callId] = out.count
                out.append(.tool(out.count, callId: callId, name: p["name"] as? String ?? "",
                                 input: inputSummary(p["input"]), output: nil, error: false))
            case "tool_result":
                if let idx = tools[p["id"] as? String ?? ""],
                   case let .tool(n, callId, name, input, _, _) = out[idx] {
                    out[idx] = .tool(n, callId: callId, name: name, input: input,
                                     output: p["content"] as? String ?? "", error: p["is_error"] as? Bool ?? false)
                }
            default:
                break
            }
        }
        flush()
    }
    return out
}

/// Text with simple markdown (bold, italics, `code`, links).
func markdownText(_ s: String) -> Text {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    if let a = try? AttributedString(markdown: s, options: options) {
        return Text(a)
    }
    return Text(s)
}

/// A turn of the conversation: the user's bubble, the AI's answer,
/// reasoning or a tool with its output.
struct TurnView: View {
    let turn: Turn
    /// The task is still running: a tool without a result is being executed.
    var running = false
    @State private var expanded = false

    var body: some View {
        switch turn {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 40)
                Text(text).textSelection(.enabled).padding(12)
                    .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(.horizontal)
        case .assistant(_, let text):
            HStack {
                markdownText(text).textSelection(.enabled).padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                Spacer(minLength: 40)
            }
            .padding(.horizontal)
        case .reasoning(_, let text):
            Text(truncate(text, 600))
                .font(.footnote).italic()
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
        case let .tool(_, _, name, input, output, error):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text(name).fontWeight(.semibold)
                    Spacer(minLength: 0)
                    if output == nil && running {
                        ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    }
                }
                .font(.caption)
                .foregroundColor(error ? Brand.red : .secondary)
                if !input.isEmpty {
                    Text(input).font(.system(.caption, design: .monospaced)).lineLimit(expanded ? nil : 3)
                }
                if let output, !output.isEmpty {
                    Text(output)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(error ? Brand.red : .secondary)
                        .lineLimit(expanded ? nil : 12)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            .onTapGesture { expanded.toggle() }
        }
    }
}
