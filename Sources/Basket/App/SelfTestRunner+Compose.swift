import AppKit
import BasketCore

extension SelfTestRunner {
    /// Extras for compose: a selected project (overview and merged logs) and the plan sheet for
    /// `<fixtures>/compose/<project>/compose.yaml` when the fixture set has one.
    func captureComposeExtras(_ window: NSWindow) async {
        store.selectedSection = .containers
        if let project = store.composeProjects.first {
            store.containerSelection = []
            store.selectedComposeProject = project.name
            for tab in ComposeDetailTab.allCases {
                store.composeDetailTab = tab
                try? await Task.sleep(for: .milliseconds(900))
                await capture(window, as: "containers-project-\(tab.rawValue.lowercased())")
            }
            store.composeDetailTab = .overview
            store.selectedComposeProject = nil
        }
        guard let fixtures = store.options.fixturesDirectory,
              let file = (try? FileManager.default.contentsOfDirectory(
                  at: fixtures.appendingPathComponent("compose"), includingPropertiesForKeys: nil))?
                  .sorted(by: { $0.path < $1.path })
                  .map({ $0.appendingPathComponent("compose.yaml") })
                  .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else { return }
        store.activeSheet = .composePlan(file)
        try? await Task.sleep(for: .milliseconds(900))
        if let sheet = window.attachedSheet { await capture(sheet, as: "sheet-compose-plan") }
        store.activeSheet = nil
        try? await Task.sleep(for: .milliseconds(500))
    }
}
