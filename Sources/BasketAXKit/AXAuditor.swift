import Foundation

/// Layout and consistency rules over accessibility trees. Pure functions; thresholds live in
/// `AXAuditRules`.
public enum AXAuditor {
    /// Audits one window snapshot. `section` (e.g. `containers`) enables the identifier contract
    /// for that section; `nil` only requires the main window identifier (or, in “Set Up Basket”,
    /// the onboarding contract). `expecting`: whether OrbStack's section and setup step belong.
    public static func audit(window: AXNode, section: String?, expecting: AXSectionExpectation = .everything) -> [AXFinding] {
        let tree = AXTreeIndex(window)
        var findings: [AXFinding] = []
        findings += missingLabels(tree)
        findings += outOfWindow(tree)
        findings += overlaps(tree)
        findings += tinyTargets(tree)
        findings += inconsistentHeights(tree)
        findings += duplicateIdentifiers(tree)
        findings += truncations(tree)
        findings += unknownRoles(tree)
        findings += repeatedLabels(tree)
        findings += columnAlignment(tree)
        findings += cardTrailingAlignment(tree)
        findings += contract(tree, section: section, expecting: expecting)
        return findings.sortedForReport()
    }

    /// Only the `missing-label` rule — used for transient UI such as a sheet, where layout rules
    /// against the main window don't apply.
    public static func auditLabels(_ root: AXNode) -> [AXFinding] {
        missingLabels(AXTreeIndex(root)).sortedForReport()
    }

    // MARK: - Per-window rules

    static func missingLabels(_ tree: AXTreeIndex) -> [AXFinding] {
        tree.indices.compactMap { i in
            let node = tree[i].node
            guard AXAuditRules.isInteractive(node), !AXAuditRules.isSystemDrawn(node),
                  AXAuditRules.spokenName(node) == nil else { return nil }
            return AXFinding(
                rule: AXAuditRules.missingLabel, severity: .error,
                message: "\(node.role) has no accessible name (title, description, help\(AXAuditRules.isTextInput(node) ? " or placeholder" : "")) — VoiceOver can only say “\(roleWord(node))”",
                path: tree[i].path, identifier: node.identifier, frame: node.frame)
        }
    }

    static func outOfWindow(_ tree: AXTreeIndex) -> [AXFinding] {
        guard let window = tree.root.node.frame, !window.isEmpty else { return [] }
        let tolerance = AXAuditRules.outOfWindowTolerance
        var findings: [AXFinding] = []
        var flagged = Set<Int>()
        for i in tree.indices.dropFirst() {
            if let parent = tree[i].parent, flagged.contains(parent) {
                flagged.insert(i)  // report only the outermost offender
                continue
            }
            let node = tree[i].node
            guard let frame = node.frame, !frame.isEmpty else { continue }
            var visible = frame
            if let scroll = tree.nearestAncestor(of: i, where: { $0.role == "AXScrollArea" }),
               let clip = tree[scroll].node.frame {
                // Scrolled out of view is fine; judge only the part shown by the scroll area.
                guard let shown = frame.intersection(clip) else { continue }
                visible = shown
            }
            if window.contains(visible, tolerance: tolerance) { continue }
            let fullyOutside = visible.intersection(window) == nil
            flagged.insert(i)
            findings.append(AXFinding(
                rule: AXAuditRules.outOfWindow, severity: fullyOutside ? .error : .warning,
                message: fullyOutside
                    ? "\(describe(node)) at \(frame.short) is entirely outside the window (\(window.short))"
                    : "\(describe(node)) at \(frame.short) is clipped by the window edge (\(window.short))",
                path: tree[i].path, identifier: node.identifier, frame: frame))
        }
        return findings
    }

    static func overlaps(_ tree: AXTreeIndex) -> [AXFinding] {
        var findings: [AXFinding] = []
        for i in tree.indices {
            let controls = tree.effectiveChildren(of: i).filter {
                AXAuditRules.isInteractive(tree[$0].node) && tree[$0].node.frame.map { !$0.isEmpty } == true
            }
            guard controls.count >= 2 else { continue }
            for (n, a) in controls.enumerated() {
                for b in controls[(n + 1)...] {
                    let fa = tree[a].node.frame!, fb = tree[b].node.frame!
                    guard let shared = fa.intersection(fb), shared.area > AXAuditRules.overlapMinArea else { continue }
                    findings.append(AXFinding(
                        rule: AXAuditRules.overlap, severity: .error,
                        message: "\(describe(tree[a].node)) (\(fa.short)) and \(describe(tree[b].node)) (\(fb.short)) overlap by \(points(shared.width))×\(points(shared.height)) pt",
                        path: tree[a].path, identifier: tree[a].node.identifier, frame: shared))
                }
            }
        }
        return findings
    }

