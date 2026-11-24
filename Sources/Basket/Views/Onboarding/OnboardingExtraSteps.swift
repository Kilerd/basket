import SwiftUI
import AppKit
import BasketCore

// The last steps: OrbStack comparison (only when OrbStack is installed), the `docker` command, summary.

struct OrbStackStep: View {
    var model: OnboardingModel

    var body: some View {
        let orb = model.orbStack ?? .notInstalled
        OnboardingStepScaffold(
            step: .orbstack, symbol: "arrow.left.arrow.right", title: "Coming from OrbStack?",
            message: "OrbStack keeps a Linux VM running and stores everything in one disk image that only grows. Basket gives each container its own small VM, so memory is used only while containers run."
        ) {
            OnboardingBox {
                VStack(alignment: .leading, spacing: 12) {
                    comparison("Memory now", orbStack: orb.memoryFootprintBytes, basket: model.basketMemoryBytes,
                               format: Format.memory, identifier: "onboarding.compare.memory")
                    comparison("Disk", orbStack: orb.dataAllocatedBytes ?? 0, basket: model.basketDiskBytes,
                               format: Format.disk, identifier: "onboarding.compare.disk")
                }
                .padding(14)
            }
            Text(advice(orb))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func comparison(
        _ title: LocalizedStringResource, orbStack: Int64, basket: Int64, format: (Int64) -> String, identifier: String
    ) -> some View {
        let scale = Double(max(orbStack, basket, 1))
        let name = String(localized: title)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                bar("OrbStack", orbStack, scale, Series.orange, format)
                bar("Basket", basket, scale, Series.blue, format)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(name): OrbStack \(format(orbStack)), Basket \(format(basket))",
                                 comment: "VoiceOver: “Memory now: OrbStack 2.1 GB, Basket 300 MB”"))
        .accessibilityIdentifier(identifier)
    }

    /// Fixed label and value slots so both bars start and end at the same x. `label` is a product name.
    private func bar(_ label: String, _ bytes: Int64, _ scale: Double, _ color: Color, _ format: (Int64) -> String) -> some View {
        GridRow {
            Text(verbatim: label).frame(width: 70, alignment: .leading)
            MeterBar(fraction: Double(bytes) / scale, color: color, height: 8)
                .frame(maxWidth: .infinity)
            Text(format(bytes))
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
        .font(.callout)
    }

    private func advice(_ orb: OrbStackSnapshot) -> String {
        switch (orb.dockerImageCount, orb.isRunning) {
        case (let count?, true):
            String(localized: "Basket can copy your OrbStack images (\(count) today) and recreate your containers. OrbStack isn’t changed: you decide what to remove, and when.")
        case (let count?, false):
            String(localized: "Basket can copy your OrbStack images (\(count) today) and recreate your containers. OrbStack isn’t changed: you decide what to remove, and when. Basket reads from OrbStack only while it runs, so start it before you migrate.")
        case (nil, true):
            String(localized: "Basket can copy your OrbStack images and recreate your containers. OrbStack isn’t changed: you decide what to remove, and when.")
        case (nil, false):
            String(localized: "Basket can copy your OrbStack images and recreate your containers. OrbStack isn’t changed: you decide what to remove, and when. Basket reads from OrbStack only while it runs, so start it before you migrate.")
        }
    }
}

struct DockerStep: View {
    var model: OnboardingModel

    var body: some View {
        OnboardingStepScaffold(
            step: .docker, symbol: "terminal", title: "Use the docker command",
            message: "Scripts and habits say docker. Basket can add a docker command to new terminal windows that translates everyday docker commands to container."
        ) {
            if let status = model.dockerStatus {
                OnboardingBox { rows(status) }
                if status.isInstalled {
                    HStack {
                        Button("Disable") { model.setDockerCommand(enabled: false) }
                            .disabled(model.dockerPhase.isRunning)
                            .accessibilityIdentifier("onboarding.action.disable-docker")
                        Spacer(minLength: 0)
                        docsLink
                    }
                    .controlSize(.large)
                } else {
                    plan(status)
                }
                if let failure = model.dockerPhase.failure {
                    OnboardingFailure(message: "\(failure)")
                }
            } else {
                OnboardingBox {
                    OnboardingStatusRow(status: .working, title: "Checking your shell…", detail: nil, identifier: "onboarding.status")
                }
            }
        }
    }

