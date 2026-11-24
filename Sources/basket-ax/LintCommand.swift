import Foundation
import BasketAXKit

/// `basket-ax lint <dir> [--fixtures <dir>]`: audits `<section>.ax.json` snapshots written by the
/// app's self-test. With `--fixtures` (the set the self-test ran on), its `orbstack.json` decides
/// whether the migration section and the OrbStack setup step must be shown or hidden.
enum LintCommand {
    static let usage = "usage: basket-ax lint <dir> [--fixtures <dir>]"

    @MainActor static func run(_ args: [String]) -> Int32 {
        var rest = args
        var expectation = AXSectionExpectation.unknown
        if let flag = rest.firstIndex(of: "--fixtures") {
            guard flag + 1 < rest.count else {
                Console.error(usage)
                return 64
            }
            expectation = .fixtures(URL(fileURLWithPath: rest[flag + 1]))
            rest.removeSubrange(flag...(flag + 1))
        }
        guard rest.count == 1, let path = rest.first, !path.hasPrefix("-") else {
            Console.error(usage)
            return 64
        }
        let dir = URL(fileURLWithPath: path).standardizedFileURL
        let report = lint(directory: dir, expecting: expectation)
        do {
            try report.write(to: dir)
        } catch {
            Console.error("cannot write report into \(dir.path): \(error)")
            return 2
        }
        Console.printReport(report, directory: dir)
        return report.exitCode
    }

    static func lint(directory dir: URL, expecting expectation: AXSectionExpectation = .unknown) -> AXAuditReport {
        let names: [String]
        do {
            names = AXAuditor.orderedSections(try AXSnapshotIO.sections(in: dir))
        } catch {
            return .runnerError(mode: .selftest, message: "cannot read \(dir.path): \(error.localizedDescription)")
        }
        guard !names.isEmpty else {
            return .runnerError(mode: .selftest, message: "no *.ax.json snapshots in \(dir.path) — did the self-test run?")
        }

        var sections: [AXAuditReport.SectionResult] = []
        var trees: [String: AXNode] = [:]
        for name in names {
            let snapshot = name + AXSnapshotIO.snapshotSuffix
            let png = name + ".png"
            let screenshot = FileManager.default.fileExists(atPath: dir.appendingPathComponent(png).path) ? png : nil
            do {
                let node = try AXSnapshotIO.load(section: name, from: dir)
                let known = AXAuditRules.sections.contains(name)
                if known { trees[name] = node }
                sections.append(.init(name: name, snapshot: snapshot, screenshot: screenshot,
                                      nodeCount: node.nodeCount,
                                      findings: AXAuditor.audit(window: node, section: known ? name : nil,
                                                                expecting: expectation)))
            } catch {
                let finding = AXFinding(rule: "snapshot-unreadable", severity: .error,
                                        message: "cannot decode \(snapshot): \(error)", path: snapshot)
                sections.append(.init(name: name, snapshot: snapshot, screenshot: screenshot,
                                      nodeCount: 0, findings: [finding]))
            }
        }
        var notes = [expectation.summary]
        let missing = expectation.requiredSections.filter { trees[$0] == nil }
        if !missing.isEmpty { notes.append("sections without a snapshot: \(missing.joined(separator: ", "))") }
        return AXAuditReport(mode: .selftest, sections: sections,
                             consistency: AXAuditor.auditConsistency(sections: trees), notes: notes)
    }
}
