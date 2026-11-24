import Darwin
import Foundation

/// What an installed OrbStack costs right now, for the side-by-side comparison.
public struct OrbStackSnapshot: Sendable, Hashable, Codable {
    public var isInstalled: Bool
    public var isRunning: Bool
    /// Summed phys_footprint of OrbStack's processes (its Linux VM lives inside "OrbStack Helper").
    public var memoryFootprintBytes: Int64
    /// OrbStack's data directory (holds `data.img.raw`, the ever-growing disk image).
    public var dataPath: String?
    /// Bytes the data directory's files actually occupy on disk (sparse-aware).
    public var dataAllocatedBytes: Int64?
    /// `docker --context orbstack images` count; nil when docker is absent or OrbStack isn't running.
    public var dockerImageCount: Int?

    public init(
        isInstalled: Bool, isRunning: Bool, memoryFootprintBytes: Int64, dataPath: String? = nil,
        dataAllocatedBytes: Int64? = nil, dockerImageCount: Int? = nil
    ) {
        self.isInstalled = isInstalled
        self.isRunning = isRunning
        self.memoryFootprintBytes = memoryFootprintBytes
        self.dataPath = dataPath
        self.dataAllocatedBytes = dataAllocatedBytes
        self.dockerImageCount = dockerImageCount
    }

    public static let notInstalled = OrbStackSnapshot(isInstalled: false, isRunning: false, memoryFootprintBytes: 0)
}

/// Read-only inspection of OrbStack. Never starts, stops or modifies anything: `docker` is only invoked
/// while OrbStack is already running (a docker call can otherwise auto-launch it).
public struct OrbStackInspector: Sendable {
    public let fixturesDirectory: URL?
    /// Where to look for OrbStack.app on the host.
    public let locator: OrbStackLocator

    /// With `fixturesDirectory` containing `orbstack.json` (an encoded `OrbStackSnapshot`), `snapshot()`
    /// returns that instead of inspecting the host; a missing or unreadable file means not installed.
    public init(fixturesDirectory: URL? = nil, locator: OrbStackLocator = .standardFolders) {
        self.fixturesDirectory = fixturesDirectory
        self.locator = locator
    }

    static let dataDirectory = NSHomeDirectory() + "/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data"

    /// Whether OrbStack is installed, without measuring anything (the fixture's `orbstack.json`, or
    /// `locator`): cheap enough to decide at launch whether to show the migration section.
    public func isInstalled() -> Bool {
        if let fixturesDirectory { return Self.fixtureSnapshot(fixturesDirectory).isInstalled }
        return locator.appPath() != nil
    }

    /// `orbstack.json` of a fixture set; `.notInstalled` when it is missing or unreadable.
    static func fixtureSnapshot(_ directory: URL) -> OrbStackSnapshot {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("orbstack.json")),
              let snapshot = try? JSONDecoder().decode(OrbStackSnapshot.self, from: data)
        else { return .notInstalled }
        return snapshot
    }

    public func snapshot() async -> OrbStackSnapshot {
        if let fixturesDirectory { return Self.fixtureSnapshot(fixturesDirectory) }

        let appPath = locator.appPath()
        let (isRunning, footprint) = Self.processFootprint(appPath: appPath)
        let data = Self.dataUsage()
        // Any process in OrbStack.app counts as "running" here; docker is only called when the
        // engine itself is up (a call against a stopped engine might start it).
        let images = isRunning && OrbStackEngine.isUp(appPath: appPath) ? await Self.dockerImageCount() : nil
        return OrbStackSnapshot(
            isInstalled: appPath != nil, isRunning: isRunning, memoryFootprintBytes: footprint,
            dataPath: data?.path, dataAllocatedBytes: data?.bytes, dockerImageCount: images)
    }

    /// Processes inside the app bundle, plus any Virtualization XPC VM they are responsible for.
    static func processFootprint(appPath: String?) -> (isRunning: Bool, bytes: Int64) {
        let prefix = (appPath ?? "/Applications/OrbStack.app") + "/"
        var orbPIDs = Set<pid_t>()
        var total: Int64 = 0
        let pids = ProcessInspector.allPIDs()
        for pid in pids {
            guard let path = ProcessInspector.executablePath(of: pid), path.hasPrefix(prefix) else { continue }
            orbPIDs.insert(pid)
            total += ProcessInspector.physFootprint(of: pid) ?? 0
        }
        for vm in HostMemorySampler.virtualMachineProcesses() {
            if let responsible = vm.responsiblePID, orbPIDs.contains(responsible) { total += vm.footprintBytes }
        }
        return (!orbPIDs.isEmpty, total)
    }

    /// Allocated bytes of the top-level files in OrbStack's data directory (no recursive walk).
    static func dataUsage(directory: String = dataDirectory) -> (path: String, bytes: Int64)? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        var total: Int64 = 0
        for name in names {
            let path = (directory as NSString).appendingPathComponent(name)
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            total += Int64(info.st_blocks) * 512
        }
        return (directory, total)
    }

    /// `docker --context orbstack image ls`, through the same read-only allowlist and docker lookup
    /// as the migration (`DockerReadOnlyPolicy`, `ProcessDockerClient.locate`).
    static func dockerImageCount() async -> Int? {
        let arguments = ["--context", DockerReadOnlyPolicy.context, "image", "ls", "--format", "json"]
        guard (try? DockerReadOnlyPolicy.validate(arguments)) != nil, let docker = ProcessDockerClient.locate() else { return nil }
        guard let result = try? await ProcessDockerClient(executableURL: docker).run(arguments, timeout: .seconds(5)),
              result.exitCode == 0
        else { return nil }
        return result.stdoutText.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("{") }.count
    }
}
