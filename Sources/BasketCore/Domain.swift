import Foundation

// UI-facing domain model and the backend contract.
//
// The app only talks to `ContainerBackend`. Implementations:
//   - `CLIBackend`     — shells out to apple/container's `container` CLI (`--format json`).
//   - `FixtureBackend` — serves raw CLI JSON captured on disk; deterministic, used by E2E tests.
//
// Contract rule: changes to this file are additive only (new fields get defaults, new
// protocol requirements get a default implementation in an extension) so the app keeps compiling.

// MARK: - System

public struct SystemStatus: Sendable, Hashable {
    public var isRunning: Bool
    public var cliVersion: String?
    public var serverVersion: String?
    public var hostCPUs: Int?
    public var hostOS: String?
    public var appRoot: String?
    public var installRoot: String?
    public var containersRunning: Int
    public var containersTotal: Int
    public var imagesTotal: Int

    public init(
        isRunning: Bool, cliVersion: String? = nil, serverVersion: String? = nil,
        hostCPUs: Int? = nil, hostOS: String? = nil, appRoot: String? = nil, installRoot: String? = nil,
        containersRunning: Int = 0, containersTotal: Int = 0, imagesTotal: Int = 0
    ) {
        self.isRunning = isRunning
        self.cliVersion = cliVersion
        self.serverVersion = serverVersion
        self.hostCPUs = hostCPUs
        self.hostOS = hostOS
        self.appRoot = appRoot
        self.installRoot = installRoot
        self.containersRunning = containersRunning
        self.containersTotal = containersTotal
        self.imagesTotal = imagesTotal
    }
}

public struct DiskUsageCategory: Sendable, Hashable {
    public var total: Int
    public var active: Int
    public var sizeBytes: Int64
    public var reclaimableBytes: Int64

    public init(total: Int, active: Int, sizeBytes: Int64, reclaimableBytes: Int64) {
        self.total = total
        self.active = active
        self.sizeBytes = sizeBytes
        self.reclaimableBytes = reclaimableBytes
    }
}

/// `container system df`.
public struct DiskUsage: Sendable, Hashable {
    public var containers: DiskUsageCategory
    public var images: DiskUsageCategory
    public var volumes: DiskUsageCategory

    public init(containers: DiskUsageCategory, images: DiskUsageCategory, volumes: DiskUsageCategory) {
        self.containers = containers
        self.images = images
        self.volumes = volumes
    }

    public var totalBytes: Int64 { containers.sizeBytes + images.sizeBytes + volumes.sizeBytes }
    public var reclaimableBytes: Int64 {
        containers.reclaimableBytes + images.reclaimableBytes + volumes.reclaimableBytes
    }
}

/// Memory the host actually pays for one VM (phys_footprint of the Virtualization XPC process),
/// as opposed to what the guest reports in `container stats`.
public struct HostMemoryFootprint: Sendable, Hashable {
    /// Container or machine id when the VM could be attributed, nil otherwise.
    public var ownerID: String?
    public var pid: Int32
    public var footprintBytes: Int64

    public init(ownerID: String?, pid: Int32, footprintBytes: Int64) {
        self.ownerID = ownerID
        self.pid = pid
        self.footprintBytes = footprintBytes
    }
}

// MARK: - Containers

public enum ContainerState: String, Sendable, Hashable, CaseIterable {
    case running, stopped, stopping, created, unknown

    public init(rawCLIValue: String) {
        self = ContainerState(rawValue: rawCLIValue.lowercased()) ?? .unknown
    }
}

public struct PortMapping: Sendable, Hashable {
    public var hostAddress: String
    public var hostPort: Int
    public var containerPort: Int
    public var proto: String
    public var count: Int

    public init(hostAddress: String, hostPort: Int, containerPort: Int, proto: String, count: Int = 1) {
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
        self.count = count
    }
}

public struct MountInfo: Sendable, Hashable {
    public var source: String
    public var destination: String
    /// "bind", "volume", "tmpfs", ...
    public var kind: String
    public var readOnly: Bool

    public init(source: String, destination: String, kind: String, readOnly: Bool) {
        self.source = source
        self.destination = destination
        self.kind = kind
        self.readOnly = readOnly
    }
}

