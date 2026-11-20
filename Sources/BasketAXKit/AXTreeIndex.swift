import Foundation

/// A flattened, parent-linked view of an `AXNode` tree that the rules query.
struct AXTreeIndex {
    struct Item {
        let node: AXNode
        let parent: Int?
        var children: [Int]
        let depth: Int
        /// Compact role/identifier chain from the root (anonymous groups are elided).
        let path: String
    }

    private(set) var items: [Item] = []

    init(_ root: AXNode) {
        add(root, parent: nil, depth: 0, prefix: "")
    }

    private mutating func add(_ node: AXNode, parent: Int?, depth: Int, prefix: String) {
        let index = items.count
        let path = prefix.isEmpty ? node.pathComponent : prefix + "/" + node.pathComponent
        items.append(Item(node: node, parent: parent, children: [], depth: depth, path: path))
        if let parent { items[parent].children.append(index) }
        let childPrefix = (parent != nil && Self.isAnonymousWrapper(node)) ? prefix : path
        for child in node.children {
            add(child, parent: index, depth: depth + 1, prefix: childPrefix)
        }
    }

    var root: Item { items[0] }
    subscript(_ i: Int) -> Item { items[i] }
    var indices: Range<Int> { items.indices }

    /// Ancestors of `i`, nearest first.
    func ancestors(of i: Int) -> [Int] {
        var out: [Int] = []
        var cursor = items[i].parent
        while let c = cursor {
            out.append(c)
            cursor = items[c].parent
        }
        return out
    }

    func isAncestor(_ a: Int, of b: Int) -> Bool {
        var cursor = items[b].parent
        while let c = cursor {
            if c == a { return true }
            cursor = items[c].parent
        }
        return false
    }

    func nearestAncestor(of i: Int, where predicate: (AXNode) -> Bool) -> Int? {
        ancestors(of: i).first { predicate(items[$0].node) }
    }

    /// Children of `i`, looking through anonymous single-child wrapper groups (SwiftUI often
    /// wraps one control in an unnamed group; for layout purposes the control is the sibling).
    func effectiveChildren(of i: Int) -> [Int] {
        items[i].children.map { child in
            var c = child
            while Self.isAnonymousWrapper(items[c].node), items[c].children.count == 1 {
                c = items[c].children[0]
            }
            return c
        }
    }

    static func isAnonymousWrapper(_ node: AXNode) -> Bool {
        AXAuditRules.anonymousWrapperRoles.contains(node.role)
            && node.identifier == nil && node.accessibleName == nil && nonBlank(node.value) == nil
    }

    /// All items carrying `identifier`, in pre-order.
    func matching(identifier: String) -> [Int] {
        indices.filter { items[$0].node.identifier == identifier }
    }

    /// The deepest item carrying `identifier` — the actual control when SwiftUI repeats an
    /// identifier on a wrapper (e.g. a toolbar item viewer and the button inside it).
    func innermost(identifier: String) -> Int? {
        matching(identifier: identifier).max { items[$0].depth < items[$1].depth }
    }

    /// Whether `i` sits in the window toolbar.
    func isInToolbar(_ i: Int) -> Bool {
        nearestAncestor(of: i) { $0.role == "AXToolbar" } != nil
    }

    /// `frame` relative to the window origin, so captures of a moved window still compare.
    func windowRelative(_ frame: AXRect) -> AXRect {
        guard let w = root.node.frame else { return frame }
        return AXRect(x: frame.x - w.x, y: frame.y - w.y, width: frame.width, height: frame.height)
    }
}
