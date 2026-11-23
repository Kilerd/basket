import Foundation

/// Finds OrbStack.app: `/Applications` or `~/Applications`, else wherever LaunchServices has its
/// bundle id registered (a custom folder, another volume). Copies in a Trash or on a read-only
/// volume (a mounted disk image) don't count as installed. Cheap enough for the main thread: a few
/// `stat`s and, only past the standard folders, one LaunchServices query.
public struct OrbStackLocator: Sendable {
    /// OrbStack's bundle identifier (from its working name, MacVirt).
    public static let bundleIdentifier = "dev.kdrag0n.MacVirt"

    public static var standardPaths: [String] {
        ["/Applications/OrbStack.app", NSHomeDirectory() + "/Applications/OrbStack.app"]
    }

    /// Copies of an app LaunchServices knows for a bundle id. The app passes
    /// `NSWorkspace.urlsForApplications(withBundleIdentifier:)`; BasketCore doesn't link AppKit
    /// (the `docker` shim links it too), so the default finds none.
    public var registeredApplications: @Sendable (String) -> [URL]

    public init(registeredApplications: @escaping @Sendable (String) -> [URL] = { _ in [] }) {
        self.registeredApplications = registeredApplications
    }

    /// The standard folders only.
    public static let standardFolders = OrbStackLocator()

    /// OrbStack.app's path, or nil when it isn't installed.
    public func appPath() -> String? {
        Self.appPath(
            standard: Self.standardPaths, registered: { registeredApplications(Self.bundleIdentifier) },
            exists: { FileManager.default.fileExists(atPath: $0) }, isOnReadOnlyVolume: Self.isOnReadOnlyVolume)
    }

    static func appPath(
        standard: [String], registered: () -> [URL], exists: (String) -> Bool, isOnReadOnlyVolume: (URL) -> Bool
    ) -> String? {
        if let path = standard.first(where: exists) { return path }
        return registered().lazy.map(\.standardizedFileURL).first { url in
            let components = url.pathComponents
            return !components.contains(".Trash") && !components.contains(".Trashes")
                && exists(url.path) && !isOnReadOnlyVolume(url)
        }?.path
    }

    static func isOnReadOnlyVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
    }
}
