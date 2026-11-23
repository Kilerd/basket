import Foundation
import Testing
@testable import BasketAXKit

/// "Migrate from OrbStack" and the "From OrbStack" setup step exist only while OrbStack is
/// installed (#47); the contract follows `AXSectionExpectation`.
@Suite struct SectionExpectationTests {
    let installed = AXSectionExpectation(orbStackInstalled: true)
    let absent = AXSectionExpectation(orbStackInstalled: false)
    let withoutMigration = AXAuditRules.sections.filter { $0 != "migration" }

    func contract(_ tree: AXNode, _ section: String?, _ expecting: AXSectionExpectation) -> [AXFinding] {
        AXAuditor.audit(window: tree, section: section, expecting: expecting).rule(AXAuditRules.contract)
    }

    @Test func sectionsAndStepsPerExpectation() {
        #expect(installed.requiredSections == AXAuditRules.sections && installed.hiddenSections.isEmpty)
        #expect(absent.requiredSections == withoutMigration && absent.hiddenSections == ["migration"])
        #expect(AXSectionExpectation.unknown.requiredSections == withoutMigration)
        #expect(AXSectionExpectation.unknown.hiddenSections.isEmpty)
        #expect(installed.requiredOnboardingSteps == AXAuditRules.onboardingSteps)
        #expect(absent.requiredOnboardingSteps == ["welcome", "install", "system", "docker", "done"])
        #expect(absent.hiddenOnboardingSteps == ["orbstack"] && AXSectionExpectation.unknown.hiddenOnboardingSteps.isEmpty)
        #expect(AXSectionExpectation.everything == installed)
    }

    @Test func withoutOrbStackTheSidebarHasNoMigration() {
        for section in withoutMigration {
            let tree = basketWindow(section: section, sidebarSections: withoutMigration)
            let findings = AXAuditor.audit(window: tree, section: section, expecting: absent)
            #expect(findings.isEmpty, "\(section): \(findings.map(\.message))")
        }
        let shown = contract(basketWindow(section: "images"), "images", absent)
        #expect(shown.map(\.identifier) == ["sidebar.migration"])
        #expect(shown.first?.severity == .error && shown.first?.message.contains("OrbStack isn't installed") == true)
    }

    @Test func withOrbStackTheSidebarNeedsMigration() {
        #expect(contract(basketWindow(section: "images"), "images", installed).isEmpty)
        let hidden = basketWindow(section: "images", sidebarSections: withoutMigration)
        #expect(contract(hidden, "images", installed).map(\.identifier) == ["sidebar.migration"])
        // The default expectation is "installed" (every section).
        #expect(contract(hidden, "images", .everything).map(\.identifier) == ["sidebar.migration"])
    }

    @Test func unknownMakesMigrationOptional() {
        let hidden = basketWindow(section: "images", sidebarSections: withoutMigration)
        #expect(contract(hidden, "images", .unknown).isEmpty)
        #expect(contract(basketWindow(section: "images"), "images", .unknown).isEmpty)
        // A captured migration section still needs its own sidebar item.
        #expect(contract(basketWindow(section: "migration"), "migration", .unknown).isEmpty)
    }

    @Test func aHiddenSectionMustNotBeCaptured() {
        let findings = contract(basketWindow(section: "migration", sidebarSections: withoutMigration), "migration", absent)
        #expect(findings.map(\.identifier) == ["section.migration"])
    }

    @Test func expectationFromFixtures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("basket-ax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(AXSectionExpectation.fixtures(directory) == absent, "no orbstack.json: not installed")
        let file = directory.appendingPathComponent("orbstack.json")
        try Data(#"{"isInstalled": true, "isRunning": false, "memoryFootprintBytes": 0}"#.utf8).write(to: file)
        #expect(AXSectionExpectation.fixtures(directory) == installed)
        try Data(#"{"isInstalled": false, "isRunning": false, "memoryFootprintBytes": 0}"#.utf8).write(to: file)
        #expect(AXSectionExpectation.fixtures(directory) == absent)
        try Data("not json".utf8).write(to: file)
        #expect(AXSectionExpectation.fixtures(directory) == absent)
    }

    // MARK: Onboarding

    func onboarding(step: String, listed: [String]) -> AXNode {
        let rows = listed.enumerated().map { i, s in
            AXNode(role: "AXStaticText", identifier: "onboarding.progress.\(s)", label: s.capitalized,
                   frame: r(112, 160 + Double(i) * 32, 190, 30))
        }
        return window([
            group(rows, id: "onboarding.progress", frame: r(100, 100, 216, 560)),
            group([AXNode(role: "AXHeading", label: "Title", frame: r(400, 200, 200, 30))],
                  id: "onboarding.step.\(step)", frame: r(320, 100, 560, 480)),
            group([button("onboarding.action.continue", r(780, 610, 90, 30), title: "Continue")], frame: r(320, 590, 560, 70)),
        ], id: "onboarding.window", frame: r(100, 100, 780, 600))
    }

    @Test func onboardingListsTheOrbStackStepOnlyWhenInstalled() {
        let all = AXAuditRules.onboardingSteps
        let five = absent.requiredOnboardingSteps
        #expect(contract(onboarding(step: "docker", listed: all), nil, installed).isEmpty)
        #expect(contract(onboarding(step: "docker", listed: five), nil, absent).isEmpty)
        #expect(contract(onboarding(step: "docker", listed: five), nil, installed).map(\.identifier)
            == ["onboarding.progress.orbstack"])
        #expect(contract(onboarding(step: "docker", listed: all), nil, absent).map(\.identifier)
            == ["onboarding.progress.orbstack"])
        #expect(contract(onboarding(step: "orbstack", listed: five), nil, absent).map(\.identifier)
            == ["onboarding.step.orbstack"])
        #expect(contract(onboarding(step: "docker", listed: five), nil, .unknown).isEmpty)
        #expect(contract(onboarding(step: "docker", listed: all), nil, .unknown).isEmpty)
        // Every required step has a row in the list.
        #expect(contract(onboarding(step: "docker", listed: five.filter { $0 != "system" }), nil, absent).map(\.identifier)
            == ["onboarding.progress.system"])
    }
}
