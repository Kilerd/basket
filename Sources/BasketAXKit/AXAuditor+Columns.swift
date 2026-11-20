import Foundation

extension AXAuditRules {
    public static let columnAlignment = "column-alignment"
    /// Non-text elements in one table column (bars, indicators, images, buttons) must share left
    /// x and width within this…
    public static let columnElementTolerance = 1.0
    /// …and a left-x spread beyond this is an error, not a warning.
    public static let columnElementErrorSpread = 4.0
    /// Texts in one column must share a left, right or centre edge within this. (2 pt, not 1:
    /// SwiftUI sidebar `Label`s put their titles 1.5 pt apart depending on the symbol's width.)
    public static let columnTextTolerance = 2.0
    /// Text that only stands in for a missing value; rows showing only this are skipped.
    public static let placeholderCharacters: Set<Character> = ["—", "–", "-", "…", "·", " "]
}

extension AXAuditor {
    /// `column-alignment`: repeated rows must line up.
    /// - Tables/outlines: cells are matched by index within their AXRow; inside a cell, elements
    ///   are matched across rows by role and order. Non-text elements must share left x and width;
    ///   texts must share a left, right or centre edge.
    /// - Repeated row layouts outside tables (e.g. a Grid flattened into its card, or a form):
    ///   consecutive rows with the same sequence of roles; every column may be left-, right- or
    ///   centre-aligned (forms right-align controls after labels of varying width). Warnings only.
    static func columnAlignment(_ tree: AXTreeIndex) -> [AXFinding] {
        var findings: [AXFinding] = []
        for t in tree.indices where ["AXTable", "AXOutline"].contains(tree[t].node.role) {
            findings += tableColumns(t, tree)
        }
        for p in tree.indices where !["AXTable", "AXOutline", "AXRow", "AXCell"].contains(tree[p].node.role) {
            findings += repeatedRows(under: p, tree)
        }
        return findings
    }

    /// One row's content for one column.
    struct ColumnSample {
        let rowLabel: String
        let elements: [Int]
    }

    private static func tableColumns(_ t: Int, _ tree: AXTreeIndex) -> [AXFinding] {
        // Only rows fully shown by the scroll area: rows scrolled out of view may not be laid out
        // (their content sits at the cell origin until the row is displayed).
        let clip = tree.nearestAncestor(of: t) { $0.role == "AXScrollArea" }.flatMap { tree[$0].node.frame }
        let rows = tree[t].children.filter { r in
            guard tree[r].node.role == "AXRow" else { return false }
            guard let clip, let frame = tree[r].node.frame else { return true }
            return clip.contains(frame, tolerance: 1)
        }
        guard rows.count >= 2 else { return [] }
        let cells = rows.map { r in tree[r].children.filter { tree[$0].node.role == "AXCell" } }
        // Rows with an unusual cell count (section headers, group rows) don't belong to the grid.
        let counts = Dictionary(grouping: cells.map(\.count), by: { $0 }).mapValues(\.count)
        guard let columns = counts.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key, columns > 0 else { return [] }
        let table = tree[t].node
        let tableName = table.identifier.map { "“\($0)”" } ?? (table.accessibleName.map { "“\($0)”" } ?? table.role)
        let labels = rows.map { rowLabel($0, tree) }
        var findings: [AXFinding] = []
        for column in 0..<columns {
            var samples: [ColumnSample] = []
            for (n, rowCells) in cells.enumerated() where rowCells.count == columns {
                let elements = contentElements(of: rowCells[column], tree)
                guard !elements.isEmpty, !elements.allSatisfy({ isPlaceholder(tree[$0].node) }) else { continue }
                samples.append(ColumnSample(rowLabel: labels[n], elements: elements))
            }
            findings += compareColumn(samples, tree, strict: true,
                                      context: "column \(column + 1) of \(tableName)",
                                      path: tree[t].path, identifier: table.identifier)
        }
        return findings
    }

