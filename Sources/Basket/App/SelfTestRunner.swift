import AppKit
import BasketAXKit

/// `BASKET_SELFTEST_DIR`: visits every section, writes `<section>.png` (the window including its
/// toolbar; see `WindowSnapshot`) and `<section>.ax.json` (the window's accessibility tree), plus
/// `settings-end` and `settings-language` (see SelfTestRunner+Settings), then every section in
/// light and dark (`<section>-light.png`, `<section>-dark.png`; SelfTestRunner+Appearance), then
/// quits with status 0.
@MainActor
struct SelfTestRunner {
    let store: AppStore
    let directory: URL

    func run() async {
        // Make SwiftUI build its full accessibility tree (toolbar items, row content) up front.
        InProcessAXCapture.prepare()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log("cannot create \(directory.path): \(error)")
            exit(1)
        }
        await waitForInitialData()
        for section in AppSection.allCases {
            store.selectedSection = section
            try? await Task.sleep(for: .milliseconds(300))
            if section == .containers, let first = store.containerRows.first {
                store.containerSelection = [first.id]
            }
            if section == .migration { await refreshMigrationAndWait() }
            // Let SwiftUI lay out the section (and the detail pane) before capturing.
            try? await Task.sleep(for: .milliseconds(600))
            guard let window = store.mainWindow else {
                log("no main window")
                exit(1)
            }
            window.layoutIfNeeded()
            window.displayIfNeeded()
            writePNG(of: window, to: directory.appending(path: "\(section.rawValue).png"))
            await writeAX(of: window, to: directory.appending(path: "\(section.rawValue).ax.json"))
            log("captured \(section.rawValue) (window \(Int(window.frame.width))×\(Int(window.frame.height)))")
            if section == .settings { await captureSettingsStates(window) }
        }
        if let window = store.mainWindow { await captureAppearances(window) }
        if ProcessInfo.processInfo.environment["BASKET_SELFTEST_EXTRAS"] == "1" {
            await captureExtras()
        }
        log("done → \(directory.path)")
        NSApp.terminate(nil)
    }

    /// Opt-in (`BASKET_SELFTEST_EXTRAS=1`): container detail tabs and every sheet, for visual
    /// review. Sheets are separate windows, captured as `sheet-<id>`.
    private func captureExtras() async {
        guard let window = store.mainWindow else { return }
        store.selectedSection = .containers
        // Prefer a container with stranded memory so the Info capture shows the breakdown.
        let stranded = store.memoryInsights.stranded.first?.id
        if let running = store.containerRows.first(where: { $0.id == stranded })
            ?? store.containerRows.first(where: { $0.summary.state == .running }) ?? store.containerRows.first {
            store.containerSelection = [running.id]
        }
        for tab in ContainerDetailTab.allCases {
            store.containerDetailTab = tab
            try? await Task.sleep(for: .milliseconds(tab == .stats ? 1500 : 900))
            await capture(window, as: "containers-\(tab.rawValue.lowercased())")
        }
        await captureInspectExtras(window)
        store.containerDetailTab = .info
        let sheets: [ActiveSheet] = [
            .newContainer(.defaults(image: "docker.io/library/nginx:latest")), .pullImage(""), .newVolume,
            .newNetwork, .newMachine, .reclaim, .reclaimMemory,
        ]
        for sheet in sheets {
            store.activeSheet = sheet
            try? await Task.sleep(for: .milliseconds(900))
            if let sheetWindow = window.attachedSheet {
                await capture(sheetWindow, as: "sheet-\(sheet.id)")
            } else {
                log("sheet \(sheet.id) did not appear")
            }
            store.activeSheet = nil
            try? await Task.sleep(for: .milliseconds(500))
        }
        await captureMigrationExtras(window)
        await captureImageExtras(window)
        await captureComposeExtras(window)
        await captureUpdateExtras(window)
    }

    func capture(_ window: NSWindow, as name: String) async {
        window.displayIfNeeded()
        writePNG(of: window, to: directory.appending(path: "\(name).png"))
        await writeAX(of: window, to: directory.appending(path: "\(name).ax.json"))
        log("captured \(name)")
    }

    /// Waits until every list has loaded once and CPU numbers exist (reported by the CLI, or from a
    /// second sample).
    private func waitForInitialData() async {
        let needed: Set<DataKind> = [.system, .containers, .stats, .images, .volumes, .networks, .machines, .disk]
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let loaded = needed.isSubset(of: store.loaded)
            // Two samples: CPU% and idle detection (network traffic is a delta between samples).
            let cpuReady = store.runningContainers.isEmpty || store.availability != .running
                || store.statsSamples >= 2
            if loaded && cpuReady && store.mainWindow != nil { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        log("timed out waiting for data; capturing anyway (loaded: \(store.loaded.map(\.rawValue).sorted()))")
    }

    func writePNG(of window: NSWindow, to url: URL) {
        guard let data = WindowSnapshot.png(of: window) else {
            log("cannot render \(url.lastPathComponent)")
            return
        }
        do { try data.write(to: url) } catch { log("write \(url.lastPathComponent): \(error)") }
    }

    private func writeAX(of window: NSWindow, to url: URL) async {
        let node = await InProcessAXCapture.settledSnapshot(of: window)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(node).write(to: url)
        } catch {
            log("write \(url.lastPathComponent): \(error)")
        }
    }

    func log(_ message: String) {
        FileHandle.standardError.write(Data("basket selftest: \(message)\n".utf8))
    }
}
