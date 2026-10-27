import Foundation

// End-to-end encrypted vaults (0.7 phase 5c, docs-next/E2EE-SSO-AUDIT.md §2
// and §11): the pure rules of the screens, as the desktop's `e2ee.rs` and
// Android's E2eeRules.kt. No engine types here (unit tested on Linux).

/// The core's answer about a typed recovery phrase (`e2ee_recovery_key_check`).
struct RecoveryCheck: Equatable {
    var valid: Bool
    var reason: String
    var words: Int
    var word: Int
}

/// What a vault says about its end-to-end encryption (`VaultInfo.e2ee`).
struct VaultE2eeFlags: Equatable {
    var keyVersion: UInt32
    var mayHoldKey: Bool
    var hasWrap: Bool
    var rekeyNeeded: Bool
    var pendingMembers: UInt32
}

enum E2eeRules {
    static let words = 24
    /// The shortest E2EE passphrase the core accepts.
    static let minPassphrase = 8

    /// The error codes of E2EE vaults, SSO and the audit (§6): always the app's text.
    static let errorCodes = [
        "e2ee_locked", "e2ee_unlock_required", "e2ee_vault", "e2ee_plaintext_rejected", "e2ee_key_outdated", "e2ee_not_enabled",
        "e2ee_already_enabled", "e2ee_incomplete", "e2ee_stale", "e2ee_wrap_invalid", "e2ee_not_set_up", "e2ee_key_exists",
        "e2ee_key_mismatch", "e2ee_client_required", "e2ee_pairing_closed", "e2ee_passphrase_invalid", "e2ee_passphrase_too_short",
        "e2ee_recovery_key_invalid", "e2ee_decrypt_failed", "sso_required", "sso_not_configured", "sso_issuer_invalid",
        "sso_redirect_invalid", "sso_pkce_invalid", "sso_state_invalid", "sso_code_invalid", "sso_failed", "sso_email_missing",
        "sso_email_unverified", "sso_account_not_found", "sso_account_not_linked", "sso_identity_taken", "sso_domain_taken",
        "sso_domain_unverified", "sso_only_account", "audit_sink_invalid", "invalid_format", "invalid_retention",
    ]

    /// The reasons a recovery phrase is refused (`detail.reason`).
    static let recoveryReasons = ["word_count", "unknown_word", "checksum", "old_format"]

    // ----- The phrase -----

    /// The words of a phrase, numbered from 1.
    static func numberedWords(_ phrase: String) -> [(Int, String)] {
        phrase.split(whereSeparator: { $0.isWhitespace }).enumerated().map { ($0.offset + 1, String($0.element)) }
    }

    /// Three different positions (0-based, sorted) to confirm, from a seed (xorshift64*, as the desktop).
    static func confirmPositions(_ seed: UInt64) -> [Int] {
        var out: [Int] = []
        var x = seed | 1
        while out.count < 3 {
            x ^= x >> 12
            x ^= x << 25
            x ^= x >> 27
            let p = Int((x &* 0x2545_F491_4F6C_DD1D) % UInt64(words))
            if !out.contains(p) { out.append(p) }
        }
        return out.sorted()
    }

    /// A typed word matches: case and spaces don't matter, its first four letters are enough.
    static func wordMatches(_ word: String, _ typed: String) -> Bool {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return word == t || (t.count >= 4 && word.hasPrefix(t))
    }

    static func confirmMatches(_ phrase: String, _ positions: [Int], _ typed: [String]) -> Bool {
        let w = phrase.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard positions.count == typed.count else { return false }
        return zip(positions, typed).allSatisfy { p, t in p < w.count && wordMatches(w[p], t) }
    }

    /// The typed tokens (numbering, punctuation and line breaks ignored).
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// What to say while a recovery phrase is typed.
    enum Feedback: Equatable {
        case empty
        case valid
        /// Words typed so far, nothing wrong yet.
        case typing(Int)
        /// Refused: the core's reason, the word (1-based) and how many were typed.
        case problem(reason: String, word: Int, words: Int)
    }

    /// Live feedback: `check` is the core's `e2ee_recovery_key_check`, `wordlist` its 2048 words (sorted).
    static func feedback(_ text: String, check: (String) -> RecoveryCheck, wordlist: [String]) -> Feedback {
        let toks = tokens(text)
        if toks.isEmpty { return .empty }
        let c = check(text)
        if c.valid { return .valid }
        if c.reason == "word_count" && toks.count < words {
            if let bad = firstUnknownWord(text, wordlist: wordlist) { return .problem(reason: "unknown_word", word: bad, words: toks.count) }
            return .typing(toks.count)
        }
        return .problem(reason: c.reason, word: c.word, words: c.words > 0 ? c.words : toks.count)
    }

    /// The first typed word (1-based) that is no recovery word nor the start of exactly one (the last may be unfinished).
    static func firstUnknownWord(_ text: String, wordlist: [String]) -> Int? {
        let toks = tokens(text)
        let endsOpen = text.last?.isLetter == true
        let set = Set(wordlist)
        for (i, t) in toks.enumerated() {
            let known = set.contains(t) || (t.count >= 4 && wordlist.filter { $0.hasPrefix(t) }.count == 1)
            if known { continue }
            if i == toks.count - 1 && endsOpen && wordlist.contains(where: { $0.hasPrefix(t) }) { continue }
            return i + 1
        }
        return nil
    }

