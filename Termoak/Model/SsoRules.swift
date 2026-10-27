import Foundation

// Single sign-on in the app (0.7 phase 5c, docs-next/E2EE-SSO-AUDIT.md §3):
// the callback `termoak://sso` (ASWebAuthenticationSession with the callback
// scheme `termoak`), the team's provider presets and form, domains and
// their TXT records, and the PKCE of linking an identity (`POST
// /me/sso/link`: the engine has no call for it; the server links it when
// the browser comes back). No engine types here (unit tested on Linux).

/// A team's SSO settings as the form edits them (the engine's `SsoSettings` fields).
struct SsoForm: Equatable {
    var enabled = true
    var preset = "generic"
    var issuer = ""
    var tenant = ""
    var clientId = ""
    var clientSecret = ""
    var scopes = ""
    var emailClaim = ""
    var requireEmailVerified = true
    var enforce = false
    var ownerPasswordAllowed = true
    var autoCreate = true
    var autoJoin = true
    var satisfies2fa = false
}

/// What the form sends: the settings' values (scopes with the base ones) and the secret (`nil`: keep the stored one).
struct SsoChecked: Equatable {
    var form: SsoForm
    var issuer: String
    var tenant: String?
    var scopes: [String]
    var emailClaim: String?
    var enforce: Bool
    var secret: String?
}

enum SsoRules {
    /// Where the browser comes back to (`CFBundleURLSchemes` has `termoak`).
    static let redirect = "termoak://sso"
    static let callbackScheme = "termoak"

    static func isCallback(_ url: String?) -> Bool {
        guard let u = url?.trimmingCharacters(in: .whitespaces) else { return false }
        return u == redirect || u.hasPrefix(redirect + "?") || u.hasPrefix(redirect + "/")
    }

    /// The query of a callback URL.
    static func query(_ url: String) -> [String: String] {
        guard let c = URLComponents(string: url.trimmingCharacters(in: .whitespaces)) else { return [:] }
        var out: [String: String] = [:]
        for item in c.queryItems ?? [] { out[item.name] = item.value ?? "" }
        return out
    }

    enum LinkResult: Equatable {
        case linked
        case failed(String)
    }

    /// What came back for a link: done, or the error code it names (the state must be ours).
    static func linkResult(_ callback: String, state: String) -> LinkResult {
        let q = query(callback)
        if q["state"] != state { return .failed("sso_state_invalid") }
        if let e = q["error"], !e.isEmpty { return .failed(e) }
        return (q["code"] ?? "").isEmpty ? .failed("sso_failed") : .linked
    }

    // ----- PKCE of a link -----