public struct ContainerSummary: Identifiable, Sendable, Hashable {
    public var id: String
    public var imageReference: String
    public var state: ContainerState
    /// Executable followed by its arguments.
    public var command: [String]
    public var createdAt: Date?
    public var startedAt: Date?
    public var cpus: Int
    public var memoryLimitBytes: Int64
    public var ports: [PortMapping]
    /// IPv4 address without the prefix length, e.g. "192.168.64.2".
    public var ipv4Address: String?
    public var hostname: String?
    public var networks: [String]
    public var labels: [String: String]
    public var mounts: [MountInfo]
    /// "linux/arm64"
    public var platform: String
    public var rosetta: Bool
    public var environment: [String]
    /// Started with `--rm`: stopping the container deletes it, so it can't be restarted.
    /// nil when unknown (the CLI's JSON doesn't say; `CLIBackend` reads the bundle's `options.json`).
    public var removeOnStop: Bool?
    /// Network name → IPv4 address (no prefix length) of a running container; `ipv4Address` is the
    /// first network's.
    public var networkAddresses: [String: String]

    public init(
        id: String, imageReference: String, state: ContainerState, command: [String] = [],
        createdAt: Date? = nil, startedAt: Date? = nil, cpus: Int = 0, memoryLimitBytes: Int64 = 0,
        ports: [PortMapping] = [], ipv4Address: String? = nil, hostname: String? = nil,
        networks: [String] = [], labels: [String: String] = [:], mounts: [MountInfo] = [],
        platform: String = "", rosetta: Bool = false, environment: [String] = [], removeOnStop: Bool? = nil,
        networkAddresses: [String: String] = [:]
    ) {
        self.id = id
        self.imageReference = imageReference
        self.state = state
        self.command = command
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.cpus = cpus
        self.memoryLimitBytes = memoryLimitBytes
        self.ports = ports
        self.ipv4Address = ipv4Address
        self.hostname = hostname
        self.networks = networks
        self.labels = labels
        self.mounts = mounts
        self.platform = platform
        self.rosetta = rosetta
        self.environment = environment
        self.removeOnStop = removeOnStop
        self.networkAddresses = networkAddresses
    }
}

/// One `container stats --no-stream` sample. CPU% needs two samples: see `cpuPercent(since:)`.
public struct ContainerStats: Identifiable, Sendable, Hashable {
    public var id: String
    public var sampledAt: Date
    public var cpuUsageMicros: Int64
    public var memoryUsageBytes: Int64
    public var memoryLimitBytes: Int64
    public var networkRxBytes: Int64
    public var networkTxBytes: Int64
    public var blockReadBytes: Int64
    public var blockWriteBytes: Int64
    public var processCount: Int
    /// CPU% (of one core) the CLI measured itself over its own ~2 s sampling window
    /// (`cpuUtilization` × 100). Available from the first poll; nil when the CLI did not report it.
    public var reportedCPUPercent: Double?
    /// False when the CLI left out the cumulative CPU counter (`cpuUsageMicros` is then 0, not "idle").
    public var cpuCounterKnown: Bool
    /// False when the CLI left out a network counter (`networkRx/TxBytes` are then 0, not "quiet").
    public var networkCountersKnown: Bool

    public init(
        id: String, sampledAt: Date = Date(), cpuUsageMicros: Int64, memoryUsageBytes: Int64,
        memoryLimitBytes: Int64, networkRxBytes: Int64 = 0, networkTxBytes: Int64 = 0,
        blockReadBytes: Int64 = 0, blockWriteBytes: Int64 = 0, processCount: Int = 0,
        reportedCPUPercent: Double? = nil, cpuCounterKnown: Bool = true, networkCountersKnown: Bool = true
    ) {
        self.id = id
        self.sampledAt = sampledAt
        self.cpuUsageMicros = cpuUsageMicros
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.networkRxBytes = networkRxBytes
        self.networkTxBytes = networkTxBytes
        self.blockReadBytes = blockReadBytes
        self.blockWriteBytes = blockWriteBytes
        self.processCount = processCount
        self.reportedCPUPercent = reportedCPUPercent
        self.cpuCounterKnown = cpuCounterKnown
        self.networkCountersKnown = networkCountersKnown
    }

