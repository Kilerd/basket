import Testing
@testable import BasketAXKit

@Suite struct ConsistencyTests {
    func all(_ make: (String) -> AXNode) -> [String: AXNode] {
        Dictionary(uniqueKeysWithValues: AXAuditRules.sections.map { ($0, make($0)) })
    }

    @Test func consistentSectionsHaveNoFindings() {
        #expect(AXAuditor.auditConsistency(sections: all { basketWindow(section: $0) }).isEmpty)
    }

    @Test func aMovedWindowIsNotInconsistent() {
        let findings = AXAuditor.auditConsistency(sections: all {
            basketWindow(section: $0, origin: $0 == "images" ? (300, 250) : (100, 100))
        })
        #expect(findings.isEmpty, "positions are compared relative to the window")
    }

    @Test func fewerThanTwoSectionsIsNothingToCompare() {
        #expect(AXAuditor.auditConsistency(sections: ["images": basketWindow(section: "images", searchY: 300)]).isEmpty)
        #expect(AXAuditor.auditConsistency(sections: [:]).isEmpty)
    }

    @Test func sidebarMustNotJump() {
        let findings = AXAuditor.auditConsistency(sections: all {
            basketWindow(section: $0, sidebarShift: $0 == "volumes" ? 6 : 0)
        }).rule(AXAuditRules.consistencySidebar)
        #expect(findings.count == AXAuditRules.sections.count, "every item moved, reported once each")
        #expect(findings.allSatisfy { $0.severity == .error && $0.path.hasPrefix("volumes:") })
        #expect(findings.first?.message.contains("in overview") == true, "compared against the first section")
    }

    @Test func subPixelSidebarDifferencesAreTolerated() {
        let findings = AXAuditor.auditConsistency(sections: all {
            basketWindow(section: $0, sidebarShift: $0 == "volumes" ? 0.4 : 0)
        })
        #expect(findings.isEmpty)
    }

    @Test func searchFieldPositionAndWidth() {
        let moved = AXAuditor.auditConsistency(sections: all {
            basketWindow(section: $0, searchY: $0 == "networks" ? 80 : 70)
        }).rule(AXAuditRules.consistencySearch)
        #expect(moved.map(\.identifier) == ["networks.search"])
        #expect(moved.first?.severity == .warning)

        let nudged = AXAuditor.auditConsistency(sections: all {
            basketWindow(section: $0, searchY: $0 == "networks" ? 73 : 70, searchWidth: $0 == "images" ? 306 : 300)
        })
        #expect(nudged.isEmpty, "within ±4 pt y and ±8 pt width")

        let narrow = AXAuditor.auditConsistency(sections: all {
            basketWindow(section: $0, searchWidth: $0 == "machines" ? 200 : 300)
        }).rule(AXAuditRules.consistencySearch)
        #expect(narrow.map(\.identifier) == ["machines.search"])
    }

    @Test func actionRolesAgreePerVerb() {
        let findings = AXAuditor.auditConsistency(sections: all {
            basketWindow(section: $0, refreshRole: $0 == "images" ? "AXMenuButton" : "AXButton")
        }).rule(AXAuditRules.consistencyActions)
        #expect(findings.map(\.identifier) == ["images.action.refresh"])
        #expect(findings.first?.message.contains("AXMenuButton") == true)
    }

    @Test func headerActionHeightsAgree() {
        let findings = AXAuditor.auditConsistency(sections: all {
            basketWindow(section: $0, refreshHeight: $0 == "containers" ? 30 : 24)
        }).rule(AXAuditRules.consistencyActions)
        #expect(Set(findings.compactMap(\.identifier)) == ["containers.action.refresh", "containers.action.export"])
        #expect(findings.allSatisfy { $0.message.contains("header") })
    }

    @Test func toolbarAndHeaderActionsAreComparedSeparately() {
        // Toolbar buttons (36 pt) vs header buttons (24 pt) differ by design.
        #expect(AXAuditor.auditConsistency(sections: all { basketWindow(section: $0) }).isEmpty)
        let findings = AXAuditor.auditConsistency(sections: all {
            basketWindow(section: $0, toolbarActionHeight: $0 == "overview" ? 28 : 36)
        }).rule(AXAuditRules.consistencyActions)
        #expect(findings.map(\.identifier) == ["overview.action.new"])
        #expect(findings.first?.message.contains("toolbar") == true)
    }

    @Test func sectionTitlesShareARole() {
        let findings = AXAuditor.auditConsistency(sections: all {
            basketWindow(section: $0, titleRole: $0 == "machines" ? "AXStaticText" : "AXHeading")
        }).rule(AXAuditRules.consistencyTitle)
        #expect(findings.count == 1)
        #expect(findings.first?.path.hasPrefix("machines:") == true)
        #expect(findings.first?.message.contains("AXHeading") == true)
    }

    @Test func localizedSectionTitlesAreFoundThroughTheSectionLabel() {
        // Titles in another language: found by the section root's label, not by English text.
        let findings = AXAuditor.auditConsistency(sections: all {
            basketWindow(section: $0, titleRole: $0 == "machines" ? "AXStaticText" : "AXHeading",
                         localizedTitle: "标题 \($0)")
        }).rule(AXAuditRules.consistencyTitle)
        #expect(findings.map(\.severity) == [.warning])
        #expect(findings.first?.path.hasPrefix("machines:") == true)
    }

    @Test func missingTitleIsInfoAndSidebarTextIsNotATitle() {
        let findings = AXAuditor.auditConsistency(sections: all {
            basketWindow(section: $0, withTitle: $0 != "images")
        }).rule(AXAuditRules.consistencyTitle)
        // The sidebar's "Images" text must not be mistaken for the title.
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .info)
        #expect(findings.first?.path.hasPrefix("images:") == true)
    }

    @Test func windowSizeChange() {
        let findings = AXAuditor.auditConsistency(sections: all {
            basketWindow(section: $0, size: $0 == "volumes" ? (1200, 820) : (1280, 820))
        }).rule(AXAuditRules.consistencyWindow)
        #expect(findings.count == 1)
        #expect(findings.first?.path.hasPrefix("volumes:") == true)
    }

    @Test func migrationTitleReadsMigrateFromOrbStack() {
        let tree = AXTreeIndex(basketWindow(section: "migration"))
        let title = AXAuditor.sectionTitle("migration", in: tree)
        #expect(title.flatMap { tree[$0].node.text } == "Migrate from OrbStack")
        #expect(AXAuditor.displayName("images") == "Images")
    }

    @Test func sectionOrderFollowsTheSidebar() {
        #expect(AXAuditor.orderedSections(["zeta", "images", "overview", "alpha"]) == ["overview", "images", "alpha", "zeta"])
    }
}
