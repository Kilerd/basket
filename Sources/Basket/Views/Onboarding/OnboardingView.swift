import SwiftUI
import AppKit
import BasketCore

/// "Set Up Basket": a Setup Assistant–style window — step list on the left, one step at a time on
/// the right, Back / Skip / Continue at the bottom. Opens on first launch (and whenever the
/// `container` CLI is missing), from the app menu and from Settings.
struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        let model = store.onboarding
        HStack(spacing: 0) {
            OnboardingStepList(model: model)
                .frame(width: 216)
            Divider()
            VStack(spacing: 0) {
                stepContent(model)
                Divider()
                OnboardingFooter(model: model, migrate: migrate, finish: finish)
            }
        }
        // The step list runs under the hidden title bar, like a sidebar.
        .ignoresSafeArea(.container, edges: .top)
        .frame(width: OnboardingWindow.size.width, height: OnboardingWindow.size.height - Self.titleBarHeight)
        .background(WindowAccessor { window in
            model.finishAction = finish
            store.attachOnboarding(window: window)
        })
        .onAppear {
            model.begin()
            if !store.options.isUITest { NSApp.activate() }
        }
        .onDisappear {
            model.windowClosed()
            // Closing setup never leaves Basket without a window.
            if store.mainWindow?.isVisible != true { openWindow(id: "main") }
        }
        .onChange(of: model.visibleSteps) {
            // OrbStack went away while its step was showing.
            if !model.visibleSteps.contains(model.step) { model.next() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from Terminal or the installer: notice a freshly installed CLI.
            if model.step == .install, model.cli == nil, !model.installPhase.isRunning {
                Task { await model.checkCLI() }
            }
        }
        .transaction { if store.options.isUITest { $0.disablesAnimations = true } }
    }

    /// Safe-area inset of a hidden title bar; the view's frame excludes it.
    static let titleBarHeight: CGFloat = 32

    @ViewBuilder private func stepContent(_ model: OnboardingModel) -> some View {
        switch model.step {
        case .welcome: WelcomeStep(model: model)
        case .install: InstallStep(model: model)
        case .system: SystemStep(model: model)
        case .orbstack: OrbStackStep(model: model)
        case .docker: DockerStep(model: model)
        case .done: DoneStep(model: model)
        }
    }

    /// "Migrate Images & Containers…": setup is over; the migration section takes it from here.
    private func migrate() {
        store.selectedSection = .migration
        finish()
    }

    private func finish() {
        store.onboarding.markCompleted()
        openWindow(id: "main")
        dismissWindow(id: OnboardingWindow.id)
    }
}

// MARK: - Step list

private struct OnboardingStepList: View {
    var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "Basket").font(.headline)
                    Text("Setup", comment: "Subtitle under the app name in the setup window's step list").font(.callout).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .padding(.leading, 8)
            .padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.visibleSteps.enumerated()), id: \.element) { index, step in
                    StepRow(model: model, step: step, number: index + 1, total: model.visibleSteps.count)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 52)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.035))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Setup steps")
        .accessibilityIdentifier("onboarding.progress")
    }
}

private struct StepRow: View {
    var model: OnboardingModel
    var step: OnboardingStep
    var number: Int
    var total: Int

    private enum Mark { case current, done, skipped, upcoming }

    private var mark: Mark {
        let order = model.visibleSteps
        let here = order.firstIndex(of: model.step) ?? 0
        let mine = order.firstIndex(of: step) ?? 0
        if mine == here { return .current }
        if mine > here { return .upcoming }
        return model.isSatisfied(step) || step == .welcome || step == .orbstack ? .done : .skipped
    }

    var body: some View {
        HStack(spacing: 10) {
            indicator.frame(width: 20, height: 20)
            Text(step.listTitle)
                .font(.body.weight(mark == .current ? .semibold : .regular))
                .foregroundStyle(mark == .upcoming ? .secondary : .primary)
                // Longer languages wrap instead of truncating.
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(minHeight: 30)
        .background {
            if mark == .current {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor.opacity(0.14))
            }
        }
        // The name is the visible title; position and state follow as hint and traits.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(mark == .current ? [.isStaticText, .isSelected] : .isStaticText)
        .accessibilityLabel(step.listTitle)
        .accessibilityHint(hint)
        .accessibilityIdentifier("onboarding.progress.\(step.rawValue)")
    }

    private var hint: Text {
        switch mark {
        case .current: Text("Step \(number) of \(total), current step", comment: "VoiceOver hint in the setup step list")
        case .done: Text("Step \(number) of \(total), done", comment: "VoiceOver hint in the setup step list")
        case .skipped: Text("Step \(number) of \(total), skipped", comment: "VoiceOver hint in the setup step list")
        case .upcoming: Text("Step \(number) of \(total)", comment: "VoiceOver hint in the setup step list")
        }
    }

    @ViewBuilder private var indicator: some View {
        switch mark {
        case .current:
            Circle().fill(Color.accentColor)
                .overlay(Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.white))
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle.fill").font(.system(size: 17)).foregroundStyle(.secondary)
        case .upcoming:
            Circle().strokeBorder(.tertiary, lineWidth: 1.5)
                .overlay(Text("\(number)").font(.caption.weight(.medium)).foregroundStyle(.secondary))
        }
    }

}

// MARK: - Footer

/// Back on the left; the step's choice on the right (default action last, as in macOS dialogs).
private struct OnboardingFooter: View {
    var model: OnboardingModel
    var migrate: () -> Void
    var finish: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if model.step != .welcome {
                button("Back", "back") { model.back() }
            }
            Spacer(minLength: 0)
            trailing
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var trailing: some View {
        switch model.step {
        case .welcome:
            primary("Continue", "continue", enabled: model.requirements.isSatisfied) { model.next() }
        case .install, .system:
            if !model.isSatisfied(model.step) {
                button("Skip", "skip") { model.next() }
            }
            primary("Continue", "continue", enabled: model.isSatisfied(model.step)) { model.next() }
        case .orbstack:
            button("Later", "later") { model.next() }
            primary("Migrate Images & Containers…", "migrate", action: migrate)
        case .docker:
            if model.dockerStatus?.isInstalled == true {
                primary("Continue", "continue") { model.next() }
            } else {
                button("Not Now", "not-now") { model.next() }
                primary("Enable", "enable-docker",
                        enabled: model.dockerStatus != nil && !model.dockerPhase.isRunning) {
                    model.setDockerCommand(enabled: true)
                }
            }
        case .done:
            primary("Open Basket", "open-basket", action: finish)
        }
    }

    private func button(_ title: LocalizedStringKey, _ verb: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .accessibilityIdentifier("onboarding.action.\(verb)")
    }

    private func primary(_ title: LocalizedStringKey, _ verb: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!enabled)
            .accessibilityIdentifier("onboarding.action.\(verb)")
    }
}

// MARK: - Launch

/// `.defaultLaunchBehavior(.presented)` loses to window restoration: relaunching after quitting
/// with no window open shows nothing. The menu bar icon is always drawn at launch, so it opens
/// "Set Up Basket" when the launch decision asked for it and the window didn't appear on its own.
struct OnboardingLaunchPresenter: ViewModifier {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            let model = store.onboarding
            guard model.showsAtLaunch, !model.launchPresentationChecked else { return }
            model.launchPresentationChecked = true
            try? await Task.sleep(for: .seconds(1))
            if model.window == nil { openWindow(id: OnboardingWindow.id) }
        }
    }
}

// MARK: - Menu command

/// App menu ▸ "Set Up Basket…".
struct OnboardingCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Set Up Basket…") { openWindow(id: OnboardingWindow.id) }
        }
    }
}