    static func tinyTargets(_ tree: AXTreeIndex) -> [AXFinding] {
        tree.indices.compactMap { i in
            let node = tree[i].node
            guard AXAuditRules.isInteractive(node), !AXAuditRules.isSystemDrawn(node),
                  !AXAuditRules.fixedSizeSystemRoles.contains(node.role),
                  let frame = node.frame, !frame.isEmpty else { return nil }
            // The search/clear glyphs inside a search field are system-drawn parts of the field.
            if let parent = tree[i].parent, AXAuditRules.isTextInput(tree[parent].node) { return nil }
            let minWidth: Double, minHeight: Double
            if AXAuditRules.isTextInput(node) {
                (minWidth, minHeight) = (AXAuditRules.minTargetSize, AXAuditRules.textInputMinHeight)
            } else if AXAuditRules.isToggle(node) {
                (minWidth, minHeight) = (AXAuditRules.toggleMinSize, AXAuditRules.toggleMinSize)
            } else {
                (minWidth, minHeight) = (AXAuditRules.minTargetSize, AXAuditRules.minTargetSize)
            }
            guard frame.width < minWidth || frame.height < minHeight else { return nil }
            return AXFinding(
                rule: AXAuditRules.tinyTarget, severity: .warning,
                message: "\(describe(node)) is \(points(frame.width))×\(points(frame.height)) pt; minimum hit target is \(points(minWidth))×\(points(minHeight)) pt",
                path: tree[i].path, identifier: node.identifier, frame: frame)
        }
    }

    static func inconsistentHeights(_ tree: AXTreeIndex) -> [AXFinding] {
        var findings: [AXFinding] = []
        for i in tree.indices {
            let buttons = tree.effectiveChildren(of: i).filter {
                let n = tree[$0].node
                return n.role == "AXButton" && !AXAuditRules.isSystemDrawn(n) && n.frame.map { !$0.isEmpty } == true
            }
            guard buttons.count >= 2 else { continue }
            for row in rows(buttons, tree: tree) where row.count >= 2 {
                let heights = row.map { tree[$0].node.frame!.height }
                let reference = consensus(heights, tolerance: AXAuditRules.heightTolerance)
                for b in row {
                    let frame = tree[b].node.frame!
                    guard abs(frame.height - reference) > AXAuditRules.heightTolerance else { continue }
                    findings.append(AXFinding(
                        rule: AXAuditRules.inconsistentHeight, severity: .warning,
                        message: "\(describe(tree[b].node)) is \(points(frame.height)) pt tall; the other buttons in its row are \(points(reference)) pt",
                        path: tree[b].path, identifier: tree[b].node.identifier, frame: frame))
                }
            }
        }
        return findings
    }

    static func duplicateIdentifiers(_ tree: AXTreeIndex) -> [AXFinding] {
        var occurrences: [String: [Int]] = [:]
        var order: [String] = []
        for i in tree.indices {
            guard let id = tree[i].node.identifier, isAppIdentifier(id) else { continue }
            if occurrences[id] == nil { order.append(id) }
            occurrences[id, default: []].append(i)
        }
        var findings: [AXFinding] = []
        for id in order {
            let hits = occurrences[id]!
            guard hits.count >= 2 else { continue }
            var anchors: [Int]
            if id.contains(".row.") {
                // A row identifier may repeat inside one row (row, cell, content) — but not across rows.
                anchors = hits.map { i in
                    tree[i].node.role == "AXRow" ? i : (tree.nearestAncestor(of: i) { $0.role == "AXRow" } ?? i)
                }
                anchors = Array(Set(anchors)).sorted()
            } else {
                anchors = hits
            }
            // Nested occurrences are one logical element (SwiftUI repeats ids on wrappers).
            let distinct = anchors.filter { a in !anchors.contains { $0 != a && tree.isAncestor($0, of: a) } }
            guard distinct.count >= 2 else { continue }
            let second = distinct[1]
            findings.append(AXFinding(
                rule: AXAuditRules.duplicateIdentifier, severity: .warning,
                message: "identifier “\(id)” is used by \(distinct.count) separate elements: "
                    + distinct.prefix(4).map { tree[$0].path }.joined(separator: "; "),
                path: tree[second].path, identifier: id, frame: tree[second].node.frame))
        }
        return findings
    }

