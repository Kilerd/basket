import Testing
@testable import BasketAXKit

// Synthetic Overview cards in the shape the in-process capture produces: the card is one AXGroup
// with its texts flattened into it (bars drawn by SwiftUI are hidden from accessibility). Offsets
// are relative to the card's origin; a 498 pt card with 16 pt padding has its content edge at 482.

private let cardOrigin = (x: 700.0, y: 217.0)

private func at(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> AXRect {
    r(cardOrigin.x + x, cardOrigin.y + y, w, h)
}

private func card(_ id: String?, _ children: [AXNode], height: Double = 414.5) -> AXNode {
    window([group(children, id: id, frame: at(0, 0, 498, height))])
}

private func cardFindings(_ tree: AXNode) -> [AXFinding] {
    AXAuditor.audit(window: tree, section: nil).rule(AXAuditRules.cardTrailingAlignment)
}

/// The Disk card's header and hero number, then the breakdown table with its numeric columns
/// shifted by `shift` (0 = the reported layout, where the table keeps its natural width).
private func diskCard(shift: Double, id: String? = "overview.card.disk", header: Bool = true,
                      categories: [(String, String, String, String)]? = nil) -> AXNode {
    var children = [
        text("Disk", at(17.5, 20, 54, 16), role: "AXHeading"),
        button("overview.action.reclaim", at(375.5, 16, 106.5, 25), title: "Reclaim…"),
        text("10.14 GB", at(16, 54.92, 133.5, 35)),
        text("1.56 GB reclaimable", at(16, 91.92, 112.5, 15)),
    ]
    if header {
        children += [
            text("In use", at(117.5 + shift, 145.42, 29, 13)),
            text("Size", at(184.5 + shift, 145.42, 20.5, 13)),
            text("Reclaimable", at(217 + shift, 145.42, 58.5, 13)),
        ]
    }
    let rows = categories ?? [
        ("Containers", "7 of 10", "2.83 GB", "849.3 MB"),
        ("Images", "6 of 7", "2.15 GB", "676.7 MB"),
        ("Volumes", "3 of 4", "5.16 GB", "34.6 MB"),
    ]
    for (n, row) in rows.enumerated() {
        let y = 166.92 + Double(n) * 23
        // Right-aligned columns: each value ends at its column's right edge.
        func right(_ value: String, _ edge: Double) -> AXNode {
            let w = TextMeasure.width(of: value, fontSize: 12).rounded(.up)
            return text(value, at(edge + shift - w, y, w, 15))
        }
        children += [
            text(row.0, at(32, y, TextMeasure.width(of: row.0, fontSize: 12).rounded(.up), 15)),
            right(row.1, 146.5), right(row.2, 205), right(row.3, 275.5),
        ]
    }
    children.append(text("177.8 MB of images is for other CPU architectures", at(17, 241.92, 302.5, 15)))
    return card(id, children)
}

@Suite struct CardTrailingAlignmentTests {
    /// Issue #31: the breakdown ends at x=275.5 of the card while the bar and the Reclaim button
    /// end at 482.
    @Test func tableKeepingItsNaturalWidthIsFlagged() {
        let findings = cardFindings(diskCard(shift: 0))
        #expect(findings.count == 1)
        let finding = findings.first
        #expect(finding?.severity == .warning)
        #expect(finding?.identifier == "overview.card.disk")
        #expect(finding?.message.contains("206.5 pt before the card's content edge") == true)
        #expect(finding?.message.contains("4 rows") == true, "the header row belongs to the table")
        #expect(finding?.message.contains("“In use” … “Volumes”") == true)
    }

    @Test func tableSpanningTheCardPasses() {
        #expect(cardFindings(diskCard(shift: 206.5)).isEmpty)
        // Within the 2 pt tolerance.
        #expect(cardFindings(diskCard(shift: 205)).isEmpty)
        #expect(cardFindings(diskCard(shift: 204)).count == 1)
    }

    @Test func singleRowIsIgnored() {
        let one = diskCard(shift: 0, header: false, categories: [("Containers", "7 of 10", "2.83 GB", "849.3 MB")])
        #expect(cardFindings(one).isEmpty)
    }

    @Test func groupWithoutCardIdentifierOrBarIsIgnored() {
        #expect(cardFindings(diskCard(shift: 0, id: nil)).isEmpty)
        #expect(cardFindings(diskCard(shift: 0, id: "images.detail")).isEmpty)
    }

    @Test func placeholderValuesKeepTheirRowButAreNotMeasured() {
        let rows = [("Containers", "7 of 10", "2.83 GB", "—"), ("Images", "6 of 7", "2.15 GB", "676.7 MB"),
                    ("Volumes", "3 of 4", "5.16 GB", "34.6 MB")]
        #expect(cardFindings(diskCard(shift: 0, categories: rows)).count == 1)
        #expect(cardFindings(diskCard(shift: 206.5, categories: rows)).isEmpty)
    }

    /// The Memory card: label, (hidden) bar, value ending at the card's edge; consumer rows with a
    /// stranded mark between the name and the value.
    @Test func memoryCardShapePasses() {
        var children = [
            text("Memory", at(17.5, 20.58, 76.5, 16), role: "AXHeading"),
            button("overview.action.reclaim-memory", at(378.5, 16, 103.5, 24.5), title: "Reclaim Memory…"),
            text("4.21 GB", at(16, 54.58, 114, 35)),
        ]
        for (n, (label, value)) in [("Host (real)", "4.21 GB"), ("Guest in use", "546.5 MB"), ("Limits", "12.5 GB")].enumerated() {
            let w = TextMeasure.width(of: value, fontSize: 12).rounded(.up)
            children += [text(label, at(16, 120.58 + Double(n) * 23, 70, 15)),
                         text(value, at(482 - w, 120.58 + Double(n) * 23, w, 15))]
        }
        children.append(text("Top consumers", at(16, 271.58, 83.5, 14)))
        children += [
            text("postgres", at(40, 299.58, 50, 15)),
            AXNode(role: "AXImage", label: "792.8 MB stranded", frame: at(387, 301, 12, 12)),
            text("1.2 GB", at(443, 299.58, 39, 15)),
            text("dev", at(40, 320.58, 21, 15)),
            text("1.1 GB", at(443, 320.58, 39, 15)),
        ]
        #expect(cardFindings(card("overview.card.memory", children)).isEmpty)
    }

    /// The Container System card: a label/value form whose values are leading-aligned text.
    @Test func leadingAlignedFormIsIgnored() {
        var children = [
            text("Container System", at(17.5, 20.58, 140.5, 16), role: "AXHeading"),
            button("overview.action.stop-system", at(408, 16.5, 74, 24), title: "Stop"),
        ]
        let rows = [("CLI", "container 1.7.1"), ("API server", "1.7.1"), ("Host", "10 CPUs · macOS 26.3"),
                    ("Images", "7"), ("Data", "/Users/demo/Library/Application Support/com.apple.container")]
        for (n, (label, value)) in rows.enumerated() {
            let w = min(349.5, TextMeasure.width(of: value, fontSize: 12).rounded(.up))
            children += [text(label, at(16, 103.58 + Double(n) * 21, 58, 15)),
                         text(value, at(89.5, 103.5 + Double(n) * 21, w, 15))]
        }
        #expect(cardFindings(card("overview.card.system", children, height: 239)).isEmpty)
    }

    /// Any group with a bar spanning its content is a card; the bar's trailing edge is the edge.
    @Test func fullWidthBarSetsTheEdge() {
        func panel(valueEdge: Double, barWidth: Double = 466) -> AXNode {
            var children = [AXNode(role: "AXProgressIndicator", label: "Disk usage", value: "0.4",
                                   frame: at(16, 40, barWidth, 10))]
            for (n, value) in ["2.83 GB", "2.15 GB", "15.16 GB"].enumerated() {
                let w = TextMeasure.width(of: value, fontSize: 12).rounded(.up)
                children += [text("Category \(n)", at(16, 70 + Double(n) * 23, 80, 15)),
                             text(value, at(valueEdge - w, 70 + Double(n) * 23, w, 15))]
            }
            return card(nil, children, height: 160)
        }
        let short = cardFindings(panel(valueEdge: 300))
        #expect(short.count == 1)
        #expect(short.first?.message.contains("182 pt before the full-width bar's trailing edge") == true)
        #expect(cardFindings(panel(valueEdge: 482)).isEmpty)
        #expect(cardFindings(panel(valueEdge: 490)).first?.message.contains("8 pt past") == true)
        // A bar that doesn't span the content is just another element: no card, no finding.
        #expect(cardFindings(panel(valueEdge: 300, barWidth: 120)).isEmpty)
    }
}
