import Foundation

extension AXAuditor {
    /// Cross-section rules: the window and sidebar don't move, list search fields sit in the
    /// same place, action buttons share role/height per placement, section titles share a role.
    /// Positions are compared relative to the window origin.
    public static func auditConsistency(sections: [String: AXNode]) -> [AXFinding] {
        let names = orderedSections(Array(sections.keys))
        guard names.count >= 2 else { return [] }
        let trees = names.map { (name: $0, tree: AXTreeIndex(sections[$0]!)) }
        var findings: [AXFinding] = []
        findings += windowSize(trees)
        findings += sidebar(trees)
        findings += searchFields(trees)
        findings += actions(trees)
        findings += titles(trees)
        return findings.sortedForReport()
    }

    /// Known sections in sidebar order, then anything else alphabetically.
    public static func orderedSections(_ names: [String]) -> [String] {
        let known = AXAuditRules.sections.filter(names.contains)
        return known + names.filter { !AXAuditRules.sections.contains($0) }.sorted()
    }

    typealias SectionTree = (name: String, tree: AXTreeIndex)

    static func windowSize(_ trees: [SectionTree]) -> [AXFinding] {
        guard let (refName, refTree) = trees.first(where: { $0.tree.root.node.frame != nil }),
              let ref = refTree.root.node.frame else { return [] }
        return trees.compactMap { name, tree in
            guard let f = tree.root.node.frame,
                  abs(f.width - ref.width) > 1 || abs(f.height - ref.height) > 1 else { return nil }
            return AXFinding(
                rule: AXAuditRules.consistencyWindow, severity: .warning,
                message: "[\(name)] window is \(points(f.width))×\(points(f.height)) pt but \(points(ref.width))×\(points(ref.height)) pt in \(refName)",
                path: "\(name):\(tree.root.path)", identifier: tree.root.node.identifier, frame: f)
        }
    }

    static func sidebar(_ trees: [SectionTree]) -> [AXFinding] {
        var ids: [String] = []
        for (_, tree) in trees {
            for item in tree.items {
                if let id = item.node.identifier, id.hasPrefix("sidebar."), !ids.contains(id) { ids.append(id) }
            }
        }
        var findings: [AXFinding] = []
        let tol = AXAuditRules.sidebarTolerance
        for id in ids {
            var reference: (section: String, frame: AXRect)?
            for (name, tree) in trees {
                guard let i = tree.innermost(identifier: id), let raw = tree[i].node.frame else { continue }
                let f = tree.windowRelative(raw)
                guard let ref = reference else { reference = (name, f); continue }
                let r = ref.frame
                guard abs(f.x - r.x) > tol || abs(f.y - r.y) > tol
                        || abs(f.width - r.width) > tol || abs(f.height - r.height) > tol else { continue }
                findings.append(AXFinding(
                    rule: AXAuditRules.consistencySidebar, severity: .error,
                    message: "[\(name)] sidebar item “\(id)” is at \(f.short) but at \(r.short) in \(ref.section) — the sidebar must not move between sections",
                    path: "\(name):\(tree[i].path)", identifier: id, frame: raw))
            }
        }
        return findings
    }

    static func searchFields(_ trees: [SectionTree]) -> [AXFinding] {
        let fields: [(name: String, path: String, raw: AXRect, rel: AXRect)] = trees.compactMap { name, tree in
            guard AXAuditRules.listSections.contains(name),
                  let i = tree.innermost(identifier: "\(name).search"),
                  let raw = tree[i].node.frame else { return nil }
            return (name, tree[i].path, raw, tree.windowRelative(raw))
        }
        guard fields.count >= 2 else { return [] }
        let refY = median(fields.map(\.rel.y)), refWidth = median(fields.map(\.rel.width))
        return fields.compactMap { field in
            let dy = abs(field.rel.y - refY), dw = abs(field.rel.width - refWidth)
            guard dy > AXAuditRules.searchYTolerance || dw > AXAuditRules.searchWidthTolerance else { return nil }
            return AXFinding(
                rule: AXAuditRules.consistencySearch, severity: .warning,
                message: "[\(field.name)] search field is at y=\(points(field.rel.y)), \(points(field.rel.width)) pt wide; other list sections put it at y=\(points(refY)), \(points(refWidth)) pt wide",
                path: "\(field.name):\(field.path)", identifier: "\(field.name).search", frame: field.raw)
        }
    }

