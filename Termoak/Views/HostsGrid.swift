import TermoakKit
import SwiftUI

// Pieces of the hosts grid of the desktop layout (iPad, regular width), like
// the desktop app's Hosts view: cards in a grid under the group chips. The
// list itself (what is shown, the actions) is HostsView's.

/// "user@address" (with ":port" when it is not the protocol's default), as
/// the desktop app shows a host.
func hostAddressLine(_ host: SshHost) -> String {
    var line = host.address
    if let u = host.settings.username, !u.isEmpty { line = "\(u)@\(line)" }
    if let p = host.settings.port, p != HostProtocol.defaultPort(host.protocol) { line += ":\(p)" }
    return line
}

/// A host in the grid: avatar, name (⭐ for favorites), user@address, the
/// system's badge, its vault and its tags, and a "⋯" button with the same
/// menu as the context menu. A tap connects (or selects, while selecting).
struct HostCard<MenuItems: View>: View {
    let host: SshHost
    /// Highlighted with the hardware keyboard.
    var highlighted = false
    var selecting = false
    var selected = false
    /// Several accounts on screen: the host's account.
    var account: AccountInfo? = nil
    /// Several vaults on screen: the host's vault.
    var vault: VaultInfo? = nil
    /// Show the vault chip (or "This device").
    var showVault = false
    /// A terminal to it is open: a green dot on its icon.
    var connected = false
    /// A tag was tapped (to filter the grid by it).
    var onTag: ((String) -> Void)? = nil
    let onTap: () -> Void
    @ViewBuilder let menuItems: () -> MenuItems

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        if selecting {
            button.accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            button
                .overlay(alignment: .topTrailing) {
                    Menu { menuItems() } label: {
                        Image(systemName: "ellipsis")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("terminal.more")
                    .padding(4)
                }
                .contextMenu { menuItems() }
        }
    }

    private var button: some View {
        Button(action: onTap) { card }.buttonStyle(.plain)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(selected ? .accentColor : .secondary)
                }
                HostIcon(host: host, size: 40)
                    .overlay(alignment: .bottomTrailing) { if connected { ConnectedDot() } }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(host.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if host.favorite { Image(systemName: "star.fill").font(.caption2).foregroundColor(Brand.amber) }
                        if host.isUseOnly {
                            Image(systemName: "lock.fill").font(.caption2).foregroundColor(Brand.amber)
                                .accessibilityLabel(Text("vaults.use_only_badge"))
                        }
                    }
                    Text(verbatim: hostAddressLine(host))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let account { AccountAvatar(account: account, size: 18) }
                // Room for the "⋯" button over the card.
                if !selecting { Color.clear.frame(width: 26, height: 1) }
            }
            badges
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: shape)
        .overlay(shape.strokeBorder(borderColor, lineWidth: highlighted || selected ? 2 : 1))
        .contentShape(shape)
        .hoverEffect(.highlight)
    }

    private var borderColor: Color {
        highlighted || selected ? Color.accentColor : Color(.separator).opacity(0.6)
    }

    /// "Telnet" (unencrypted), the system's badge (or "SSH"), the vault and
    /// the first tags.
    private var badges: some View {
        HStack(spacing: 4) {
            if host.isTelnet { TelnetBadge() }
            if let badge = osBadge(host.os) {
                SmallBadge(text: badge.0, color: badge.1)
            } else if !host.isTelnet {
                SmallBadge(text: "SSH", color: Brand.blue)
            }
            if showVault && (vault != nil || host.accountId == nil) { VaultChip(vault: vault) }
            if host.isUseOnly { UseOnlyBadge() }
            ForEach(Array(host.tags.prefix(3).enumerated()), id: \.offset) { _, tag in
                TappableTag(text: tag, onTap: selecting ? nil : onTag)
            }
            if host.tags.count > 3 { TagChip(text: "+\(host.tags.count - 3)") }
        }
        .lineLimit(1)
    }
}

/// Small rectangular badge in a color (the host's system, like the desktop's).
struct SmallBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// A chip of the bar above the grid: "Production · 4".
struct FilterChip: View {
    let title: String
    let count: Int
    var symbol: String? = nil
    var tint: Color = .accentColor
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.caption) }
                Text(verbatim: "\(title) · \(count)").lineLimit(1)
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .foregroundColor(selected ? .white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? tint : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Search field of the desktop headers (with a clear button).
struct DesktopSearchField: View {
    let prompt: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(focused)
                .submitLabel(.search)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("common.clear")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Title of a group in the grid: folder, name, how many hosts and its menu.
struct GridGroupHeader<MenuItems: View>: View {
    let title: String
    let count: Int
    var color: Color = .accentColor
    var account: AccountInfo? = nil
    var vault: VaultInfo? = nil
    /// The "⋯" menu (groups you can change).
    var showsMenu = true
    @ViewBuilder let menuItems: () -> MenuItems

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundColor(color)
            Text(verbatim: title).font(.headline).lineLimit(1)
            Text("hosts.group.count \(count)").font(.caption).foregroundColor(.secondary)
            if let vault { VaultChip(vault: vault) }
            if let account { AccountAvatar(account: account, size: 18) }
            if showsMenu {
                Menu { menuItems() } label: {
                    Image(systemName: "ellipsis")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("terminal.more")
            }
            Spacer(minLength: 0)
        }
    }
}

/// Label of a button of the desktop headers: icon and title on a rounded
/// background (filled with the accent color for the main one).
struct HeaderButtonLabel: View {
    let title: String
    let symbol: String
    var prominent = false
    /// Narrow window: only the icon (the title is for VoiceOver).
    var iconOnly = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: symbol)
            if !iconOnly { Text(verbatim: title).lineLimit(1) }
        }
        .font(.subheadline.weight(.medium))
        .foregroundColor(prominent ? .white : .primary)
        .padding(.horizontal, iconOnly ? 9 : 12)
        .frame(minWidth: 34, minHeight: 34)
        .background(prominent ? Color.accentColor : Color(.tertiarySystemFill), in: shape)
        .contentShape(shape)
        .accessibilityLabel(Text(verbatim: title))
    }
}
