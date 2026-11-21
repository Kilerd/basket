import SwiftUI
import BasketCore

/// Settings ▸ Updates: the daily check and "Check Now"; disabled with the reason for copies that
/// can't update themselves.
struct UpdateSettingsSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let updates = store.updates
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updates.isAvailable && updates.automaticallyChecks },
                set: { updates.automaticallyChecks = $0 }))
                .disabled(!updates.isAvailable)
                .accessibilityIdentifier("settings.updates.automatic")
            LabeledContent("Basket \(updates.currentVersionText)") {
                Button("Check Now") { updates.checkForUpdates() }
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
        if let offer = updates.offer {
            let version = offer.version.description
            return String(localized: "Basket checks GitHub Releases once a day and installs an update only after verifying its signature. Basket \(version) is available.")
        }
        if let last = updates.lastChecked {
            let when = last.formatted(.relative(presentation: .named))
            return String(localized: "Basket checks GitHub Releases once a day and installs an update only after verifying its signature. Last checked \(when).",
                          comment: "The placeholder is a relative date such as “2 hours ago”")
        }
        return String(localized: "Basket checks GitHub Releases once a day and installs an update only after verifying its signature.")
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