    /// Consecutive rows (loose siblings clustered by y, or sibling groups laid out as one row)
    /// with identical role sequences.
    private static func repeatedRows(under p: Int, _ tree: AXTreeIndex) -> [AXFinding] {
        var units: [[Int]?] = []  // nil breaks a run
        var loose: [Int] = []
        func flushLoose() {
            for row in bands(loose, tree) { units.append(row) }
            loose = []
        }
        for c in tree[p].children {
            let n = tree[c].node
            guard let f = n.frame, !f.isEmpty else { continue }
            if n.role == "AXGroup", !tree[c].children.isEmpty {
                flushLoose()
                let content = contentElements(of: c, tree)
                let rows = bands(content, tree)
                units.append(rows.count == 1 ? rows[0] : nil)
            } else if AXAuditRules.structuralRoles.contains(n.role) || n.role == "AXScrollArea" || n.role == "AXToolbar" {
                flushLoose()
                units.append(nil)
            } else {
                loose.append(c)
            }
        }
        flushLoose()

        var findings: [AXFinding] = []
        var run: [[Int]] = []
        func flushRun() {
            defer { run = [] }
            guard run.count >= 2 else { return }
            let samples = run.map { ColumnSample(rowLabel: excerpt(tree[$0[0]].node.text ?? tree[$0[0]].node.role, limit: 24), elements: $0) }
            findings += compareColumn(samples, tree, strict: false, context: "repeated rows",
                                      path: tree[p].path, identifier: tree[p].node.identifier)
        }
        for unit in units {
            guard let unit, unit.count >= 2, !unit.allSatisfy({ isPlaceholder(tree[$0].node) }) else { flushRun(); continue }
            if let last = run.last, signature(last, tree) != signature(unit, tree) { flushRun() }
            run.append(unit)
        }
        flushRun()
        return findings
    }

    private static func compareColumn(
        _ samples: [ColumnSample], _ tree: AXTreeIndex, strict: Bool, context: String, path: String, identifier: String?
    ) -> [AXFinding] {
        guard samples.count >= 2 else { return [] }
        // Match elements across rows by class (text, or the role) and their order within the cell.
        var keyed: [String: [(row: String, frame: AXRect)]] = [:]
        var order: [String] = []
        for sample in samples {
            var seen: [String: Int] = [:]
            for e in sample.elements.sorted(by: { (tree[$0].node.frame?.minX ?? 0) < (tree[$1].node.frame?.minX ?? 0) }) {
                let node = tree[e].node
                guard let frame = node.frame, !frame.isEmpty else { continue }
                let cls = elementClass(node)
                let key = "\(cls)#\(seen[cls, default: 0])"
                seen[cls, default: 0] += 1
                // A placeholder ("—" for a missing value) keeps its slot but isn't compared.
                guard !isPlaceholder(node) else { continue }
                if keyed[key] == nil { order.append(key) }
                keyed[key, default: []].append((sample.rowLabel, frame))
            }
        }
        var findings: [AXFinding] = []
        for key in order {
            let members = keyed[key]!
            guard members.count >= 2 else { continue }
            let cls = String(key.split(separator: "#")[0])
            let lefts = members.map(\.frame.minX), rights = members.map(\.frame.maxX)
            let centers = members.map(\.frame.midX), widths = members.map(\.frame.width)
            func spread(_ v: [Double]) -> Double { (v.max() ?? 0) - (v.min() ?? 0) }
            let what = cls == "text" ? "text" : cls
            let lo = members.min { $0.frame.minX < $1.frame.minX }!, hi = members.max { $0.frame.minX < $1.frame.minX }!
            let example = "row “\(lo.row)” at x=\(points(lo.frame.minX)), row “\(hi.row)” at x=\(points(hi.frame.minX))"
            if cls == "text" || cls == "heading" {
                let tol = AXAuditRules.columnTextTolerance
                guard spread(lefts) > tol, spread(rights) > tol, spread(centers) > tol else { continue }
                findings.append(AXFinding(
                    rule: AXAuditRules.columnAlignment, severity: .warning,
                    message: "ragged column (\(context)): \(members.count) texts are neither left-, right- nor centre-aligned — left edges vary by \(points(spread(lefts))) pt, right edges by \(points(spread(rights))) pt (\(example))",
                    path: path, identifier: identifier, frame: hi.frame))
            } else if strict {
                let tol = AXAuditRules.columnElementTolerance
                guard spread(lefts) > tol || spread(widths) > tol else { continue }
                let severity: AXFinding.Severity = spread(lefts) > AXAuditRules.columnElementErrorSpread ? .error : .warning
                findings.append(AXFinding(
                    rule: AXAuditRules.columnAlignment, severity: severity,
                    message: "ragged column (\(context)): \(what) elements in \(members.count) rows start \(points(spread(lefts))) pt apart and differ in width by \(points(spread(widths))) pt — they must share x and width (\(example))",
                    path: path, identifier: identifier, frame: hi.frame))
            } else {
                let tol = AXAuditRules.columnElementTolerance
                guard spread(lefts) > tol, spread(rights) > tol, spread(centers) > tol else { continue }
                findings.append(AXFinding(
                    rule: AXAuditRules.columnAlignment, severity: .warning,
                    message: "ragged column (\(context)): \(what) elements in \(members.count) rows are neither left-, right- nor centre-aligned — left edges vary by \(points(spread(lefts))) pt (\(example))",
                    path: path, identifier: identifier, frame: hi.frame))
            }
        }
        return findings
    }

