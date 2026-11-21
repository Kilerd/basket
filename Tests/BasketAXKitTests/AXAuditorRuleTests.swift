import Testing
@testable import BasketAXKit

@Suite struct CleanTreeTests {
    @Test(arguments: AXAuditRules.sections)
    func contractCompleteWindowHasNoFindings(section: String) {
        let findings = AXAuditor.audit(window: basketWindow(section: section), section: section)
        #expect(findings.isEmpty, "\(findings.map { "\($0.rule): \($0.message)" })")
    }
}

@Suite struct MissingLabelTests {
    func audit(_ n: AXNode) -> [AXFinding] {
        AXAuditor.audit(window: window([n]), section: nil).rule(AXAuditRules.missingLabel)
    }

    @Test func unnamedButtonIsAnError() {
        let findings = audit(button("x.action.trash", r(200, 200, 30, 30), title: nil))
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .error)
        #expect(findings.first?.identifier == "x.action.trash")
        #expect(findings.first?.path == "AXWindow#basket.main/AXButton#x.action.trash")
    }

    @Test func titleDescriptionOrHelpNameIt() {
        #expect(audit(button(nil, r(200, 200, 30, 30), title: "Trash")).isEmpty)
        #expect(audit(button(nil, r(200, 200, 30, 30), title: nil, label: "Trash")).isEmpty)
        #expect(audit(AXNode(role: "AXButton", help: "Move to trash", frame: r(200, 200, 30, 30))).isEmpty)
        #expect(audit(button(nil, r(200, 200, 30, 30), title: "   ")).count == 1, "whitespace is not a name")
    }

    @Test func valueNamesPopUpsButNotCheckBoxes() {
        #expect(audit(AXNode(role: "AXPopUpButton", value: "Newest first", frame: r(200, 200, 120, 24))).isEmpty)
        #expect(audit(AXNode(role: "AXCheckBox", value: "1", frame: r(200, 200, 20, 20))).count == 1)
        #expect(audit(AXNode(role: "AXSlider", value: "0.5", frame: r(200, 200, 120, 20))).count == 1)
    }

    @Test func textFieldsMayUsePlaceholderButNotTheirContent() {
        #expect(audit(field("a.search", r(200, 200, 200, 24))).isEmpty)
        #expect(audit(AXNode(role: "AXTextField", value: "alpine:latest", frame: r(200, 200, 200, 24))).count == 1)
    }

    @Test func ignoresWindowChromeAndNonInteractiveRoles() {
        #expect(audit(button(nil, r(120, 118, 16, 16), title: nil, subrole: "AXCloseButton")).isEmpty)
        #expect(audit(node("AXStaticText", nil, r(200, 200, 50, 16))).isEmpty)
        #expect(audit(node("AXGroup", nil, r(200, 200, 50, 16))).isEmpty)
    }

    @Test func ignoresSystemControlParts() {
        // Stepper arrows and scroll-bar parts as exposed out of process (unnamed, system-sized).
        let stepper = AXNode(role: "AXIncrementor", title: "CPUs", frame: r(200, 200, 20, 26), children: [
            AXNode(role: "AXButton", subrole: "AXIncrementArrow", frame: r(200, 200, 20, 13)),
            AXNode(role: "AXButton", subrole: "AXDecrementArrow", frame: r(200, 213, 20, 13)),
        ])
        let scrollBar = AXNode(role: "AXScrollBar", value: "0", frame: r(400, 200, 15, 300), children: [
            AXNode(role: "AXButton", subrole: "AXIncrementPage", frame: r(404, 300, 6, 159)),
            AXNode(role: "AXButton", subrole: "AXDecrementPage", frame: r(404, 200, 6, 0)),
        ])
        let findings = AXAuditor.audit(window: window([stepper, scrollBar]), section: nil)
        #expect(findings.isEmpty, "\(findings.map(\.message))")
    }

    @Test func coversSubroleOnlyControls() {
        let segment = AXNode(role: "AXRadioButton", subrole: "AXSegment", frame: r(200, 200, 40, 24))
        let toggle = AXNode(role: "AXCheckBox", subrole: "AXSwitch", frame: r(200, 240, 40, 24))
        let findings = AXAuditor.audit(window: window([segment, toggle]), section: nil).rule(AXAuditRules.missingLabel)
        #expect(findings.count == 2)
    }

    @Test func labelsOnlyAuditForSheets() {
        let sheet = node("AXSheet", nil, r(300, 200, 400, 300), children: [
            AXNode(role: "AXTextField", title: "Name", frame: r(320, 220, 200, 24)),
            AXNode(role: "AXTextField", frame: r(320, 250, 200, 24)),
            AXNode(role: "AXButton", title: "Cancel", frame: r(-5000, 0, 2, 2)),
        ])
        let findings = AXAuditor.auditLabels(sheet)
        #expect(findings.map(\.rule) == [AXAuditRules.missingLabel])
    }
}

