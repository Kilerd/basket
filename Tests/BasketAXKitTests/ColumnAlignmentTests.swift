import Testing
@testable import BasketAXKit

/// A table whose rows each have one cell per entry of `columns`; each cell holds the given nodes.
private func table(_ rows: [[[AXNode]]], id: String = "containers.list") -> AXNode {
    let tableRows = rows.enumerated().map { i, cells in
        let y = 230 + Double(i) * 24
        return node("AXRow", nil, r(570, y, 1052, 24), children: cells.enumerated().map { c, content in
            node("AXCell", nil, r(586 + Double(c) * 200, y, 190, 24), children: [
                AXNode(role: "AXGroup", subrole: "AXHostingView", frame: r(586 + Double(c) * 200, y, 190, 24), children: content),
            ])
        })
    }
    return window([node("AXScrollArea", nil, r(570, 197, 1052, 600), children: [
        node("AXOutline", id, r(570, 197, 1052, 600), children: tableRows),
    ])])
}

private func bar(_ x: Double, _ y: Double, width: Double = 60, role: String = "AXProgressIndicator") -> AXNode {
    AXNode(role: role, label: "Memory", value: "0.4", frame: r(x, y + 8, width, 8))
}

private func columnFindings(_ tree: AXNode) -> [AXFinding] {
    AXAuditor.audit(window: tree, section: nil).rule(AXAuditRules.columnAlignment)
}

@Suite struct ColumnAlignmentTests {
    let memory = ["10.2 MB / 512 MB", "1.9 MB / 1 GB", "212 MB / 1 GB", "9.2 MB / 256 MB"]

