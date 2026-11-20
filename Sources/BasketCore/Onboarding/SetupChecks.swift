import Darwin
import Foundation

// Host checks behind "Set Up Basket" (the onboarding flow). Pure and injectable so they can be
// tested without depending on the Mac running the tests.

/// What Basket needs from the Mac: macOS 26 or later on Apple silicon (apple/container's own
/// requirements).
public struct SetupRequirements: Sendable, Equatable {
    public static let minimumMacOSMajor = 26

    public var macOSVersion: String
    public var macOSMajor: Int
    public var isAppleSilicon: Bool

    public init(macOSMajor: Int, macOSVersion: String, isAppleSilicon: Bool) {
        self.macOSMajor = macOSMajor
        self.macOSVersion = macOSVersion
        self.isAppleSilicon = isAppleSilicon
    }

    public var meetsMacOS: Bool { macOSMajor >= Self.minimumMacOSMajor }
    public var isSatisfied: Bool { meetsMacOS && isAppleSilicon }

    /// This Mac. `hw.optional.arm64` is 1 on Apple silicon even for a process running under Rosetta.
    public static func current() -> SetupRequirements {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let text = version.patchVersion > 0
            ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let found = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0
        return SetupRequirements(macOSMajor: version.majorVersion, macOSVersion: text, isAppleSilicon: found && arm64 == 1)
    }
}

/// Finds Homebrew for "Install with Homebrew" (`brew install container`).
public enum HomebrewLocator {
    /// Apple silicon prefix first, then the Intel one (still used by migrated setups).
    public static let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    public static let installArguments = ["install", "container"]

    public static func locate(isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> URL? {
        candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    /// The child environment for `brew`: no colour codes, hints or auto-update prompts in the log
    /// Basket shows, and no interactive questions (there is no terminal to answer them).
    public static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        environment["HOMEBREW_NO_COLOR"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_EMOJI"] = "1"
        environment["NONINTERACTIVE"] = "1"
        return environment
    }
}

/// The installed `container` CLI: where it is and which version.
public struct ContainerCLIInfo: Sendable, Equatable {
    public var path: String
    /// "1.7.1"; nil when `container --version` didn't answer.
    public var version: String?

    public init(path: String, version: String?) {
        self.path = path
        self.version = version
    }
}

public enum ContainerCLIProbe {
    /// Locates the CLI the same way `CLIBackend` does and asks it for its version (works without the
    /// apiserver). nil when it isn't installed.
    public static func detect(
        explicitPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaultsPath: String? = UserDefaults.standard.string(forKey: "containerCLIPath")
    ) async -> ContainerCLIInfo? {
        guard let url = try? CLIRunner.locateContainerCLI(
            explicitPath: explicitPath, environment: environment, userDefaultsPath: userDefaultsPath)
        else { return nil }
        return ContainerCLIInfo(path: url.path, version: await version(of: url))
    }

    public static func version(of executable: URL) async -> String? {
        let runner = CLIRunner(executableURL: executable)
        guard let result = try? await runner.run(["--version"], timeout: .seconds(5)), result.exitCode == 0 else {
            return nil
        }
        return CLIBackend.parseVersion(result.stdoutText)
    }
}

/// When the onboarding window opens on its own.
public enum OnboardingPolicy {
    /// Bump when the flow gains a step every existing user should see once.
    public static let currentVersion = 1

    /// First launch (completed version below the current one) or the CLI is missing. UI-test and
    /// self-test runs never show it unless `forced` (`BASKET_ONBOARDING=1`).
    public static func shouldShowAtLaunch(completedVersion: Int, cliInstalled: Bool, isUITest: Bool, forced: Bool) -> Bool {
        if forced { return true }
        if isUITest { return false }
        return completedVersion < currentVersion || !cliInstalled
    }
}
