import Foundation

/// Reads what the CLI's JSON leaves out from a container's bundle under the app root
/// (`<appRoot>/containers/<id>/`). Read-only; same-user files, no privileges needed.
enum ContainerBundleOptions {
    /// apple/container's default app root (`container system status` reports the real one).
    static var defaultAppRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.container", directoryHint: .isDirectory)
    }

    /// `options.json` → `{"autoRemove": true}` for containers started with `--rm` (verified on 1.7.1:
    /// stopping such a container deletes it). nil when the file is missing or unreadable.
    static func removeOnStop(containerID: String, appRoot: URL) -> Bool? {
        struct Options: Decodable { var autoRemove: Bool? }
        let url = appRoot.appending(path: "containers", directoryHint: .isDirectory)
            .appending(path: containerID, directoryHint: .isDirectory)
            .appending(path: "options.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(Options.self, from: data))?.autoRemove
    }
}