    /// Percent of one CPU core used between `previous` and `self` (can exceed 100 on multi-core);
    /// 0 when either sample lacks the CPU counter (check `cpuCounterKnown`).
    public func cpuPercent(since previous: ContainerStats) -> Double {
        let elapsed = sampledAt.timeIntervalSince(previous.sampledAt)
        guard elapsed > 0, cpuCounterKnown, previous.cpuCounterKnown, cpuUsageMicros >= previous.cpuUsageMicros else { return 0 }
        return Double(cpuUsageMicros - previous.cpuUsageMicros) / (elapsed * 1_000_000) * 100
    }
}

/// Parameters for `container run`.
public struct RunSpec: Sendable, Hashable {
    public var image: String
    public var name: String?
    public var command: [String]
    public var cpus: Int?
    /// e.g. "512M", "2G"
    public var memory: String?
    /// "8080:80", "127.0.0.1:5432:5432/tcp"
    public var ports: [String]
    /// "/host/path:/container/path[:ro]" or "volume-name:/path"
    public var volumes: [String]
    /// "KEY=VALUE"
    public var environment: [String]
    public var network: String?
    public var removeOnExit: Bool
    public var rosetta: Bool
    public var platform: String?
    /// `--label key=value`
    public var labels: [String: String]
    /// `--entrypoint`: replaces the image's entrypoint (a single executable; arguments go in `command`).
    public var entrypoint: String?
    /// `--workdir`
    public var workingDirectory: String?
    /// `--user name|uid[:gid]`
    public var user: String?
    /// Networks attached after `network` (one `--network` each).
    public var additionalNetworks: [String]
    /// `--cap-add` / `--cap-drop` (e.g. "NET_ADMIN")
    public var capAdd: [String]
    public var capDrop: [String]
    /// `--tmpfs` mount points
    public var tmpfs: [String]
    /// `--read-only` root filesystem
    public var readOnlyRootFilesystem: Bool
    /// `--init`: an init process that forwards signals and reaps zombies
    public var initProcess: Bool
    /// `--dns` / `--dns-search`
    public var dns: [String]
    public var dnsSearch: [String]
    /// `--shm-size` (e.g. "64M")
    public var shmSize: String?
    /// `--ulimit type=soft[:hard]`
    public var ulimits: [String]
    /// `--interactive` / `--tty`
    public var interactive: Bool
    public var tty: Bool

    public init(
        image: String, name: String? = nil, command: [String] = [], cpus: Int? = nil,
        memory: String? = nil, ports: [String] = [], volumes: [String] = [], environment: [String] = [],
        network: String? = nil, removeOnExit: Bool = false, rosetta: Bool = false, platform: String? = nil,
        labels: [String: String] = [:], entrypoint: String? = nil, workingDirectory: String? = nil,
        user: String? = nil, additionalNetworks: [String] = [], capAdd: [String] = [], capDrop: [String] = [],
        tmpfs: [String] = [], readOnlyRootFilesystem: Bool = false, initProcess: Bool = false,
        dns: [String] = [], dnsSearch: [String] = [], shmSize: String? = nil, ulimits: [String] = [],
        interactive: Bool = false, tty: Bool = false
    ) {
        self.image = image
        self.name = name
        self.command = command
        self.cpus = cpus
        self.memory = memory
        self.ports = ports
        self.volumes = volumes
        self.environment = environment
        self.network = network
        self.removeOnExit = removeOnExit
        self.rosetta = rosetta
        self.platform = platform
        self.labels = labels
        self.entrypoint = entrypoint
        self.workingDirectory = workingDirectory
        self.user = user
        self.additionalNetworks = additionalNetworks
        self.capAdd = capAdd
        self.capDrop = capDrop
        self.tmpfs = tmpfs
        self.readOnlyRootFilesystem = readOnlyRootFilesystem
        self.initProcess = initProcess
        self.dns = dns
        self.dnsSearch = dnsSearch
        self.shmSize = shmSize
        self.ulimits = ulimits
        self.interactive = interactive
        self.tty = tty
    }
}