    /// The user-reported defect: "<text> <bar>" with the bar right after the text.
    @Test func barsFollowingTextOfVaryingWidthAreRagged() {
        let rows = memory.enumerated().map { i, label -> [[AXNode]] in
            let y = 230 + Double(i) * 24
            let w = TextMeasure.width(of: label, fontSize: 13).rounded(.up)
            return [[text("row\(i)", r(586, y + 4, 60, 16))],
                    [text(label, r(786, y + 4, w, 16)), bar(786 + w + 6, y)]]
        }
        let findings = columnFindings(table(rows))
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .error, "bars start > 4 pt apart")
        #expect(findings.first?.message.contains("column 2 of “containers.list”") == true)
        #expect(findings.first?.message.contains("AXProgressIndicator") == true)
    }

    @Test func fixedBarColumnPasses() {
        let rows = memory.enumerated().map { i, label -> [[AXNode]] in
            let y = 230 + Double(i) * 24
            return [[text("row\(i)", r(586, y + 4, 60, 16))],
                    [text(label, r(786, y + 4, TextMeasure.width(of: label, fontSize: 13).rounded(.up), 16)), bar(900, y)]]
        }
        #expect(columnFindings(table(rows)).isEmpty)
    }

    @Test func rightAlignedNumbersPass() {
        let rows = ["3.25 GB", "375.5 MB", "10.75 GB"].enumerated().map { i, label -> [[AXNode]] in
            let w = TextMeasure.width(of: label, fontSize: 13).rounded(.up)
            return [[text(label, r(976 - w, 234 + Double(i) * 24, w, 16))]]
        }
        #expect(columnFindings(table(rows)).isEmpty)
    }

    @Test func raggedTextIsAWarning() {
        let rows = [(800.0, 60.0), (812.0, 30.0), (790.0, 90.0)].enumerated().map { i, xw -> [[AXNode]] in
            [[text("value \(i)", r(xw.0, 234 + Double(i) * 24, xw.1, 16))]]
        }
        let findings = columnFindings(table(rows))
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .warning)
        #expect(findings.first?.message.contains("neither left-, right- nor centre-aligned") == true)
    }

    @Test func smallBarDriftIsAWarningAndSubPointIsFine() {
        func rows(_ xs: [Double]) -> [[[AXNode]]] {
            xs.enumerated().map { i, x in [[bar(x, 230 + Double(i) * 24)]] }
        }
        #expect(columnFindings(table(rows([900, 902.5]))).first?.severity == .warning)
        #expect(columnFindings(table(rows([900, 900.5]))).isEmpty)
        // Same x but different widths is ragged too.
        let widths = [[[bar(900, 230, width: 60)]], [[bar(900, 254, width: 40)]]]
        #expect(columnFindings(table(widths)).count == 1)
    }

    @Test func singleRowAndPlaceholderRowsAreIgnored() {
        #expect(columnFindings(table([[[text("10.2 MB / 512 MB", r(786, 234, 104, 16)), bar(896, 230)]]])).isEmpty)
        // A "—" row has no bar; only the two real rows are compared (and they agree).
        let rows: [[[AXNode]]] = [
            [[text("—", r(786, 234, 11.5, 16))]],
            [[text("10.2 MB / 512 MB", r(786, 258, 104, 16)), bar(900, 254)]],
            [[text("1.9 MB / 1 GB", r(786, 282, 80, 16)), bar(900, 278)]],
        ]
        #expect(columnFindings(table(rows)).isEmpty)
    }

    @Test func thinUnknownRoleShapesCountAsBarsButUnknownTextDoesNot() {
        // SwiftUI exposes a labelled bar shape as AXUnknown (8 pt tall): treated as a bar.
        let bars: [[[AXNode]]] = [[[bar(890, 230, role: "AXUnknown")]], [[bar(910, 254, role: "AXUnknown")]]]
        #expect(columnFindings(table(bars)).first?.severity == .error)
        // Text-height AXUnknown elements ("1.4%") are text: left-aligned values pass.
        let texts: [[[AXNode]]] = [
            [[AXNode(role: "AXUnknown", label: "1.4%", frame: r(1189, 234, 32, 16))]],
            [[AXNode(role: "AXUnknown", label: "12.25%", frame: r(1189, 258, 45, 16))]],
        ]
        #expect(columnFindings(table(texts)).isEmpty)
    }

    @Test func sidebarLabelJitterIsTolerated() {
        let rows = [373.5, 372, 372.5, 373.5].enumerated().map { i, x -> [[AXNode]] in
            [[text(["Overview", "Images", "Volumes", "Networks"][i], r(x, 205 + Double(i) * 32, 60 + Double(i) * 5, 16))]]
        }
        #expect(columnFindings(table(rows)).isEmpty)
    }

    @Test func sidebarSectionHeadersAreNotComparedWithItems() {
        let rows: [[[AXNode]]] = [
            [[text("Overview", r(373.5, 205, 56, 16))]],
            [[text("Resources", r(364, 244, 58, 14), role: "AXHeading")]],
            [[text("Containers", r(373.5, 268, 66, 16))]],
            [[text("Images", r(372, 300, 43, 16))]],
            [[text("Linux", r(364, 404, 30, 14), role: "AXHeading")]],
        ]
        #expect(columnFindings(table(rows)).isEmpty)
    }

    @Test func badgeFollowingVaryingTextIsRagged() {
        // Images "Disk" column: "30.4 MB [8 platforms]" — the badge trails the size text.
        let rows: [[[AXNode]]] = [
            [[text("30.4 MB", r(1008.5, 234, 51.5, 16)), text("8 platforms", r(1066, 234, 83, 17))]],
            [[text("158.9 MB", r(1008.5, 258, 60, 16)), text("6 platforms", r(1074.5, 258, 83, 17))]],
        ]
        #expect(columnFindings(table(rows)).count == 1)
    }

    @Test func placeholdersKeepTheirSlot() {
        // The fixed layout: used (right-aligned) · "/ limit" (left-aligned) · bar; "—" when unknown.
        let rows: [[[AXNode]]] = [
            [[text("—", r(1336.5, 234, 11.5, 16)), text("/ 256 MB", r(1354, 234, 55.5, 16))]],
            [[text("212 MB", r(1300, 258, 48, 16)), text("/ 1 GB", r(1354, 258, 37.5, 16)), bar(1424, 254, width: 40.5)]],
            [[text("9.2 MB", r(1304.5, 282, 43.5, 16)), text("/ 256 MB", r(1354, 282, 55.5, 16)), bar(1424, 278, width: 40.5)]],
        ]
        #expect(columnFindings(table(rows)).isEmpty)
    }

    @Test func rowsScrolledOutOfViewAreSkipped() {
        // The table's scroll area shows y 197…797 (rows 0–23). Row 25 isn't laid out yet: its
        // checkbox still sits at the cell origin.
        func checkbox(_ x: Double, row i: Int) -> [[AXNode]] {
            [[AXNode(role: "AXCheckBox", label: "Import \(i)", frame: r(x, 234 + Double(i) * 24, 16, 16))]]
        }
        let visibleOnly = (0..<24).map { checkbox(604, row: $0) } + [checkbox(586, row: 24), checkbox(586, row: 25)]
        #expect(columnFindings(table(visibleOnly)).isEmpty)
        // The same drift inside the visible area is caught.
        let inView = (0..<3).map { checkbox(604, row: $0) } + [checkbox(586, row: 3)]
        #expect(columnFindings(table(inView)).first?.severity == .error)
    }

    @Test func rowsWithADifferentCellCountAreNotPartOfTheGrid() {
        var rows: [[[AXNode]]] = (0..<3).map { i in [[text("name", r(586, 234 + Double(i) * 24, 40, 16))], [bar(900, 230 + Double(i) * 24)]] }
        rows.append([[bar(700, 302)]])  // a group/header row with one cell
        #expect(columnFindings(table(rows)).isEmpty)
    }
}

