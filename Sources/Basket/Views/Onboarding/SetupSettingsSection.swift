import SwiftUI
import BasketCore

/// Settings ▸ Setup: re-run "Set Up Basket" and switch the `docker` command on or off (same
/// installer as the onboarding step; enabling first shows the exact lines it adds).
struct SetupSettingsSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var confirmEnable = false

    var body: some View {
        let model = store.onboarding
        Section("Setup") {
            LabeledContent("Setup assistant") {
                Button("Run Setup Again…") { openWindow(id: OnboardingWindow.id) }
                    .accessibilityIdentifier("settings.run-setup")
            }
            Toggle("Provide a docker command", isOn: Binding(
                get: { model.dockerStatus?.isInstalled == true },
                set: { enabled in
                    if enabled { confirmEnable = true } else { model.setDockerCommand(enabled: false) }
                }))
                .disabled(model.dockerStatus == nil || model.dockerPhase.isRunning)
                .accessibilityIdentifier("settings.docker-command")
            Text(caption(model))
                .font(.caption)
                .foregroundStyle(model.dockerPhase.failure == nil ? .secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await model.loadDocker() }
        .alert("Add the docker command?", isPresented: $confirmEnable) {
            Button("Enable") { model.setDockerCommand(enabled: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(planText(model))
        }
    }

    private func caption(_ model: OnboardingModel) -> String {
        if let failure = model.dockerPhase.failure { return failure }
        guard let status = model.dockerStatus else { return String(localized: "Checking your shell…") }
        if status.isInstalled {
            let path = model.displayPath(status.binPath)
            return String(localized: "New terminal windows run Basket’s docker (\(path)), which translates docker commands to container.")
        }
        if status.currentDockerIsOrbStack, let current = status.currentDocker {
            let path = model.displayPath(current)
            return String(localized: "Adds a docker command to new \(status.shell) windows that translates docker commands to container. OrbStack’s docker stays at \(path).")
        }
        return String(localized: "Adds a docker command to new \(status.shell) windows that translates docker commands to container.")
    }

    private func planText(_ model: OnboardingModel) -> String {
        // File names and the lines Basket adds are shown exactly as they will be written.
        let changes = model.dockerPlan.map { "\(model.displayPath($0.file)):\n\($0.contents.trimmingCharacters(in: .newlines))" }
        guard !changes.isEmpty else { return String(localized: "Basket adds a docker command for new terminal windows.") }
        let listing = changes.joined(separator: "\n\n")
        return String(localized: "Basket adds:\n\n\(listing)\n\nTurn it off here to remove exactly these lines.",
                      comment: "Confirmation: the files and the exact lines Basket writes to them")
    }
}