// MARK: - Images

public struct ImageVariant: Sendable, Hashable {
    /// "linux/arm64/v8"; attestation manifests ("unknown/unknown") are excluded.
    public var platform: String
    public var digest: String
    public var sizeBytes: Int64

    public init(platform: String, digest: String, sizeBytes: Int64) {
        self.platform = platform
        self.digest = digest
        self.sizeBytes = sizeBytes
    }
}

public struct ImageSummary: Identifiable, Sendable, Hashable {
    /// The reference ("docker.io/library/alpine:latest") — unique per tag.
    public var id: String { reference }
    public var reference: String
    public var digest: String
    public var createdAt: Date?
    public var variants: [ImageVariant]
    /// Size of the variant matching the host platform (linux/arm64), 0 if absent.
    public var hostVariantSizeBytes: Int64
    /// Sum of all variant sizes (what an all-platform pull costs on disk).
    public var totalSizeBytes: Int64

    public init(
        reference: String, digest: String, createdAt: Date? = nil, variants: [ImageVariant] = [],
        hostVariantSizeBytes: Int64 = 0, totalSizeBytes: Int64 = 0
    ) {
        self.reference = reference
        self.digest = digest
        self.createdAt = createdAt
        self.variants = variants
        self.hostVariantSizeBytes = hostVariantSizeBytes
        self.totalSizeBytes = totalSizeBytes
    }
}

// MARK: - Volumes & networks

public struct VolumeSummary: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public var name: String
    public var driver: String
    public var format: String
    /// Logical capacity (volumes are sparse: default 512 GB).
    public var capacityBytes: Int64
    /// Bytes actually allocated on the host disk for the backing image, nil if unknown.
    public var allocatedBytes: Int64?
    /// Host path of the backing image file.
    public var source: String
    public var createdAt: Date?
    public var labels: [String: String]

    public init(
        name: String, driver: String = "local", format: String = "ext4", capacityBytes: Int64 = 0,
        allocatedBytes: Int64? = nil, source: String = "", createdAt: Date? = nil, labels: [String: String] = [:]
    ) {
        self.name = name
        self.driver = driver
        self.format = format
        self.capacityBytes = capacityBytes
        self.allocatedBytes = allocatedBytes
        self.source = source
        self.createdAt = createdAt
        self.labels = labels
    }
}

public struct NetworkSummary: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public var name: String
    /// "nat", "hostOnly", ...
    public var mode: String
    public var ipv4Subnet: String?
    public var ipv4Gateway: String?
    public var ipv6Subnet: String?
    public var isBuiltin: Bool
    public var createdAt: Date?
    public var labels: [String: String]

    public init(
        name: String, mode: String = "nat", ipv4Subnet: String? = nil, ipv4Gateway: String? = nil,
        ipv6Subnet: String? = nil, isBuiltin: Bool = false, createdAt: Date? = nil, labels: [String: String] = [:]
    ) {
        self.name = name
        self.mode = mode
        self.ipv4Subnet = ipv4Subnet
        self.ipv4Gateway = ipv4Gateway
        self.ipv6Subnet = ipv6Subnet
        self.isBuiltin = isBuiltin
        self.createdAt = createdAt
        self.labels = labels
    }
}

// MARK: - Machines (full Linux VMs, OrbStack "machines")

public struct MachineSummary: Identifiable, Sendable, Hashable {
    public var id: String
    public var image: String
    public var state: ContainerState
    public var cpus: Int
    public var memoryBytes: Int64
    public var isDefault: Bool
    /// "ro", "rw", "none"
    public var homeMount: String
    public var ipv4Address: String?
    /// Bytes the machine's root disk occupies on the host (`diskSize`), nil if unknown.
    public var diskBytes: Int64?
    public var createdAt: Date?

    public init(
        id: String, image: String, state: ContainerState, cpus: Int = 0, memoryBytes: Int64 = 0,
        isDefault: Bool = false, homeMount: String = "rw", ipv4Address: String? = nil,
        diskBytes: Int64? = nil, createdAt: Date? = nil
    ) {
        self.id = id
        self.image = image
        self.state = state
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.isDefault = isDefault
        self.homeMount = homeMount
        self.ipv4Address = ipv4Address
        self.diskBytes = diskBytes
        self.createdAt = createdAt
    }
}

