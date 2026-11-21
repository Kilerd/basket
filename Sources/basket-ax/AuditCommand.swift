import AppKit
import BasketAXKit
import Synchronization

/// `basket-ax audit`: the out-of-process E2E. Launches Basket.app with the fixtures backend,
/// drives it through AXUIElement (sidebar, buttons, sheet) and audits every section.
/// Only ever touches the process it launched.
@MainActor
enum AuditCommand {
    struct Options {
        var app: URL
        var fixtures: URL?
        var out: URL
        var sections: [String] = AXAuditRules.sections
        var launchTimeout: Double = 30
        var stepTimeout: Double = 10
        /// Whole-run budget (seconds). Past it the runner stops, writes a runner-error report and
        /// terminates the app; a watchdog thread does the same 30 s later if the main thread is stuck.
        var deadline: Double = 300
        /// App language for the run (`-AppleLanguages (<id>)`, e.g. `zh-Hans`); nil = the system's.
        var language: String?
        /// Region format for the run (`-AppleLocale <id>`, e.g. `fr_FR`); nil = the system's.
        var locale: String?
    }

    struct UsageError: Error, CustomStringConvertible { let description: String }

    static func parse(_ args: [String]) throws -> Options {
        var app: URL?, fixtures: URL?, out: URL?, sections: [String]?, deadlineOverride: Double?
        var language: String?, locale: String?
        var i = 0
        func value() throws -> String {
            i += 1
            guard i < args.count else { throw UsageError(description: "\(args[i - 1]) needs a value") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--app": app = URL(fileURLWithPath: try value())
            case "--fixtures": fixtures = URL(fileURLWithPath: try value())
            case "--out": out = URL(fileURLWithPath: try value())
            case "--deadline":
                guard let seconds = Double(try value()), seconds > 0 else {
                    throw UsageError(description: "--deadline needs a positive number of seconds")
                }
                deadlineOverride = seconds
            case "--language":
                let id = try value()
                guard id.range(of: #"^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil else {
                    throw UsageError(description: "--language needs a language id such as zh-Hans")
                }
                language = id
            case "--locale":
                let id = try value()
                guard id.range(of: #"^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil else {
                    throw UsageError(description: "--locale needs a locale id such as fr_FR")
                }
                locale = id
            case "--sections":
                sections = try value().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            default: throw UsageError(description: "unknown argument \(args[i])")
            }
            i += 1
        }
        guard let app else { throw UsageError(description: "--app is required") }
        guard let out else { throw UsageError(description: "--out is required") }
        var options = Options(app: app.standardizedFileURL, fixtures: fixtures?.standardizedFileURL,
                              out: out.standardizedFileURL)
        if let sections, !sections.isEmpty { options.sections = sections }
        if let deadlineOverride { options.deadline = deadlineOverride }
        options.language = language
        options.locale = locale
        return options
    }

    static func run(_ args: [String]) async -> Int32 {
        let options: Options
        do {
            options = try parse(args)
        } catch {
            Console.error("basket-ax audit: \(error)\n\(usage)")
            return 64
        }
        try? FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
        Console.openLog(at: options.out.appendingPathComponent("runner.log"))
        Console.log("basket-ax audit app=\(options.app.path) fixtures=\(options.fixtures?.path ?? "-") out=\(options.out.path) sections=\(options.sections.joined(separator: ","))")
        Console.log("runner bundle=\(Bundle.main.bundlePath) id=\(Bundle.main.bundleIdentifier ?? "-") pid=\(getpid())")

        AXErrorLog.sink = { Console.log($0) }
        let report: AXAuditReport
        if !RemoteAXCapture.isTrusted(prompt: true) {
            Console.log("Accessibility permission is not granted to this runner — stopping (exit 3)")
            report = .needsAccessibilityPermission(app: options.app.path, notes: permissionNotes())
        } else {
            HardDeadline.arm(after: options.deadline + 30, out: options.out, app: options.app)
            report = await AuditRunner(options: options).run()
        }
        do {
            try report.write(to: options.out)
        } catch {
            Console.log("cannot write report: \(error)")
            return 2
        }
        Console.printReport(report, directory: options.out)
        return report.exitCode
    }

