import AppKit
import BasketCore

extension SelfTestRunner {
    /// Extras for "Migrate from OrbStack": the containers tab, the recreate preview, and an import
    /// run to completion (fixture backends simulate it) with the section afterwards.
    func captureMigrationExtras(_ window: NSWindow) async {
        let model = store.migration
        store.selectedSection = .migration
        await model.refresh()
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
        await capture(window, as: "migration-imported")
    }
}
