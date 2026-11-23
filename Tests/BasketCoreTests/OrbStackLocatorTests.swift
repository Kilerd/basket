import Foundation
import Synchronization
import Testing
@testable import BasketCore

/// Where Basket looks for OrbStack.app (#47): the standard folders, then LaunchServices by bundle
/// id, never a copy in the Trash or on a read-only volume.
@Suite("OrbStackLocator")
struct OrbStackLocatorTests {
    let standard = ["/Applications/OrbStack.app", "/Users/demo/Applications/OrbStack.app"]

    func locate(existing: Set<String>, registered: [String] = [], readOnly: Set<String> = []) -> String? {
        OrbStackLocator.appPath(
            standard: standard, registered: { registered.map { URL(fileURLWithPath: $0) } },
            exists: existing.contains, isOnReadOnlyVolume: { readOnly.contains($0.path) })
    }

    @Test func standardFoldersComeFirst() {
        #expect(locate(existing: ["/Applications/OrbStack.app", "/Users/demo/Tools/OrbStack.app"],
                       registered: ["/Users/demo/Tools/OrbStack.app"]) == "/Applications/OrbStack.app")
        #expect(locate(existing: ["/Users/demo/Applications/OrbStack.app"]) == "/Users/demo/Applications/OrbStack.app")
    }

    @Test func launchServicesFindsOtherFolders() {
        #expect(locate(existing: ["/Users/demo/Tools/OrbStack.app"], registered: ["/Users/demo/Tools/OrbStack.app"])
            == "/Users/demo/Tools/OrbStack.app")
        #expect(locate(existing: ["/Volumes/Work/Apps/OrbStack.app"], registered: ["/Volumes/Work/Apps/../Apps/OrbStack.app"])
            == "/Volumes/Work/Apps/OrbStack.app")
    }

    @Test func trashDiskImagesAndStaleEntriesDontCount() {
        let trash = "/Users/demo/.Trash/OrbStack.app"
        let volumeTrash = "/Volumes/Work/.Trashes/501/OrbStack.app"
        let diskImage = "/Volumes/OrbStack/OrbStack.app"
        let gone = "/Users/demo/Old/OrbStack.app"
        #expect(locate(existing: [trash, volumeTrash, diskImage], registered: [trash, volumeTrash, diskImage, gone],
                       readOnly: [diskImage]) == nil)
        let kept = "/Users/demo/Tools/OrbStack.app"
        #expect(locate(existing: [trash, kept], registered: [trash, gone, kept]) == kept)
    }

    @Test func nothingInstalled() {
        #expect(locate(existing: []) == nil)
    }

    @Test func asksLaunchServicesForOrbStacksBundleID() {
        let asked = Mutex<[String]>([])
        let locator = OrbStackLocator { id in
            asked.withLock { $0.append(id) }
            return []
        }
        _ = locator.appPath()
        // Only consulted when neither standard folder has OrbStack.
        let standardExists = OrbStackLocator.standardPaths.contains { FileManager.default.fileExists(atPath: $0) }
        #expect(asked.withLock { $0 } == (standardExists ? [] : [OrbStackLocator.bundleIdentifier]))
        #expect(OrbStackLocator.bundleIdentifier == "dev.kdrag0n.MacVirt")
    }
}