    static func permissionNotes() -> [String] {
        let bundle = Bundle.main.bundlePath
        if bundle.hasSuffix(".app") {
            let name = (bundle as NSString).lastPathComponent
            return [
                "The runner (\(name), bundle id \(Bundle.main.bundleIdentifier ?? "?")) is not allowed to use the Accessibility API.",
                "Grant it once: System Settings › Privacy & Security › Accessibility → turn on “\((name as NSString).deletingPathExtension)” (or press + and add \(bundle)), then run scripts/e2e.sh again.",
                "The grant survives rebuilds because the runner is Developer-ID signed (TCC keys on its designated requirement).",
            ]
        }
        return [
            "basket-ax runs outside BasketE2E.app, so macOS attributes it to the terminal that launched it.",
            "Use scripts/e2e.sh (which runs BasketE2E.app), or grant your terminal app Accessibility in System Settings › Privacy & Security › Accessibility.",
        ]
    }
}

@MainActor
final class AuditRunner {
    let options: AuditCommand.Options
    private var app: NSRunningApplication?
    private var pid: pid_t = 0
    private var appElement: RemoteAXElement?
    private var cachedWindow: RemoteAXElement?
    private var sections: [AXAuditReport.SectionResult] = []
    private var trees: [String: AXNode] = [:]
    private var checks: [AXAuditReport.Check] = []
    private var notes: [String] = []
    private let screenshots = WindowScreenshot.isPermitted
    private let runDeadline: Date

    init(options: AuditCommand.Options) {
        self.options = options
        self.runDeadline = Date().addingTimeInterval(options.deadline)
    }

    private func checkDeadline() throws {
        guard Date() < runDeadline else {
            throw RunnerError(description: "run deadline of \(Int(options.deadline)) s exceeded (is the app hung? see AX errors in runner.log)")
        }
    }

    struct RunnerError: Error, CustomStringConvertible { let description: String }

    func run() async -> AXAuditReport {
        if !screenshots {
            notes.append("Screen Recording is not granted to the runner — screenshots skipped (optional: System Settings › Privacy & Security › Screen & System Audio Recording).")
        }
        // Every AX call (children included) gives up after 3 s; the whole run after `deadline`.
        RemoteAXCapture.setGlobalMessagingTimeout(3)
        RemoteAXCapture.deadline = runDeadline
        do {
            try await launch()
            _ = try await waitForMainWindow()
            for section in options.sections {
                try checkDeadline()
                await auditSection(section)
            }
            if options.sections.contains("containers") {
                try checkDeadline()
                await checkContainerDetail()
                try checkDeadline()
                await checkNewContainerSheet()
            }
            try checkDeadline()
        } catch {
            Console.log("ERROR: \(error)")
            await terminate()
            return .runnerError(mode: .remote, message: "\(error)", partial: makeReport())
        }
        await terminate()
        return makeReport()
    }

    private func makeReport() -> AXAuditReport {
        AXAuditReport(mode: .remote, sections: sections, consistency: AXAuditor.auditConsistency(sections: trees),
                      checks: checks, notes: notes, app: options.app.path, fixtures: options.fixtures?.path)
    }

    // MARK: Launch / terminate

    private func launch() async throws {
        guard let bundle = Bundle(url: options.app), bundle.executableURL != nil else {
            throw RunnerError(description: "\(options.app.path) is not an app bundle")
        }
        Console.log("launching \(bundle.bundleIdentifier ?? "?") from \(options.app.path) with -ApplePersistenceIgnoreState YES")
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("BASKET_") }
        env["BASKET_UI_TEST"] = "1"
        if let fixtures = options.fixtures {
            env["BASKET_BACKEND"] = "fixtures"
            env["BASKET_FIXTURES_DIR"] = fixtures.path
        } else {
            notes.append("no --fixtures given: the app used its default (live) backend")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.environment = env
        config.createsNewApplicationInstance = true
        config.activates = true
        config.addsToRecentItems = false
        config.promptsUserIfNeeded = false
        // Don't restore saved window state: a restored session can leave the main window closed.
        config.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        if let language = options.language {
            // The argument domain overrides the app's language for this run only.
            config.arguments += ["-AppleLanguages", "(\(language))"]
            notes.append("language: \(language)")
        }
        if let locale = options.locale {
            config.arguments += ["-AppleLocale", locale]
            notes.append("region format: \(locale)")
        }
        let launched = try await NSWorkspace.shared.openApplication(at: options.app, configuration: config)
        app = launched
        pid = launched.processIdentifier
        HardDeadline.launchedPid.withLock { $0 = pid }
        Console.log("launched pid \(pid)")
        let element = RemoteAXElement.application(pid: pid)
        RemoteAXCapture.setMessagingTimeout(3, for: element)
        appElement = element
    }