    @ViewBuilder private func rows(_ status: DockerShimStatus) -> some View {
        if status.isInstalled {
            OnboardingStatusRow(
                status: .ok, title: "The docker command is on",
                detail: "New \(status.shell) windows run \(model.displayPath(status.binPath)).",
                identifier: "onboarding.status")
        } else {
            OnboardingStatusRow(
                status: status.currentDockerIsOrbStack ? .warning : .neutral, title: today(status),
                detail: todayDetail(status), identifier: "onboarding.status")
        }
    }

    private func today(_ status: DockerShimStatus) -> LocalizedStringKey {
        guard let current = status.currentDocker else { return "No docker command today" }
        return "docker today: \(model.displayPath(current))"
    }

    private func todayDetail(_ status: DockerShimStatus) -> LocalizedStringKey {
        guard let current = status.currentDocker else {
            return "Your \(status.shell) shell finds no docker command, so nothing else changes."
        }
        if status.currentDockerIsOrbStack {
            return "That’s OrbStack’s. New terminals will use Basket’s docker; OrbStack’s stays at \(model.displayPath(current))."
        }
        return "New terminals will use Basket’s docker instead; the current one stays where it is."
    }

    @ViewBuilder private func plan(_ status: DockerShimStatus) -> some View {
        if model.dockerPlan.isEmpty {
            Text("Basket couldn’t work out which file to change for your \(status.shell) shell.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(model.dockerPlan) { change in
                VStack(alignment: .leading, spacing: 6) {
                    Text(planTitle(change))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    OnboardingCodeBlock(text: change.contents.trimmingCharacters(in: .newlines))
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Planned change to \(model.displayPath(change.file))")
                .accessibilityIdentifier("onboarding.planned-change")
            }
        }
        HStack {
            Text("Turn it off any time in Settings to remove these lines.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            docsLink
        }
    }

    private func planTitle(_ change: PlannedShellChange) -> LocalizedStringKey {
        let path = model.displayPath(change.file)
        return path.hasSuffix("/docker") ? "Basket adds the command at \(path):" : "Basket adds these lines to \(path):"
    }

    private var docsLink: some View {
        Link(destination: OnboardingModel.dockerDocsURL) {
            Text("What’s supported").padding(.vertical, 3).contentShape(Rectangle())
        }
            .font(.callout)
            .help(OnboardingModel.dockerDocsURL.absoluteString)
            .accessibilityIdentifier("onboarding.action.docs")
    }
}

struct DoneStep: View {
    var model: OnboardingModel
    @AppStorage(DefaultsKey.memorySaverEnabled) private var memorySaver = false

    var body: some View {
        OnboardingStepScaffold(
            step: .done, symbol: "checkmark.seal", title: "Basket is ready",
            message: "Here’s what’s set up. You can change any of it later in Settings."
        ) {
            OnboardingBox {
                if let cli = model.cli {
                    OnboardingStatusRow(status: .ok, title: cli.version.map { "container \($0) installed" } ?? "container installed", detail: nil)
                } else {
                    OnboardingStatusRow(status: .warning, title: "container isn’t installed", detail: "Basket needs it to run containers.")
                }
                OnboardingRowDivider()
                if model.systemStatus?.isRunning == true {
                    OnboardingStatusRow(status: .ok, title: "Container system running", detail: nil)
                } else {
                    OnboardingStatusRow(status: .neutral, title: "Container system not started", detail: "Start it from the Container menu.")
                }
                OnboardingRowDivider()
                if model.dockerStatus?.isInstalled == true {
                    OnboardingStatusRow(status: .ok, title: "docker command on", detail: nil)
                } else {
                    OnboardingStatusRow(status: .neutral, title: "docker command off", detail: "Turn it on in Settings when you want it.")
                }
                if model.orbStackInstalled {
                    OnboardingRowDivider()
                    OnboardingStatusRow(status: .neutral, title: "OrbStack left as it is", detail: "Migrate any time from the sidebar.")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Summary")
            .accessibilityIdentifier("onboarding.summary")
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Turn on Memory Saver", isOn: $memorySaver)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("onboarding.memory-saver")
                Text("Stops containers that have been idle for a while so their memory goes back to macOS. Containers started with --rm and ones you exempt are never stopped.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
    }
}