    static func truncations(_ tree: AXTreeIndex) -> [AXFinding] {
        tree.indices.compactMap { i in
            let node = tree[i].node
            guard AXAuditRules.textRoles.contains(node.role), let text = node.text,
                  text.count >= (AXAuditRules.hasWideCharacters(text)
                      ? AXAuditRules.truncationMinLengthWide : AXAuditRules.truncationMinLength),
                  let frame = node.frame, !frame.isEmpty else { return nil }
            let (fontSize, lines) = TextMeasure.estimateFont(forFrameHeight: frame.height)
            let needed = text.split(whereSeparator: \.isNewline)
                .map { TextMeasure.width(of: String($0), fontSize: fontSize) }.max() ?? 0
            let capacity = frame.width * Double(lines)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let message: String
            if needed > capacity + AXAuditRules.truncationTolerance {
                message = "“\(excerpt(text))” needs ~\(points(needed)) pt at \(points(fontSize)) pt but has \(points(frame.width)) pt\(lines > 1 ? " × \(lines) lines" : "")"
            } else if trimmed.hasSuffix("…") || trimmed.hasSuffix("..."),
                      needed >= capacity - AXAuditRules.ellipsisFillSlack {
                message = "“\(excerpt(text))” ends with an ellipsis and fills its \(points(frame.width)) pt frame"
            } else {
                return nil
            }
            return AXFinding(rule: AXAuditRules.truncation, severity: .warning, message: message,
                             path: tree[i].path, identifier: node.identifier, frame: frame)
        }
    }

    /// One finding per container: SwiftUI produces AXUnknown for `.accessibilityElement(children: .ignore)`
    /// without traits, and often for every cell of a labelled GridRow at once.
    static func unknownRoles(_ tree: AXTreeIndex) -> [AXFinding] {
        var byParent: [Int: [Int]] = [:]
        var order: [Int] = []
        for i in tree.indices {
            let node = tree[i].node
            guard node.role == "AXUnknown", node.accessibleName ?? node.text != nil else { continue }
            let parent = tree[i].parent ?? i
            if byParent[parent] == nil { order.append(parent) }
            byParent[parent, default: []].append(i)
        }
        return order.map { parent in
            let members = byParent[parent]!
            let first = tree[members[0]]
            let names = members.prefix(4).map { "“\(excerpt(tree[$0].node.accessibleName ?? tree[$0].node.text ?? ""))”" }
                .joined(separator: ", ") + (members.count > 4 ? ", …" : "")
            let subject = members.count == 1 ? "\(names) has" : "\(members.count) elements (\(names)) have"
            return AXFinding(
                rule: AXAuditRules.unknownRole, severity: .warning,
                message: "\(subject) no accessibility role (AXUnknown): VoiceOver reads them without saying what they are — combine into the container (.accessibilityElement(children: .combine)) or add a trait",
                path: first.path, identifier: first.node.identifier, frame: first.node.frame)
        }
    }

    static func repeatedLabels(_ tree: AXTreeIndex) -> [AXFinding] {
        var findings: [AXFinding] = []
        for i in tree.indices {
            var groups: [String: [Int]] = [:]
            var order: [String] = []
            for c in tree.effectiveChildren(of: i) {
                let n = tree[c].node
                // Repeated static text ("—", "Running") is normal; repeated *names* are not.
                guard !AXAuditRules.structuralRoles.contains(n.role), !AXAuditRules.textRoles.contains(n.role),
                      let name = nonBlank(n.title) ?? nonBlank(n.label) else { continue }
                if groups[name] == nil { order.append(name) }
                groups[name, default: []].append(c)
            }
            for name in order {
                let members = groups[name]!
                guard members.count >= 2 else { continue }
                let first = tree[members[0]]
                findings.append(AXFinding(
                    rule: AXAuditRules.repeatedLabel, severity: .warning,
                    message: "\(members.count) sibling elements are all named “\(excerpt(name))” (\(members.map { tree[$0].node.role }.joined(separator: ", "))): VoiceOver users can't tell them apart — a label on a GridRow/ForEach is copied onto every child; label each element or combine them",
                    path: first.path, identifier: first.node.identifier, frame: first.node.frame))
            }
        }
        return findings
    }

