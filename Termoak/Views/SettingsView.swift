import TermoakKit
import SwiftUI

/// Profile tab: the account (or signing in), the AI keys and every setting
/// of the app and the terminal.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Account
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sessions: Sessions
    @Environment(\.openURL) private var openURL
    @State private var twoFactor: TwoFactorStatus?
    @State private var loggingIn = false
    @State private var loggingOut = false
    @State private var customizing = false

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    var body: some View {
        NavigationView {
            Form {
                if account.loggedIn == true {
                    Section {
                        accountCard
                        HStack {
                            Text(syncStatus)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("settings.sync") { account.sync() }.disabled(account.syncing)
                        }
                        if let s = account.server, let url = URL(string: "\(s)/app/account") {
                            Button { openURL(url) } label: { Label("settings.web_account", systemImage: "arrow.up.right.square") }
                        }
                        if let tf = twoFactor {
                            HStack {
                                Label("settings.two_factor", systemImage: "lock.shield")
                                Spacer()
                                Chip(tf.enabled ? String(localized: "settings.two_factor.on") : String(localized: "settings.two_factor.off"),
                                     tf.enabled ? Brand.green : Brand.amber)
                            }
                        }
                    }

                    Section("settings.ai") {
                        NavigationLink { AiSettingsView() } label: {
                            Label("settings.ai.keys", systemImage: "sparkles")
                        }
                    }
                } else {
                    Section {
                        localCard
                        Button { loggingIn = true } label: {
                            Label("common.log_in", systemImage: "person.crop.circle.badge.plus")
                        }
                    }
                }

                Section {
                    HStack {
                        Text("settings.font_size")
                        Spacer()
                        Text("settings.font_size.value \(Int(settings.fontSize))").foregroundColor(.secondary)
                    }
                    Slider(value: $settings.fontSize, in: AppSettings.minFontSize...AppSettings.maxFontSize, step: 1)
                    Picker("common.theme", selection: $settings.terminalThemeId) {
                        ForEach(TerminalTheme.all) { Text($0.name).tag($0.id) }
                    }
                    Picker("common.font", selection: $settings.fontId) {
                        ForEach(TerminalFont.all) { Text($0.name).tag($0.id) }
                    }
                    Button { customizing = true } label: { Label("settings.keyboard_keys", systemImage: "keyboard") }
                    Picker("settings.cursor_gestures", selection: $settings.gestureMode) {
                        ForEach(GestureMode.allCases) { Text($0.title).tag($0) }
                    }
                    Text(settings.gestureMode.explanation).font(.footnote).foregroundColor(.secondary)
                    Picker("settings.command_suggestions", selection: $settings.suggestionMode) {
                        ForEach(SuggestionMode.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("settings.keep_screen_on", isOn: $settings.keepScreenOn)
                } header: { Text("settings.terminal") } footer: {
                    Text("settings.terminal.footer")
                }

                Section {
                    Toggle("settings.confirm_multiline_paste", isOn: $settings.confirmMultilinePaste)
                } footer: {
                    Text("settings.confirm_multiline_paste.footer")
                }

                Section("settings.appearance") {
                    Picker("common.theme", selection: $settings.appTheme) {
                        ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        HStack {
                            Label("settings.language", systemImage: "globe")
                            Spacer()
                            Text("language.name").foregroundColor(.secondary)
                        }
                    }
                } footer: {
                    Text("settings.language.footer")
                }

                Section("settings.about") {
                    HStack {
                        Text("settings.version")
                        Spacer()
                        Text("settings.version.value \(version) \(libraryVersion())").foregroundColor(.secondary)
                    }
                    if let url = URL(string: account.server ?? defaultServer) {
                        Button { openURL(url) } label: { Label("settings.website", systemImage: "globe") }
                    }
                }

                if account.loggedIn == true {
                    Section {
                        Button(role: .destructive) { loggingOut = true } label: {
                            Label("common.log_out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } footer: { Text("settings.log_out.footer") }
                }
            }
            .navigationTitle("nav.profile")
            .sheet(isPresented: $loggingIn) {
                LoginView(welcome: false) {}.environmentObject(account).environmentObject(settings)
            }
            .confirmationDialog("settings.log_out.confirm", isPresented: $loggingOut, titleVisibility: .visible) {
                Button("common.log_out", role: .destructive) {
                    sessions.closeAll()
                    account.logOut()
                }
            }
        }
        .navigationViewStyle(.stack)
        .task(id: account.loggedIn) {
            if account.loggedIn == true {
                twoFactor = try? await model.core.twoFactorStatus()
            } else {
                twoFactor = nil
            }
        }
        .onChange(of: settings.fontSize) { _ in sessions.applyAppearance() }
        .onChange(of: settings.terminalThemeId) { _ in sessions.applyAppearance() }
        .onChange(of: settings.fontId) { _ in sessions.applyAppearance() }
        .onChange(of: settings.suggestionMode) { _ in sessions.applyAppearance() }
        .onChange(of: settings.gestureMode) { _ in sessions.applyAppearance() }
        .onChange(of: settings.keyboard) { _ in sessions.applyKeyboard() }
        .sheet(isPresented: $customizing) { KeyboardEditor().environmentObject(settings) }
    }

    /// Who you are and where your vault syncs.
    private var accountCard: some View {
        HStack(spacing: 14) {
            ProfileAvatar(name: account.user ?? "?")
            VStack(alignment: .leading, spacing: 3) {
                Text(account.user ?? String(localized: "common.connected"))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(verbatim: (account.server ?? "").replacingOccurrences(of: "https://", with: ""))
                    .font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(account.live ? Brand.green : Brand.amber).frame(width: 7, height: 7)
                    Text(account.live ? String(localized: "nav.account.synced_live") : String(localized: "nav.account.synced"))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// Without an account: the vault is only on this device.
    private var localCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image("Logo")
                .resizable()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("profile.local.title").font(.title3.weight(.semibold))
                Text("settings.account.local_hint")
                    .font(.footnote).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }

    private var syncStatus: String {
        if account.syncing { return String(localized: "common.syncing") }
        if let last = account.lastSync { return String(localized: "settings.synced \(relativeTime(last))") }
        return String(localized: "settings.never_synced")
    }
}

/// Round avatar with the first letter of the account.
private struct ProfileAvatar: View {
    let name: String

    var body: some View {
        Circle()
            .fill(LinearGradient(gradient: Gradient(colors: [Brand.blue, Brand.blue.opacity(0.7)]),
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 56, height: 56)
            .overlay(
                Text(verbatim: name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            )
            .accessibilityHidden(true)
    }
}