// MARK: - System properties

/// Defaults from `container system property list` (what new containers/machines get).
public struct SystemProperties: Sendable, Hashable {
    public var containerCPUs: Int?
    /// e.g. "1gb"
    public var containerMemory: String?
    public var machineCPUs: Int?
    /// e.g. "16gb"
    public var machineMemory: String?
    /// "ro", "rw", "none"
    public var machineHomeMount: String?
    public var registryDomain: String?
    public var kernelURL: String?
    public var builderImage: String?
    public var initImage: String?

    public init(
        containerCPUs: Int? = nil, containerMemory: String? = nil, machineCPUs: Int? = nil,
        machineMemory: String? = nil, machineHomeMount: String? = nil, registryDomain: String? = nil,
        kernelURL: String? = nil, builderImage: String? = nil, initImage: String? = nil
    ) {
        self.containerCPUs = containerCPUs
        self.containerMemory = containerMemory
        self.machineCPUs = machineCPUs
        self.machineMemory = machineMemory
        self.machineHomeMount = machineHomeMount
        self.registryDomain = registryDomain
        self.kernelURL = kernelURL
        self.builderImage = builderImage
        self.initImage = initImage
    }
}

/// Lines of a followed log delivered together (see `ContainerBackend.followLogBatches`).
public struct LogBatch: Sendable, Hashable {
    public var lines: [String]
    /// Lines discarded just before this batch because the consumer fell behind the producer.
    public var droppedLines: Int

    public init(lines: [String], droppedLines: Int = 0) {
        self.lines = lines
        self.droppedLines = droppedLines
    }
}

// MARK: - Errors

public enum BackendError: Error, LocalizedError, Sendable, Equatable {
    case cliNotFound(searched: [String])
    case systemNotRunning
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case decodingFailed(command: String, detail: String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound(let searched):
            String(localized: "The `container` CLI was not found (looked in \(searched.joined(separator: ", "))). Install it with `brew install container`.", bundle: .main)
        case .systemNotRunning:
            String(localized: "The container system service is not running.", bundle: .main)
        case .commandFailed(let command, let code, let stderr):
            String(localized: "`\(command)` failed (exit \(Int(code))): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))", bundle: .main,
                   comment: "1: command line, 2: exit status, 3: the command's error output")
        case .decodingFailed(let command, let detail):
            String(localized: "Could not read the output of `\(command)`: \(detail)", bundle: .main)
        case .unsupported(let what):
            String(localized: "\(what) is not supported by this backend.", bundle: .main,
                   comment: "The argument is an operation, e.g. “Starting a machine”")
        }
    }
}

// MARK: - Backend contract

/// Streams (`AsyncThrowingStream<String, Error>`) yield human-readable progress/log lines and
/// finish when the underlying command exits; cancelling the consuming task terminates the command.
public protocol ContainerBackend: Sendable {
    // System
    func systemStatus() async throws -> SystemStatus
    func startSystem() async throws
    func stopSystem() async throws
    func diskUsage() async throws -> DiskUsage
    func hostMemoryFootprints() async throws -> [HostMemoryFootprint]

    // Containers (always includes stopped ones)
    func listContainers() async throws -> [ContainerSummary]
    func containerStats() async throws -> [ContainerStats]
    /// Pretty-printed JSON of `container inspect`.
    func inspectContainer(_ id: String) async throws -> String
    func startContainer(_ id: String) async throws
    func stopContainers(_ ids: [String]) async throws
    func killContainers(_ ids: [String]) async throws
    func deleteContainers(_ ids: [String], force: Bool) async throws
    func pruneContainers() async throws
    /// Detached run; returns the container id.
    func run(_ spec: RunSpec) async throws -> String
    func logs(_ id: String, tail: Int?) async throws -> String
    func followLogs(_ id: String) -> AsyncThrowingStream<String, Error>
    /// Shell command line to open an interactive shell in a container, for Terminal.app.
    func shellCommandLine(forContainer id: String) -> String