    /// Suggestions for the word being typed (the last token, while the text doesn't end in a space).
    static func suggestions(_ text: String, wordlist: [String], max: Int = 4) -> [String] {
        guard let last = text.last, last.isLetter, let t = tokens(text).last else { return [] }
        let list = wordlist.filter { $0.hasPrefix(t) }
        if list.count == 1 && list[0] == t { return [] }
        return Array(list.prefix(max))
    }

    /// The text with its last (unfinished) word replaced by `word` and a space.
    static func complete(_ text: String, _ word: String) -> String {
        guard let i = text.lastIndex(where: { !$0.isLetter }) else { return word + " " }
        return String(text[...i]) + word + " "
    }

    // ----- Passphrase, pairing -----

    enum Strength: Int, Comparable {
        case tooShort, weak, fair, good, strong
        static func < (a: Strength, b: Strength) -> Bool { a.rawValue < b.rawValue }
    }

    static func strength(_ p: String) -> Strength {
        let len = p.count
        if len < minPassphrase { return .tooShort }
        let classes = [p.contains(where: \.isLowercase), p.contains(where: \.isUppercase), p.contains(where: \.isNumber),
                       p.contains(where: { !$0.isLetter && !$0.isNumber })].filter { $0 }.count
        let wordCount = p.split(whereSeparator: { $0.isWhitespace }).filter { $0.count >= 3 }.count
        if Set(p).count <= 3 { return .weak }
        switch len / 4 + classes + min(wordCount, 4) {
        case ...3: return .weak
        case 4...5: return .fair
        case 6...8: return .good
        default: return .strong
        }
    }

    /// Empty (it is optional) or 8+ characters typed twice the same.
    static func passphraseOk(_ p1: String, _ p2: String, required: Bool) -> Bool {
        p1.isEmpty ? !required : (p1.count >= minPassphrase && p1 == p2)
    }

    /// "9:12" left of a pairing (ms times).
    static func pairingLeft(expiresAt: Int64, now: Int64) -> String {
        let secs = max((expiresAt - now) / 1000, 0)
        return String(format: "%d:%02d", Int(secs / 60), Int(secs % 60))
    }

    /// "482 913": the six digits in two groups.
    static func spacedCode(_ code: String) -> String {
        code.count == 6 ? String(code.prefix(3)) + " " + String(code.suffix(3)) : code
    }

    // ----- Vaults -----

    enum Badge { case none, e2ee, locked }

    /// Locked: this device can't open its secrets yet (not unlocked here, or no key for you yet). Roles without a key are not "locked".
    static func badge(_ e: VaultE2eeFlags?, unlocked: Bool) -> Badge {
        guard let e else { return .none }
        return e.mayHoldKey && (!unlocked || !e.hasWrap) ? .locked : .e2ee
    }

    enum KeyState { case off, holder, noKeyRole, setUpFirst, unlockFirst, waiting }

    static func keyState(_ e: VaultE2eeFlags?, setUp: Bool, unlocked: Bool) -> KeyState {
        guard let e else { return .off }
        if !e.mayHoldKey { return .noKeyRole }
        if !setUp { return .setUpFirst }
        if !e.hasWrap { return .waiting }
        if !unlocked { return .unlockFirst }
        return .holder
    }

    /// This unlocked device rotates a vault flagged `rekey_needed` when it holds its key.
    static func shouldRotate(_ e: VaultE2eeFlags?, unlocked: Bool) -> Bool {
        guard let e else { return false }
        return unlocked && e.rekeyNeeded && e.hasWrap
    }

    /// Members wait for this vault's key and this device holds it.
    static func hasPending(_ e: VaultE2eeFlags?, unlocked: Bool) -> Bool {
        guard let e else { return false }
        return unlocked && e.hasWrap && e.pendingMembers > 0
    }

    // ----- The recovery document -----

    static func documentLines(_ phrase: String) -> [String] {
        let w = numberedWords(phrase)
        return stride(from: 0, to: w.count, by: 4).map { i in
            w[i..<min(i + 4, w.count)].map { n, word in
                let num = n < 10 ? " \(n)" : "\(n)"
                return "\(num). " + word.padding(toLength: 10, withPad: " ", startingAt: 0)
            }.joined(separator: "  ").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
    }

    static func document(_ phrase: String, title: String, account: String, date: String, keep: String) -> String {
        "\(title)\n\n\(account)\n\(date)\n\n" + documentLines(phrase).map { $0 + "\n" }.joined() + "\n\(keep)\n"
    }

    static func printPage(_ phrase: String, title: String, account: String, date: String, keep: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let cells = numberedWords(phrase).map { "<li><span>\($0.0)</span> \(esc($0.1))</li>" }.joined()
        return "<!doctype html><meta charset=utf-8><title>\(esc(title))</title>"
            + "<style>body{font-family:-apple-system,sans-serif;margin:2em;color:#111}"
            + "ol{list-style:none;padding:0;display:grid;grid-template-columns:repeat(4,1fr);gap:.6em 1.2em;font:1.1em ui-monospace,monospace}"
            + "li span{display:inline-block;width:2em;color:#777;text-align:right;margin-right:.4em}p{line-height:1.5}</style>"
            + "<h1>\(esc(title))</h1><p>\(esc(account))<br>\(esc(date))</p><ol>\(cells)</ol><p>\(esc(keep))</p>"
    }
}