    private func terminate() async {
        guard let app, pid > 0 else { return }
        Console.log("terminating pid \(pid)")
        app.terminate()
        if await waitFor(5, honorDeadline: false, { kill(self.pid, 0) != 0 ? true : nil }) == nil {
            Console.log("app did not quit in 5 s — force terminating")
            app.forceTerminate()
            _ = await waitFor(3, honorDeadline: false, { kill(self.pid, 0) != 0 ? true : nil })
        }
        self.app = nil
        HardDeadline.launchedPid.withLock { $0 = 0 }
    }

    // MARK: Window

    private func waitForMainWindow() async throws -> RemoteAXElement {
        guard let appElement else { throw RunnerError(description: "app not launched") }
        var enhanced = false
        var lastDiagnosis = Date.distantPast
        let started = Date()
        let window = await waitFor(options.launchTimeout) { () -> RemoteAXElement? in
            guard kill(self.pid, 0) == 0 else { return nil }
            if !enhanced, appElement.role != nil {
                RemoteAXCapture.enableEnhancedUserInterface(appElement)
                enhanced = true
            }
            if Date().timeIntervalSince(lastDiagnosis) > 2 {
                lastDiagnosis = Date()
                self.diagnose(appElement)
            }
            if let window = self.findMainWindow() { return window }
            // Fallback: the identifier isn't visible out of process but the app shows exactly one
            // standard window — use it (the contract rule will still flag the missing id).
            if Date().timeIntervalSince(started) > self.options.launchTimeout / 3 {
                let standard = appElement.windows.filter { $0.subrole == "AXStandardWindow" }
                if standard.count == 1 {
                    self.notes.append("no window exposes “\(AXAuditRules.mainWindowIdentifier)” out of process; audited the app's only standard window (“\(standard[0].title ?? "?")”)")
                    return standard[0]
                }
            }
            return nil
        }
        guard let window else {
            if kill(pid, 0) != 0 { throw RunnerError(description: "Basket exited during launch (pid \(pid))") }
            throw RunnerError(description: "window “\(AXAuditRules.mainWindowIdentifier)” did not appear within \(Int(options.launchTimeout)) s")
        }
        Console.log("main window found")
        cachedWindow = window
        return window
    }

