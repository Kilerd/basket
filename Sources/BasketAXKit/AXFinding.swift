import Foundation

/// One problem found in an accessibility tree.
public struct AXFinding: Codable, Sendable, Hashable {
    public enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
        case error, warning, info

        private var rank: Int {
            switch self {
            case .error: 0
            case .warning: 1
            case .info: 2
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    /// Rule id, e.g. `missing-label`, `overlap`, `consistency-sidebar`.
    public var rule: String
    public var severity: Severity
    public var message: String
    /// Role/identifier chain from the window to the element, e.g.
    /// `AXWindow#basket.main/AXGroup#section.containers/AXButton#containers.action.new`.
    public var path: String
    public var identifier: String?
    public var frame: AXRect?

    public init(
        rule: String,
        severity: Severity,
        message: String,
        path: String,
        identifier: String? = nil,
        frame: AXRect? = nil
    ) {
        self.rule = rule
        self.severity = severity
        self.message = message
        self.path = path
        self.identifier = identifier
        self.frame = frame
    }
}

/// Finding totals by severity.
public struct AXFindingCounts: Codable, Sendable, Hashable {
    public var errors: Int
    public var warnings: Int
    public var infos: Int

    public init(errors: Int = 0, warnings: Int = 0, infos: Int = 0) {
        self.errors = errors
        self.warnings = warnings
        self.infos = infos
    }

    public init(_ findings: [AXFinding]) {
        self.init()
        for f in findings { add(f.severity) }
    }

    public mutating func add(_ severity: AXFinding.Severity) {
        switch severity {
        case .error: errors += 1
        case .warning: warnings += 1
        case .info: infos += 1
        }
    }

    public static func + (a: AXFindingCounts, b: AXFindingCounts) -> AXFindingCounts {
        AXFindingCounts(errors: a.errors + b.errors, warnings: a.warnings + b.warnings, infos: a.infos + b.infos)
    }
}

extension Array where Element == AXFinding {
    /// Errors first, then by rule and path — stable, readable report order.
    public func sortedForReport() -> [AXFinding] {
        sorted {
            ($0.severity, $0.rule, $0.path, $0.message) < ($1.severity, $1.rule, $1.path, $1.message)
        }
    }

    public var hasErrors: Bool { contains { $0.severity == .error } }
}
