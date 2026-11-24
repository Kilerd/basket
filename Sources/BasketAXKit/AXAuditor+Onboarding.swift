import Foundation

extension AXAuditRules {
    // MARK: Onboarding window contract (docs/ARCHITECTURE.md)
    public static let onboardingWindowIdentifier = "onboarding.window"
    public static let onboardingSteps = ["welcome", "install", "system", "orbstack", "docker", "done"]
    public static let onboardingStepPrefix = "onboarding.step."
    public static let onboardingActionPrefix = "onboarding.action."
    /// The step list (`onboarding.progress`) names its rows `onboarding.progress.<step>`.
    public static let onboardingProgressIdentifier = "onboarding.progress"
    /// Steps shown only while OrbStack is installed.
    public static let orbStackOnboardingSteps: Set<String> = ["orbstack"]

    /// A window snapshot whose tree carries `onboarding.window` ("Set Up Basket"), audited with
    /// the onboarding contract instead of the main window's.
    public static func isOnboardingWindow(_ root: AXNode) -> Bool {
        AXTreeIndex(root).items.contains { $0.node.identifier == onboardingWindowIdentifier }
    }
}

extension AXAuditor {
    /// "Set Up Basket": exactly one known `onboarding.step.<name>` is shown, buttons and links are
    /// `onboarding.action.<verb>`, and every other control carries an `onboarding.` identifier.
    /// OrbStack's step is shown (as the step and in the step list) only when `expecting` says so.
    static func onboardingContract(_ tree: AXTreeIndex, expecting: AXSectionExpectation = .everything) -> [AXFinding] {
        var findings: [AXFinding] = []
        let ids = tree.items.compactMap(\.node.identifier)
        let steps = ids.filter { $0.hasPrefix(AXAuditRules.onboardingStepPrefix) }
        let known = AXAuditRules.onboardingSteps.map { AXAuditRules.onboardingStepPrefix + $0 }
        if steps.isEmpty {
            findings.append(AXFinding(
                rule: AXAuditRules.contract, severity: .error,
                message: "missing identifier “onboarding.step.<name>” (\(AXAuditRules.onboardingSteps.joined(separator: ", "))) in the onboarding window (docs/ARCHITECTURE.md contract)",
                path: tree.root.path, identifier: AXAuditRules.onboardingStepPrefix + "<name>"))
        } else if Set(steps).count > 1 {
            findings.append(AXFinding(
                rule: AXAuditRules.contract, severity: .error,
                message: "the onboarding window shows several steps at once: \(Set(steps).sorted().joined(separator: ", "))",
                path: tree.root.path, identifier: steps[0]))
        }
        for step in Set(steps) where !known.contains(step) {
            findings.append(AXFinding(
                rule: AXAuditRules.contract, severity: .error,
                message: "unknown onboarding step “\(step)”; the contract lists \(AXAuditRules.onboardingSteps.joined(separator: ", "))",
                path: tree.root.path, identifier: step))
        }
        findings += onboardingStepList(tree, ids: Set(ids), expecting: expecting)
        for i in tree.indices {
            let node = tree[i].node
            guard AXAuditRules.isInteractive(node), !AXAuditRules.isSystemDrawn(node) else { continue }
            let id = node.identifier ?? ""
            let isAction = node.role == "AXButton" || node.role == "AXLink"
            let ok = isAction ? id.hasPrefix(AXAuditRules.onboardingActionPrefix) && id.count > AXAuditRules.onboardingActionPrefix.count
                : id.hasPrefix("onboarding.")
            guard !ok else { continue }
            let wanted = isAction ? "“onboarding.action.<verb>”" : "an “onboarding.<control>” identifier"
            findings.append(AXFinding(
                rule: AXAuditRules.contract, severity: .error,
                message: "\(node.role) “\(AXAuditRules.spokenName(node) ?? "?")” in the onboarding window needs \(wanted)\(id.isEmpty ? "" : " (has “\(id)”)")",
                path: tree[i].path, identifier: node.identifier, frame: node.frame))
        }
        return findings
    }

    /// The steps that must and mustn't appear: a hidden step is neither shown nor listed, and the
    /// step list (when captured) has a row `onboarding.progress.<step>` for every required step.
    static func onboardingStepList(_ tree: AXTreeIndex, ids: Set<String>, expecting: AXSectionExpectation) -> [AXFinding] {
        var findings: [AXFinding] = []
        let progress = AXAuditRules.onboardingProgressIdentifier
        for step in expecting.hiddenOnboardingSteps {
            for id in [AXAuditRules.onboardingStepPrefix + step, "\(progress).\(step)"] where ids.contains(id) {
                let i = tree.innermost(identifier: id)
                findings.append(AXFinding(
                    rule: AXAuditRules.contract, severity: .error,
                    message: "“\(id)” is shown, but OrbStack isn't installed: the \(step) step appears only while it is (docs/ARCHITECTURE.md contract)",
                    path: i.map { tree[$0].path } ?? tree.root.path, identifier: id, frame: i.flatMap { tree[$0].node.frame }))
            }
        }
        guard ids.contains(progress) else { return findings }
        for step in expecting.requiredOnboardingSteps where !ids.contains("\(progress).\(step)") {
            findings.append(AXFinding(
                rule: AXAuditRules.contract, severity: .error,
                message: "missing identifier “\(progress).\(step)” in the onboarding step list (docs/ARCHITECTURE.md contract)",
                path: tree.root.path, identifier: "\(progress).\(step)"))
        }
        return findings
    }
}