@Suite struct OutOfWindowTests {
    func audit(_ children: [AXNode]) -> [AXFinding] {
        AXAuditor.audit(window: window(children), section: nil).rule(AXAuditRules.outOfWindow)
    }

    @Test func fullyOutsideIsAnErrorPartiallyClippedAWarning() {
        let findings = audit([
            button("a.outside", r(2000, 300, 80, 24)),
            button("a.clipped", r(1350, 300, 80, 24)),  // window spans x 100…1380
            button("a.inside", r(1290, 300, 80, 24)),
        ])
        #expect(findings.count == 2)
        #expect(findings.first { $0.identifier == "a.outside" }?.severity == .error)
        #expect(findings.first { $0.identifier == "a.clipped" }?.severity == .warning)
    }

    @Test func roundingToleranceOfOnePoint() {
        #expect(audit([button("a.edge", r(99, 99, 80, 24))]).isEmpty)
        #expect(audit([button("a.edge", r(98, 99, 80, 24))]).count == 1)
    }

    @Test func scrolledOutContentIsIgnored() {
        let scroll = node("AXScrollArea", nil, r(200, 200, 400, 300), children: [
            node("AXOutline", nil, r(200, 200, 400, 3000), children: [
                node("AXRow", nil, r(200, 1800, 400, 24), children: [text("row", r(210, 1804, 50, 16))]),
                node("AXRow", nil, r(200, 490, 400, 24)),  // half visible at the bottom edge
            ]),
        ])
        #expect(audit([scroll]).isEmpty)
    }

    @Test func scrollAreaItselfIsChecked() {
        let scroll = node("AXScrollArea", nil, r(1200, 200, 400, 300), children: [
            node("AXOutline", nil, r(1200, 200, 400, 300)),
        ])
        let findings = audit([scroll])
        #expect(findings.count == 1, "only the outermost offender is reported")
        #expect(findings.first?.path == "AXWindow#basket.main/AXScrollArea")
    }

    @Test func zeroSizedElementsAndFramelessWindowsAreSkipped() {
        #expect(audit([node("AXSplitter", nil, r(5000, 0, 0, 400))]).isEmpty)
        let noFrame = window([button("a.b", r(5000, 0, 10, 10))], frame: nil)
        #expect(AXAuditor.audit(window: noFrame, section: nil).rule(AXAuditRules.outOfWindow).isEmpty)
    }
}

@Suite struct OverlapTests {
    func audit(_ children: [AXNode]) -> [AXFinding] {
        AXAuditor.audit(window: window([group(children)]), section: nil).rule(AXAuditRules.overlap)
    }

