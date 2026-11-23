import AppKit
import BasketAXKit

/// `basket-ax update-install`: the real-UI update test behind `scripts/update-e2e.sh`.
/// Launches Basket A (a DEBUG build with a local test feed), chooses Basket ▸ Check for Updates…
/// in its menu bar, waits for the update sheet and presses “Install and Relaunch”
/// (`update.install`) with AXPress — the path a user takes. Passes when A quits within
/// `--quit-timeout` seconds of starting the install, the bundle at `--app` is then version
/// `--expect-version`, and that version runs from there; the relaunched copy is quit again.
/// With `--kill`, Basket is told not to quit (DEBUG `BASKET_UPDATE_TEST_BLOCK_QUIT=1`, as
/// 0.0.1–0.0.3 couldn't) and the runner ends it 1 s after “Installing…” with SIGKILL or a Force
/// Quit: the swap helper must survive that and still install and relaunch the update (#41).
/// Only ever touches processes running from `--app`. Writes `result.json` and `runner.log`.
/// When A doesn't quit it is left running: the script stops the swap helper first, so that
/// killing A can't let a late swap happen.
@MainActor
enum UpdateInstallCommand {
    /// How `--kill` ends Basket once it shows “Installing…”.
    enum Kill: String {
        case sigkill
        /// LaunchServices' force quit, as ⌥⌘⎋, the Dock and Activity Monitor do it.
        case forceQuit = "force-quit"
    }

    struct Options {
        var app: URL
        var fixtures: URL?
        var feed: String
        var publicKey: String
        var expectVersion: String
        var out: URL
        var quitTimeout: Double = 10
        var deadline: Double = 180
        var kill: Kill?
    }

    static func parse(_ args: [String]) throws -> Options {
        var values: [String: String] = [:]
        var i = 0
        while i < args.count {
            let key = args[i]
            guard ["--app", "--fixtures", "--feed", "--public-key", "--expect-version", "--out", "--quit-timeout", "--deadline", "--kill"]
                .contains(key) else { throw AuditCommand.UsageError(description: "unknown argument \(key)") }
            guard i + 1 < args.count else { throw AuditCommand.UsageError(description: "\(key) needs a value") }
            values[key] = args[i + 1]
            i += 2
        }
        guard let app = values["--app"], let feed = values["--feed"], let key = values["--public-key"],
              let version = values["--expect-version"], let out = values["--out"] else {
            throw AuditCommand.UsageError(description: "--app, --feed, --public-key, --expect-version and --out are required")
        }
        var options = Options(app: URL(fileURLWithPath: app).standardizedFileURL,
                              fixtures: values["--fixtures"].map { URL(fileURLWithPath: $0).standardizedFileURL },
                              feed: feed, publicKey: key, expectVersion: version,
                              out: URL(fileURLWithPath: out).standardizedFileURL)
        if let text = values["--quit-timeout"] {
            guard let seconds = Double(text), seconds > 0 else { throw AuditCommand.UsageError(description: "--quit-timeout needs seconds") }
            options.quitTimeout = seconds
        }
        if let text = values["--deadline"] {
            guard let seconds = Double(text), seconds > 0 else { throw AuditCommand.UsageError(description: "--deadline needs seconds") }
            options.deadline = seconds
        }
        if let text = values["--kill"] {
            guard let kill = Kill(rawValue: text) else { throw AuditCommand.UsageError(description: "--kill needs sigkill or force-quit") }
            options.kill = kill
        }
        return options
    }

