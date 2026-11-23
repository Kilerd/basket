import Foundation

/// What Basket should show (docs/ARCHITECTURE.md contract): every one of `AXAuditRules.sections`
/// in the sidebar and every onboarding step, except that the `migration` section (“Migrate from
/// OrbStack”) and the `orbstack` setup step appear only while OrbStack is installed.
///
/// The E2E runner and `lint` take the answer from the fixture set's `orbstack.json` — not from the
/// app — so a section that is shown or hidden wrongly fails the run.
public struct AXSectionExpectation: Sendable, Hashable {
    /// nil when unknown (no fixtures, e.g. a live backend): OrbStack's section and step are then
    /// neither required nor forbidden.
    public var orbStackInstalled: Bool?

    public init(orbStackInstalled: Bool?) {
        self.orbStackInstalled = orbStackInstalled
    }

    /// OrbStack installed: every section and step (the default of `AXAuditor.audit`).
    public static let everything = AXSectionExpectation(orbStackInstalled: true)
    public static let unknown = AXSectionExpectation(orbStackInstalled: nil)

    /// Reads `orbstack.json` from a fixture set as Basket does: `isInstalled`, and a missing or
    /// unreadable file means OrbStack isn't installed.
    public static func fixtures(_ directory: URL) -> AXSectionExpectation {
        struct Snapshot: Decodable { var isInstalled: Bool }
        let data = try? Data(contentsOf: directory.appendingPathComponent("orbstack.json"))
        let snapshot = data.flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        return AXSectionExpectation(orbStackInstalled: snapshot?.isInstalled ?? false)
    }

    /// Sidebar sections that must be present, in sidebar order.
    public var requiredSections: [String] { AXAuditRules.sections.filter { !isConditional(section: $0) || orbStackInstalled == true } }
    /// Sections whose sidebar item and root must be absent.
    public var hiddenSections: [String] { AXAuditRules.sections.filter { isConditional(section: $0) && orbStackInstalled == false } }

    /// Onboarding steps the step list must show, in order.
    public var requiredOnboardingSteps: [String] {
        AXAuditRules.onboardingSteps.filter { !isConditional(step: $0) || orbStackInstalled == true }
    }
    /// Onboarding steps that must not appear, neither in the step list nor as the shown step.
    public var hiddenOnboardingSteps: [String] {
        AXAuditRules.onboardingSteps.filter { isConditional(step: $0) && orbStackInstalled == false }
    }

    /// One line for reports.
    public var summary: String {
        switch orbStackInstalled {
        case true?: "OrbStack installed per orbstack.json: the migration section and the setup step must be shown"
        case false?: "OrbStack not installed per orbstack.json: the migration section and the setup step must be hidden"
        case nil: "OrbStack unknown (no fixtures): the migration section and the setup step are optional"
        }
    }

    private func isConditional(section: String) -> Bool { AXAuditRules.orbStackSections.contains(section) }
    private func isConditional(step: String) -> Bool { AXAuditRules.orbStackOnboardingSteps.contains(step) }
}
