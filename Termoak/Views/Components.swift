import TermoakKit
import SwiftUI
import UIKit

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

/// Colors a host can be given (the same as the desktop's host editor).
private let hostPalette: [UInt32] = [0x4F7CFF, 0x30A46C, 0xF5A524, 0xE5484D, 0x8E4EC6, 0x0EA5E9, 0xD6409F, 0x12A594]

/// `#rrggbb` (or `rrggbb`) as a color; `nil` if it is not one.
func hexColor(_ hex: String?) -> Color? {
    guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
    return rgb(value)
}

/// A color of the palette that is always the same for the same name.
private func paletteColor(_ name: String) -> Color {
    let seed = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    return rgb(hostPalette[seed % hostPalette.count])
}

/// SF Symbol of the systems that have a fitting one; the rest show the
/// initials of their name.
private func osSymbol(_ os: String?) -> String? {
    guard let os = os?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
    switch os {
    case "macos", "darwin", "ios": return "applelogo"
    case "windows": return "squareshape.split.2x2"
    case "linux": return "terminal.fill"
    default: return nil
    }
}

/// Avatar of a host on the home screens, like Termius's: a rounded square in
/// the host's color (or its system's), with the system's symbol or initials,
/// or else the first letter of its name.
struct HostIcon: View {
    let label: String
    let os: String?
    let color: String?
    let size: CGFloat

    init(host: SshHost, size: CGFloat = 42) {
        label = host.label.isEmpty ? host.address : host.label
        os = host.os
        color = host.color
        self.size = size
    }

    init(label: String, os: String?, color: String? = nil, size: CGFloat = 42) {
        self.label = label
        self.os = os
        self.color = color
        self.size = size
    }

    var body: some View {
        let badge = osBadge(os)
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        shape
            .fill(hexColor(color) ?? badge?.1 ?? paletteColor(label))
            .overlay(shape.fill(LinearGradient(gradient: Gradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0)]),
                                               startPoint: .top, endPoint: .bottom)))
            .frame(width: size, height: size)
            .overlay(glyph(badge))
            .accessibilityHidden(true)
    }

    @ViewBuilder private func glyph(_ badge: (String, Color)?) -> some View {
        if let symbol = osSymbol(os) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(.white)
        } else if let badge {
            Text(verbatim: String(badge.0.prefix(2)).uppercased())
                .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        } else {
            Text(verbatim: initial)
                .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
    }

    private var initial: String {
        label.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }
}

/// Small gray capsule with a host tag.
struct TagChip: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundColor(.secondary)
            .background(Color(.tertiarySystemFill), in: Capsule())
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

/// Round avatar of a person in a shared session: their initials on a color
/// that is always the same for the same name.
struct ParticipantAvatar: View {
    let name: String
    var size: CGFloat = 36

    var body: some View {
        let initials = name.split(whereSeparator: { $0 == " " }).prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }.joined()
        Circle()
            .fill(paletteColor(name))
            .frame(width: size, height: size)
            .overlay(Text(verbatim: initials.isEmpty ? "?" : initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundColor(.white))
            .accessibilityHidden(true)
    }
}

/// System share sheet for links and text.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
