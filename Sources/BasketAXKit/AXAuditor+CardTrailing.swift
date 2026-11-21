import Foundation

extension AXAuditRules {
    public static let cardTrailingAlignment = "card-trailing-alignment"
    /// A card's right-aligned value column may end this far from the card's content edge.
    public static let cardTrailingTolerance = 2.0
    /// Groups checked as cards by identifier (the Overview cards). Other groups are checked only
    /// when they hold a full-width bar.
    public static let cardIdentifierPrefix = "overview.card."
    /// Bars and meters exposed to accessibility.
    public static let barRoles: Set<String> = ["AXProgressIndicator", "AXLevelIndicator"]
    /// A bar alone in its row is full-width when it spans this much of its group's content.
    public static let fullWidthBarFraction = 0.75
}

extension AXAuditor {
    /// `card-trailing-alignment`: inside a card, a column of right-aligned values (the rightmost
    /// texts of consecutive table-like rows) ends where the card's full-width content ends — the
    /// trailing edge of a full-width bar, else the rightmost edge of the card's other content
    /// (header accessory, other rows). Catches a table that keeps its natural width and leaves the
    /// right part of the card empty under a bar that spans it.
    ///
    /// Cards: `overview.card.*` groups, and any group with a full-width bar (an
    /// `AXProgressIndicator`/`AXLevelIndicator` alone in its row). A table-like row has at least two
    /// elements, no heading, and a text as its rightmost element; a run of at least two such rows is
    /// a table. Only right-aligned columns are judged (leading-aligned text columns, as in a
    /// label/value form, and ragged ones are left to `column-alignment`); a column whose texts all
    /// share both edges counts as right-aligned only when it holds numbers.
    static func cardTrailingAlignment(_ tree: AXTreeIndex) -> [AXFinding] {
        var findings: [AXFinding] = []
        var reported = Set<Int>()
        // Innermost groups first (pre-order reversed), so a nested card reports its own tables once.
        for g in tree.indices.reversed() where tree[g].node.role == "AXGroup" && !tree[g].children.isEmpty {
            findings += cardTables(in: g, tree, reported: &reported)
        }
        return findings
    }

    private static func cardTables(in g: Int, _ tree: AXTreeIndex, reported: inout Set<Int>) -> [AXFinding] {
        let group = tree[g].node
        let isCard = group.identifier?.hasPrefix(AXAuditRules.cardIdentifierPrefix) == true
        let elements = contentElements(of: g, tree).filter { e in
            guard let f = tree[e].node.frame, !f.isEmpty else { return false }
            return group.frame.map { $0.contains(f, tolerance: 1) } ?? true
        }
        guard elements.count >= 4 else { return [] }  // two rows of two
        let frames = elements.map { tree[$0].node.frame! }
        let contentMinX = frames.map(\.minX).min()!, contentMaxX = frames.map(\.maxX).max()!
        let rows = cardRows(elements, tree)

        let bar = rows.compactMap { row -> Int? in
            guard row.count == 1, AXAuditRules.barRoles.contains(tree[row[0]].node.role) else { return nil }
            let width = tree[row[0]].node.frame!.width
            return width >= AXAuditRules.fullWidthBarFraction * (contentMaxX - contentMinX) ? row[0] : nil
        }.max { tree[$0].node.frame!.width < tree[$1].node.frame!.width }
        let reference: Double
        let referenceName: String
        if let bar {
            reference = tree[bar].node.frame!.maxX
            referenceName = "the full-width bar's trailing edge"
        } else if isCard {
            reference = contentMaxX
            referenceName = "the card's content edge (header accessory, other rows)"
        } else {
            return []
        }

        // Runs of consecutive table-like rows; each row contributes its rightmost element.
        var runs: [[(row: [Int], value: Int)]] = []
        var run: [(row: [Int], value: Int)] = []
        for row in rows {
            let last = row.max { tree[$0].node.frame!.maxX < tree[$1].node.frame!.maxX }!
            let tableLike = row.count >= 2 && elementClass(tree[last].node) == "text"
                && !row.contains { elementClass(tree[$0].node) == "heading" }
            if tableLike {
                run.append((row, last))
            } else {
                if run.count >= 2 { runs.append(run) }
                run = []
            }
        }
        if run.count >= 2 { runs.append(run) }

        var findings: [AXFinding] = []
        let tolerance = AXAuditRules.cardTrailingTolerance
        func spread(_ v: [Double]) -> Double { (v.max() ?? 0) - (v.min() ?? 0) }
        for run in runs {
            // A placeholder ("—") keeps its row in the table but isn't measured.
            let measured = run.filter { !isPlaceholder(tree[$0.value].node) }
            guard measured.count >= 2, let first = measured.first?.value, !reported.contains(first) else { continue }
            let values = measured.map { tree[$0.value].node.frame! }
            let rights = values.map(\.maxX), lefts = values.map(\.minX)
            guard spread(rights) <= tolerance else { continue }
            if spread(lefts) <= tolerance,
               !measured.allSatisfy({ looksNumeric(tree[$0.value].node.text ?? "") }) { continue }
            let edge = median(rights)
            let offset = reference - edge
            guard abs(offset) > tolerance else { continue }
            reported.insert(first)
            let labels = [measured.first!, measured.last!].map { entry -> String in
                let lead = entry.row.min { tree[$0].node.frame!.minX < tree[$1].node.frame!.minX }!
                return "“\(excerpt(tree[lead].node.text ?? tree[lead].node.role, limit: 24))”"
            }
            let column = AXRect(x: lefts.min()!, y: values.map(\.minY).min()!,
                                width: rights.max()! - lefts.min()!,
                                height: values.map(\.maxY).max()! - values.map(\.minY).min()!)
            let gap = offset > 0 ? "\(points(offset)) pt before" : "\(points(-offset)) pt past"
            findings.append(AXFinding(
                rule: AXAuditRules.cardTrailingAlignment, severity: .warning,
                message: "the value column of \(measured.count) rows (\(labels[0]) … \(labels[1])) ends at x=\(points(edge)), \(gap) \(referenceName) at x=\(points(reference)) — let the leading column flex so the numbers end where the card's full-width content ends",
                path: tree[g].path, identifier: group.identifier, frame: column))
        }
        return findings
    }

    /// Splits elements (in reading order) into rows by vertical overlap.
    private static func cardRows(_ items: [Int], _ tree: AXTreeIndex) -> [[Int]] {
        var rows: [[Int]] = []
        for item in items {
            let f = tree[item].node.frame!
            if let last = rows.last, let lf = tree[last[0]].node.frame,
               min(f.maxY, lf.maxY) - max(f.minY, lf.minY) >= AXAuditRules.rowBandOverlap * min(f.height, lf.height) {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows
    }

    /// "2.83 GB", "1,2 Go", "7 of 10", "12 %": has a digit and at most a short unit's worth of letters.
    static func looksNumeric(_ text: String) -> Bool {
        text.contains { $0.isNumber } && text.filter(\.isLetter).count <= 3
    }
}
