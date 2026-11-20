import Foundation
import Testing
@testable import BasketCore

@Suite("Onboarding")
struct OnboardingTests {
    // MARK: Fixtures/fresh (a Mac without the CLI)

    @Test func freshSetHasNoCLIUntilInstalled() async throws {
        let backend = FixtureBackend(directory: TestFixtures.set("fresh"))
        #expect(await backend.isCLIInstalled == false)
        await #expect(throws: BackendError.cliNotFound(searched: ["/opt/homebrew/bin/container", "/usr/local/bin/container"])) {
            _ = try await backend.systemStatus()
        }
        await #expect(throws: BackendError.cliNotFound(searched: ["/opt/homebrew/bin/container", "/usr/local/bin/container"])) {
            _ = try await backend.listContainers()
        }
        await #expect(throws: BackendError.cliNotFound(searched: ["/opt/homebrew/bin/container", "/usr/local/bin/container"])) {
            try await backend.startSystem()
        }
        await #expect(throws: BackendError.cliNotFound(searched: ["/opt/homebrew/bin/container", "/usr/local/bin/container"])) {
            _ = try await backend.hostMemoryFootprints()
        }
        await #expect(throws: BackendError.cliNotFound(searched: ["/opt/homebrew/bin/container", "/usr/local/bin/container"])) {
            _ = try await collect(backend.pullImage("alpine", platform: nil))
        }

        // "brew install container" → the CLI exists, its system service isn't started yet.
        await backend.simulateCLIInstall()
        #expect(await backend.isCLIInstalled)
        let status = try await backend.systemStatus()
        #expect(!status.isRunning && status.cliVersion == "1.7.1")
        await #expect(throws: BackendError.systemNotRunning) { _ = try await backend.listContainers() }

        try await backend.startSystem()
        #expect(try await backend.systemStatus().isRunning)
        #expect(try await backend.listContainers().isEmpty)
        #expect(try await backend.listImages().isEmpty)
        #expect(try await backend.listNetworks().map(\.name) == ["default"])
        #expect(try await backend.diskUsage().totalBytes == 0)
    }

    @Test func otherSetsHaveTheCLI() async {
        for set in ["demo", "empty", "stopped"] {
            #expect(await FixtureBackend(directory: TestFixtures.set(set)).isCLIInstalled, "\(set)")
        }
    }

    @Test func freshSetHasOrbStackRunning() async {
        let snapshot = await OrbStackInspector(fixturesDirectory: TestFixtures.set("fresh")).snapshot()
        #expect(snapshot.isInstalled && snapshot.isRunning)
        #expect(snapshot.memoryFootprintBytes > 1 << 30 && (snapshot.dataAllocatedBytes ?? 0) > 10 << 30)
        #expect(snapshot.dataPath?.hasPrefix("/Users/demo/") == true)
    }

    // MARK: Requirements

    @Test func requirements() {
        #expect(SetupRequirements(macOSMajor: 26, macOSVersion: "26.0", isAppleSilicon: true).isSatisfied)
        let oldMac = SetupRequirements(macOSMajor: 15, macOSVersion: "15.6", isAppleSilicon: true)
        #expect(!oldMac.meetsMacOS && !oldMac.isSatisfied)
        let intel = SetupRequirements(macOSMajor: 26, macOSVersion: "26.1", isAppleSilicon: false)
        #expect(intel.meetsMacOS && !intel.isSatisfied)
    }

    @Test func thisMacMeetsTheRequirements() {
        let current = SetupRequirements.current()
        // The package itself requires macOS 26.
        #expect(current.meetsMacOS && current.macOSVersion.hasPrefix("\(current.macOSMajor)."))
        #if arch(arm64)
        #expect(current.isAppleSilicon)
        #endif
    }

    // MARK: Homebrew

    @Test func homebrewPrefersAppleSiliconPrefix() {
        #expect(HomebrewLocator.locate { _ in true }?.path == "/opt/homebrew/bin/brew")
        #expect(HomebrewLocator.locate { $0 == "/usr/local/bin/brew" }?.path == "/usr/local/bin/brew")
        #expect(HomebrewLocator.locate { _ in false } == nil)
        #expect(HomebrewLocator.installArguments == ["install", "container"])
    }

    @Test func homebrewRunsQuietlyAndNonInteractively() {
        let environment = HomebrewLocator.environment(base: ["HOME": "/Users/demo", "PATH": "/usr/bin"])
        #expect(environment["HOME"] == "/Users/demo" && environment["PATH"] == "/usr/bin")
        #expect(environment["NONINTERACTIVE"] == "1" && environment["HOMEBREW_NO_COLOR"] == "1")
        #expect(environment["HOMEBREW_NO_ENV_HINTS"] == "1")
    }

    // MARK: CLI detection

    @Test func detectsCLIAndVersion() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let path = try directory.script(
            "container", "echo 'container CLI version 1.7.1 (build: release, commit: 0123456)'")
        let info = await ContainerCLIProbe.detect(explicitPath: path, environment: [:], userDefaultsPath: nil)
        #expect(info == ContainerCLIInfo(path: path, version: "1.7.1"))

        let silent = try directory.script("silent", "exit 3")
        #expect(await ContainerCLIProbe.detect(explicitPath: silent, environment: [:], userDefaultsPath: nil)
            == ContainerCLIInfo(path: silent, version: nil))
        #expect(await ContainerCLIProbe.detect(
            explicitPath: directory.url.appendingPathComponent("missing").path, environment: [:], userDefaultsPath: nil) == nil)
    }

    // MARK: When onboarding opens

    @Test func policy() {
        let current = OnboardingPolicy.currentVersion
        // First launch, or a newer flow.
        #expect(OnboardingPolicy.shouldShowAtLaunch(completedVersion: 0, cliInstalled: true, isUITest: false, forced: false))
        #expect(!OnboardingPolicy.shouldShowAtLaunch(completedVersion: current, cliInstalled: true, isUITest: false, forced: false))
        // The CLI went missing after setup.
        #expect(OnboardingPolicy.shouldShowAtLaunch(completedVersion: current, cliInstalled: false, isUITest: false, forced: false))
        // UI tests stay deterministic unless asked (BASKET_ONBOARDING=1).
        #expect(!OnboardingPolicy.shouldShowAtLaunch(completedVersion: 0, cliInstalled: false, isUITest: true, forced: false))
        #expect(OnboardingPolicy.shouldShowAtLaunch(completedVersion: current, cliInstalled: true, isUITest: true, forced: true))
    }
}
