import AppKit
import BasketAXKit

extension SelfTestRunner {
    /// `BASKET_SELFTEST_DIR` + `BASKET_ONBOARDING=1`: walks "Set Up Basket" (use `Fixtures/fresh`,
    /// a Mac without the CLI, with `BASKET_FAKE_BREW=1`), writing `onboarding-<step>[-<state>]`
    /// `.png` + `.ax.json` and a `-dark.png` of each. Then it clicks Open Basket: the main window's
    /// own self-test captures the sections and quits.
    func runOnboarding() async {
        InProcessAXCapture.prepare()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            onboardingLog("cannot create \(directory.path): \(error)")
            exit(1)
        }
        let model = store.onboarding
        await waitFor { model.window != nil && model.orbStack != nil && model.dockerStatus != nil && !model.isCheckingCLI }
        guard let window = model.window else {
            onboardingLog("no onboarding window")
            exit(1)
        }
        // Same place on every run (the window server picks a different origin per screen). Like
        // every self-test capture, the window is usually inactive: default buttons are drawn grey.
        window.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.visibleFrame.maxY ?? 900) - 40))

        await captureOnboarding(window, "welcome")

        model.go(to: .install)
        await waitFor { !model.isCheckingCLI }
        await captureOnboarding(window, "install")
        if model.cli == nil, model.brewPath != nil, model.isSimulated {
            // The other variant: no Homebrew → Download Installer / Check Again.
            let brew = model.brewPath
            model.brewPath = nil
            await captureOnboarding(window, "install-download")
            model.brewPath = brew
            model.installWithHomebrew()
            await waitFor(seconds: 15) { !model.installPhase.isRunning }
            await captureOnboarding(window, "install-done")
        }

        model.next()
        await waitFor { !model.isCheckingSystem && model.systemStatus != nil || model.cli == nil }
        await captureOnboarding(window, "system")
        if model.cli != nil, model.systemStatus?.isRunning != true, model.isSimulated {
            model.startSystem()
            await waitFor(seconds: 15) { !model.startPhase.isRunning }
            await captureOnboarding(window, "system-running")
        }

        model.next()
        if model.step == .orbstack {
            await captureOnboarding(window, "orbstack")
            model.next()
        }

        await waitFor { model.dockerStatus != nil }
        await captureOnboarding(window, "docker")
        if model.dockerStatus?.isInstalled == false, model.isSimulated {
            // Fixture runs only (`SimulatedDockerShim`): the real home is never touched.
            model.setDockerCommand(enabled: true)
            await waitFor { !model.dockerPhase.isRunning && model.dockerStatus?.isInstalled == true }
            await captureOnboarding(window, "docker-enabled")
        }

        model.next()
        await captureOnboarding(window, "done")
        onboardingLog("onboarding captured; opening the main window")
        guard let finish = model.finishAction else {
            onboardingLog("no finish action")
            exit(1)
        }
        finish()
    }

    /// Light (with the AX dump) and dark, whatever the Mac's own appearance is (through Settings ▸
    /// General ▸ Appearance, never saved in UI-test runs).
    private func captureOnboarding(_ window: NSWindow, _ name: String) async {
        let initial = store.appearance.selection
        await switchAppearance(to: .light, in: window)
        await capture(window, as: "onboarding-\(name)")
        await switchAppearance(to: .dark, in: window)
        window.displayIfNeeded()
        writePNG(of: window, to: directory.appending(path: "onboarding-\(name)-dark.png"))
        await switchAppearance(to: initial, in: window)
    }

    private func waitFor(seconds: Double = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        if !condition() { onboardingLog("timed out after \(Int(seconds)) s; capturing anyway") }
    }

    private func onboardingLog(_ message: String) {
        FileHandle.standardError.write(Data("basket selftest: \(message)\n".utf8))
    }
}