    @Test func overlappingSiblingButtons() {
        let findings = audit([button("a.one", r(200, 200, 80, 24)), button("a.two", r(270, 200, 80, 24))])
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .error)
        #expect(findings.first?.frame == r(270, 200, 10, 24))
    }

    @Test func tinyOrTouchingOverlapsAreFine() {
        #expect(audit([button("a.one", r(200, 200, 80, 24)), button("a.two", r(278, 222, 80, 24))]).isEmpty, "2×2 = 4 pt²")
        #expect(audit([button("a.one", r(200, 200, 80, 24)), button("a.two", r(280, 200, 80, 24))]).isEmpty)
    }

    @Test func looksThroughAnonymousWrappers() {
        let wrapped = group([button("a.two", r(250, 200, 80, 24))])
        #expect(audit([button("a.one", r(200, 200, 80, 24)), wrapped]).count == 1)
    }

    @Test func ignoresNonInteractiveAndNestedElements() {
        #expect(audit([button("a.one", r(200, 200, 80, 24)), text("label", r(200, 200, 80, 16))]).isEmpty)
        // Toolbar item viewer + the button inside it (same id) are nested, not siblings.
        let viewer = button("a.pull", r(200, 0, 44, 52), title: nil, label: "Pull",
                            children: [button("a.pull", r(204, 8, 36, 36), title: nil, label: "Pull")])
        #expect(audit([viewer]).isEmpty)
    }
}

@Suite struct TinyTargetTests {
    func audit(_ n: AXNode) -> [AXFinding] {
        AXAuditor.audit(window: window([n]), section: nil).rule(AXAuditRules.tinyTarget)
    }

    @Test func buttonsNeedTwentyByTwenty() {
        #expect(audit(button("a.b", r(200, 200, 16, 16))).first?.severity == .warning)
        #expect(audit(button("a.b", r(200, 200, 80, 19))).count == 1)
        #expect(audit(button("a.b", r(200, 200, 20, 20))).isEmpty)
    }

    @Test func textInputsNeedEighteenHigh() {
        #expect(audit(field("a.search", r(200, 200, 200, 18))).isEmpty)
        #expect(audit(field("a.search", r(200, 200, 200, 16))).count == 1)
    }

    @Test func togglesUseTheSystemGlyphSize() {
        #expect(audit(AXNode(role: "AXCheckBox", title: "Auto-start", frame: r(200, 200, 84, 16))).isEmpty)
        #expect(audit(AXNode(role: "AXCheckBox", title: "x", frame: r(200, 200, 12, 12))).count == 1)
    }

    @Test func exemptsChromeFixedSystemControlsAndHiddenElements() {
        #expect(audit(button(nil, r(120, 118, 14, 14), title: nil, subrole: "AXCloseButton")).isEmpty)
        #expect(audit(AXNode(role: "AXDisclosureTriangle", title: "expand", frame: r(200, 200, 13, 13))).isEmpty)
        #expect(audit(button("a.b", r(200, 200, 0, 0))).isEmpty)
        #expect(audit(button("a.b", nil)).isEmpty)
    }

    @Test func searchFieldGlyphButtonsArePartOfTheField() {
        var search = field("a.search", r(200, 200, 200, 24))
        search.children = [button(nil, r(206, 207, 16, 9), title: "Search"), button(nil, r(380, 206, 12, 12), title: "Clear")]
        #expect(audit(search).isEmpty)
    }
}

@Suite struct InconsistentHeightTests {
    func audit(_ children: [AXNode]) -> [AXFinding] {
        AXAuditor.audit(window: window([group(children)]), section: nil).rule(AXAuditRules.inconsistentHeight)
    }

    @Test func outlierInARowIsFlagged() {
        let findings = audit([
            button("a.one", r(200, 200, 80, 24)), button("a.two", r(290, 200, 80, 24)),
            button("a.three", r(380, 204, 20, 16)),
        ])
        #expect(findings.count == 1)
        #expect(findings.first?.identifier == "a.three")
        #expect(findings.first?.message.contains("24 pt") == true)
    }

    @Test func smallDifferencesAreTolerated() {
        #expect(audit([button("a.one", r(200, 200, 80, 24)), button("a.two", r(290, 199, 80, 26))]).isEmpty)
    }

    @Test func tieGoesToTheTallerButton() {
        let findings = audit([button("a.one", r(200, 200, 80, 24)), button("a.two", r(290, 204, 30, 14))])
        #expect(findings.map(\.identifier) == ["a.two"])
    }

    @Test func differentRowsAndParentsAreIndependent() {
        #expect(audit([button("a.one", r(200, 200, 80, 24)), button("a.two", r(200, 300, 80, 32))]).isEmpty)
        let split = window([group([button("a.one", r(200, 200, 80, 24))]),
                            group([button("a.two", r(290, 200, 80, 32)), text("t", r(400, 200, 20, 16))])])
        #expect(AXAuditor.audit(window: split, section: nil).rule(AXAuditRules.inconsistentHeight).isEmpty)
    }

