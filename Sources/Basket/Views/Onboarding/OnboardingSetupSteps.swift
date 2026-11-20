import SwiftUI
import AppKit
import BasketCore

// Steps 1–3: welcome + requirements, install the `container` CLI, start its system service.

struct WelcomeStep: View {
    var model: OnboardingModel

    var body: some View {
        let req = model.requirements
        OnboardingStepScaffold(
            step: .welcome, title: "Welcome to Basket",
            message: "Run Linux containers on your Mac with Apple’s own container runtime. Each container gets a small virtual machine that uses memory only while it runs, and Basket shows what memory and disk everything costs.",
            centered: true
        ) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 80, height: 80)
        } content: {
            OnboardingBox {
                OnboardingStatusRow(
                    status: req.meetsMacOS ? .ok : .blocked, title: "macOS 26 or later",
                    detail: "This Mac runs macOS \(req.macOSVersion).", identifier: "onboarding.requirement.macos")
                OnboardingRowDivider()
                OnboardingStatusRow(
                    status: req.isAppleSilicon ? .ok : .blocked, title: "Apple silicon",
                    detail: req.isAppleSilicon ? "This Mac has an Apple silicon chip." : "This Mac has an Intel processor.",
                    identifier: "onboarding.requirement.apple-silicon")
            }
            if req.isSatisfied {
                Text("Setup takes a few minutes: install Apple’s container tool, start it, and choose the extras you want. You can skip anything and come back from the Basket menu.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                OnboardingFailure(message: "Basket can’t run on this Mac. Apple’s container runtime needs Apple silicon and macOS 26 or later.")
            }
        }
    }
}

struct InstallStep: View {
    var model: OnboardingModel

    var body: some View {
        OnboardingStepScaffold(
            step: .install, symbol: "shippingbox", title: "Install container",
            message: "Basket runs containers with container, Apple’s open-source container tool. Basket drives it for you, so you don’t need to learn its commands."
        ) {
            OnboardingBox { status }
            if model.cli == nil {
                actions
            }
            if !model.installLog.isEmpty {
                OnboardingLog(lines: model.installLog, label: "Homebrew output")
            }
            if model.cli == nil, let failure = model.installPhase.failure {
                OnboardingFailure(message: failure)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let cli = model.cli {
            OnboardingStatusRow(
                status: .ok, title: "container \(cli.version ?? "") is installed".replacingOccurrences(of: "  ", with: " "),
                detail: cli.path, identifier: "onboarding.status")
        } else if model.installPhase.isRunning {
            OnboardingStatusRow(
                status: .working, title: "Installing container with Homebrew…",
                detail: "Usually a minute or two. You can keep using your Mac.", identifier: "onboarding.status")
        } else if model.isCheckingCLI {
            OnboardingStatusRow(status: .working, title: "Looking for container…", detail: nil, identifier: "onboarding.status")
        } else {
            OnboardingStatusRow(
                status: .warning, title: "container isn’t installed",
                detail: model.brewPath != nil
                    ? "Homebrew is installed, so Basket can install container with it."
                    : "Download Apple’s installer, open it, then come back and click Check Again.",
                identifier: "onboarding.status")
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 10) {
            if model.brewPath != nil {
                Button("Install with Homebrew") { model.installWithHomebrew() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.installPhase.isRunning)
                    .accessibilityIdentifier("onboarding.action.install-brew")
                if model.installPhase.isRunning {
                    Button("Cancel") { model.cancelInstall() }
                        .accessibilityIdentifier("onboarding.action.cancel")
                }
            } else {
                Button("Download Installer") { model.openReleasesPage() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("onboarding.action.download")
                Button("Check Again") { Task { await model.checkCLI() } }
                    .disabled(model.isCheckingCLI)
                    .accessibilityIdentifier("onboarding.action.check-again")
            }
            Spacer(minLength: 8)
            Button { model.chooseCLI() } label: {
                // Padding makes the link a 22 pt tall target.
                Text("I Installed It Elsewhere…").padding(.vertical, 3).contentShape(Rectangle())
            }
                .buttonStyle(.link)
                .disabled(model.installPhase.isRunning)
                .help("Choose the container executable")
                .accessibilityIdentifier("onboarding.action.choose-cli")
        }
        .controlSize(.large)
    }
}

struct SystemStep: View {
    var model: OnboardingModel

    var body: some View {
        OnboardingStepScaffold(
            step: .system, symbol: "power", title: "Start the container system",
            message: "container keeps a small background service for images, networks and container VMs. It uses almost no memory until you run a container."
        ) {
            OnboardingBox { status }
            if model.cli != nil, model.systemStatus?.isRunning != true {
                HStack(spacing: 10) {
                    Button("Start") { model.startSystem() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.startPhase.isRunning)
                        .accessibilityIdentifier("onboarding.action.start-system")
                    if model.startPhase.isRunning {
                        Button("Cancel") { model.cancelStart() }
                            .accessibilityIdentifier("onboarding.action.cancel")
                    }
                    Spacer(minLength: 0)
                }
                .controlSize(.large)
                Text("The first start downloads Linux kernel files (about 650 MB) and keeps a 30 MB kernel. On a fast connection that takes a few minutes; later starts take seconds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure = model.startPhase.failure {
                    OnboardingFailure(message: failure)
                }
            }
            if !model.startLog.isEmpty {
                OnboardingLog(lines: model.startLog, label: "container system start output")
            }
        }
    }

    @ViewBuilder private var status: some View {
        if model.cli == nil {
            OnboardingStatusRow(
                status: .warning, title: "Install container first",
                detail: "Go back a step to install it, or continue and start it later from Basket.",
                identifier: "onboarding.status")
        } else if model.systemStatus?.isRunning == true {
            OnboardingStatusRow(
                status: .ok, title: "The container system is running",
                detail: version.map { "container \($0)" }, identifier: "onboarding.status")
        } else if model.startPhase.isRunning {
            OnboardingStatusRow(
                status: .working, title: "Starting the container system…",
                detail: "Downloads the kernel on the first start.", identifier: "onboarding.status")
        } else if model.isCheckingSystem, model.systemStatus == nil {
            OnboardingStatusRow(status: .working, title: "Checking the container system…", detail: nil, identifier: "onboarding.status")
        } else {
            OnboardingStatusRow(
                status: .neutral, title: "The container system isn’t running",
                detail: "Click Start and Basket starts it for you.", identifier: "onboarding.status")
        }
    }

    private var version: String? { model.systemStatus?.serverVersion ?? model.systemStatus?.cliVersion ?? model.cli?.version }
}