@Suite struct RepeatedRowAlignmentTests {
    /// A Grid flattened into its card: label + value pairs per line.
    func card(_ pairs: [(String, Double, Double)]) -> AXNode {
        let children = pairs.enumerated().flatMap { i, p -> [AXNode] in
            let y = 337 + Double(i) * 23
            return [text(p.0, r(606, y, 60, 15)), text("value", r(p.1, y, p.2, 15))]
        }
        return window([group(children, id: "overview.card.memory", frame: r(590, 217, 498, 376))])
    }

    @Test func rightAlignedValuesPass() {
        let tree = card([("Host", 1025.5, 46.5), ("Guest", 1016, 56), ("Stranded", 1016, 56), ("Limits", 1017.5, 54.5)])
        #expect(columnFindings(tree).isEmpty)
    }

    @Test func raggedValuesAreFlagged() {
        let tree = card([("Host", 1000, 40), ("Guest", 1016, 70), ("Limits", 990, 30)])
        let findings = columnFindings(tree)
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .warning)
        #expect(findings.first?.message.contains("repeated rows") == true)
    }

    @Test func formFieldsRightAlignedAfterVaryingLabelsPass() {
        let rows = [("Name", 796.5, 416.5), ("Command", 823, 390)].enumerated().flatMap { i, f -> [AXNode] in
            let y = 409 + Double(i) * 37
            return [text(f.0, r(753, y, 40, 16)),
                    AXNode(role: "AXTextField", title: f.0, frame: r(f.1, y, f.2, 16))]
        }
        #expect(columnFindings(window([group(rows, frame: r(743, 361, 480, 111))])).isEmpty)
    }

    @Test func differentRowShapesAreNotCompared() {
        let tree = window([group([
            text("Memory", r(606, 237, 76, 16)), button("a.reclaim", r(968, 233, 103, 24), title: "Reclaim"),
            text("Host", r(606, 337, 60, 15)), text("3.25 GB", r(1025, 337, 46, 15)),
        ], frame: r(590, 217, 498, 376))])
        #expect(columnFindings(tree).isEmpty)
    }
}
