import SwiftUI

/// Over the whole app while it is locked, or while it is not active (the
/// app switcher's snapshot shows only the logo).
struct AppLockOverlay: View {
    @ObservedObject var lock: AppLock

    var body: some View {
        if lock.locked || lock.covered {
            LockScreen(lock: lock, showsButton: lock.locked && !lock.covered)
                .transition(.opacity)
        }
    }
}

private struct LockScreen: View {
    @ObservedObject var lock: AppLock
    let showsButton: Bool

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                if showsButton { details }
            }
            .padding(32)
            .frame(maxWidth: 420)
        }
    }

    @ViewBuilder private var details: some View {
        Text("lock.title").font(.title3.weight(.semibold))
        Text("lock.detail \(lock.method)")
            .font(.subheadline)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
        if let error = lock.error {
            Text(error).font(.footnote).foregroundColor(Brand.red).multilineTextAlignment(.center)
        }
        Button { lock.unlock() } label: {
            Label(String(localized: "lock.unlock \(lock.method)"), systemImage: "lock.open")
                .frame(maxWidth: 280)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(lock.checking)
    }
}

/// Settings → Lock: on/off (checked once), when it asks again, and Lock now.
struct AppLockSection: View {
    @ObservedObject var lock: AppLock

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { lock.enabled }, set: { lock.setEnabled($0) })) {
                Text("settings.lock.enabled")
            }
            .disabled(lock.checking || (!lock.enabled && !lock.available))
            if lock.enabled {
                Picker("settings.lock.after", selection: $lock.delay) {
                    ForEach(LockDelay.allCases) { Text(title($0)).tag($0) }
                }
                Button { lock.lockNow() } label: { Label("settings.lock.lock_now", systemImage: "lock") }
            }
            if let error = lock.error, !lock.locked {
                Text(error).font(.footnote).foregroundColor(Brand.red)
            }
        } header: {
            Text("settings.lock.title")
        } footer: {
            Text(lock.available ? String(localized: "settings.lock.enabled_hint \(lock.method)")
                                : String(localized: "lock.unavailable \(lock.method)"))
        }
    }

    private func title(_ d: LockDelay) -> String {
        switch d {
        case .immediately: return String(localized: "settings.lock.after_background")
        case .hour: return String(localized: "settings.lock.after_hour")
        default: return String(localized: "settings.lock.after_minutes \(d.rawValue / 60)")
        }
    }
}
