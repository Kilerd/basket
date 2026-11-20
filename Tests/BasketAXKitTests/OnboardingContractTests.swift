import Testing
@testable import BasketAXKit

/// "Set Up Basket" snapshots are linted with `section: nil` (they aren't sidebar sections); a tree
/// carrying `onboarding.window` gets the onboarding contract instead of requiring `basket.main`.
@Suite struct OnboardingContractTests {
    let frame = r(100, 100, 780, 560)

    func onboardingWindow(step: String? = "install", extra: [AXNode] = []) -> AXNode {
        var content: [AXNode] = []
        if let step {
            content.append(group([
                AXNode(role: "AXHeading", label: "Install container", frame: r(400, 200, 200, 30)),
                button("onboarding.action.install-brew", r(340, 400, 160, 30), title: "Install with Homebrew"),
            ], id: "onboarding.step.\(step)", frame: r(320, 100, 560, 480)))
        }
        content.append(group([
            button("onboarding.action.back", r(340, 610, 70, 30), title: "Back"),
            button("onboarding.action.continue", r(780, 610, 90, 30), title: "Continue"),
        ], frame: r(320, 590, 560, 70)))
        let chrome = [
            button(nil, r(120, 118, 16, 16), title: nil, subrole: "AXCloseButton"),
            button(nil, r(142, 118, 16, 16), title: nil, subrole: "AXMinimizeButton"),
        ]
        return window(content + extra + chrome, id: "onboarding.window", frame: frame)
    }

    func contract(_ tree: AXNode) -> [AXFinding] {
        AXAuditor.audit(window: tree, section: nil).rule(AXAuditRules.contract)
    }

    @Test func compliantWindowPassesWithoutBasketMain() {
        #expect(AXAuditRules.isOnboardingWindow(onboardingWindow()))
        #expect(!AXAuditRules.isOnboardingWindow(basketWindow(section: "overview")))
        #expect(contract(onboardingWindow()).isEmpty)
        for step in AXAuditRules.onboardingSteps {
            #expect(contract(onboardingWindow(step: step)).isEmpty, "\(step)")
        }
    }

    @Test func needsExactlyOneKnownStep() {
        #expect(contract(onboardingWindow(step: nil)).map(\.identifier) == ["onboarding.step.<name>"])
        let unknown = contract(onboardingWindow(step: "billing"))
        #expect(unknown.count == 1 && unknown.first?.identifier == "onboarding.step.billing")
        let two = onboardingWindow(extra: [group([], id: "onboarding.step.done", frame: r(320, 100, 10, 10))])
        #expect(contract(two).count == 1 && contract(two).first?.message.contains("several steps") == true)
    }

    @Test func buttonsAndLinksAreActions() {
        let stray = onboardingWindow(extra: [
            button(nil, r(340, 450, 120, 30), title: "Download Installer"),
            button("onboarding.download", r(480, 450, 120, 30), title: "Check Again"),
            AXNode(role: "AXLink", identifier: "onboarding.action.docs", label: "What’s supported", frame: r(620, 450, 120, 20)),
        ])
        let findings = contract(stray)
        #expect(findings.count == 2)
        #expect(findings.allSatisfy { $0.severity == .error })
        #expect(findings.contains { $0.message.contains("“Download Installer”") && $0.identifier == nil })
        #expect(findings.contains { $0.identifier == "onboarding.download" })
    }

    @Test func otherControlsNeedAnOnboardingIdentifier() {
        let toggle = AXNode(role: "AXCheckBox", identifier: "onboarding.memory-saver", title: "Turn on Memory Saver",
                            frame: r(340, 500, 200, 20), isEnabled: true)
        let log = AXNode(role: "AXTextArea", identifier: "onboarding.log", label: "Homebrew output", frame: r(340, 300, 480, 110))
        #expect(contract(onboardingWindow(extra: [toggle, log])).isEmpty)
        let bare = AXNode(role: "AXCheckBox", identifier: "settings.memory-saver", title: "Turn on Memory Saver",
                          frame: r(340, 500, 200, 20), isEnabled: true)
        #expect(contract(onboardingWindow(extra: [bare])).map(\.identifier) == ["settings.memory-saver"])
    }

    @Test func windowChromeIsExempt() {
        // The close/minimize buttons in `onboardingWindow()` carry no identifier and aren't flagged.
        #expect(contract(onboardingWindow()).isEmpty)
    }

    @Test func mainWindowsKeepTheirContract() {
        // Without `onboarding.window`, a section-less snapshot still needs `basket.main`.
        let plain = window([button("x.action.go", r(200, 200, 60, 30), title: "Go")], id: nil)
        #expect(contract(plain).map(\.identifier) == ["basket.main"])
    }
}
