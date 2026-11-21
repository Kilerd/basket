import AppKit
import BasketCore

/// Quitting while Basket still runs `docker save` / `container image load` children (imports from
/// OrbStack, recreations, "Keep only linux/arm64") would leave them running and their archives
/// behind: ask first, and on "Quit Anyway" cancel them, wait briefly and clean up.
@MainActor
final class BasketAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `AppStore.init` (there is one store per process).
    static weak var store: AppStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = Self.store else { return .terminateNow }
        let work = store.longRunningWork
        guard !work.isEmpty else { return .terminateNow }
        if !store.options.isUITest {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Basket is still working")
            alert.informativeText = work.map { "• \($0)" }.joined(separator: "\n") + "\n\n"
                + String(localized: "Quitting stops this work. Import archives are deleted (OrbStack keeps its images). If keeping one platform was already loading the image back, its archive is kept and offered for restore in Images.")
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Quit Anyway")).hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        Task {
            await store.cancelLongRunningWork()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Anything still running (log follows, stats samples, a cancelled export that didn't stop in
        // time) would outlive the app otherwise.
        CLIRunner.terminateAllChildren()
    }
}

/// A `.tar` left in the image-archive directory: a "Keep only linux/arm64" that was interrupted (or
/// whose load failed) kept it so the image can be restored.
struct RecoveryArchive: Identifiable, Hashable {
    var url: URL
    var sizeBytes: Int64
    var modified: Date?
    /// Reference(s) named in the archive; empty when it can't be read (e.g. cut off mid-write).
    var references: [String]
    var platforms: [String]

    var id: String { url.lastPathComponent }
    var isReadable: Bool { !references.isEmpty }
    var title: String { references.first.map { ImageName($0).display } ?? url.lastPathComponent }
}

extension AppStore {
    /// Work whose child processes would outlive Basket, as one line each (empty = nothing running).
    var longRunningWork: [String] {
        var items: [String] = []
        if migration.isImporting {
            let left = migration.importItems.filter { !$0.state.isFinished }.count
            items.append(String(localized: "Importing \(left) images from OrbStack"))
        }
        if migration.activeRecreations > 0 {
            let count = migration.activeRecreations
            items.append(String(localized: "Recreating \(count) OrbStack containers in Basket"))
        }
        for reference in slimTasks.keys.sorted() {
            items.append(String(localized: "Keeping only \(hostPlatform) of “\(ImageName(reference).display)”"))
        }
        return items
    }

    /// Cancels imports, recreations and slims (terminating their children), waits up to `timeout`
    /// for them to unwind, then removes this process's import scratch directories.
    func cancelLongRunningWork(timeout: Duration = .seconds(5)) async {
        migration.cancelAll()
        slimTasks.values.forEach { $0.cancel() }
        let deadline = ContinuousClock.now + timeout
        while (migration.hasRunningWork || !slimTasks.isEmpty), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        CLIRunner.terminateAllChildren()
        OrbStackMigrator.sweepImportDirectories(includingOwn: true)
    }

    /// At launch: import directories of a Basket that crashed or was force-quit (never one another
    /// running Basket still uses), and recovery archives to offer in Images.
    func cleanUpAfterPreviousRun() {
        if !options.isUITest { OrbStackMigrator.sweepImportDirectories() }
        scanRecoveryArchives()
    }

    /// Re-reads the archive directory; skipped while a slim runs (its archive is in use).
    func scanRecoveryArchives() {
        guard slimTasks.isEmpty else { return }
        let directory = imageArchiveDirectory
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        let found = files.filter { $0.pathExtension == "tar" }.compactMap { url -> RecoveryArchive? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { return nil }
            let inspected = try? ImageArchive.inspect(url)
            return RecoveryArchive(
                url: url, sizeBytes: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate,
                references: inspected?.references ?? [], platforms: inspected?.manifests.map(\.platform) ?? [])
        }
        .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        if found != recoveryArchives { recoveryArchives = found }
    }

    /// `image load` the archive; once Basket lists the image again the archive is deleted.
    func restoreRecoveryArchive(_ archive: RecoveryArchive) async {
        let id = "archive:\(archive.id)"
        pending[id] = String(localized: "Restoring…", comment: "Shown next to an image archive while it is loaded back")
        defer { pending[id] = nil }
        do {
            let loaded = try await backend.loadImage(from: archive.url)
            await refresh([.images, .disk])
            let listed = Set(images.map { ImageUsage.normalized($0.reference) })
            let wanted = (archive.references.isEmpty ? loaded : archive.references).map(ImageUsage.normalized)
            if !wanted.isEmpty, wanted.allSatisfy(listed.contains) {
                try? FileManager.default.removeItem(at: archive.url)
                banner = BannerMessage(
                    title: String(localized: "Restored \(archive.title)"),
                    detail: String(localized: "Loaded from \(archive.url.lastPathComponent); the archive was deleted."))
            } else {
                banner = BannerMessage(
                    title: String(localized: "Loaded \(archive.url.lastPathComponent)"),
                    detail: String(localized: "Basket doesn't list \(wanted.localizedList) yet, so the archive was kept."))
            }
        } catch {
            showError(String(localized: "Couldn't restore \(archive.title)"), error)
        }
        scanRecoveryArchives()
    }

    func confirmDeleteRecoveryArchive(_ archive: RecoveryArchive) {
        confirmation = Confirmation(
            title: String(localized: "Delete the archive of “\(archive.title)”?"),
            message: String(localized: "\(archive.url.lastPathComponent) (\(Format.disk(archive.sizeBytes))) is the copy kept when keeping one platform was interrupted. If the image in Basket is missing or broken, this is the only way to get it back without a pull."),
            confirmLabel: String(localized: "Delete Archive"), cancelIsDefault: true
        ) { [weak self] in
            try? FileManager.default.removeItem(at: archive.url)
            self?.scanRecoveryArchives()
        }
    }
}
