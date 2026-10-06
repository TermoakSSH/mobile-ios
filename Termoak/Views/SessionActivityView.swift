import TermoakKit
import SwiftUI

/// Activity of one of your server sessions: who had the keyboard and when,
/// from the author marks of its recording (`sessionActivity`). Only who
/// typed and when, not what.
struct SessionActivityView: View {
    let core: TermoakCore
    let sessionId: String
    let title: String

    @Environment(\.dismiss) private var dismiss

    private enum Load {
        case loading
        /// The session was not recorded.
        case notRecorded
        case failed(String)
        case done(SessionActivity)
    }

    @State private var load: Load = .loading

    var body: some View {
        NavigationView {
            content
                .navigationTitle("activity.title")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
                }
        }
        .navigationViewStyle(.stack)
        .task { await fetch() }
    }

    @ViewBuilder
    private var content: some View {
        switch load {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notRecorded:
            EmptyState(icon: "record.circle", title: title,
                       text: String(localized: "activity.not_recorded"))
        case .failed(let message):
            EmptyState(icon: "exclamationmark.triangle",
                       title: String(localized: "activity.failed"),
                       text: message,
                       action: String(localized: "common.retry")) {
                Task { await fetch() }
            }
        case .done(let activity):
            List {
                Section {
                    if activity.periods.isEmpty {
                        Text("activity.none").foregroundColor(.secondary)
                    }
                    ForEach(Array(activity.periods.enumerated()), id: \.offset) { _, p in
                        PeriodRow(period: p)
                    }
                } header: {
                    Text(verbatim: title)
                } footer: {
                    if let start = activity.startedAt, start > 0 {
                        Text(String(localized: "activity.started \(startDate(start))"))
                    } else {
                        Text("activity.hint")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await fetch() }
        }
    }

    private func fetch() async {
        do {
            if let activity = try await core.sessionActivity(sessionId: sessionId) {
                load = .done(activity)
            } else {
                load = .notRecorded
            }
        } catch {
            load = .failed(errorMessage(error))
        }
    }

    private func startDate(_ ms: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000).formatted(date: .abbreviated, time: .shortened)
    }
}

/// "Ana · Owner        00:12 – 05:30".
private struct PeriodRow: View {
    let period: AuthorPeriod

    var body: some View {
        HStack(spacing: 12) {
            if period.kind == "ai" {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.accentColor))
                    .accessibilityHidden(true)
            } else {
                ParticipantAvatar(name: name, size: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).lineLimit(1)
                Text(verbatim: kindLabel).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Text(verbatim: span)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var name: String {
        if !period.name.isEmpty { return period.name }
        return period.kind == "ai" ? String(localized: "activity.kind.ai") : String(localized: "activity.unknown")
    }

    private var kindLabel: String {
        switch period.kind {
        case "owner": return String(localized: "share.access.owner")
        case "guest": return String(localized: "share.participants.guest")
        case "ai": return String(localized: "activity.kind.ai")
        default: return String(localized: "share.kind.user")
        }
    }

    /// `00:12 – 05:30`, or `from 05:30` for the last one.
    private var span: String {
        let from = clock(period.fromSecs)
        if let to = period.toSecs { return "\(from) – \(clock(to))" }
        return String(localized: "activity.from \(from)")
    }

    /// `mm:ss`, or `h:mm:ss` past an hour.
    private func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}
