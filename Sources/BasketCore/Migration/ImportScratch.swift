import Darwin
import Foundation

// Export archives live in `$TMPDIR/basket-orbstack-import-*` while an import runs. Each directory
// records the pid of the Basket that made it, so one left behind by a crash or a forced quit can be
// told apart from one another running Basket (a self-test, say) is still writing.

extension OrbStackMigrator {
    static let importDirectoryPrefix = "basket-orbstack-import-"
    /// Hidden file holding the owning process id.
    static let importOwnerFile = ".basket-owner"
    /// Directories without an owner file (older builds) are removed once this old.
    static let unownedImportDirectoryAge: TimeInterval = 3600

    static func makeImportDirectory(in parent: URL) throws -> URL {
        let directory = parent.appendingPathComponent("\(importDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("\(getpid())".utf8).write(to: directory.appendingPathComponent(importOwnerFile))
        return directory
    }

    /// Removes import directories whose Basket is gone (and, with `includingOwn`, this process's own:
    /// for quitting after the imports were cancelled). Returns what was removed.
    @discardableResult
    public static func sweepImportDirectories(
        in parent: URL = FileManager.default.temporaryDirectory, includingOwn: Bool = false,
        isAlive: (pid_t) -> Bool = OrbStackMigrator.processIsAlive, now: Date = Date()
    ) -> [URL] {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? []
        var removed: [URL] = []
        for entry in entries where entry.lastPathComponent.hasPrefix(importDirectoryPrefix) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let owner = (try? String(contentsOf: entry.appendingPathComponent(importOwnerFile), encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let stale: Bool
            if let owner {
                stale = owner == getpid() ? includingOwn : !isAlive(owner)
            } else {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                stale = modified.map { now.timeIntervalSince($0) > unownedImportDirectoryAge } ?? false
            }
            if stale, (try? fileManager.removeItem(at: entry)) != nil { removed.append(entry) }
        }
        return removed
    }

    public static func processIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
