import Foundation

// Host logos, like the desktop app's (src/logos.rs): a host's avatar shows
// its chosen logo (`SshHost.icon`), else the logo of the system detected
// when connecting (`SshHost.os`), else its colored initial.
//
// Two families:
// - systems: white logos drawn on the system's color, in the asset catalog
//   (`HostLogo/<id>`, vector SVGs rendered as templates). The paths come from
//   Simple Icons (https://simpleicons.org, CC0 1.0); the Windows one is
//   drawn by hand. The logos are trademarks of their owners and only
//   identify each system.
// - generic: SF Symbols (server, database, router...).
//
// The ids are stored in the host and synced: never rename one. An id this
// version does not know (a later app's) falls back to the automatic logo.

struct HostLogo: Equatable, Identifiable {
    enum Kind: Equatable {
        /// `HostLogo/<id>` in the asset catalog.
        case system
        /// An SF Symbol.
        case generic(symbol: String)
    }

    /// Stored in `SshHost.icon`.
    let id: String
    /// Name of a system (not translated); generic ones are translated
    /// (`logo.<id>`).
    let systemName: String
    /// Background of the avatar (`0xrrggbb`).
    let color: UInt32
    let kind: Kind

    var isSystem: Bool { kind == .system }
    /// Name of the image in the asset catalog (systems).
    var assetName: String { "HostLogo/\(id)" }

    private static func system(_ id: String, _ name: String, _ color: UInt32) -> HostLogo {
        HostLogo(id: id, systemName: name, color: color, kind: .system)
    }

    private static func generic(_ id: String, _ symbol: String, _ color: UInt32) -> HostLogo {
        HostLogo(id: id, systemName: "", color: color, kind: .generic(symbol: symbol))
    }

    /// Every logo, in the order of the picker (the desktop's).
    static let all: [HostLogo] = [
        system("ubuntu", "Ubuntu", 0xE95420),
        system("debian", "Debian", 0xD70A53),
        system("fedora", "Fedora", 0x3C6EB4),
        system("rhel", "Red Hat", 0xEE0000),
        system("centos", "CentOS", 0x9C27B0),
        system("rocky", "Rocky Linux", 0x10B981),
        system("alma", "AlmaLinux", 0x0F4266),
        system("arch", "Arch Linux", 0x1793D1),
        system("manjaro", "Manjaro", 0x35BF5C),
        system("endeavouros", "EndeavourOS", 0x7F3FBF),
        system("alpine", "Alpine", 0x0D597F),
        system("opensuse", "openSUSE", 0x73BA25),
        system("suse", "SUSE", 0x30BA78),
        system("mint", "Linux Mint", 0x87CF3E),
        system("popos", "Pop!_OS", 0x48B9C7),
        system("elementary", "elementary OS", 0x64BAFF),
        system("zorin", "Zorin OS", 0x15A6F0),
        system("kali", "Kali", 0x367BF0),
        system("gentoo", "Gentoo", 0x54487A),
        system("nixos", "NixOS", 0x5277C3),
        system("void", "Void Linux", 0x478061),
        system("raspberrypi", "Raspberry Pi", 0xC51A4A),
        system("linux", "Linux", 0xF5A524),
        system("freebsd", "FreeBSD", 0xAB2B28),
        system("macos", "macOS", 0x8E8E93),
        system("windows", "Windows", 0x0078D4),
        // SF Symbols available since iOS 14.
        generic("server", "server.rack", 0x4F7CFF),
        generic("database", "cylinder.split.1x2", 0x12A594),
        generic("router", "network", 0x0EA5E9),
        generic("firewall", "flame", 0xE5484D),
        generic("cloud", "cloud", 0x3B82F6),
        generic("container", "shippingbox", 0x1D63ED),
        generic("kubernetes", "helm", 0x326CE5),
        generic("web", "globe", 0x30A46C),
        generic("mail", "envelope", 0xD6409F),
        generic("storage", "internaldrive", 0x8E4EC6),
        generic("terminal", "terminal", 0x475569),
        generic("iot", "cpu", 0xF5A524),
        generic("security", "lock", 0xBF8700),
    ]

    static var systems: [HostLogo] { all.filter(\.isSystem) }
    static var generics: [HostLogo] { all.filter { !$0.isSystem } }

    /// The logo with this id (as stored in `SshHost.icon`).
    static func byId(_ id: String) -> HostLogo? {
        let id = id.trimmingCharacters(in: .whitespaces).lowercased()
        return all.first { $0.id == id }
    }

    /// The logo of a detected system (the `ID` of `/etc/os-release`, or
    /// `macos`, `windows`...).
    static func forOs(_ os: String) -> HostLogo? {
        let os = os.trimmingCharacters(in: .whitespaces).lowercased()
        let id: String
        switch os {
        case "devuan": id = "debian"
        case "raspbian": id = "raspberrypi"
        case "linuxmint": id = "mint"
        case "pop": id = "popos"
        case "nobara": id = "fedora"
        case "redhat": id = "rhel"
        case "almalinux": id = "alma"
        case "artix", "garuda", "archarm": id = "arch"
        case "postmarketos": id = "alpine"
        case "opensuse-leap", "opensuse-tumbleweed", "opensuse-microos": id = "opensuse"
        case "sles", "sled": id = "suse"
        case "darwin", "osx": id = "macos"
        default: id = os
        }
        // A generic id would make "server" look detected.
        guard let logo = byId(id), logo.isSystem else { return nil }
        return logo
    }

    /// What a host shows: its chosen logo, else its system's, else none (the
    /// initial).
    static func resolve(icon: String?, os: String?) -> HostLogo? {
        if let icon, let logo = byId(icon) { return logo }
        if let os, let logo = forOs(os) { return logo }
        return nil
    }
}