    @Test func windowChromeIsIgnored() {
        #expect(audit([button(nil, r(120, 118, 16, 16), title: nil, subrole: "AXCloseButton"),
                       button("a.one", r(140, 110, 80, 32))]).isEmpty)
    }
}

@Suite struct DuplicateIdentifierTests {
    func audit(_ children: [AXNode]) -> [AXFinding] {
        AXAuditor.audit(window: window(children), section: nil).rule(AXAuditRules.duplicateIdentifier)
    }

    @Test func siblingsSharingAnIdentifier() {
        let findings = audit([button("a.refresh", r(200, 200, 80, 24)), button("a.refresh", r(300, 200, 80, 24))])
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .warning)
        #expect(findings.first?.message.contains("2 separate elements") == true)
    }

    @Test func nestedRepeatsAreOneElement() {
        let viewer = button("a.pull", r(200, 0, 44, 52), children: [button("a.pull", r(204, 8, 36, 36))])
        #expect(audit([viewer]).isEmpty)
    }

    @Test func rowIdentifiersMustBeUniqueAmongRows() {
        func row(_ y: Double, id: String) -> AXNode {
            node("AXRow", nil, r(200, y, 400, 24), children: [
                node("AXCell", nil, r(200, y, 200, 24), children: [text("a", r(210, y + 4, 40, 16), id: id)]),
                node("AXCell", nil, r(400, y, 200, 24), children: [text("b", r(410, y + 4, 40, 16), id: id)]),
            ])
        }
        // Same id in two cells of one row: fine. Same id in two rows: duplicate.
        #expect(audit([node("AXOutline", nil, r(200, 200, 400, 100), children: [row(200, id: "c.row.web"), row(224, id: "c.row.db")])]).isEmpty)
        let dup = audit([node("AXOutline", nil, r(200, 200, 400, 100), children: [row(200, id: "c.row.web"), row(224, id: "c.row.web")])])
        #expect(dup.count == 1)
        #expect(dup.first?.identifier == "c.row.web")
    }

    @Test func systemIdentifiersAreIgnored() {
        #expect(audit([node("AXColumn", "ListColumn"), node("AXColumn", "ListColumn"),
                       button("_NS:12", nil), button("_NS:12", nil),
                       button("com.apple.SwiftUI.x", nil), button("com.apple.SwiftUI.x", nil)]).isEmpty)
    }
}

@Suite struct TruncationTests {
    func audit(_ n: AXNode) -> [AXFinding] {
        AXAuditor.audit(window: window([n]), section: nil).rule(AXAuditRules.truncation)
    }

    let long = "A status line that cannot fit into a narrow frame"

