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
        guard let status = model.dockerStatus else { return "Checking your shell…" }
        if status.isInstalled {
            return "New terminal windows run Basket’s docker (\(model.displayPath(status.binPath))), which translates docker commands to container."
        }
        var text = "Adds a docker command to new \(status.shell) windows that translates docker commands to container."
        if status.currentDockerIsOrbStack, let current = status.currentDocker {
            text += " OrbStack’s docker stays at \(model.displayPath(current))."
        }
        return text
    }

    private func planText(_ model: OnboardingModel) -> String {
        let changes = model.dockerPlan.map { "\(model.displayPath($0.file)):\n\($0.contents.trimmingCharacters(in: .newlines))" }
        guard !changes.isEmpty else { return "Basket adds a docker command for new terminal windows." }
        return "Basket adds:\n\n" + changes.joined(separator: "\n\n") + "\n\nTurn it off here to remove exactly these lines."
    }
}
