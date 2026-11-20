import Foundation

/// A rectangle in screen coordinates with a top-left origin (the AXUIElement convention:
/// y grows downwards from the top of the primary screen).
public struct AXRect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var area: Double { max(0, width) * max(0, height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// The overlapping rectangle, or `nil` when the rectangles don't overlap (touching edges don't count).
    public func intersection(_ other: AXRect) -> AXRect? {
        let x0 = max(minX, other.minX), y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return AXRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// True when `other` lies inside `self`, allowing `tolerance` points of slack on every edge.
    public func contains(_ other: AXRect, tolerance: Double = 0) -> Bool {
        other.minX >= minX - tolerance && other.minY >= minY - tolerance
            && other.maxX <= maxX + tolerance && other.maxY <= maxY + tolerance
    }

    /// Short human-readable form used in findings: `x,y wxh`.
    public var short: String {
        func f(_ v: Double) -> String {
            v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
        }
        return "\(f(x)),\(f(y)) \(f(width))x\(f(height))"
    }
}

/// One element of an accessibility tree, as VoiceOver sees it. The same model is produced by the
/// in-process capture (NSAccessibility) and the out-of-process capture (AXUIElement).
public struct AXNode: Codable, Sendable, Hashable {
    public var role: String
    public var subrole: String?
    public var identifier: String?
    public var title: String?
    /// AXDescription — what VoiceOver reads as the element's label.
    public var label: String?
    public var help: String?
    public var value: String?
    public var placeholder: String?
    public var frame: AXRect?
    public var isEnabled: Bool?
    public var isFocused: Bool?
    public var isSelected: Bool?
    public var children: [AXNode]

    public init(
        role: String,
        subrole: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        label: String? = nil,
        help: String? = nil,
        value: String? = nil,
        placeholder: String? = nil,
        frame: AXRect? = nil,
        isEnabled: Bool? = nil,
        isFocused: Bool? = nil,
        isSelected: Bool? = nil,
        children: [AXNode] = []
    ) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.label = label
        self.help = help
        self.value = value
        self.placeholder = placeholder
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.isSelected = isSelected
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case role, subrole, identifier, title, label, help, value, placeholder, frame
        case isEnabled, isFocused, isSelected, children
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        subrole = try c.decodeIfPresent(String.self, forKey: .subrole)
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        help = try c.decodeIfPresent(String.self, forKey: .help)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        frame = try c.decodeIfPresent(AXRect.self, forKey: .frame)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled)
        isFocused = try c.decodeIfPresent(Bool.self, forKey: .isFocused)
        isSelected = try c.decodeIfPresent(Bool.self, forKey: .isSelected)
        // Leaves omit `children` (see `encode(to:)`).
        children = try c.decodeIfPresent([AXNode].self, forKey: .children) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encodeIfPresent(subrole, forKey: .subrole)
        try c.encodeIfPresent(identifier, forKey: .identifier)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(help, forKey: .help)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(placeholder, forKey: .placeholder)
        try c.encodeIfPresent(frame, forKey: .frame)
        try c.encodeIfPresent(isEnabled, forKey: .isEnabled)
        try c.encodeIfPresent(isFocused, forKey: .isFocused)
        try c.encodeIfPresent(isSelected, forKey: .isSelected)
        if !children.isEmpty { try c.encode(children, forKey: .children) }
    }
}

// MARK: - Traversal helpers

extension AXNode {
    /// The name VoiceOver would announce, ignoring the value (title, then description, then help).
    public var accessibleName: String? {
        for candidate in [title, label, help] {
            if let s = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        }
        return nil
    }

    /// Visible text of a static-text-like node: value, then title, then description.
    public var text: String? {
        for candidate in [value, title, label] {
            if let s = candidate, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        }
        return nil
    }

    /// `AXButton#containers.action.new` style path component.
    public var pathComponent: String {
        if let identifier, !identifier.isEmpty { return "\(role)#\(identifier)" }
        if let name = accessibleName ?? (role == "AXStaticText" ? text : nil) {
            let short = name.count > 24 ? String(name.prefix(23)) + "…" : name
            return "\(role)[\(short)]"
        }
        return role
    }

    /// Depth-first, pre-order visit. The closure receives the node and its ancestors (root first).
    public func walk(_ visit: (AXNode, [AXNode]) throws -> Void) rethrows {
        var ancestors: [AXNode] = []
        try walk(&ancestors, visit)
    }

    private func walk(_ ancestors: inout [AXNode], _ visit: (AXNode, [AXNode]) throws -> Void) rethrows {
        try visit(self, ancestors)
        ancestors.append(self)
        for child in children { try child.walk(&ancestors, visit) }
        ancestors.removeLast()
    }

    /// All nodes in pre-order (including `self`).
    public var allNodes: [AXNode] {
        var out: [AXNode] = []
        walk { node, _ in out.append(node) }
        return out
    }

    /// First node (pre-order) whose identifier equals `identifier`.
    public func first(identifier: String) -> AXNode? {
        first { $0.identifier == identifier }
    }

    public func first(where predicate: (AXNode) -> Bool) -> AXNode? {
        if predicate(self) { return self }
        for child in children {
            if let hit = child.first(where: predicate) { return hit }
        }
        return nil
    }

    public func all(where predicate: (AXNode) -> Bool) -> [AXNode] {
        allNodes.filter(predicate)
    }

    public func contains(identifier: String) -> Bool { first(identifier: identifier) != nil }

    public var nodeCount: Int { 1 + children.reduce(0) { $0 + $1.nodeCount } }
}

// MARK: - JSON

extension AXNode {
    /// Stable, human-diffable JSON (sorted keys, pretty-printed). This is the `<section>.ax.json` format.
    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(jsonData: Data) throws -> AXNode {
        try JSONDecoder().decode(AXNode.self, from: jsonData)
    }
}

/// Reading and writing the per-section snapshot files shared by self-test and the runner.
public enum AXSnapshotIO {
    public static let snapshotSuffix = ".ax.json"

    /// Writes `<section>.ax.json` into `directory` (created if needed) and returns its URL.
    @discardableResult
    public static func write(_ node: AXNode, section: String, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(section + snapshotSuffix)
        try node.jsonData().write(to: url, options: .atomic)
        return url
    }

    /// Section names (file stems) of every `*.ax.json` in `directory`, sorted.
    public static func sections(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(snapshotSuffix) }
            .map { String($0.dropLast(snapshotSuffix.count)) }
            .sorted()
    }

    public static func load(section: String, from directory: URL) throws -> AXNode {
        let url = directory.appendingPathComponent(section + snapshotSuffix)
        return try AXNode.decode(jsonData: Data(contentsOf: url))
    }
}
