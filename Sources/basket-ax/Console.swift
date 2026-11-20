import Foundation
import BasketAXKit

/// Terminal output plus an optional log file (when launched via `open`, stdout is invisible).
@MainActor
enum Console {
    private static var logHandle: FileHandle?
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func openLog(at url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: url)
    }

    static func log(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        logHandle?.write(Data(line.utf8))
    }

    nonisolated static func error(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func printReport(_ report: AXAuditReport, directory: URL, limit: Int = 25) {
        var lines = ["basket-ax \(report.mode.rawValue): \(report.summary)"]
        var shown: [(String, AXFinding)] = []
        for section in report.sections {
            shown += section.findings.map { (section.name, $0) }
        }
        shown += report.consistency.map { ("consistency", $0) }
        shown = shown.filter { $0.1.severity != .info }.sorted { $0.1.severity < $1.1.severity }
        for (where_, f) in shown.prefix(limit) {
            lines.append("  [\(f.severity.rawValue)] \(where_) \(f.rule): \(f.message)")
        }
        if shown.count > limit { lines.append("  … \(shown.count - limit) more in report.md") }
        for check in report.checks where !check.passed {
            lines.append("  [check failed] \(check.name): \(check.message)")
        }
        for note in report.notes { lines.append("  note: \(note)") }
        lines.append("report: \(directory.appendingPathComponent("report.md").path)")
        for line in lines { log(line) }
    }
}
