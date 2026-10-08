import TermoakKit
import Combine
import Foundation

/// The aliases of your accounts and "Hide email addresses" (Settings), as
/// the engine's rules take them (`accountDisplayName`, `maskEmail`...).
/// One shared copy, kept up to date by `AppModel` from `AppSettings`, so
/// any view can name an account without needing the settings around.
@MainActor
final class AccountNamesStore: ObservableObject {
    static let shared = AccountNamesStore()
    @Published var names = AccountNames()
}

extension AccountInfo {
    /// Its alias, or its email (masked when emails are hidden).
    @MainActor var displayName: String {
        accountDisplayName(names: AccountNamesStore.shared.names, accountId: id, email: email)
    }

    /// Its email as shown (masked when emails are hidden).
    @MainActor var displayEmail: String {
        accountDisplayEmail(names: AccountNamesStore.shared.names, email: email)
    }

    /// The name, followed by " · ssh.example.com" for a server that is not
    /// the official one.
    @MainActor var displayLabel: String {
        accountDisplayLabel(names: AccountNamesStore.shared.names, accountId: id, email: email, server: serverLabel)
    }

    /// The alias given to it on this device.
    @MainActor var alias: String? { AccountNamesStore.shared.names.aliases[id] }

    /// Letter of its avatar (from the alias, the name or the email).
    @MainActor var initial: String {
        accountInitial(names: AccountNamesStore.shared.names, accountId: id, name: name, email: email)
    }
}
