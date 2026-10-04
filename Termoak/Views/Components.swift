import TermoakKit
import SwiftUI

enum Brand {
    static let blue = Color(red: 0x4F / 255, green: 0x7C / 255, blue: 0xFF / 255)
    static let green = Color(red: 0x3F / 255, green: 0xB2 / 255, blue: 0x7F / 255)
    static let amber = Color(red: 0xE8 / 255, green: 0xA3 / 255, blue: 0x3D / 255)
    static let red = Color(red: 0xE5 / 255, green: 0x53 / 255, blue: 0x4B / 255)
    static let terminalBackground = Color(red: 0x12 / 255, green: 0x15 / 255, blue: 0x1D / 255)
    static let terminalBar = Color(red: 0x1A / 255, green: 0x1F / 255, blue: 0x2B / 255)
}

private func rgb(_ hex: UInt32) -> Color {
    Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
}

/// Label and color of a host's detected operating system (like the desktop app).
func osBadge(_ os: String?) -> (String, Color)? {
    guard let os = os?.trimmingCharacters(in: .whitespaces).lowercased(), !os.isEmpty else { return nil }
    switch os {
    case "ubuntu": return ("Ubuntu", rgb(0xE95420))
    case "debian": return ("Debian", rgb(0xD70A53))
    case "raspbian": return ("Raspbian", rgb(0xC51A4A))
    case "linuxmint", "mint": return ("Mint", rgb(0x87CF3E))
    case "fedora": return ("Fedora", rgb(0x51A2DA))
    case "centos": return ("CentOS", rgb(0x932279))
    case "rocky": return ("Rocky", rgb(0x10B981))
    case "almalinux": return ("Alma", rgb(0x0F4266))
    case "rhel": return ("RHEL", rgb(0xEE0000))
    case "arch": return ("Arch", rgb(0x1793D1))
    case "alpine": return ("Alpine", rgb(0x0D597F))
    case "freebsd": return ("FreeBSD", rgb(0xAB2B28))
    case "macos", "darwin": return ("macOS", rgb(0x8E8E93))
    case "windows": return ("Windows", rgb(0x0078D4))
    default: return (os.prefix(1).uppercased() + os.dropFirst(), rgb(0x6B7A99))
    }
}

/// Square with the host's initials and the color of its operating system.
struct HostAvatar: View {
    let name: String
    let os: String?
    var size: CGFloat = 40

    var body: some View {
        let color = osBadge(os)?.1 ?? Brand.blue
        let initials = name.split(whereSeparator: { " -_.".contains($0) }).prefix(2)
            .map { String($0.prefix(1)).uppercased() }.joined()
        RoundedRectangle(cornerRadius: size / 4)
            .fill(color.opacity(0.18))
            .frame(width: size, height: size)
            .overlay(Text(verbatim: initials.isEmpty ? "?" : initials)
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundColor(color))
    }
}

/// Square filled with the color of the host's operating system (like Termius's).
struct HostTile: View {
    let name: String
    let os: String?
    var size: CGFloat = 42

    var body: some View {
        let badge = osBadge(os)
        let text = badge.map { String($0.0.prefix(2)).uppercased() }
            ?? name.split(whereSeparator: { " -_.".contains($0) }).prefix(2).map { String($0.prefix(1)).uppercased() }.joined()
        RoundedRectangle(cornerRadius: size / 4.5, style: .continuous)
            .fill(badge?.1 ?? Brand.blue)
            .frame(width: size, height: size)
            .overlay(Text(verbatim: text.isEmpty ? "?" : text)
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundColor(.white))
    }
}

/// "ssh, user" like Termius (with the port if it is not 22).
func hostSubtitle(_ host: SshHost) -> String {
    var parts = ["ssh"]
    if let u = host.settings.username, !u.isEmpty { parts.append(u) }
    if let p = host.settings.port, p != 22 { parts.append(String(localized: "hosts.subtitle.port \(Int(p))")) }
    return parts.joined(separator: ", ")
}

/// Small chip with a status text.
struct Chip: View {
    let text: String
    let color: Color

    init(_ text: String, _ color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundColor(color)
    }
}

/// Placeholder for an empty list. Texts are already localized.
struct EmptyState: View {
    let icon: String
    let title: String
    let text: String
    var action: String?
    var onTap: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundColor(.accentColor)
                .frame(width: 72, height: 72)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            if let action {
                Button(action, action: onTap).buttonStyle(.borderedProminent).padding(.top, 8)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "5 min ago", "yesterday"... (accepts seconds or milliseconds).
func relativeTime(_ timestamp: Int64?) -> String {
    guard let timestamp, timestamp > 0 else { return "" }
    let seconds = timestamp > 10_000_000_000 ? Double(timestamp) / 1000 : Double(timestamp)
    return relativeTime(Date(timeIntervalSince1970: seconds))
}

func relativeTime(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: Date())
}