    // Images
    func listImages() async throws -> [ImageSummary]
    func inspectImage(_ reference: String) async throws -> String
    /// `platform` nil means the host platform only (saves disk vs. pulling every variant).
    func pullImage(_ reference: String, platform: String?) -> AsyncThrowingStream<String, Error>
    func deleteImages(_ references: [String], force: Bool) async throws
    func pruneImages(all: Bool) async throws
    func tagImage(_ source: String, as target: String) async throws

    // Volumes
    func listVolumes() async throws -> [VolumeSummary]
    func createVolume(name: String, size: String?) async throws
    func deleteVolumes(_ names: [String]) async throws
    func pruneVolumes() async throws

    // Networks
    func listNetworks() async throws -> [NetworkSummary]
    func createNetwork(name: String, subnet: String?) async throws
    func deleteNetworks(_ names: [String]) async throws

    // Machines
    func listMachines() async throws -> [MachineSummary]
    func createMachine(image: String, name: String?, cpus: Int?, memory: String?) -> AsyncThrowingStream<String, Error>
    func stopMachine(_ id: String) async throws
    func deleteMachine(_ id: String) async throws
    func setDefaultMachine(_ id: String) async throws
    func shellCommandLine(forMachine id: String) -> String

    // Additions (default implementations below keep older conformers compiling)

    /// Boots a stopped machine.
    func startMachine(_ id: String) async throws
    /// `container system property list`.
    func systemProperties() async throws -> SystemProperties

    /// `container image save --platform P -o archive reference`: writes an OCI archive holding only
    /// `platform`'s variant (nil = every variant). Nothing in the image store changes.
    func saveImage(_ reference: String, platform: String?, to archive: URL) async throws
    /// `container image load -i archive`; returns the references it created. A reference that already
    /// exists is repointed to the archive's content (no delete needed first).
    func loadImage(from archive: URL) async throws -> [String]
    /// `followLogs`, coalesced off the main thread: at most one batch per ~100 ms and a bounded buffer
    /// (lines a slow consumer can't take are dropped and counted). Same lifetime rules as other streams.
    func followLogBatches(_ id: String) -> AsyncThrowingStream<LogBatch, Error>

    /// `container exec [--user U] id command…` in a running container; returns its stdout. A non-zero
    /// exit throws `BackendError.commandFailed`. `user` nil = the container's own user.
    func exec(_ id: String, command: [String], user: String?) async throws -> String
    /// `network create` with `--label`s (Compose marks the networks it owns).
    func createNetwork(name: String, subnet: String?, labels: [String: String]) async throws
    /// `volume create` with `--label`s.
    func createVolume(name: String, size: String?, labels: [String: String]) async throws
}

extension ContainerBackend {
    public func startMachine(_ id: String) async throws {
        throw BackendError.unsupported(String(localized: "Starting a machine", bundle: .main))
    }

    public func systemProperties() async throws -> SystemProperties {
        throw BackendError.unsupported(String(localized: "Reading system properties", bundle: .main))
    }

    public func saveImage(_ reference: String, platform: String?, to archive: URL) async throws {
        throw BackendError.unsupported(String(localized: "Saving an image", bundle: .main))
    }

    public func loadImage(from archive: URL) async throws -> [String] {
        throw BackendError.unsupported(String(localized: "Loading an image", bundle: .main))
    }

    public func followLogBatches(_ id: String) -> AsyncThrowingStream<LogBatch, Error> {
        LineBatcher.batches(of: followLogs(id))
    }

    public func exec(_ id: String, command: [String], user: String?) async throws -> String {
        throw BackendError.unsupported(String(localized: "Running a command in a container", bundle: .main))
    }

    /// Runs `command` as the container's own user.
    public func exec(_ id: String, command: [String]) async throws -> String {
        try await exec(id, command: command, user: nil)
    }

    /// Labels are dropped by backends that can't store them.
    public func createNetwork(name: String, subnet: String?, labels: [String: String]) async throws {
        try await createNetwork(name: name, subnet: subnet)
    }

    public func createVolume(name: String, size: String?, labels: [String: String]) async throws {
        try await createVolume(name: name, size: size)
    }
}
