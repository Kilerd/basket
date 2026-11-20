import Foundation

/// Result of an accessibility audit run: written as `report.json` + `report.md`.
public struct AXAuditReport: Codable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// Snapshots dumped by the app itself (`BASKET_SELFTEST_DIR`), checked by `basket-ax lint`.
        case selftest
        /// Out-of-process capture through AXUIElement (`basket-ax audit`).
        case remote
    }

    public enum Status: String, Codable, Sendable {
        case passed
        case failed
        case needsAccessibilityPermission = "needs-accessibility-permission"
        case runnerError = "runner-error"

        /// Process exit code for this status.
        public var exitCode: Int32 {
            switch self {
            case .passed: 0
            case .failed: 1
            case .runnerError: 2
            case .needsAccessibilityPermission: 3
            }
        }
    }

    public struct SectionResult: Codable, Sendable {
        public var name: String
        /// `<section>.ax.json`, relative to the report directory.
        public var snapshot: String?
        /// `<section>.png`, relative to the report directory.
        public var screenshot: String?
        public var nodeCount: Int
        public var findings: [AXFinding]
        public var counts: AXFindingCounts

        public init(name: String, snapshot: String?, screenshot: String?, nodeCount: Int, findings: [AXFinding]) {
            self.name = name
            self.snapshot = snapshot
            self.screenshot = screenshot
            self.nodeCount = nodeCount
            self.findings = findings
            self.counts = AXFindingCounts(findings)
        }
    }

    /// A scripted interaction (remote mode), e.g. "select first container shows its detail".
    public struct Check: Codable, Sendable {
        public var name: String
        public var passed: Bool
        public var message: String
        public var findings: [AXFinding]

        public init(name: String, passed: Bool, message: String, findings: [AXFinding] = []) {
            self.name = name
            self.passed = passed
            self.message = message
            self.findings = findings
        }
    }

    public var mode: Mode
    public var status: Status
    public var exitCode: Int32
    /// ISO 8601.
    public var generatedAt: String
    public var app: String?
    public var fixtures: String?
    public var sections: [SectionResult]
    public var consistency: [AXFinding]
    public var checks: [Check]
    public var notes: [String]
    public var counts: AXFindingCounts

    public init(
        mode: Mode,
        sections: [SectionResult] = [],
        consistency: [AXFinding] = [],
        checks: [Check] = [],
        notes: [String] = [],
        app: String? = nil,
        fixtures: String? = nil,
        generatedAt: Date = Date()
    ) {
        self.mode = mode
        self.sections = sections
        self.consistency = consistency
        self.checks = checks
        self.notes = notes
        self.app = app
        self.fixtures = fixtures
        self.generatedAt = ISO8601DateFormatter().string(from: generatedAt)
        self.status = .passed
        self.exitCode = 0
        self.counts = AXFindingCounts()
        finalize()
    }

    /// A report that only says the runner may not use the Accessibility API yet.
    public static func needsAccessibilityPermission(mode: Mode = .remote, app: String?, notes: [String]) -> AXAuditReport {
        var report = AXAuditReport(mode: mode, notes: notes, app: app)
        report.status = .needsAccessibilityPermission
        report.exitCode = report.status.exitCode
        return report
    }

    /// A report for a run that could not complete (app didn't launch, window never appeared…).
    public static func runnerError(mode: Mode, message: String, partial: AXAuditReport? = nil) -> AXAuditReport {
        var report = partial ?? AXAuditReport(mode: mode)
        report.notes.append("runner error: \(message)")
        report.finalize()
        report.status = .runnerError
        report.exitCode = report.status.exitCode
        return report
    }

    /// Recomputes counts, status and exit code from sections, consistency findings and checks.
    public mutating func finalize() {
        counts = sections.reduce(AXFindingCounts()) { $0 + $1.counts }
            + AXFindingCounts(consistency)
            + AXFindingCounts(checks.flatMap(\.findings))
        let failed = counts.errors > 0 || checks.contains { !$0.passed }
        status = failed ? .failed : .passed
        exitCode = status.exitCode
    }

    public var allFindings: [AXFinding] {
        sections.flatMap(\.findings) + consistency + checks.flatMap(\.findings)
    }

    // MARK: - Output

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func load(from url: URL) throws -> AXAuditReport {
        try JSONDecoder().decode(AXAuditReport.self, from: Data(contentsOf: url))
    }

    /// Writes `report.json` and `report.md` into `directory`.
    public func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try jsonData().write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        try Data(markdown().utf8).write(to: directory.appendingPathComponent("report.md"), options: .atomic)
    }

    /// One-line summary for terminals.
    public var summary: String {
        "\(status.rawValue): \(counts.errors) errors, \(counts.warnings) warnings, \(counts.infos) info"
            + " across \(sections.count) sections"
            + (checks.isEmpty ? "" : ", \(checks.filter(\.passed).count)/\(checks.count) checks passed")
    }

    public func markdown() -> String {
        var md: [String] = []
        md.append("# Basket accessibility audit (\(mode.rawValue))")
        md.append("")
        md.append("- Status: **\(status.rawValue)** (exit \(exitCode))")
        md.append("- Generated: \(generatedAt)")
        if let app { md.append("- App: `\(app)`") }
        if let fixtures { md.append("- Fixtures: `\(fixtures)`") }
        md.append("- Totals: \(counts.errors) errors, \(counts.warnings) warnings, \(counts.infos) info")
        md.append("")

        if !sections.isEmpty {
            md.append("| Section | Errors | Warnings | Info | Nodes | Screenshot |")
            md.append("|---|---:|---:|---:|---:|---|")
            for s in sections {
                let shot = s.screenshot.map { "[\($0)](\($0))" } ?? "–"
                md.append("| \(s.name) | \(s.counts.errors) | \(s.counts.warnings) | \(s.counts.infos) | \(s.nodeCount) | \(shot) |")
            }
            let c = AXFindingCounts(consistency)
            md.append("| *consistency* | \(c.errors) | \(c.warnings) | \(c.infos) | | |")
            md.append("")
        }

        if !checks.isEmpty {
            md.append("## Interaction checks")
            md.append("")
            for check in checks {
                md.append("- **\(check.passed ? "PASS" : "FAIL")** \(check.name): \(check.message)")
                for f in check.findings { md.append("  - " + line(f)) }
            }
            md.append("")
        }

        for s in sections where !s.findings.isEmpty {
            md.append("## \(s.name)")
            md.append("")
            md += s.findings.map { "- " + line($0) }
            md.append("")
        }

        if !consistency.isEmpty {
            md.append("## Consistency across sections")
            md.append("")
            md += consistency.map { "- " + line($0) }
            md.append("")
        }

        if !notes.isEmpty {
            md.append("## Notes")
            md.append("")
            md += notes.map { "- " + $0 }
            md.append("")
        }
        return md.joined(separator: "\n")
    }

    private func line(_ f: AXFinding) -> String {
        var s = "**\(f.severity.rawValue)** `\(f.rule)` — \(f.message)"
        s += "<br>`\(f.path)`"
        if let frame = f.frame { s += " @ \(frame.short)" }
        return s
    }
}
