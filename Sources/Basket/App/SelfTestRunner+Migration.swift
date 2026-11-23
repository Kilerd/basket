import AppKit
import BasketCore

extension SelfTestRunner {
    /// Reads OrbStack again and waits until every image Basket lists under the same name has been
    /// compared, so a capture shows final states rather than a comparison in progress (#17).
    func refreshMigrationAndWait() async {
        let model = store.migration
        await model.refresh()
        let deadline = Date().addingTimeInterval(10)
        // The comparison runs in the section's `.task`, which restarts after the refresh.
        try? await Task.sleep(for: .milliseconds(100))
        while model.isLoading || model.hasPendingComparisons, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if model.hasPendingComparisons { log("migration: comparisons still running after 10 s; capturing anyway") }
    }

    /// Extras for "Migrate from OrbStack": the containers tab, the recreate preview, and an import
    /// run to completion (fixture backends simulate it) with the section afterwards.
    func captureMigrationExtras(_ window: NSWindow) async {
        let model = store.migration
        guard store.isVisible(.migration) else { return }
        store.selectedSection = .migration
        await refreshMigrationAndWait()
        guard model.status?.isReady == true else { return }

        model.tab = .containers
        let preferred = model.containerRows.first { $0.container.isRunning && !$0.container.ports.isEmpty } ?? model.containerRows.first
        model.containerSelection = preferred?.id
        try? await Task.sleep(for: .milliseconds(900))
        await capture(window, as: "migration-containers")

        if let preferred {
            model.sheet = .recreate(preferred.id)
            try? await Task.sleep(for: .milliseconds(900))
            if let sheet = window.attachedSheet { await capture(sheet, as: "sheet-migration-recreate") }
            model.sheet = nil
            try? await Task.sleep(for: .milliseconds(500))
        }

        model.tab = .images
        let wanted = ["busybox:latest", "traefik/whoami:latest", "demo-app:amd64"]
        let importable = model.imageRows.filter { model.isImportable($0.image) }
        let picks = importable.filter { wanted.contains($0.image.reference ?? "") }
        model.checked = Set((picks.isEmpty ? Array(importable.prefix(2)) : picks).map(\.id))
        model.startImport()
        let deadline = Date().addingTimeInterval(15)
        while model.isImporting, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(500))
        if let sheet = window.attachedSheet { await capture(sheet, as: "sheet-migration-import") }
        model.sheet = nil
        try? await Task.sleep(for: .milliseconds(700))
        let deadline2 = Date().addingTimeInterval(10)
        while model.hasPendingComparisons, Date() < deadline2 { try? await Task.sleep(for: .milliseconds(100)) }
        await capture(window, as: "migration-imported")
    }
}