    static func contract(_ tree: AXTreeIndex, section: String?, expecting: AXSectionExpectation = .everything) -> [AXFinding] {
        let present = Set(tree.items.compactMap(\.node.identifier))
        if section == nil, present.contains(AXAuditRules.onboardingWindowIdentifier) {
            return onboardingContract(tree, expecting: expecting)
        }
        var findings = AXAuditRules.requiredIdentifiers(section: section, expecting: expecting).compactMap { alternatives -> AXFinding? in
            guard !alternatives.contains(where: present.contains) else { return nil }
            let what = alternatives.map { "“\($0)”" }.joined(separator: " or ")
            return AXFinding(
                rule: AXAuditRules.contract, severity: .error,
                message: "missing identifier \(what)\(section.map { " in section \($0)" } ?? "") (docs/ARCHITECTURE.md contract)",
                path: tree.root.path, identifier: alternatives[0])
        }
        // OrbStack's section exists only while OrbStack is installed: no sidebar item, no root.
        for hidden in expecting.hiddenSections {
            for id in ["sidebar.\(hidden)", "section.\(hidden)"] where present.contains(id) {
                let i = tree.innermost(identifier: id)
                findings.append(AXFinding(
                    rule: AXAuditRules.contract, severity: .error,
                    message: "“\(id)” is shown\(section.map { " in section \($0)" } ?? ""), but OrbStack isn't installed: the \(hidden) section appears only while it is (docs/ARCHITECTURE.md contract)",
                    path: i.map { tree[$0].path } ?? tree.root.path, identifier: id, frame: i.flatMap { tree[$0].node.frame }))
            }
        }
        return findings
    }

    // MARK: - Helpers

    /// Groups buttons into rows: same row when their vertical extents overlap enough.
    static func rows(_ items: [Int], tree: AXTreeIndex) -> [[Int]] {
        let sorted = items.sorted { tree[$0].node.frame!.minY < tree[$1].node.frame!.minY }
        var rows: [[Int]] = []
        for item in sorted {
            let f = tree[item].node.frame!
            let match = rows.firstIndex { row in
                row.contains { other in
                    let o = tree[other].node.frame!
                    let shared = min(f.maxY, o.maxY) - max(f.minY, o.minY)
                    return shared >= AXAuditRules.rowBandOverlap * min(f.height, o.height)
                }
            }
            if let match { rows[match].append(item) } else { rows.append([item]) }
        }
        return rows
    }

    /// The value most others agree with (within `tolerance`); ties go to the larger value.
    static func consensus(_ values: [Double], tolerance: Double) -> Double {
        values.max { a, b in
            let ca = values.filter { abs($0 - a) <= tolerance }.count
            let cb = values.filter { abs($0 - b) <= tolerance }.count
            return ca != cb ? ca < cb : a < b
        } ?? 0
    }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Identifiers the app set itself (the contract uses dotted names); excludes SwiftUI/AppKit
    /// internals such as `ListColumn`, `_NS:…` and `com.apple.…`.
    static func isAppIdentifier(_ id: String) -> Bool {
        id.contains(".") && !id.hasPrefix("_") && !id.hasPrefix("NS") && !id.hasPrefix("com.apple.")
    }

    static func describe(_ node: AXNode) -> String {
        if let id = node.identifier { return "\(node.role) “\(id)”" }
        if let name = AXAuditRules.spokenName(node) ?? node.text { return "\(node.role) “\(excerpt(name))”" }
        return node.role
    }

    static func roleWord(_ node: AXNode) -> String {
        node.role.hasPrefix("AX") ? String(node.role.dropFirst(2)).lowercased() : node.role
    }

    static func excerpt(_ s: String, limit: Int = 40) -> String {
        s.count > limit ? String(s.prefix(limit - 1)) + "…" : s
    }

    static func points(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
    }
}
