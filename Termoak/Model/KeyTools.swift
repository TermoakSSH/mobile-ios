import Foundation

// Keys on servers (`~/.ssh/authorized_keys`), the text files the file browser
// edits and the QR codes, without the engine's types so the unit tests
// compile this file on its own.

enum AuthorizedKeys {
    /// Where OpenSSH reads them, relative to the home folder.
    static let folder = ".ssh"
    static let file = ".ssh/authorized_keys"

    /// `type base64` of a public key line (`ssh-ed25519 AAAA… comment`),
    /// without the options before it or the comment after: two lines with
    /// the same key match even if their comments differ.
    static func identity(_ line: String) -> String? {
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // The key type is the first word that looks like one (options such as
        // `from="…"` or `no-pty` can come first).
        guard let i = words.firstIndex(where: isKeyType), i + 1 < words.count else { return nil }
        return "\(words[i]) \(words[i + 1])"
    }

    private static func isKeyType(_ word: String) -> Bool {
        word.hasPrefix("ssh-") || word.hasPrefix("ecdsa-sha2-") || word.hasPrefix("sk-")
    }

    /// The file already has this key (any comment or options).
    static func contains(_ existing: String, publicKey: String) -> Bool {
        guard let wanted = identity(publicKey) else { return false }
        return existing.split(whereSeparator: \.isNewline).contains { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            return !l.hasPrefix("#") && identity(l) == wanted
        }
    }

    /// The file with the key added at the end (on its own line).
    static func appending(_ existing: String, publicKey: String) -> String {
        let key = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.isEmpty { return key + "\n" }
        let separator = existing.hasSuffix("\n") ? "" : "\n"
        return existing + separator + key + "\n"
    }
}

enum TextFiles {
    /// The largest file the editor opens (1 MiB).
    static let maxBytes: UInt64 = 1 << 20

    /// Text the editor can show and save back as it was: valid UTF-8 without
    /// NUL bytes. `nil` for anything else (binary files).
    static func decode(_ data: Data) -> String? {
        if data.contains(0) { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A path typed in "Go to": absolute as it is, `~` and `~/x` from the
    /// home folder, anything else inside the folder on screen. Trailing
    /// slashes go away; `nil` for an empty path.
    static func resolve(_ typed: String, current: String, home: String) -> String? {
        var t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t == "~" {
            t = home
        } else if t.hasPrefix("~/") {
            t = RemotePaths.child(home, String(t.dropFirst(2)))
        } else if !t.hasPrefix("/") {
            t = RemotePaths.child(current.isEmpty ? "/" : current, t)
        }
        while t.count > 1 && t.hasSuffix("/") { t.removeLast() }
        return t
    }
}
