import TermoakKit
import SwiftUI

// Status dots of the hosts lists (Settings → Host status, off by default):
// green with the time a connection took, red when the host doesn't answer.

/// The dot of a host, next to its name (nothing when the setting is off or
/// the host isn't checked).
struct HostStatusDot: View {
    let host: SshHost
    /// Also the time ("12 ms") next to the dot.
    var showsLatency = false
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = HostStatusStore.shared

    var body: some View {
        if settings.hostStatusChecks {
            switch store.dot(for: host) {
            case .up(let ms):
                HStack(spacing: 3) {
                    dot(Brand.green)
                    if showsLatency {
                        Text(verbatim: HostStatusPlan.latency(ms))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("host_status.up \(HostStatusPlan.latency(ms))"))
            case .down:
                dot(.red)
                    .accessibilityLabel(Text("host_status.down"))
            case .unknown:
                EmptyView()
            }
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

/// Checks the status of the hosts of a list while it is on screen
/// (`active`) and the app is in the foreground, every host at most once a
/// minute. Nothing at all while the setting is off.
struct HostStatusChecks: ViewModifier {
    let hosts: [SshHost]
    let active: Bool
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var phase

    /// What restarts the checks: the hosts and their targets, the hosts
    /// left out, the setting and whether the list is in view.
    private var key: String {
        guard settings.hostStatusChecks, active, phase == .active else { return "" }
        return hosts.map { "\($0.key)@\(HostStatusStore.target($0))" }.joined(separator: ",")
            + "|" + settings.hostStatusOff.joined(separator: ",")
    }

    func body(content: Content) -> some View {
        content.task(id: key) {
            guard !key.isEmpty else { return }
            let (core, off, list) = (model.core, settings.hostStatusOff, hosts)
            while !Task.isCancelled {
                await HostStatusStore.shared.refresh(list, core: core, off: off)
                try? await Task.sleep(nanoseconds: UInt64(HostStatusPlan.tick * 1_000_000_000))
            }
        }
    }
}

extension View {
    func hostStatusChecks(_ hosts: [SshHost], active: Bool) -> some View {
        modifier(HostStatusChecks(hosts: hosts, active: active))
    }
}

/// "Don't check status" / "Check status" in a host's menu.
struct HostStatusMenuItem: View {
    let host: SshHost
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        if settings.hostStatusChecks {
            let off = settings.hostStatusOff.contains(host.id)
            Button {
                settings.hostStatusOff = HostStatusPlan.toggled(settings.hostStatusOff, host.id)
                HostStatusStore.shared.forget(host)
            } label: {
                if off {
                    Label("host_status.turn_on", systemImage: "dot.radiowaves.left.and.right")
                } else {
                    Label("host_status.turn_off", systemImage: "circle.slash")
                }
            }
        }
    }
}

/// Settings → Host status.
struct HostStatusSettingsSection: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Section {
            Toggle("host_status.setting", isOn: $settings.hostStatusChecks)
        } footer: {
            Text("host_status.setting.footer")
        }
    }
}
