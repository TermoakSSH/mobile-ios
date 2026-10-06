import TermoakKit
import SwiftUI

// Small pieces shared by the screens that show accounts and vaults.

/// Round avatar of an account: its initial on its color.
struct AccountAvatar: View {
    let account: AccountInfo
    var size: CGFloat = 28

    var body: some View {
        Circle()
            .fill(accountColor(account))
            .frame(width: size, height: size)
            .overlay(
                Text(verbatim: account.initial)
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            )
            .accessibilityLabel(Text(verbatim: account.email))
    }
}

/// The account's color, or one of the palette that is always the same for
/// the same email.
func accountColor(_ a: AccountInfo) -> Color {
    if let c = hexColor(a.color) { return c }
    let seed = a.email.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    return hexColor(String(format: "#%06x", hostPalette[seed % hostPalette.count])) ?? Brand.blue
}

/// Color of a vault (its own, or the brand's).
func vaultColor(_ v: VaultInfo?) -> Color {
    hexColor(v?.color) ?? (v?.kind == .personal ? Brand.blue : Color.purple)
}

/// Small capsule with a vault's icon and name ("This device" without one).
struct VaultChip: View {
    let vault: VaultInfo?
    var small = true

    var body: some View {
        let tint = vault == nil ? Color.secondary : vaultColor(vault)
        HStack(spacing: 3) {
            Image(systemName: vault.map { vaultSymbol($0.icon, kind: $0.kind) } ?? "iphone")
            Text(verbatim: vault?.displayName ?? String(localized: "accounts.this_device")).lineLimit(1)
        }
        .font(small ? .caption2.weight(.semibold) : .caption.weight(.semibold))
        .foregroundColor(tint)
        .padding(.horizontal, small ? 6 : 8)
        .padding(.vertical, small ? 2 : 4)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

/// "Use only": you can connect, never see the secrets nor change it.
struct UseOnlyBadge: View {
    var body: some View {
        Label("vaults.use_only_badge", systemImage: "lock.fill")
            .font(.caption2.weight(.semibold))
            .foregroundColor(Brand.amber)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Brand.amber.opacity(0.14), in: Capsule())
    }
}

/// Picker of where to save a new item (This device or a vault).
struct PlacePicker: View {
    @EnvironmentObject private var account: Accounts
    @Binding var place: ItemPlace

    var body: some View {
        Picker("vaults.save_in", selection: $place) {
            ForEach(account.places) { p in
                Text(verbatim: account.placeTitle(p)).tag(p)
            }
        }
    }
}

/// The account switcher at the top of the hosts: each account, All
/// accounts, This device only, Add account, Manage accounts and Vaults.
struct AccountSwitcher: View {
    @EnvironmentObject private var account: Accounts
    let onAdd: () -> Void
    let onManage: () -> Void
    let onVaults: () -> Void

    var body: some View {
        Menu {
            Section {
                ForEach(account.list, id: \.id) { a in
                    Button { account.setScope(.account(a.id)) } label: {
                        let text = a.serverLabel.map { "\(a.email) · \($0)" } ?? a.email
                        if account.scope == .account(a.id) {
                            Label(text, systemImage: "checkmark")
                        } else if a.status != .active {
                            Label(text, systemImage: "exclamationmark.circle")
                        } else {
                            Text(verbatim: text)
                        }
                    }
                }
                if account.list.count > 1 {
                    Button { account.setScope(.all) } label: {
                        if account.scope == .all {
                            Label("accounts.all", systemImage: "checkmark")
                        } else {
                            Text("accounts.all")
                        }
                    }
                }
                Button { account.setScope(.device) } label: {
                    if account.scope == .device || account.list.isEmpty {
                        Label("accounts.device_only", systemImage: "checkmark")
                    } else {
                        Text("accounts.device_only")
                    }
                }
            }
            Section {
                Button(action: onAdd) { Label("accounts.add", systemImage: "person.crop.circle.badge.plus") }
                if !account.list.isEmpty {
                    Button(action: onManage) { Label("accounts.manage", systemImage: "person.2") }
                }
                if account.list.contains(where: \.vaultsSupported) {
                    Button(action: onVaults) { Label("vaults.title", systemImage: "lock.shield") }
                }
            }
        } label: {
            label
        }
        .accessibilityLabel("accounts.switcher")
    }

    @ViewBuilder private var label: some View {
        switch account.scope {
        case .account(let id):
            if let a = account.account(id) {
                AccountAvatar(account: a, size: 28)
            } else {
                Image(systemName: "person.crop.circle")
            }
        case .all:
            if account.list.count > 1 {
                Image(systemName: "person.2.circle")
            } else if let a = account.list.first {
                AccountAvatar(account: a, size: 28)
            } else {
                Image(systemName: "iphone")
            }
        case .device:
            Image(systemName: "iphone")
        }
    }
}

/// Vault chips above the hosts: All, each vault, This device.
struct VaultFilterBar: View {
    @EnvironmentObject private var account: Accounts
    /// Device items exist (the "This device" chip).
    let hasDeviceItems: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(String(localized: "vaults.filter.all"), symbol: "square.grid.2x2", tint: Brand.blue, selected: account.vaultFilter == .all) {
                    account.vaultFilter = .all
                }
                ForEach(account.scopedVaults, id: \.key) { v in
                    let title = account.showsAccountBadges
                        ? "\(v.displayName) · \(account.account(v.accountId)?.email ?? "")" : v.displayName
                    chip(title, symbol: vaultSymbol(v.icon, kind: v.kind), tint: vaultColor(v),
                         selected: account.vaultFilter == .vault(accountId: v.accountId, vaultId: v.id)) {
                        account.vaultFilter = .vault(accountId: v.accountId, vaultId: v.id)
                    }
                }
                if hasDeviceItems {
                    chip(String(localized: "accounts.this_device"), symbol: "iphone", tint: .secondary,
                         selected: account.vaultFilter == .device) {
                        account.vaultFilter = .device
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func chip(_ title: String, symbol: String, tint: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(verbatim: title).lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(selected ? .white : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? tint : tint.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