    static func base64url(_ data: [UInt8]) -> String {
        Data(data).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A random token (32 bytes, base64url).
    static func token() -> String {
        var g = SystemRandomNumberGenerator()
        return base64url((0..<32).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    /// S256 challenge of a verifier (RFC 7636).
    static func challenge(_ verifier: String) -> String { base64url(Sha256.hash(Array(verifier.utf8))) }

    /// The body of `POST /me/sso/link`.
    static func linkBody(teamId: String, state: String, verifier: String, deviceName: String) -> String {
        let o: [String: String] = [
            "team_id": teamId, "redirect_uri": redirect, "state": state, "code_challenge": challenge(verifier),
            "code_challenge_method": "S256", "device_name": deviceName, "platform": "ios",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // ----- Team settings -----

    static let presets = ["google", "microsoft", "keycloak", "authentik", "generic"]

    struct PresetFields: Equatable {
        var issuer: Bool
        var tenant: Bool
        var issuerExample: String
        var requireEmailVerified: Bool
        /// Localization key of its setup steps.
        var help: String
    }

    static func fields(_ preset: String) -> PresetFields {
        switch preset {
        case "google": return PresetFields(issuer: false, tenant: false, issuerExample: "https://accounts.google.com", requireEmailVerified: true, help: "sso.help.google")
        case "microsoft": return PresetFields(issuer: false, tenant: true, issuerExample: "https://login.microsoftonline.com/<tenant>/v2.0", requireEmailVerified: false, help: "sso.help.microsoft")
        case "keycloak": return PresetFields(issuer: true, tenant: false, issuerExample: "https://sso.example.com/realms/example", requireEmailVerified: true, help: "sso.help.keycloak")
        case "authentik": return PresetFields(issuer: true, tenant: false, issuerExample: "https://auth.example.com/application/o/termoak/", requireEmailVerified: true, help: "sso.help.authentik")
        default: return PresetFields(issuer: true, tenant: false, issuerExample: "https://idp.example.com", requireEmailVerified: true, help: "sso.help.generic")
        }
    }

    static let baseScopes = ["openid", "email", "profile"]

    /// A new form for a preset (its email-verified default).
    static func newForm(_ preset: String) -> SsoForm {
        var f = SsoForm()
        f.preset = preset
        f.requireEmailVerified = fields(preset).requireEmailVerified
        return f
    }

    /// The extra scopes of stored settings, for the form.
    static func extraScopes(_ scopes: [String]) -> String { scopes.filter { !baseScopes.contains($0) }.joined(separator: " ") }

    /// The values to send, or the localization key of what is missing.
    static func check(_ f: SsoForm, hasSecret: Bool, canEnforce: Bool) -> Result<SsoChecked, SsoFormError> {
        let fl = fields(f.preset)
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if trim(f.clientId).isEmpty { return .failure(SsoFormError(key: "sso.form.client_id_required")) }
        if fl.tenant && trim(f.tenant).isEmpty { return .failure(SsoFormError(key: "sso.form.tenant_required")) }
        if fl.issuer && trim(f.issuer).isEmpty { return .failure(SsoFormError(key: "sso.form.issuer_required")) }
        if f.preset == "google" && trim(f.clientSecret).isEmpty && !hasSecret { return .failure(SsoFormError(key: "sso.form.secret_required_google")) }
        var scopes = baseScopes
        for s in f.scopes.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init) where !scopes.contains(s) { scopes.append(s) }
        var form = f
        form.clientId = trim(f.clientId)
        return .success(SsoChecked(
            form: form, issuer: fl.issuer ? trim(f.issuer) : "", tenant: fl.tenant ? (trim(f.tenant).isEmpty ? nil : trim(f.tenant)) : nil,
            scopes: scopes, emailClaim: trim(f.emailClaim).isEmpty ? nil : trim(f.emailClaim), enforce: f.enforce && canEnforce,
            secret: trim(f.clientSecret).isEmpty ? nil : trim(f.clientSecret)
        ))
    }

    /// The TXT record as a zone file line.
    static func zoneLine(name: String, value: String) -> String { "\(name). 300 IN TXT \"\(value)\"" }

    /// A domain name a team can claim.
    static func domainValid(_ d: String) -> Bool {
        var t = d.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasSuffix(".") { t.removeLast() }
        guard (3...253).contains(t.count), t.contains(".") else { return false }
        return t.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { l in
            !l.isEmpty && l.count <= 63 && l.allSatisfy { ($0.isLetter || $0.isNumber) && $0.isASCII || $0 == "-" } && !l.hasPrefix("-") && !l.hasSuffix("-")
        }
    }

    enum DomainState { case verified, failed, pending }

    static func domainState(verified: Bool, lastError: String?) -> DomainState {
        if verified { return .verified }
        if let e = lastError, !e.isEmpty { return .failed }
        return .pending
    }

    /// Worth asking the server about (something@domain.tld).
    static func looksLikeEmail(_ e: String) -> Bool {
        guard let at = e.firstIndex(of: "@"), at > e.startIndex else { return false }
        let domain = e[e.index(after: at)...]
        guard let dot = domain.firstIndex(of: "."), dot > domain.startIndex else { return false }
        return !e.hasSuffix(".") && !e.contains(where: \.isWhitespace)
    }
}

struct SsoFormError: Error, Equatable {
    /// Localization key.
    let key: String
}

/// SHA-256 (FIPS 180-4) in plain Swift: the PKCE challenge, and the unit
/// tests' fingerprints and pairing codes (CryptoKit isn't on Linux).
enum Sha256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var m = message
        let bits = UInt64(message.count) &* 8
        m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        for i in (0..<8).reversed() { m.append(UInt8(truncatingIfNeeded: bits >> (UInt64(i) * 8))) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: m.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(m[b]) << 24 | UInt32(m[b + 1]) << 16 | UInt32(m[b + 2]) << 8 | UInt32(m[b + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - UInt32($0) * 8)) } }
    }
}
