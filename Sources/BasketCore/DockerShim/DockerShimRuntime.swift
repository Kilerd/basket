import Foundation

/// Host-side helpers for the `basket-docker` executable (everything that isn't pure translation).
public enum DockerShimRuntime {
    /// The app's defaults domain: the shim honours the `container` path chosen in Basket's settings.
    static let appDefaultsDomain = "dev.basket.app"

    /// Finds the `container` CLI the same way the app does (`BASKET_CONTAINER_CLI` → Basket's setting →
    /// Homebrew → /usr/local → PATH).
    public static func locateContainerCLI(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let settingsPath = UserDefaults(suiteName: appDefaultsDomain)?.string(forKey: "containerCLIPath")
        return try CLIRunner.locateContainerCLI(environment: environment, userDefaultsPath: settingsPath)
    }

    /// The `docker compose` hook: `BASKET_COMPOSE_CLI`, else an executable `basket-compose` next to the
    /// shim's real location (the app's Helpers directory). nil = compose stays unsupported.
    public static func composeExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment, shimPath: String
    ) -> String? {
        if let explicit = environment["BASKET_COMPOSE_CLI"], !explicit.isEmpty,
           FileManager.default.isExecutableFile(atPath: explicit) {
            return explicit
        }
        let sibling = URL(fileURLWithPath: shimPath).resolvingSymlinksInPath()
            .deletingLastPathComponent().appending(path: "basket-compose").path
        return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : nil
    }

    /// Shell-ready command line for dry runs and messages.
    public static func render(_ containerArgs: [String], executable: String = "container") -> String {
        ([executable] + containerArgs).map(shellQuoteIfNeeded).joined(separator: " ")
    }

    /// Containers a translated `docker restart` would destroy: apple/container deletes `--rm` containers
    /// when they stop, so their "restart" would be a delete. Unknown = not listed (the stop then fails or
    /// succeeds exactly like `container stop` would).
    public static func containersDeletedByRestart(
        _ translation: DockerTranslation, appRoot: URL? = nil
    ) -> [String] {
        let appRoot = appRoot ?? ContainerBundleOptions.defaultAppRoot
        let commands = translation.containerCommands.map { $0.first == "--debug" ? Array($0.dropFirst()) : $0 }
        guard commands.contains(where: { $0.first == "stop" }) else { return [] }
        let restarted = commands.filter { $0.first == "start" }.compactMap(\.last)
        return restarted.filter { ContainerBundleOptions.removeOnStop(containerID: $0, appRoot: appRoot) == true }
    }
}