    /// Logs what the app exposes at the top level (and every AX error) while waiting for it.
    private func diagnose(_ app: RemoteAXElement) {
        let running = self.app
        Console.log("  app: finishedLaunching=\(running?.isFinishedLaunching ?? false) active=\(running?.isActive ?? false) policy=\(running?.activationPolicy.rawValue ?? -1)")
        let role = app.copy(kAXRoleAttribute)
        let windows = app.copy(kAXWindowsAttribute)
        let count = (windows.value as? [AnyObject])?.count ?? -1
        Console.log("  app element: role=\(RemoteAXCapture.text(role.value) ?? "nil") (\(AXErrorLog.name(role.error))) windows=\(count) (\(AXErrorLog.name(windows.error)))")
        for (n, w) in app.windows.enumerated() {
            Console.log("  window[\(n)]: role=\(w.role ?? "nil") subrole=\(w.subrole ?? "nil") id=\(w.identifier ?? "nil") title=\(w.title ?? "nil") frame=\(w.frame?.short ?? "nil") children=\(w.children.count)")
        }
        for attr in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            let r = app.copy(attr)
            let w = r.value.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? $0 : nil }
            Console.log("  \(attr): \(w == nil ? "none" : "present") (\(AXErrorLog.name(r.error)))")
        }
        if let summary = AXErrorLog.drainSummary() { Console.log("  AX errors so far: \(summary)") }
    }

    private func findMainWindow() -> RemoteAXElement? {
        guard let appElement else { return nil }
        let windows = appElement.windows
        for w in windows where w.identifier == AXAuditRules.mainWindowIdentifier { return w }
        for w in windows where RemoteAXCapture.find(identifier: AXAuditRules.mainWindowIdentifier, in: w, maxDepth: 8) != nil {
            return w
        }
        return nil
    }

    private var mainWindow: RemoteAXElement? {
        if let w = cachedWindow, w.role == "AXWindow" { return w }
        cachedWindow = findMainWindow()
        return cachedWindow
    }

    // MARK: Sections

    private func auditSection(_ section: String) async {
        Console.log("section \(section)")
        guard let window = mainWindow else {
            notes.append("[\(section)] main window lost")
            return
        }
        if let item = RemoteAXCapture.find(identifier: "sidebar.\(section)", in: window) {
            let how = activate(item)
            Console.log("  sidebar.\(section) activated via \(how ?? "nothing (no AXPress, row not selectable)")")
            if how == nil { notes.append("[\(section)] could not activate sidebar.\(section)") }
            let shown = await waitFor(options.stepTimeout) {
                RemoteAXCapture.find(identifier: "section.\(section)", in: window)
            }
            if shown == nil {
                notes.append("[\(section)] section.\(section) did not appear within \(Int(options.stepTimeout)) s after selecting the sidebar item")
            }
        } else {
            notes.append("[\(section)] sidebar.\(section) not found — captured whatever is showing")
        }
        var node = await capture(name: section, of: window, isSection: true)
        if !node.contains(identifier: "section.\(section)"), Date() < runDeadline,
           let item = RemoteAXCapture.find(identifier: "sidebar.\(section)", in: window) {
            // Something else changed the selection while we captured (e.g. a click on the
            // window, which sits on the user's screen) — navigate once more and recapture.
            let shownNow = node.first { $0.identifier?.hasPrefix("section.") == true }?.identifier ?? "?"
            Console.log("  section.\(section) missing from the capture (showing \(shownNow)); retrying once")
            notes.append("[\(section)] the app showed \(shownNow) while capturing; re-selected sidebar.\(section) and captured again")
            _ = activate(item)
            _ = await waitFor(options.stepTimeout) { RemoteAXCapture.find(identifier: "section.\(section)", in: window) }
            node = await capture(name: section, of: window, isSection: true)
        }
        guard Date() < runDeadline else {
            notes.append("[\(section)] capture cut off by the run deadline — not audited")
            return
        }
        trees[section] = node
        let findings = AXAuditor.audit(window: node, section: section)
        Console.log("  \(node.nodeCount) nodes, \(AXFindingCounts(findings).errors) errors, \(AXFindingCounts(findings).warnings) warnings")
        sections.append(.init(name: section, snapshot: section + AXSnapshotIO.snapshotSuffix,
                              screenshot: await screenshot(name: section, window: node),
                              nodeCount: node.nodeCount, findings: findings))
    }

    /// Captures until two consecutive snapshots agree (max 3 s), then writes `<name>.ax.json`
    /// (sections) or `check-<name>.json` (interaction states, which `lint` must not treat as sections).
    private func capture(name: String, of element: RemoteAXElement, isSection: Bool = false) async -> AXNode {
        var node = RemoteAXCapture.snapshot(of: element)
        var passes = [node.nodeCount]
        var lastChange = ""
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(300))
            let next = RemoteAXCapture.snapshot(of: element)
            passes.append(next.nodeCount)
            // Rows scrolled out of view keep being re-laid out; only the visible part must settle.
            let (a, b) = (Self.visiblePart(node), Self.visiblePart(next))
            node = next
            if a == b { break }
            lastChange = Self.firstDifference(a, b) ?? ""
        }
        if passes.count > 2 {
            Console.log("  \(name): tree still changing — node counts per pass \(passes); last change: \(lastChange)")
        }
        Console.log("  captured \(name): \(node.nodeCount) nodes")
        if let summary = AXErrorLog.drainSummary() { Console.log("  AX errors: \(summary)") }
        do {
            if isSection {
                try AXSnapshotIO.write(node, section: name, to: options.out)
            } else {
                try node.jsonData().write(to: options.out.appendingPathComponent("check-\(name).json"), options: .atomic)
            }
        } catch {
            notes.append("cannot write the \(name) snapshot: \(error)")
        }
        return node
    }

    /// `node` without descendants that lie entirely outside their nearest scroll area.
    static func visiblePart(_ node: AXNode, clip: AXRect? = nil) -> AXNode {
        var copy = node
        let childClip = node.role == "AXScrollArea" ? (node.frame ?? clip) : clip
        copy.children = node.children.compactMap { child in
            if let clip = childClip, let f = child.frame, !f.isEmpty, f.intersection(clip) == nil { return nil }
            return visiblePart(child, clip: childClip)
        }
        return copy
    }

    /// The first node (pre-order) whose own attributes differ, for "tree still changing" logs.
    static func firstDifference(_ a: AXNode, _ b: AXNode, path: String = "") -> String? {
        let here = path.isEmpty ? a.pathComponent : path + "/" + a.pathComponent
        var shallowA = a, shallowB = b
        shallowA.children = []
        shallowB.children = []
        if shallowA != shallowB {
            let fields = Mirror(reflecting: shallowA).children.compactMap { child -> String? in
                guard let label = child.label else { return nil }
                let other = Mirror(reflecting: shallowB).children.first { $0.label == label }?.value
                let x = String(describing: child.value), y = String(describing: other ?? "nil")
                return x == y ? nil : "\(label): \(x) → \(y)"
            }
            return "\(here) [\(fields.joined(separator: "; "))]"
        }
        if a.children.count != b.children.count { return "\(here) [children \(a.children.count) → \(b.children.count)]" }
        for (ca, cb) in zip(a.children, b.children) {
            if let diff = firstDifference(ca, cb, path: here) { return diff }
        }
        return nil
    }

    private func screenshot(name: String, window: AXNode) async -> String? {
        guard screenshots else { return nil }
        let file = name + ".png"
        let frame = window.frame.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        do {
            try await WindowScreenshot.capture(pid: pid, matching: frame, to: options.out.appendingPathComponent(file))
            return file
        } catch {
            notes.append("[\(name)] screenshot failed: \(error)")
            return nil
        }
    }

    // MARK: Interaction checks

    private func checkContainerDetail() async {
        let name = "containers: selecting the first row shows containers.detail"
        guard let window = await showSection("containers") else {
            checks.append(.init(name: name, passed: false, message: "could not show the containers section"))
            return
        }
        guard let row = RemoteAXCapture.find(in: window, where: { $0.identifier?.hasPrefix("containers.row.") == true }) else {
            checks.append(.init(name: name, passed: false, message: "no containers.row.* element (are the fixtures empty?)"))
            return
        }
        let rowID = row.identifier ?? "?"
        let how = activate(row)
        Console.log("  \(rowID) activated via \(how ?? "nothing")")
        let detail = await waitFor(options.stepTimeout) { RemoteAXCapture.find(identifier: "containers.detail", in: window) }
        guard detail != nil else {
            checks.append(.init(name: name, passed: false,
                                message: "selected \(rowID) (\(how ?? "no way to select it")) but containers.detail did not appear"))
            return
        }
        let node = await capture(name: "containers-detail", of: window)
        let findings = newFindings(AXAuditor.audit(window: node, section: "containers"), comparedTo: "containers")
        checks.append(.init(name: name, passed: !findings.hasErrors,
                            message: "selected \(rowID) via \(how ?? "?"); containers.detail appeared"
                                + (findings.isEmpty ? "" : "; \(findings.count) new findings in the detail state (check-containers-detail.json)"),
                            findings: findings))
        _ = await screenshot(name: "containers-detail", window: node)
    }

    private func checkNewContainerSheet() async {
        let name = "containers.action.new opens a sheet whose fields are all labelled; Cancel closes it"
        guard let window = await showSection("containers") else {
            checks.append(.init(name: name, passed: false, message: "could not show the containers section"))
            return
        }
        guard let button = RemoteAXCapture.find(identifier: "containers.action.new", in: window) else {
            checks.append(.init(name: name, passed: false, message: "containers.action.new not found"))
            return
        }
        let pressed = button.perform(kAXPressAction)
        Console.log("  containers.action.new AXPress → \(pressed.rawValue)")
        guard let sheet = await waitFor(options.stepTimeout, { self.findSheet(of: window) }) else {
            checks.append(.init(name: name, passed: false, message: "no sheet appeared after pressing containers.action.new (AXPress → \(pressed.rawValue))"))
            return
        }
        let node = await capture(name: "containers-new-sheet", of: sheet)
        _ = await screenshot(name: "containers-new-sheet", window: trees["containers"] ?? node)
        let labelFindings = AXAuditor.auditLabels(node)
        let fields = node.allNodes.filter { AXAuditRules.isInteractive($0) && $0.role != "AXButton" }
        var problems: [String] = []
        if fields.isEmpty { problems.append("the sheet has no input fields") }
        if labelFindings.hasErrors { problems.append("\(labelFindings.count) unlabelled controls") }

        let cancel = RemoteAXCapture.find(in: sheet) { element in
            if element.identifier?.lowercased().hasSuffix(".cancel") == true { return true }
            guard element.role == "AXButton" else { return false }
            let names = [element.title, element.string(kAXDescriptionAttribute)].compactMap { $0?.lowercased() }
            return names.contains("cancel")
        }
        if let cancel {
            cancel.perform(kAXPressAction)
            let closed = await waitFor(options.stepTimeout) { self.findSheet(of: window) == nil ? true : nil }
            if closed == nil { problems.append("Cancel did not close the sheet") }
        } else {
            problems.append("no Cancel button (title “Cancel” or identifier *.cancel)")
            // Leave the app as found; terminate() will close it anyway.
        }
        checks.append(.init(name: name, passed: problems.isEmpty,
                            message: problems.isEmpty
                                ? "sheet with \(fields.count) fields, all labelled; Cancel closed it"
                                : problems.joined(separator: "; "),
                            findings: labelFindings))
    }

    private func findSheet(of window: RemoteAXElement) -> RemoteAXElement? {
        if let sheet = window.children.first(where: { $0.role == "AXSheet" }) { return sheet }
        // Some presentations use a separate dialog window instead of an attached sheet.
        return appElement?.windows.first { $0.subrole == "AXDialog" && $0.identifier != AXAuditRules.mainWindowIdentifier }
    }

    private func showSection(_ section: String) async -> RemoteAXElement? {
        guard let window = mainWindow else { return nil }
        if RemoteAXCapture.find(identifier: "section.\(section)", in: window) != nil { return window }
        guard let item = RemoteAXCapture.find(identifier: "sidebar.\(section)", in: window), activate(item) != nil else {
            return nil
        }
        return await waitFor(options.stepTimeout) {
            RemoteAXCapture.find(identifier: "section.\(section)", in: window) != nil ? window : nil
        }
    }

    /// Selects the outline/table row containing `element`, else presses it. Returns how.
    private func activate(_ element: RemoteAXElement) -> String? {
        var row: RemoteAXElement? = element
        for _ in 0..<5 where row?.role != "AXRow" { row = row?.parent }
        if let row, row.role == "AXRow" {
            if row.isSettable(kAXSelectedAttribute), row.set(kAXSelectedAttribute, kCFBooleanTrue) == .success {
                return "AXSelected on its row"
            }
            if let table = row.parent, table.isSettable(kAXSelectedRowsAttribute),
               table.set(kAXSelectedRowsAttribute, [row.ref] as CFArray) == .success {
                return "AXSelectedRows on its \(table.role ?? "table")"
            }
        }
        if element.actionNames.contains(kAXPressAction), element.perform(kAXPressAction) == .success {
            return "AXPress"
        }
        return nil
    }

    /// Findings of a follow-up capture that weren't already reported for `section`.
    private func newFindings(_ findings: [AXFinding], comparedTo section: String) -> [AXFinding] {
        let known = Set((sections.first { $0.name == section }?.findings ?? []).map { "\($0.rule)|\($0.path)|\($0.message)" })
        return findings.filter { !known.contains("\($0.rule)|\($0.path)|\($0.message)") }
    }

    // MARK: Polling

    private func waitFor<T>(_ seconds: Double, interval: Double = 0.2, honorDeadline: Bool = true,
                            _ probe: () -> T?) async -> T? {
        var deadline = Date().addingTimeInterval(seconds)
        if honorDeadline { deadline = min(deadline, runDeadline) }
        while true {
            if let value = probe() { return value }
            if Date() >= deadline { return nil }
            try? await Task.sleep(for: .seconds(interval))
        }
    }
}

/// Backstop for a main thread stuck inside AX calls: a background timer that, if the run is still
/// going, kills the Basket instance this runner launched (and nothing else), writes a
/// runner-error report and exits with 2.
enum HardDeadline {
    static let launchedPid = Mutex<pid_t>(0)

    static func arm(after seconds: Double, out: URL, app: URL) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
            let message = "hard deadline (\(Int(seconds)) s) hit with the runner still busy — killed the app and aborted"
            let pid = launchedPid.withLock { $0 }
            if pid > 0, let running = NSRunningApplication(processIdentifier: pid),
               running.bundleURL?.standardizedFileURL.path == app.standardizedFileURL.path {
                kill(pid, SIGKILL)
            }
            let report = AXAuditReport.runnerError(mode: .remote, message: message)
            try? report.write(to: out)
            if let log = try? FileHandle(forWritingTo: out.appendingPathComponent("runner.log")) {
                log.seekToEndOfFile()
                log.write(Data("ERROR: \(message)\n".utf8))
            }
            FileHandle.standardError.write(Data("basket-ax: \(message)\n".utf8))
            exit(2)
        }
    }
}