    static func run(_ args: [String]) async -> Int32 {
        let options: Options
        do {
            options = try parse(args)
        } catch {
            Console.error("basket-ax update-install: \(error)\n\(usage)")
            return 64
        }
        try? FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
        Console.openLog(at: options.out.appendingPathComponent("runner.log"))
        Console.log("basket-ax update-install app=\(options.app.path) expect=\(options.expectVersion) out=\(options.out.path)")
        AXErrorLog.sink = { Console.log($0) }
        let result: UpdateInstallResult
        if !RemoteAXCapture.isTrusted(prompt: true) {
            result = UpdateInstallResult(exitCode: 3, message: "Accessibility permission is not granted to this runner")
        } else {
            UpdateInstallResult.armWatchdog(after: options.deadline + 30, out: options.out)
            result = await UpdateInstallRunner(options: options).run()
        }
        Console.log((result.exitCode == 0 ? "PASS: " : "FAIL: ") + result.message)
        result.write(to: options.out)
        return result.exitCode
    }
}

/// `result.json`: exitCode 0 pass, 1 the update didn't install, 2 runner error, 3 no Accessibility.
struct UpdateInstallResult {
    var exitCode: Int32
    var message: String
    var pid: pid_t = 0
    var relaunchedPid: pid_t = 0
    /// Seconds from pressing Install to A's exit, and from the install starting (“Installing…”
    /// shown or the sheet gone) to A's exit.
    var secondsToQuit: Double?
    var secondsFromInstalling: Double?

    func write(to directory: URL) {
        var object: [String: Any] = ["exitCode": Int(exitCode), "message": message, "pid": Int(pid),
                                     "relaunchedPid": Int(relaunchedPid)]
        if let secondsToQuit { object["secondsToQuit"] = secondsToQuit }
        if let secondsFromInstalling { object["secondsFromInstalling"] = secondsFromInstalling }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        }
    }

    /// A main thread stuck in AX calls: write a runner error and exit. Never kills Basket (the
    /// script stops the swap helper first).
    static func armWatchdog(after seconds: Double, out: URL) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
            let message = "hard deadline (\(Int(seconds)) s) hit with the runner still busy"
            let data = try? JSONSerialization.data(withJSONObject: ["exitCode": 2, "message": message])
            try? data?.write(to: out.appendingPathComponent("result.json"), options: .atomic)
            FileHandle.standardError.write(Data("basket-ax: \(message)\n".utf8))
            exit(2)
        }
    }
}

@MainActor
final class UpdateInstallRunner {
    let options: UpdateInstallCommand.Options
    private var pid: pid_t = 0
    private var appElement: RemoteAXElement?
    private let runDeadline: Date

    struct Failure: Error { var code: Int32; var message: String }

    init(options: UpdateInstallCommand.Options) {
        self.options = options
        runDeadline = Date().addingTimeInterval(options.deadline)
    }

    func run() async -> UpdateInstallResult {
        RemoteAXCapture.setGlobalMessagingTimeout(3)
        var result = UpdateInstallResult(exitCode: 0, message: "")
        do {
            try await launch()
            result.pid = pid
            let window = try await waitForMainWindow()
            try await chooseCheckForUpdates(in: window)
            let sheet = try await waitForOffer(in: window)
            let (toQuit, fromInstalling) = try await installAndWaitForQuit(window: window, sheet: sheet)
            result.secondsToQuit = toQuit
            result.secondsFromInstalling = fromInstalling
            let relaunched = try await waitForRelaunch()
            result.relaunchedPid = relaunched.processIdentifier
            await quit(relaunched)
            let ended = options.kill.map { "was ended (\($0.rawValue))" } ?? "quit"
            result.message = String(format: "Basket (pid %d) %@ %.1f s after Install was pressed (%.1f s after installing started); "
                                    + "%@ is now %@ and ran as pid %d", pid, ended, toQuit, fromInstalling,
                                    options.app.path, options.expectVersion, relaunched.processIdentifier)
        } catch let failure as Failure {
            result.exitCode = failure.code
            result.message = failure.message
        } catch {
            result.exitCode = 2
            result.message = "\(error)"
        }
        return result
    }

    // MARK: Steps

