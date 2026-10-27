import TermoakKit
import SwiftUI
import AuthenticationServices

// Single sign-on (0.7 phase 5c, docs-next/E2EE-SSO-AUDIT.md §3): the
// provider in ASWebAuthenticationSession (callback scheme `termoak`, back to
// `termoak://sso`), the sign-in card, and Teams → Single sign-on.

enum SsoBrowserError: Error {
    case cancelled
    case failed
}

/// The identity provider in the system's web authentication session (its
/// cookies and passwords, never a web view of the app). The engine's PKCE
/// makes a code caught on its way useless without the verifier.
@MainActor
enum SsoBrowser {
    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }

    private static let anchor = Anchor()
    private static var current: ASWebAuthenticationSession?

    /// Opens `url` and returns the `termoak://sso…` URL it came back to.
    static func open(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: SsoRules.callbackScheme) { callback, error in
                current = nil
                if let callback { c.resume(returning: callback); return }
                if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin { c.resume(throwing: SsoBrowserError.cancelled); return }
                c.resume(throwing: SsoBrowserError.failed)
            }
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            current = session
            if !session.start() {
                current = nil
                c.resume(throwing: SsoBrowserError.failed)
            }
        }
    }
}

/// "Corp can sign you in with single sign-on" with Continue with Corp; when
/// the team requires it, only that (the owner's break-glass password behind
/// a small button).
struct SsoCard: View {
    let hint: SsoHint
    let busy: Bool
    let onContinue: () -> Void
    var onOwnerPassword: (() -> Void)?