    static func actions(_ trees: [SectionTree]) -> [AXFinding] {
        struct Action { let section, verb, id, path, role: String; let toolbar: Bool; let frame: AXRect? }
        var all: [Action] = []
        for (name, tree) in trees {
            let prefix = "\(name).action."
            var seen = Set<String>()
            for item in tree.items {
                guard let id = item.node.identifier, id.hasPrefix(prefix), seen.insert(id).inserted,
                      let i = tree.innermost(identifier: id) else { continue }
                let n = tree[i].node
                all.append(Action(section: name, verb: String(id.dropFirst(prefix.count)), id: id,
                                  path: tree[i].path, role: n.role + (n.subrole.map { "/\($0)" } ?? ""),
                                  toolbar: tree.isInToolbar(i), frame: n.frame))
            }
        }
        var findings: [AXFinding] = []

        // Same verb → same role everywhere (refresh is a button in every section, …).
        let verbs = all.map(\.verb).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for verb in verbs {
            let group = all.filter { $0.verb == verb }
            let roles = group.map(\.role)
            guard Set(roles).count > 1 else { continue }
            let majority = roles.max { a, b in roles.filter { $0 == a }.count < roles.filter { $0 == b }.count }!
            for a in group where a.role != majority {
                findings.append(AXFinding(
                    rule: AXAuditRules.consistencyActions, severity: .warning,
                    message: "[\(a.section)] “\(a.id)” is \(a.role); “\(verb)” actions in other sections are \(majority)",
                    path: "\(a.section):\(a.path)", identifier: a.id, frame: a.frame))
            }
        }

        // Buttons in the same placement (toolbar vs. content header) share one height.
        for toolbar in [true, false] {
            let group = all.filter { $0.toolbar == toolbar && $0.role.hasPrefix("AXButton") && $0.frame != nil }
            guard Set(group.map(\.section)).count >= 2 else { continue }
            let reference = consensus(group.map { $0.frame!.height }, tolerance: AXAuditRules.actionHeightTolerance)
            for a in group where abs(a.frame!.height - reference) > AXAuditRules.actionHeightTolerance {
                findings.append(AXFinding(
                    rule: AXAuditRules.consistencyActions, severity: .warning,
                    message: "[\(a.section)] \(toolbar ? "toolbar" : "header") action “\(a.id)” is \(points(a.frame!.height)) pt tall; \(toolbar ? "toolbar" : "header") actions elsewhere are \(points(reference)) pt",
                    path: "\(a.section):\(a.path)", identifier: a.id, frame: a.frame))
            }
        }
        return findings
    }

    static func titles(_ trees: [SectionTree]) -> [AXFinding] {
        var found: [(name: String, role: String, path: String, id: String?, frame: AXRect?)] = []
        var findings: [AXFinding] = []
        for (name, tree) in trees {
            guard let i = sectionTitle(name, in: tree) else {
                findings.append(AXFinding(
                    rule: AXAuditRules.consistencyTitle, severity: .info,
                    message: "[\(name)] no section title found (“\(name).title” or a heading reading “\(titleCandidates(name, in: tree)[0])”)",
                    path: "\(name):\(tree.root.path)"))
                continue
            }
            let n = tree[i].node
            found.append((name, n.role + (n.subrole.map { "/\($0)" } ?? ""), tree[i].path, n.identifier, n.frame))
        }
        let roles = found.map(\.role)
        guard Set(roles).count > 1 else { return findings }
        let majority = roles.max { a, b in roles.filter { $0 == a }.count < roles.filter { $0 == b }.count }!
        for t in found where t.role != majority {
            findings.append(AXFinding(
                rule: AXAuditRules.consistencyTitle, severity: .warning,
                message: "[\(t.name)] section title is \(t.role); other sections use \(majority)",
                path: "\(t.name):\(t.path)", identifier: t.id, frame: t.frame))
        }
        return findings
    }

    /// `<section>.title` if present; else the first heading, then static text, outside the sidebar
    /// that reads the section's name. The name comes from the tree — the accessible name of
    /// `section.<name>`, else the sidebar item's text — so the rule works in every language; the
    /// English display name is the last resort.
    static func sectionTitle(_ section: String, in tree: AXTreeIndex) -> Int? {
        if let i = tree.innermost(identifier: "\(section).title") { return i }
        let names = Set(titleCandidates(section, in: tree).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        func outsideSidebar(_ i: Int) -> Bool {
            ([i] + tree.ancestors(of: i)).allSatisfy { tree[$0].node.identifier?.hasPrefix("sidebar.") != true }
        }
        for role in ["AXHeading", "AXStaticText"] {
            if let i = tree.indices.first(where: {
                let n = tree[$0].node
                guard n.role == role, let text = n.text?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
                return names.contains(text) && outsideSidebar($0)
            }) { return i }
        }
        return nil
    }

    /// What the section's title may read: its root's accessible name, the sidebar item's text,
    /// then the English display name.
    static func titleCandidates(_ section: String, in tree: AXTreeIndex) -> [String] {
        var names: [String] = []
        if let i = tree.innermost(identifier: "section.\(section)"), let name = tree[i].node.accessibleName {
            names.append(name)
        }
        if let i = tree.innermost(identifier: "sidebar.\(section)") {
            let item = tree[i].node
            if let text = item.accessibleName ?? item.text { names.append(text) }
            names += item.allNodes.compactMap { $0.role == "AXStaticText" ? $0.text : nil }
        }
        names.append(displayName(section))
        return names
    }

    static func displayName(_ section: String) -> String {
        AXAuditRules.sectionTitles[section] ?? section.prefix(1).uppercased() + section.dropFirst()
    }
}