    @Test func textWiderThanItsFrame() {
        let findings = audit(text(long, r(200, 200, 120, 16), id: "a.status"))
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .warning)
        #expect(findings.first?.message.contains("13 pt") == true)
    }

    @Test func fittingTextIsFine() {
        let width = TextMeasure.width(of: long, fontSize: 13)
        #expect(audit(text(long, r(200, 200, width.rounded(.up), 16))).isEmpty)
        #expect(audit(text(long, r(200, 200, width - 1.5, 16))).isEmpty, "2 pt tolerance")
    }

    @Test func smallerFontsAreInferredFromFrameHeight() {
        // A 12 pt caption (15 pt tall frame) fitting exactly must not be measured at 13 pt…
        let w12 = TextMeasure.width(of: long, fontSize: 12)
        #expect(audit(text(long, r(200, 200, w12.rounded(.up), 15))).isEmpty)
        // …but the same width in a 16 pt (13 pt font) frame is too narrow.
        #expect(audit(text(long, r(200, 200, w12.rounded(.up), 16))).count == 1)
        // 11 pt text when the frame is under 15 pt tall.
        let w11 = TextMeasure.width(of: long, fontSize: 11)
        #expect(audit(text(long, r(200, 200, w11.rounded(.up), 14))).isEmpty)
    }

    @Test func wrappedTextUsesAllLines() {
        let w = TextMeasure.width(of: long, fontSize: 13)
        #expect(audit(text(long, r(200, 200, (w / 2).rounded(.up) + 10, 32))).isEmpty)
        #expect(audit(text(long, r(200, 200, 60, 32))).count == 1)
    }

    @Test func ellipsisOnlyCountsWhenTheTextFillsItsFrame() {
        #expect(audit(text("Loading…", r(200, 200, 300, 16))).isEmpty, "intentional ellipsis")
        let truncated = "/Users/someone/Library/Containers/…"
        let w = TextMeasure.width(of: truncated, fontSize: 13)
        #expect(audit(text(truncated, r(200, 200, w.rounded(.up), 16))).count == 1)
    }

    @Test func veryShortTextIsNotChecked() {
        #expect(audit(text("—", r(200, 200, 7.7, 15))).isEmpty)
        #expect(audit(text("42", r(200, 200, 5, 16))).isEmpty)
        #expect(audit(text("4 GB", r(200, 200, 5, 16))).count == 1)
    }

    @Test func chineseAndJapaneseTextIsMeasuredFromTwoCharacters() {
        // Two ideographs are a whole word ("容器" = container).
        #expect(audit(text("容器", r(200, 200, 14, 16))).count == 1)
        let width = TextMeasure.width(of: "容器", fontSize: 13)
        #expect(width > 20, "ideographs are measured with a fallback font, not as zero-width glyphs")
        #expect(audit(text("容器", r(200, 200, width.rounded(.up), 16))).isEmpty)
        #expect(audit(text("滞留メモリを解放", r(200, 200, 40, 16))).count == 1)
    }

    @Test func headingsUseTheirLabel() {
        #expect(audit(text(long, r(200, 200, 60, 16), role: "AXHeading")).count == 1)
        #expect(audit(node("AXStaticText", nil, r(200, 200, 10, 16))).isEmpty, "no text, nothing to measure")
    }
}

@Suite struct UnknownRoleAndRepeatedLabelTests {
    @Test func labelOnAGridRowIsCopiedOntoEveryCell() {
        // What SwiftUI produces for `GridRow { … }.accessibilityElement(children: .ignore).accessibilityLabel("Host")`.
        let cells = [r(200, 200, 60, 16), r(270, 200, 100, 20), r(380, 200, 40, 16)].map {
            AXNode(role: "AXUnknown", label: "Host (real)", frame: $0)
        }
        let findings = AXAuditor.audit(window: window([group(cells, id: "overview.card.memory")]), section: nil)
        let unknown = findings.rule(AXAuditRules.unknownRole)
        #expect(unknown.count == 1, "one finding per container")
        #expect(unknown.first?.message.contains("3 elements") == true)
        let repeated = findings.rule(AXAuditRules.repeatedLabel)
        #expect(repeated.count == 1)
        #expect(repeated.first?.message.contains("3 sibling elements") == true)
    }

    @Test func distinctLabelsAndNamelessUnknownsAreFine() {
        let tree = window([group([
            button("a.copy-ip", r(200, 200, 80, 24), title: "Copy IP"),
            button("a.copy-id", r(290, 200, 80, 24), title: "Copy ID"),
            node("AXUnknown", nil, r(200, 240, 10, 10)),
        ])])
        let findings = AXAuditor.audit(window: tree, section: nil)
        #expect(findings.rule(AXAuditRules.repeatedLabel).isEmpty)
        #expect(findings.rule(AXAuditRules.unknownRole).isEmpty)
    }