    private func launch() async throws {
        guard let bundle = Bundle(url: options.app), bundle.executableURL != nil else {
            throw Failure(code: 2, message: "\(options.app.path) is not an app bundle")
        }
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("BASKET_") }
        env["BASKET_UI_TEST"] = "1"
        if let fixtures = options.fixtures {
            env["BASKET_BACKEND"] = "fixtures"
            env["BASKET_FIXTURES_DIR"] = fixtures.path
        }
        env["BASKET_UPDATE_FEED_URL"] = options.feed
        env["BASKET_UPDATE_TEST_PUBLIC_KEY"] = options.publicKey
        env["BASKET_UPDATE_ALLOW_UNNOTARIZED"] = "1"
        if options.kill != nil { env["BASKET_UPDATE_TEST_BLOCK_QUIT"] = "1" }
        let config = NSWorkspace.OpenConfiguration()
        config.environment = env
        config.createsNewApplicationInstance = true
        config.activates = true
        config.addsToRecentItems = false
        config.promptsUserIfNeeded = false
        config.arguments = ["-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        let launched = try await NSWorkspace.shared.openApplication(at: options.app, configuration: config)
        pid = launched.processIdentifier
        try? Data("\(pid)\n".utf8).write(to: options.out.appendingPathComponent("app.pid"))
        Console.log("launched Basket \(bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") as pid \(pid)")
        let element = RemoteAXElement.application(pid: pid)
        RemoteAXCapture.setMessagingTimeout(3, for: element)
        appElement = element
    }

    private func waitForMainWindow() async throws -> RemoteAXElement {
        guard let appElement else { throw Failure(code: 2, message: "app not launched") }
        var enhanced = false
        let window = await waitFor(30) { () -> RemoteAXElement? in
            guard kill(self.pid, 0) == 0 else { return nil }
            if !enhanced, appElement.role != nil {
                RemoteAXCapture.enableEnhancedUserInterface(appElement)
                enhanced = true
            }
            let windows = appElement.windows
            return windows.first { $0.identifier == AXAuditRules.mainWindowIdentifier }
                ?? windows.first { RemoteAXCapture.find(identifier: AXAuditRules.mainWindowIdentifier, in: $0, maxDepth: 8) != nil }
        }
        guard let window else {
            throw Failure(code: 2, message: kill(pid, 0) == 0
                          ? "the main window (\(AXAuditRules.mainWindowIdentifier)) did not appear within 30 s"
                          : "Basket exited during launch")
        }
        Console.log("main window found")
        return window
    }

    /// Basket ▸ Check for Updates… through the menu bar (AXPress on the menu item).
    private func chooseCheckForUpdates(in window: RemoteAXElement) async throws {
        guard let appElement else { throw Failure(code: 2, message: "app not launched") }
        let item = await waitFor(10) { () -> RemoteAXElement? in
            guard let menuBar = appElement.children.first(where: { $0.role == "AXMenuBar" }) else { return nil }
            return RemoteAXCapture.find(in: menuBar, maxDepth: 4) {
                $0.role == "AXMenuItem" && $0.title == "Check for Updates…"
            }
        }
        guard let item else { throw Failure(code: 2, message: "no “Check for Updates…” item in Basket's menu bar") }
        let pressed = item.perform(kAXPressAction)
        Console.log("pressed Basket ▸ Check for Updates… (AXPress → \(AXErrorLog.name(pressed)))")
        guard pressed == .success else { throw Failure(code: 2, message: "AXPress on “Check for Updates…” failed: \(AXErrorLog.name(pressed))") }
    }

    /// The update sheet with an enabled “Install and Relaunch”.
    private func waitForOffer(in window: RemoteAXElement) async throws -> RemoteAXElement {
        let sheet = await waitFor(30) { () -> RemoteAXElement? in
            guard let sheet = self.sheet(of: window),
                  let install = RemoteAXCapture.find(identifier: "update.install", in: sheet),
                  RemoteAXCapture.text(install.attribute(kAXEnabledAttribute)) == "1" else { return nil }
            return sheet
        }
        guard let sheet else {
            let texts = self.sheet(of: window).map(texts(in:)) ?? ["no sheet"]
            throw Failure(code: 2, message: "the update sheet offered no install within 30 s (it shows: \(texts.joined(separator: " | ")))")
        }
        let version = RemoteAXCapture.find(identifier: "update.version", in: sheet).flatMap(label(of:)) ?? "?"
        Console.log("update sheet: “\(version)”")
        return sheet
    }