    var body: some View {
        let team = (hint.teamName?.isEmpty == false ? hint.teamName : nil) ?? String(localized: "add_account.sso.your_team")
        VStack(alignment: .leading, spacing: 10) {
            Text(hint.enforced ? "add_account.sso.enforced \(team)" : "add_account.sso.available \(team)").font(.callout)
            Button(action: onContinue) {
                Group {
                    if busy { ProgressView() } else { Label("add_account.sso.continue \(team)", systemImage: "person.badge.key") }
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
            .accessibilityIdentifier("sso-continue")
            if let onOwnerPassword {
                Button("add_account.sso.owner_password", action: onOwnerPassword).font(.footnote)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Teams → Single sign-on

/// Owners and admins set the provider (Google Workspace, Microsoft Entra
/// ID, Keycloak, Authentik, any OpenID Connect provider), the redirect URI
/// to register there, a write-only client secret, the rules and the domains
/// with their TXT records to copy or share; members see the summary.
struct TeamSsoView: View {
    let accountId: String
    let teamId: String
    let teamName: String
    let canManage: Bool
    @EnvironmentObject private var model: AppModel
    @State private var settings: SsoSettings?
    @State private var loaded = false
    @State private var form = SsoRules.newForm("generic")
    @State private var domains: [TeamDomainInfo]?
    @State private var newDomain = ""
    @State private var busy = false
    @State private var error: String?
    @State private var message: String?
    @State private var removing = false
    @State private var removingDomain: TeamDomainInfo?

    private var handle: AccountHandle? { try? model.core.account(accountId: accountId) }
    private var canEnforce: Bool { (domains ?? []).contains(where: \.verified) }
    private var redirect: String {
        if let r = settings?.redirectUri, !r.isEmpty { return r }
        return (model.account.account(accountId)?.serverUrl ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1/auth/sso/callback"
    }

    var body: some View {
        Form {
            Text("sso.intro").font(.footnote).foregroundColor(.secondary)
            if !E2eeBook.shared.ssoSupported(accountId) {
                Text("sso.no_public_url")
            } else if !loaded {
                ProgressView()
            } else if !canManage {
                if let s = settings, s.enabled {
                    Text("sso.member_summary \(NSLocalizedString(SsoRules.presetKey(s.preset), comment: "")) \(NSLocalizedString(s.enforce ? "sso.member_enforced" : "sso.member_optional", comment: ""))")
                } else {
                    Text("sso.member_none")
                }
            } else {
                providerSection
                rulesSection
                if let error { Text(verbatim: error).foregroundColor(Brand.red) }
                if let message { Text(verbatim: message).foregroundColor(Brand.green) }
                Section {
                    Button("sso.save") { save() }.disabled(busy).accessibilityIdentifier("sso-save")
                    if settings != nil { Button("sso.remove", role: .destructive) { removing = true } }
                }
                domainsSection
            }
        }
        .navigationTitle(Text("sso.title"))
        .task(id: teamId) { await load() }
        .alert(Text("sso.remove_title"), isPresented: $removing) {
            Button("sso.remove", role: .destructive) { act { try await $0.deleteTeamSso(teamId: teamId); form = SsoRules.newForm("generic"); return String(localized: "sso.removed") } }
            Button("common.cancel", role: .cancel) {}
        } message: { Text("sso.remove_message \(teamName)") }
        .alert(Text("sso.domain.remove_title \(removingDomain?.domain ?? "")"), isPresented: Binding(get: { removingDomain != nil }, set: { if !$0 { removingDomain = nil } })) {
            Button("sso.domain.remove", role: .destructive) {
                guard let d = removingDomain else { return }
                act { try await $0.removeTeamDomain(teamId: teamId, domain: d.domain); return nil }
            }
            Button("common.cancel", role: .cancel) {}
        } message: { Text("sso.domain.remove_message") }
    }

    @ViewBuilder private var providerSection: some View {
        let fields = SsoRules.fields(form.preset)
        Section {
            Picker("sso.field.preset", selection: Binding(get: { form.preset }, set: { form.preset = $0; form.requireEmailVerified = SsoRules.fields($0).requireEmailVerified })) {
                ForEach(SsoRules.presets, id: \.self) { Text(LocalizedStringKey(SsoRules.presetKey($0))).tag($0) }
            }
            Text(LocalizedStringKey(fields.help)).font(.caption).foregroundColor(.secondary)
            copyRow("sso.field.redirect_uri", redirect)
            if fields.issuer { TextField(fields.issuerExample, text: $form.issuer).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled() }
            if fields.tenant { TextField("sso.field.tenant", text: $form.tenant).textInputAutocapitalization(.never).autocorrectionDisabled() }
            TextField("sso.field.client_id", text: $form.clientId).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("sso.field.client_secret", text: $form.clientSecret)
            Text(settings?.hasClientSecret == true ? LocalizedStringKey("sso.field.client_secret_stored") : LocalizedStringKey("sso.field.client_secret_hint"))
                .font(.caption).foregroundColor(.secondary)
            TextField("sso.field.scopes", text: $form.scopes).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("sso.field.email_claim", text: $form.emailClaim).textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: { Text("sso.provider.title") }
    }

    @ViewBuilder private var rulesSection: some View {
        Section {
            Toggle("sso.rule.enabled", isOn: $form.enabled)
            Toggle("sso.rule.email_verified", isOn: $form.requireEmailVerified)
            Toggle("sso.rule.enforce", isOn: Binding(get: { form.enforce && canEnforce }, set: { form.enforce = $0 })).disabled(!canEnforce)
            Text(canEnforce ? LocalizedStringKey("sso.rule.enforce_hint") : LocalizedStringKey("sso.rule.enforce_needs_domain")).font(.caption).foregroundColor(.secondary)
            Toggle("sso.rule.owner_password", isOn: $form.ownerPasswordAllowed)
            Toggle("sso.rule.auto_create", isOn: $form.autoCreate)
            Toggle("sso.rule.auto_join", isOn: $form.autoJoin)
            Toggle("sso.rule.satisfies_2fa", isOn: $form.satisfies2fa)
            Text("sso.rule.satisfies_2fa_hint").font(.caption).foregroundColor(.secondary)
        } header: { Text("sso.rules.title") }
    }

    @ViewBuilder private var domainsSection: some View {
        Section {
            Text("sso.domains.hint").font(.caption).foregroundColor(.secondary)
            if let domains {
                if domains.isEmpty { Text("sso.domains.none").foregroundColor(.secondary) }
                ForEach(domains, id: \.domain) { d in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(verbatim: d.domain).font(.headline)
                            Spacer()
                            switch SsoRules.domainState(verified: d.verified, lastError: d.lastError) {
                            case .verified: Text("sso.domain.verified").font(.caption).foregroundColor(Brand.green)
                            case .failed: Text("sso.domain.failed \(d.lastError ?? "")").font(.caption).foregroundColor(Brand.red).lineLimit(2)
                            case .pending: Text("sso.domain.pending").font(.caption).foregroundColor(Brand.amber)
                            }
                        }
                        if !d.verified {
                            Text("sso.domain.txt_hint").font(.caption)
                            copyRow("sso.domain.txt_name", d.recordName)
                            copyRow("sso.domain.txt_value", d.recordValue)
                            let zone = SsoRules.zoneLine(name: d.recordName, value: d.recordValue)
                            copyRow("sso.domain.txt_zone", zone)
                            ShareLink(item: zone) { Label("ca.install.share", systemImage: "square.and.arrow.up") }
                            Button("sso.domain.verify") { verify(d) }.disabled(busy)
                        }
                        Button("sso.domain.remove", role: .destructive) { removingDomain = d }.font(.footnote)
                    }
                }
            } else {
                ProgressView()
            }
            HStack {
                TextField(String("example.com"), text: $newDomain).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("sso.domain.add") { add() }.disabled(busy || !SsoRules.domainValid(newDomain))
            }
        } header: { Text("sso.domains.title") }
    }

    private func copyRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary)
            HStack {
                Text(verbatim: value).font(.caption.monospaced()).textSelection(.enabled)
                Spacer()
                Button { UIPasteboard.general.string = value; message = String(localized: "sso.copied") } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func load() async {
        guard let h = handle else { return }
        settings = try? await h.teamSso(teamId: teamId)
        if let s = settings {
            form = SsoForm(enabled: s.enabled, preset: s.preset.isEmpty ? "generic" : s.preset, issuer: s.issuer, tenant: s.tenant ?? "", clientId: s.clientId,
                           clientSecret: "", scopes: SsoRules.extraScopes(s.scopes), emailClaim: s.emailClaim ?? "", requireEmailVerified: s.requireEmailVerified,
                           enforce: s.enforce, ownerPasswordAllowed: s.ownerPasswordAllowed, autoCreate: s.autoCreate, autoJoin: s.autoJoin, satisfies2fa: s.satisfies2fa)
        }
        if canManage { domains = (try? await h.teamDomains(teamId: teamId)) ?? [] }
        loaded = true
    }

    private func save() {
        switch SsoRules.check(form, hasSecret: settings?.hasClientSecret == true, canEnforce: canEnforce) {
        case .failure(let e): error = NSLocalizedString(e.key, comment: "")
        case .success(let c):
            let s = SsoSettings(enabled: c.form.enabled, preset: c.form.preset, issuer: c.issuer, tenant: c.tenant, clientId: c.form.clientId, scopes: c.scopes,
                                emailClaim: c.emailClaim, requireEmailVerified: c.form.requireEmailVerified, enforce: c.enforce,
                                ownerPasswordAllowed: c.form.ownerPasswordAllowed, autoCreate: c.form.autoCreate, autoJoin: c.form.autoJoin,
                                satisfies2fa: c.form.satisfies2fa, hasClientSecret: false, redirectUri: "")
            act {
                _ = try await $0.setTeamSso(teamId: teamId, settings: s, clientSecret: c.secret)
                form.clientSecret = ""
                return String(localized: s.enabled ? "sso.saved_on" : "sso.saved")
            }
        }
    }

    private func add() {
        let d = newDomain.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        act { _ = try await $0.addTeamDomain(teamId: teamId, domain: d); newDomain = ""; return String(localized: "sso.domain.added") }
    }

    private func verify(_ d: TeamDomainInfo) {
        act {
            let r = try await $0.verifyTeamDomain(teamId: teamId, domain: d.domain)
            return r.verified ? String(localized: "sso.domain.verified_toast \(d.domain)") : String(localized: "sso.domain.not_yet \(d.domain) \(r.lastError ?? "")")
        }
    }

    private func act(_ f: @escaping (AccountHandle) async throws -> String?) {
        guard let h = handle else { return }
        busy = true
        error = nil
        message = nil
        Task {
            defer { busy = false }
            do { message = try await f(h) } catch { self.error = userMessage(error) }
            await load()
        }
    }
}

extension SsoRules {
    /// Localization key of a preset's name.
    static func presetKey(_ p: String) -> String {
        switch p {
        case "google", "microsoft", "keycloak", "authentik": return "sso.preset." + p
        default: return "sso.preset.generic"
        }
    }
}
