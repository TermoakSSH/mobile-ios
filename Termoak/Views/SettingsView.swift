import TermoakKit
import SwiftUI

/// Profile tab: the account (or signing in), the AI keys and every setting
/// of the app and the terminal.
struct SettingsView: View {
    /// In a sheet (⌘, from the terminal): with a Done button.
    var closable = false
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var account: Accounts
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sessions: Sessions
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var twoFactor: TwoFactorStatus?
    @State private var loggingIn = false
    @State private var customizing = false
    @State private var showingShortcuts = false

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    var body: some View {
        NavigationView {
            Form {
                if let current = account.current {
                    Section {
                        accountCard(current)
                        HStack {
                            Text(syncStatus)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("settings.sync") { account.sync() }.disabled(account.syncing)
                        }
                        NavigationLink { AccountsView() } label: {
                            HStack {
                                Label("accounts.title", systemImage: "person.2")
                                Spacer()
                                Text(verbatim: "\(account.list.count)").foregroundColor(.secondary)
                            }
                        }
                        if account.list.contains(where: \.vaultsSupported) {
                            NavigationLink { VaultsView() } label: {
                                Label("vaults.title", systemImage: "lock.shield")
                            }
                        }
                        if account.loggedIn == true {
                            NavigationLink { TeamsView() } label: {
                                Label("desktop.section.teams", systemImage: "person.3")
                            }
                        }
                        if account.loggedIn == true, let url = URL(string: "\(current.serverUrl)/app/account") {
                            Button { openURL(url) } label: { Label("settings.web_account", systemImage: "arrow.up.right.square") }
                        }
                        if let tf = twoFactor { twoFactorRow(tf) }
                    }

                    if account.loggedIn == true {
                        Section("settings.ai") {
                            NavigationLink { AiSettingsView() } label: {
                                Label("settings.ai.keys", systemImage: "sparkles")
                            }
                        }
                    }
                } else {
                    Section {
                        localCard
                        Button { loggingIn = true } label: {
                            Label("accounts.add", systemImage: "person.crop.circle.badge.plus")
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
                    bellToggle
                    Toggle("settings.telnet_auto_login", isOn: $settings.telnetAutoLogin)
                    Text("settings.telnet_auto_login.footer").font(.footnote).foregroundColor(.secondary)
                } header: { Text("settings.terminal") } footer: {
                    Text("settings.terminal.footer")
                }

                Section {
                    Toggle("settings.confirm_multiline_paste", isOn: $settings.confirmMultilinePaste)
                } footer: {
                    Text("settings.confirm_multiline_paste.footer")
                }

                Section {
                    Toggle("settings.option_as_meta", isOn: $settings.optionAsMeta)
                    Toggle("settings.key_bar_hardware_keyboard", isOn: $settings.keyBarWithHardwareKeyboard)
                    Button { showingShortcuts = true } label: { Label("shortcuts.title", systemImage: "command") }
                } header: {
                    Text("settings.hardware_keyboard")
                } footer: {
                    Text("settings.hardware_keyboard.footer")
                }

                AppLockSection(lock: AppLock.shared)

                Section {
                    Picker("common.theme", selection: $settings.appTheme) {
                        ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("settings.wide_layout", selection: $settings.wideLayout) {
                        ForEach(WideLayout.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("settings.appearance")
                } footer: {
                    Text("settings.wide_layout.footer")
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
                    if let url = URL(string: account.server ?? officialServerUrl()) {
                        Button { openURL(url) } label: { Label("settings.website", systemImage: "globe") }
                    }
                }

            }
            .navigationTitle("nav.profile")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if closable {
                        Button("common.done") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                }
            }
            .sheet(isPresented: $loggingIn) {
                LoginView(welcome: false) {}.environmentObject(account).environmentObject(settings)
            }
        }
        .navigationViewStyle(.stack)
        .task(id: account.current?.id) {
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
        .onChange(of: settings.optionAsMeta) { _ in sessions.applyAppearance() }
        .onChange(of: settings.keyboard) { _ in sessions.applyKeyboard() }
        .onChange(of: settings.bellFeedback) { _ in sessions.applyAppearance() }
        .sheet(isPresented: $customizing) { KeyboardEditor().environmentObject(settings) }
        .sheet(isPresented: $showingShortcuts) { ShortcutsSheet() }
    }

    /// The bell vibrates on a phone and flashes the terminal on an iPad.
    private var bellToggle: some View {
        Toggle(isOn: $settings.bellFeedback) {
            VStack(alignment: .leading, spacing: 2) {
                Text(UIDevice.current.userInterfaceIdiom == .pad ? LocalizedStringKey("settings.bell.flash") : LocalizedStringKey("settings.bell.vibrate"))
                Text("settings.bell.hint").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    /// The current account: who you are and where it syncs.
    private func accountCard(_ current: AccountInfo) -> some View {
        HStack(spacing: 14) {
            AccountAvatar(account: current, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: current.email)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(verbatim: current.serverUrl.replacingOccurrences(of: "https://", with: ""))
                    .font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                if current.status == .active {
                    HStack(spacing: 6) {
                        Circle().fill(account.live ? Brand.green : Brand.amber).frame(width: 7, height: 7)
                        Text(account.live ? String(localized: "nav.account.synced_live") : String(localized: "nav.account.synced"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                } else {
                    AccountStatusText(info: current).font(.caption)
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// Two-step verification: On with the recovery codes left, or Off; it
    /// opens the page that turns it on or off.
    private func twoFactorRow(_ tf: TwoFactorStatus) -> some View {
        NavigationLink { TwoFactorView() } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("settings.two_factor", systemImage: "lock.shield")
                    Text(tf.enabled ? String(localized: "two_factor.codes_left \(Int(tf.recoveryCodesLeft))")
                                    : String(localized: "two_factor.off_hint"))
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Chip(tf.enabled ? String(localized: "settings.two_factor.on") : String(localized: "settings.two_factor.off"),
                     tf.enabled ? Brand.green : Brand.amber)
            }
        }
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
