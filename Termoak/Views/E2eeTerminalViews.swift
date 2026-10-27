import TermoakKit
import SwiftUI

/// The card of a terminal to an end-to-end encrypted host (0.7 phase 5c):
/// Unlock (this device can't open the host's credentials yet; connects
/// again after), or "Send this host's credentials for this session?" for a
/// server session (the server uses them for that session only, audited
/// `e2ee.unlock`).
struct TerminalE2eeCard: View {
    let session: TerminalSession
    let need: E2eeNeed
    var onClose: () -> Void
    @EnvironmentObject private var model: AppModel
    @State private var unlocking = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.system(size: 40)).foregroundColor(Brand.amber)
            Text(need == .send ? LocalizedStringKey("vault_e2ee.session.title") : LocalizedStringKey("vault_e2ee.locked_card.title"))
                .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(need == .send ? LocalizedStringKey("vault_e2ee.session.text") : LocalizedStringKey("error.e2ee_locked"))
                .font(.subheadline).multilineTextAlignment(.center).foregroundColor(.secondary)
            if need == .send { Text("vault_e2ee.session.hint").font(.caption).multilineTextAlignment(.center).foregroundColor(.secondary) }
            HStack(spacing: 12) {
                Button("common.close", action: onClose).buttonStyle(.bordered)
                if need == .send {
                    Button("vault_e2ee.session.send") { (session as? ServerTerminal)?.sendCredentialsAndConnect() }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("e2ee-send")
                } else {
                    Button("e2ee.unlock.button") { unlocking = true }.buttonStyle(.borderedProminent).disabled(session.accountId == nil)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
        .padding()
        .sheet(isPresented: $unlocking) {
            if let id = session.accountId {
                UnlockView(accountId: id) {
                    unlocking = false
                    if E2eeBook.shared.unlocked(id) { session.e2eeUnlocked() }
                }
                .environmentObject(model)
                .environmentObject(model.account)
            }
        }
    }
}