    /// Presses “Install and Relaunch” and waits for A to quit. Returns the seconds from the press
    /// and from the moment installing started (“Installing…” shown, or the sheet gone).
    private func installAndWaitForQuit(window: RemoteAXElement, sheet: RemoteAXElement) async throws -> (Double, Double) {
        guard let install = RemoteAXCapture.find(identifier: "update.install", in: sheet) else {
            throw Failure(code: 2, message: "update.install disappeared")
        }
        let pressed = install.perform(kAXPressAction)
        Console.log("pressed update.install (AXPress → \(AXErrorLog.name(pressed)))")
        guard pressed == .success else { throw Failure(code: 2, message: "AXPress on update.install failed: \(AXErrorLog.name(pressed))") }
        let start = Date()
        var installingSince: Date?
        var killed = false
        var lastStatus = ""
        while true {
            if kill(pid, 0) != 0 {
                let now = Date()
                let fromInstalling = now.timeIntervalSince(installingSince ?? start)
                Console.log(String(format: "Basket (pid %d) quit %.1f s after the press, %.1f s after installing started", pid,
                                   now.timeIntervalSince(start), fromInstalling))
                return (now.timeIntervalSince(start), fromInstalling)
            }
            let current = self.sheet(of: window)
            let status: String
            if let current {
                status = RemoteAXCapture.find(identifier: "update.progress", in: current, maxDepth: 12).flatMap(label(of:)) ?? "sheet"
            } else {
                status = "no sheet"
            }
            if status != lastStatus {
                Console.log(String(format: "  +%.1f s: %@", Date().timeIntervalSince(start), status))
                lastStatus = status
            }
            if installingSince == nil, status.hasPrefix("Installing") || current == nil {
                installingSince = Date()
            }
            if let kill = options.kill, !killed, let installingSince, Date().timeIntervalSince(installingSince) >= 1 {
                killed = true
                try end(with: kill)
            }
            if let installingSince, Date().timeIntervalSince(installingSince) > options.quitTimeout {
                let shown = current.map(texts(in:)) ?? ["no sheet"]
                throw Failure(code: 1, message: String(
                    format: "Basket (pid %d) was still running %.0f s after installing started; the update sheet shows: %@",
                    pid, options.quitTimeout, shown.joined(separator: " | ")))
            }
            if Date().timeIntervalSince(start) > 60 || Date() > runDeadline {
                let shown = current.map(texts(in:)) ?? ["no sheet"]
                throw Failure(code: 1, message: "Basket (pid \(pid)) never started installing within 60 s; the update sheet shows: \(shown.joined(separator: " | "))")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// `--kill`: ends Basket while the swap helper waits for it to exit.
    private func end(with kill: UpdateInstallCommand.Kill) throws {
        switch kill {
        case .sigkill:
            let status = Darwin.kill(pid, SIGKILL)
            Console.log("sent SIGKILL to Basket (pid \(pid)) → \(status == 0 ? "ok" : String(cString: strerror(errno)))")
        case .forceQuit:
            if let error = ForceQuit.application(pid: pid) {
                throw Failure(code: 2, message: "Force Quit of pid \(pid) failed: \(error)")
            }
            Console.log("force-quit Basket (pid \(pid)) through LaunchServices")
        }
    }

    /// The swap helper replaces the bundle and opens it: wait for that version to run from `--app`.
    private func waitForRelaunch() async throws -> NSRunningApplication {
        let path = options.app.resolvingSymlinksInPath().path
        let relaunched = await waitFor(60) { () -> NSRunningApplication? in
            NSWorkspace.shared.runningApplications.first {
                $0.processIdentifier != self.pid && $0.bundleURL?.resolvingSymlinksInPath().path == path
            }
        }
        let installed = installedVersion()
        guard let relaunched else {
            throw Failure(code: 1, message: "Basket quit, but nothing ran from \(options.app.path) within 60 s (its version is now \(installed ?? "unreadable"); see ~/Library/Logs/Basket/update.log)")
        }
        Console.log("pid \(relaunched.processIdentifier) runs from \(options.app.path), version \(installed ?? "?")")
        guard installed == options.expectVersion else {
            await quit(relaunched)
            throw Failure(code: 1, message: "the app at \(options.app.path) is version \(installed ?? "unreadable"), not \(options.expectVersion)")
        }
        return relaunched
    }

    private func quit(_ app: NSRunningApplication) async {
        Console.log("quitting pid \(app.processIdentifier)")
        app.terminate()
        if await waitFor(10, { app.isTerminated ? true : nil }) == nil {
            Console.log("pid \(app.processIdentifier) did not quit in 10 s — force terminating")
            app.forceTerminate()
            _ = await waitFor(5) { app.isTerminated ? true : nil }
        }
    }

    // MARK: Helpers

    /// Read from disk each time (Bundle caches its Info.plist).
    private func installedVersion() -> String? {
        let plist = options.app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    private func sheet(of window: RemoteAXElement) -> RemoteAXElement? {
        window.children.first { $0.role == "AXSheet" }
    }

    private func label(of element: RemoteAXElement) -> String? {
        element.title ?? element.string(kAXDescriptionAttribute) ?? element.string(kAXValueAttribute)
    }

    private func texts(in element: RemoteAXElement) -> [String] {
        RemoteAXCapture.snapshot(of: element).allNodes.compactMap { node in
            guard node.role == "AXStaticText" || node.role == "AXButton" else { return nil }
            let text = node.value ?? node.title ?? node.label
            return node.role == "AXButton" ? text.map { "[\($0)]" } : text
        }
    }

    private func waitFor<T>(_ seconds: Double, interval: Double = 0.2, _ probe: () -> T?) async -> T? {
        let deadline = min(Date().addingTimeInterval(seconds), runDeadline)
        while true {
            if let value = probe() { return value }
            if Date() >= deadline { return nil }
            try? await Task.sleep(for: .seconds(interval))
        }
    }
}

/// The Force Quit a user does with ⌥⌘⎋, the Dock or Activity Monitor: each calls LaunchServices'
/// `_LSForceQuitApplication`, which ends every process of the app's coalition, not only the app —
/// what stopped the swap helper of Basket 0.0.1–0.0.4 (#41). A private function, looked up at run
/// time; only this test runner uses it, always with the pid it launched itself.
enum ForceQuit {
    private typealias CreateASN = @convention(c) (CFAllocator?, Int32) -> Unmanaged<CFTypeRef>?
    private typealias Completion = @convention(block) (UInt8, CFError?) -> Void
    private typealias Quit = @convention(c) (Int32, CFTypeRef, CFDictionary?, Completion?) -> UInt8

    /// nil on success, else why it failed.
    static func application(pid: pid_t) -> String? {
        guard dlopen("/usr/lib/libLaunchServicesSupport.dylib", RTLD_NOW) != nil,
              let createSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_LSASNCreateWithPid"),
              let quitSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_LSForceQuitApplication")
        else { return "LaunchServices' force quit isn't available" }
        let createASN = unsafeBitCast(createSymbol, to: CreateASN.self)
        let quit = unsafeBitCast(quitSymbol, to: Quit.self)
        guard let asn = createASN(kCFAllocatorDefault, pid)?.takeRetainedValue() else {
            return "pid \(pid) is not a running application"
        }
        // -2: the current session (kLSDefaultSessionID). The completion only reports.
        return quit(-2, asn, nil, { _, _ in }) != 0 ? nil : "_LSForceQuitApplication refused"
    }
}
