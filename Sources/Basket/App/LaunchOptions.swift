import Foundation
import BasketCore

enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case overview, containers, images, volumes, networks, machines, migration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .containers: String(localized: "Containers")
        case .images: String(localized: "Images")
        case .volumes: String(localized: "Volumes")
        case .networks: String(localized: "Networks")
        case .machines: String(localized: "Machines")
        case .migration: String(localized: "Migrate from OrbStack")
        }
    }

    /// Placeholder (and accessible name) of the toolbar search field.
    var searchPrompt: String {
        switch self {
        case .overview: String(localized: "Search")
        case .containers: String(localized: "Search Containers")
        case .images: String(localized: "Search Images")
        case .volumes: String(localized: "Search Volumes")
        case .networks: String(localized: "Search Networks")
        case .machines: String(localized: "Search Machines")
        case .migration: String(localized: "Search OrbStack")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .volumes: "externaldrive"
        case .networks: "network"
        case .machines: "desktopcomputer"
        case .migration: "square.and.arrow.down.on.square"
        }
    }
}

/// Process-level switches (see docs/ARCHITECTURE.md, "Runtime switches").
struct LaunchOptions: Sendable {
    enum BackendKind: Sendable, Equatable {
        case cli
        case fixtures(URL)
        /// In-memory demo data (`BASKET_BACKEND=preview`), also used by SwiftUI previews.
        case preview
    }

    var backend: BackendKind
    var explicitCLIPath: String?
    var isUITest: Bool
    var initialSection: AppSection?
    var selfTestDirectory: URL?

    static func fromProcess(_ env: [String: String] = ProcessInfo.processInfo.environment) -> LaunchOptions {
        let backend: BackendKind
        switch env["BASKET_BACKEND"]?.lowercased() {
        case "fixtures":
            let dir = env["BASKET_FIXTURES_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Fixtures/demo")
            backend = .fixtures(dir)
        case "preview":
            backend = .preview
        default:
            backend = .cli
        }
        let selfTest = env["BASKET_SELFTEST_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        return LaunchOptions(
            backend: backend,
            explicitCLIPath: env["BASKET_CONTAINER_CLI"].flatMap { $0.isEmpty ? nil : $0 },
            isUITest: env["BASKET_UI_TEST"] == "1" || selfTest != nil,
            initialSection: env["BASKET_INITIAL_SECTION"].flatMap { AppSection(rawValue: $0.lowercased()) },
            selfTestDirectory: selfTest
        )
    }

    var fixturesDirectory: URL? {
        if case .fixtures(let url) = backend { return url }
        return nil
    }

    /// Builds the backend. `settingsCLIPath` is the user's choice from Settings (`containerCLIPath`).
    func makeBackend(settingsCLIPath: String?) -> any ContainerBackend {
        switch backend {
        case .fixtures(let dir):
            return FixtureBackend(directory: dir)
        case .preview:
            return PreviewBackend()
        case .cli:
            let trimmed = settingsCLIPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CLIBackend(cliPath: explicitCLIPath ?? (trimmed?.isEmpty == false ? trimmed : nil))
        }
    }
}

enum DefaultsKey {
    static let containerCLIPath = "containerCLIPath"
    static let refreshInterval = "refreshInterval"
    static let defaultCPUs = "defaultCPUs"
    static let defaultMemoryMB = "defaultMemoryMB"
}
