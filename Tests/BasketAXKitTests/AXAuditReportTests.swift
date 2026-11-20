import AppKit
import Foundation
import Testing
@testable import BasketAXKit

@Suite struct AXAuditReportTests {
    let error = AXFinding(rule: "overlap", severity: .error, message: "a overlaps b", path: "AXWindow/AXButton#a",
                          identifier: "a", frame: r(1, 2, 3, 4))
    let warning = AXFinding(rule: "tiny-target", severity: .warning, message: "small", path: "AXWindow/AXButton#b")

    @Test func countsStatusAndExitCode() {
        var report = AXAuditReport(mode: .selftest, sections: [
            .init(name: "images", snapshot: "images.ax.json", screenshot: "images.png", nodeCount: 10, findings: [warning]),
        ])
        #expect(report.status == .passed && report.exitCode == 0, "warnings don't fail the run")
        #expect(report.counts == AXFindingCounts(errors: 0, warnings: 1, infos: 0))

        report.consistency = [error]
        report.finalize()
        #expect(report.status == .failed && report.exitCode == 1)
        #expect(report.counts.errors == 1)
    }

    @Test func failedCheckFailsTheRun() {
        let report = AXAuditReport(mode: .remote, checks: [.init(name: "sheet", passed: false, message: "no sheet")])
        #expect(report.status == .failed)
        #expect(report.exitCode == 1)
    }

    @Test func permissionAndRunnerErrorReports() throws {
        let permission = AXAuditReport.needsAccessibilityPermission(app: "/x/Basket.app", notes: ["grant it"])
        #expect(permission.status == .needsAccessibilityPermission && permission.exitCode == 3)
        let json = String(decoding: try permission.jsonData(), as: UTF8.self)
        #expect(json.contains("\"status\" : \"needs-accessibility-permission\""))
        #expect(json.contains("\"exitCode\" : 3"))

        let partial = AXAuditReport(mode: .remote, sections: [.init(name: "overview", snapshot: nil, screenshot: nil, nodeCount: 1, findings: [error])])
        let failed = AXAuditReport.runnerError(mode: .remote, message: "window never appeared", partial: partial)
        #expect(failed.status == .runnerError && failed.exitCode == 2)
        #expect(failed.sections.count == 1, "keeps what was captured")
        #expect(failed.notes.last == "runner error: window never appeared")
    }

    @Test func jsonRoundTripAndFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("axreport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = AXAuditReport(
            mode: .remote,
            sections: [.init(name: "containers", snapshot: "containers.ax.json", screenshot: nil, nodeCount: 42, findings: [error, warning])],
            consistency: [warning],
            checks: [.init(name: "detail", passed: true, message: "ok")],
            notes: ["Screen Recording not granted"], app: "/x/Basket.app", fixtures: "/x/Fixtures/demo")
        try report.write(to: dir)
        let loaded = try AXAuditReport.load(from: dir.appendingPathComponent("report.json"))
        #expect(loaded.sections.first?.findings == [error, warning])
        #expect(loaded.counts == AXFindingCounts(errors: 1, warnings: 2, infos: 0))
        #expect(loaded.exitCode == 1)
        let md = try String(contentsOf: dir.appendingPathComponent("report.md"), encoding: .utf8)
        #expect(md.contains("# Basket accessibility audit (remote)"))
        #expect(md.contains("| containers | 1 | 1 | 0 | 42 | – |"))
        #expect(md.contains("**PASS** detail: ok"))
        #expect(md.contains("## Consistency across sections"))
        #expect(md.contains("`AXWindow/AXButton#a` @ 1,2 3x4"))
        #expect(md.contains("Screen Recording not granted"))
    }

    @Test func sortsErrorsFirst() {
        let info = AXFinding(rule: "a", severity: .info, message: "", path: "")
        #expect([info, warning, error].sortedForReport().map(\.severity) == [.error, .warning, .info])
        #expect([info, warning].hasErrors == false)
    }
}

/// A plain view that is an accessibility element (the modern NSAccessibility protocol path).
private final class FakeButton: NSView {
    var title = ""
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
}

/// Over a real AppKit window: the in-process capture sees identifiers, labels and frames in AX
/// (top-left) coordinates, and skips hidden views.
@Suite struct InProcessCaptureTests {
    @MainActor @Test func capturesAnAppKitWindow() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("basket.main")
        let button = FakeButton(frame: NSRect(x: 20, y: 20, width: 100, height: 24))
        button.title = "Refresh"
        button.setAccessibilityIdentifier("images.action.refresh")
        let hidden = FakeButton(frame: NSRect(x: 20, y: 60, width: 100, height: 24))
        hidden.title = "Hidden"
        hidden.setAccessibilityIdentifier("images.hidden")
        hidden.isHidden = true
        let field = NSTextField(frame: NSRect(x: 140, y: 20, width: 200, height: 22))
        field.placeholderString = "Search images"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        container.addSubview(button)
        container.addSubview(hidden)
        container.addSubview(field)
        window.contentView = container
        defer { window.close() }

        let tree = InProcessAXCapture.snapshot(of: window)
        #expect(tree.role == "AXWindow")
        #expect(tree.identifier == "basket.main")
        let refresh = try #require(tree.first(identifier: "images.action.refresh"))
        #expect(refresh.role == "AXButton")
        #expect(refresh.label == "Refresh")
        #expect(tree.first { $0.role == "AXTextField" }?.placeholder == "Search images")
        #expect(tree.first(identifier: "images.hidden") == nil, "hidden views are skipped")
        #expect(tree.first { $0.subrole == "AXCloseButton" } != nil, "window chrome is included")

        // Frames are converted to top-left screen coordinates and lie inside the window.
        let windowFrame = try #require(tree.frame)
        let buttonFrame = try #require(refresh.frame)
        #expect(buttonFrame.width == 100 && buttonFrame.height == 24)
        #expect(windowFrame.contains(buttonFrame))
        let screenHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let cocoa = window.convertToScreen(button.convert(button.bounds, to: nil))
        #expect(abs(buttonFrame.y - (screenHeight - Double(cocoa.maxY))) < 0.01)
        #expect(abs(buttonFrame.x - Double(cocoa.minX)) < 0.01)
    }
}