    /// The visible pieces of a cell/row container: descends through groups, cells and unnamed
    /// unknowns; anything else (text, controls, indicators, images, labelled unknowns) is a leaf.
    static func contentElements(of i: Int, _ tree: AXTreeIndex) -> [Int] {
        var out: [Int] = []
        for c in tree[i].children {
            let n = tree[c].node
            let isContainer = ["AXGroup", "AXCell"].contains(n.role) || (n.role == "AXUnknown" && n.accessibleName == nil)
            if isContainer, !tree[c].children.isEmpty {
                out += contentElements(of: c, tree)
            } else if n.frame.map({ !$0.isEmpty }) == true {
                out.append(c)
            }
        }
        return out
    }

    /// "text" for anything that renders as body text (static text, and SwiftUI's AXUnknown text
    /// elements, which are at least one line tall); "heading" for headings (section-header rows
    /// in a sidebar are a different kind of row); otherwise the role.
    static func elementClass(_ node: AXNode) -> String {
        if node.role == "AXHeading" { return "heading" }
        if node.role == "AXStaticText" { return "text" }
        if node.role == "AXUnknown", (node.frame?.height ?? 0) >= 12, node.accessibleName ?? node.text != nil { return "text" }
        return node.role + (node.subrole.map { "/\($0)" } ?? "")
    }

    static func isPlaceholder(_ node: AXNode) -> Bool {
        guard ["text", "heading"].contains(elementClass(node)) else { return false }
        let text = node.text ?? node.accessibleName ?? ""
        return text.allSatisfy { AXAuditRules.placeholderCharacters.contains($0) }
    }

    /// Splits elements (in reading order) into rows by vertical overlap.
    private static func bands(_ items: [Int], _ tree: AXTreeIndex) -> [[Int]] {
        var rows: [[Int]] = []
        for item in items {
            guard let f = tree[item].node.frame else { continue }
            if let last = rows.last, let lf = tree[last[0]].node.frame,
               min(f.maxY, lf.maxY) - max(f.minY, lf.minY) >= AXAuditRules.rowBandOverlap * min(f.height, lf.height) {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows
    }

    private static func signature(_ row: [Int], _ tree: AXTreeIndex) -> [String] {
        row.sorted { (tree[$0].node.frame?.minX ?? 0) < (tree[$1].node.frame?.minX ?? 0) }.map { elementClass(tree[$0].node) }
    }

    /// First text in the row, for messages (descendants follow their row in pre-order).
    private static func rowLabel(_ row: Int, _ tree: AXTreeIndex) -> String {
        var i = row + 1
        while i < tree.items.count, tree[i].depth > tree[row].depth {
            if let text = tree[i].node.text { return excerpt(text, limit: 24) }
            i += 1
        }
        return "row"
    }
}