    @Test func ambiguousButtonsAreFlaggedButRowsAndNestingAreNot() {
        let ambiguous = window([group([button("a.one", r(200, 200, 80, 24), title: "Copy"),
                                       button("a.two", r(290, 200, 80, 24), title: "Copy")])])
        #expect(AXAuditor.audit(window: ambiguous, section: nil).rule(AXAuditRules.repeatedLabel).count == 1)
        let rows = window([node("AXOutline", nil, r(200, 200, 400, 100), children: [
            AXNode(role: "AXRow", label: "Row", frame: r(200, 200, 400, 24)),
            AXNode(role: "AXRow", label: "Row", frame: r(200, 224, 400, 24)),
        ])])
        #expect(AXAuditor.audit(window: rows, section: nil).rule(AXAuditRules.repeatedLabel).isEmpty)
        let placeholders = window([group([
            AXNode(role: "AXStaticText", help: "—", value: "—", frame: r(200, 200, 10, 16)),
            AXNode(role: "AXStaticText", help: "—", value: "—", frame: r(200, 220, 10, 16)),
        ])])
        #expect(AXAuditor.audit(window: placeholders, section: nil).rule(AXAuditRules.repeatedLabel).isEmpty)
        let viewer = window([button("a.pull", r(200, 100, 44, 52), title: nil, label: "Pull",
                                    children: [button("a.pull", r(204, 108, 36, 36), title: nil, label: "Pull")])])
        #expect(AXAuditor.audit(window: viewer, section: nil).rule(AXAuditRules.repeatedLabel).isEmpty)
    }
}

@Suite struct ContractTests {
    func contract(_ tree: AXNode, _ section: String?) -> [AXFinding] {
        AXAuditor.audit(window: tree, section: section).rule(AXAuditRules.contract)
    }

    @Test func mainWindowIdentifierIsAlwaysRequired() {
        let findings = contract(window([], id: nil), nil)
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .error)
        #expect(findings.first?.identifier == "basket.main")
        #expect(contract(window([group([], id: "basket.main")], id: nil), nil).isEmpty, "may sit on the content")
    }

    @Test func listSectionNeedsSearchRefreshAndListOrEmpty() {
        var tree = basketWindow(section: "volumes")
        #expect(contract(tree, "volumes").isEmpty)
        tree = strip(tree, ids: ["volumes.search", "volumes.action.refresh"])
        #expect(Set(contract(tree, "volumes").compactMap(\.identifier)) == ["volumes.search", "volumes.action.refresh"])

        let empty = strip(basketWindow(section: "volumes"), ids: ["volumes.list"])
        #expect(contract(empty, "volumes").map(\.identifier) == ["volumes.list"])
        let withEmptyState = window(empty.children + [group([], id: "volumes.empty")])
        #expect(contract(withEmptyState, "volumes").isEmpty)
    }

    @Test func migrationIsAListSection() {
        #expect(contract(basketWindow(section: "migration"), "migration").isEmpty)
        let tree = strip(basketWindow(section: "migration"), ids: ["migration.search", "migration.action.refresh", "sidebar.migration"])
        #expect(Set(contract(tree, "migration").compactMap(\.identifier))
            == ["migration.search", "migration.action.refresh", "sidebar.migration"])
        let empty = window(strip(basketWindow(section: "migration"), ids: ["migration.list"]).children + [group([], id: "migration.empty")])
        #expect(contract(empty, "migration").isEmpty)
    }

    @Test func sectionRootAndSidebarItems() {
        let tree = strip(basketWindow(section: "networks"), ids: ["section.networks", "sidebar.machines"])
        #expect(Set(contract(tree, "networks").compactMap(\.identifier)) == ["section.networks", "sidebar.machines"])
    }

    @Test func overviewNeedsItsCards() {
        #expect(contract(basketWindow(section: "overview"), "overview").isEmpty)
        let tree = strip(basketWindow(section: "overview"), ids: ["overview.card.disk"])
        #expect(contract(tree, "overview").map(\.identifier) == ["overview.card.disk"])
        // The overview isn't a list section: no search/refresh needed.
        #expect(!AXAuditRules.requiredIdentifiers(section: "overview").joined().contains("overview.search"))
    }

    /// Removes the identifier (not the node) from every node carrying one of `ids`.
    func strip(_ n: AXNode, ids: Set<String>) -> AXNode {
        var copy = n
        if let id = copy.identifier, ids.contains(id) { copy.identifier = nil }
        copy.children = copy.children.map { strip($0, ids: ids) }
        return copy
    }
}
