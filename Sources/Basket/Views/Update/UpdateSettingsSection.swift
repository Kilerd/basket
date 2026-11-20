import SwiftUI
import BasketCore

/// Settings ▸ Updates: the daily check and "Check Now"; disabled with the reason for copies that
/// can't update themselves.
struct UpdateSettingsSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let updates = store.updates
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updates.isAvailable && updates.automaticallyChecks },
                set: { updates.automaticallyChecks = $0 }))
                .disabled(!updates.isAvailable)
                .accessibilityIdentifier("settings.updates.automatic")
            LabeledContent("Basket \(updates.currentVersionText)") {
                Button("Check Now") {
                    openWindow(id: "main")
                    NSApp.activate()
                    updates.checkForUpdates()
                }
                .disabled(!updates.isAvailable || updates.isBusy)
                .accessibilityIdentifier("settings.updates.check")
            }
            Text(status(updates))
                .font(.caption)
                .foregroundStyle(updates.isAvailable ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.updates.status")
        }
    }

    private func status(_ updates: UpdateController) -> String {
        if let reason = updates.unavailableReason { return reason }
        var text = "Basket checks GitHub Releases once a day and installs an update only after verifying its signature."
        if let offer = updates.offer {
            text += " Basket \(offer.version) is available."
        } else if let last = updates.lastChecked {
            text += " Last checked \(last.formatted(.relative(presentation: .named)))."
        }
        return text
    }
}

/// App menu ▸ Check for Updates…
struct UpdateCommands: Commands {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                openWindow(id: "main")
                NSApp.activate()
                store.updates.checkForUpdates()
            }
        }
    }
}
