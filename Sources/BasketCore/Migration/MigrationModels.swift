import Foundation

// Public model of the OrbStack → Basket migration (images and containers read from OrbStack's
// docker engine, read-only).

/// Whether OrbStack's docker engine can be read right now.
public enum MigrationSourceStatus: Sendable, Hashable {
    case notInstalled
    /// Installed but not running. Basket never launches it (a docker call could).
    case notRunning
    /// Running, but no `docker` CLI was found or it failed to answer.
    case dockerUnavailable(String)
    /// Ready; carries the engine version ("29.8.2").
    case ready(dockerVersion: String?)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// One row of OrbStack's image list (one per reference; untagged images get their digest reference).
public struct OrbStackImage: Identifiable, Sendable, Hashable {
    /// Unique per row: the reference, or the image ID for dangling images.
    public var id: String { reference ?? imageID }
    /// `sha256:…` (the index/manifest digest in the containerd store).
    public var imageID: String
    /// "redis", "grafana/grafana"; "<none>" for dangling images.
    public var repository: String
    /// nil when untagged.
    public var tag: String?
    /// What `docker save` gets: "redis:7-alpine", "python@sha256:…"; nil for dangling images.
    public var reference: String?
    /// Disk usage in OrbStack (unpacked + content) of the platform docker resolves by default.
    public var sizeBytes: Int64
    public var createdAt: Date?
    /// Containers (any state) in OrbStack using this image.
    public var containerCount: Int
    /// The platform present in OrbStack that an import would export ("linux/arm64/v8",
    /// "linux/amd64"); nil when unknown (then the import tries the host platform).
    public var platform: String?

    public init(
        imageID: String, repository: String, tag: String?, reference: String?, sizeBytes: Int64,
        createdAt: Date? = nil, containerCount: Int = 0, platform: String? = nil
    ) {
        self.imageID = imageID
        self.repository = repository
        self.tag = tag
        self.reference = reference
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
        self.containerCount = containerCount
        self.platform = platform
    }

    /// `<none>:<none>`: nothing to name it by in Basket.
    public var isDangling: Bool { reference == nil }
    /// No tag (digest-only references and dangling images); hidden by default.
    public var isUntagged: Bool { tag == nil }
    /// The image is available for this Mac's platform (no Rosetta needed).
    public var isHostNative: Bool { platform.map(MigrationPlatform.isHost) ?? false }
    /// The reference the image gets in Basket ("docker.io/library/redis:7-alpine").
    public var basketReference: String? { reference.map(normalizeImageReference) }
    /// `--platform` for `docker save`: the host platform when present, else what OrbStack has.
    public var exportPlatform: String {
        guard let platform, !MigrationPlatform.isHost(platform) else { return MigrationPlatform.host }
        return platform
    }
}

/// A published port as Docker configured it.
public struct OrbStackPortBinding: Sendable, Hashable {
    /// "" = all interfaces.
    public var hostIP: String
    /// nil = Docker picked a random port.
    public var hostPort: Int?
    public var containerPort: Int
    public var proto: String

    public init(hostIP: String, hostPort: Int?, containerPort: Int, proto: String) {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
    }
}

public struct OrbStackMount: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case bind, volume, tmpfs, other }
    public var kind: Kind
    /// Host path (bind), volume name (volume; a 64-hex name means anonymous), "" for tmpfs.
    public var source: String
    public var destination: String
    public var readOnly: Bool
    /// Volume driver ("local") when `kind == .volume`.
    public var driver: String?
    /// tmpfs options ("size=9g").
    public var options: String?

    public init(kind: Kind, source: String, destination: String, readOnly: Bool, driver: String? = nil, options: String? = nil) {
        self.kind = kind
        self.source = source
        self.destination = destination
        self.readOnly = readOnly
        self.driver = driver
        self.options = options
    }

    /// Docker names volumes it creates for an image's `VOLUME` with 64 hex characters.
    public var isAnonymousVolume: Bool {
        kind == .volume && source.count == 64 && source.allSatisfy(\.isHexDigit)
    }
}

/// One OrbStack container with the settings needed to recreate it (from `docker inspect`).
public struct OrbStackContainer: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    /// The reference the container was created from, as typed ("redis:7-alpine", "busybox").
    public var image: String
    public var imageID: String
    /// "running", "exited", "created", "paused", …
    public var state: String
    /// "Up 2 days", "Exited (0) 3 hours ago".
    public var status: String
    public var createdAt: Date?
    public var ports: [OrbStackPortBinding]
    /// Full effective environment (image defaults included).
    public var environment: [String]
    public var entrypoint: [String]?
    public var command: [String]?
    public var workingDirectory: String?
    public var user: String?
    public var labels: [String: String]
    public var mounts: [OrbStackMount]
    /// "no", "always", "unless-stopped", "on-failure".
    public var restartPolicy: String
    public var memoryLimitBytes: Int64
    /// CPU limit in cores (`--cpus`), 0 = unlimited.
    public var cpuLimit: Double
    public var networkMode: String
    /// Networks the container is attached to, with their aliases.
    public var networks: [String: [String]]
    public var tty: Bool
    public var openStdin: Bool
    public var autoRemove: Bool
    public var initProcess: Bool
    public var readOnlyRootFS: Bool
    public var hostname: String?
    public var hasHealthcheck: Bool
    public var privileged: Bool
    public var capAdd: [String]
    public var capDrop: [String]
    public var devices: [String]
    public var gpuRequests: Int
    public var dns: [String]
    public var dnsSearch: [String]
    public var dnsOptions: [String]
    public var extraHosts: [String]
    public var links: [String]
    public var securityOptions: [String]
    public var ulimits: [String]
    public var sysctls: [String: String]
    public var staticIPs: [String]
    /// "host", "container:…" namespaces shared with something outside the container.
    public var sharedNamespaces: [String]
    public var volumesFrom: [String]
    public var publishAll: Bool
    /// `Config.ExposedPorts` ("6379/tcp"), used for `-P`.
    public var exposedPorts: [String]
    /// Defaults baked into the image, when OrbStack still has it (used to emit only overrides).
    public var imageDefaults: ImageDefaults?

    public struct ImageDefaults: Sendable, Hashable {
        public var environment: [String]
        public var entrypoint: [String]?
        public var command: [String]?
        public var workingDirectory: String?
        public var user: String?
        public var labels: [String: String]
        /// "os/arch[/variant]" docker resolved for the container's image.
        public var platform: String?

        public init(
            environment: [String] = [], entrypoint: [String]? = nil, command: [String]? = nil,
            workingDirectory: String? = nil, user: String? = nil, labels: [String: String] = [:], platform: String? = nil
        ) {
            self.environment = environment
            self.entrypoint = entrypoint
            self.command = command
            self.workingDirectory = workingDirectory
            self.user = user
            self.labels = labels
            self.platform = platform
        }
    }

    public init(
        id: String, name: String, image: String, imageID: String = "", state: String = "exited", status: String = "",
        createdAt: Date? = nil, ports: [OrbStackPortBinding] = [], environment: [String] = [],
        entrypoint: [String]? = nil, command: [String]? = nil, workingDirectory: String? = nil, user: String? = nil,
        labels: [String: String] = [:], mounts: [OrbStackMount] = [], restartPolicy: String = "no",
        memoryLimitBytes: Int64 = 0, cpuLimit: Double = 0, networkMode: String = "bridge",
        networks: [String: [String]] = [:], tty: Bool = false, openStdin: Bool = false, autoRemove: Bool = false,
        initProcess: Bool = false, readOnlyRootFS: Bool = false, hostname: String? = nil, hasHealthcheck: Bool = false,
        privileged: Bool = false, capAdd: [String] = [], capDrop: [String] = [], devices: [String] = [],
        gpuRequests: Int = 0, dns: [String] = [], dnsSearch: [String] = [], dnsOptions: [String] = [],
        extraHosts: [String] = [], links: [String] = [], securityOptions: [String] = [], ulimits: [String] = [],
        sysctls: [String: String] = [:], staticIPs: [String] = [], sharedNamespaces: [String] = [],
        volumesFrom: [String] = [], publishAll: Bool = false, exposedPorts: [String] = [], imageDefaults: ImageDefaults? = nil
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.imageID = imageID
        self.state = state
        self.status = status
        self.createdAt = createdAt
        self.ports = ports
        self.environment = environment
        self.entrypoint = entrypoint
        self.command = command
        self.workingDirectory = workingDirectory
        self.user = user
        self.labels = labels
        self.mounts = mounts
        self.restartPolicy = restartPolicy
        self.memoryLimitBytes = memoryLimitBytes
        self.cpuLimit = cpuLimit
        self.networkMode = networkMode
        self.networks = networks
        self.tty = tty
        self.openStdin = openStdin
        self.autoRemove = autoRemove
        self.initProcess = initProcess
        self.readOnlyRootFS = readOnlyRootFS
        self.hostname = hostname
        self.hasHealthcheck = hasHealthcheck
        self.privileged = privileged
        self.capAdd = capAdd
        self.capDrop = capDrop
        self.devices = devices
        self.gpuRequests = gpuRequests
        self.dns = dns
        self.dnsSearch = dnsSearch
        self.dnsOptions = dnsOptions
        self.extraHosts = extraHosts
        self.links = links
        self.securityOptions = securityOptions
        self.ulimits = ulimits
        self.sysctls = sysctls
        self.staticIPs = staticIPs
        self.sharedNamespaces = sharedNamespaces
        self.volumesFrom = volumesFrom
        self.publishAll = publishAll
        self.exposedPorts = exposedPorts
        self.imageDefaults = imageDefaults
    }

    public var isRunning: Bool { state == "running" }
    /// The image reference in Basket's naming ("docker.io/library/redis:7-alpine").
    public var basketImageReference: String { normalizeImageReference(image) }
}

// MARK: - Import

/// Progress of one image import, in order: checking → exporting → loading → done.
public enum ImportPhase: Sendable, Hashable {
    case checking
    /// `docker save` is writing the archive; bytes written so far.
    case exporting(bytes: Int64)
    /// `container image load` is reading the archive (its size).
    case loading(bytes: Int64)
    /// Loaded; the references now in Basket and the archive size.
    case done(references: [String], archiveBytes: Int64)
}

public struct ImportProgress: Sendable, Hashable {
    public var phase: ImportPhase
    public var message: String

    public init(phase: ImportPhase, message: String) {
        self.phase = phase
        self.message = message
    }
}

// MARK: - Recreation

public struct MigrationWarning: Identifiable, Sendable, Hashable {
    public enum Severity: Sendable, Hashable { case info, warning }
    public var severity: Severity
    /// Short topic in English ("Restart policy", "Volume data"): identifies the kind of warning.
    public var topic: String
    /// The topic in the user's language, for display.
    public var title: String
    /// In the user's language.
    public var message: String
    public var id: String { topic + "|" + message }

    /// `topic` and `message` are localized (String Catalog keys in English).
    public init(_ severity: Severity, _ topic: LocalizedStringResource, _ message: LocalizedStringResource) {
        self.severity = severity
        self.topic = topic.key
        self.title = String(localized: topic)
        self.message = String(localized: message)
    }

    /// A warning whose topic is a technical name ("tmpfs"): shown as is, never translated.
    public init(_ severity: Severity, key: String, _ message: LocalizedStringResource) {
        self.severity = severity
        self.topic = key
        self.title = key
        self.message = String(localized: message)
    }
}

public struct RecreationOptions: Sendable, Hashable {
    /// Container name in Basket; nil = the Docker name.
    public var name: String?
    /// Memory when Docker had no limit (Docker's default is "all of the VM").
    public var defaultMemory: String
    /// Bind sources that don't exist on this Mac produce a warning (injected for tests).
    public var hostPathExists: @Sendable (String) -> Bool

    public init(
        name: String? = nil, defaultMemory: String = "1G",
        hostPathExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.name = name
        self.defaultMemory = defaultMemory
        self.hostPathExists = hostPathExists
    }

    public static func == (lhs: RecreationOptions, rhs: RecreationOptions) -> Bool {
        lhs.name == rhs.name && lhs.defaultMemory == rhs.defaultMemory
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(defaultMemory)
    }
}

/// How an OrbStack container becomes a Basket container.
public struct RecreationPlan: Sendable, Hashable {
    public var name: String
    /// Basket image reference ("docker.io/library/redis:7").
    public var image: String
    /// Named volumes to create first (`container volume create`), if missing.
    public var volumes: [String]
    /// `container run` arguments (without the executable).
    public var runArguments: [String]
    /// The same in `RunSpec` terms, minus what RunSpec can't express (entrypoint, workdir, user,
    /// labels, capabilities…); used by backends without a CLI (fixtures).
    public var runSpec: RunSpec
    public var warnings: [MigrationWarning]

    public init(name: String, image: String, volumes: [String], runArguments: [String], runSpec: RunSpec, warnings: [MigrationWarning]) {
        self.name = name
        self.image = image
        self.volumes = volumes
        self.runArguments = runArguments
        self.runSpec = runSpec
        self.warnings = warnings
    }

    /// Shell commands a user can paste into Terminal (volume creation first).
    public var commandLines: [String] {
        volumes.map { "container volume create \(shellQuoteIfNeeded($0))" }
            + ["container " + runArguments.map(shellQuoteIfNeeded).joined(separator: " ")]
    }

    /// `commandLines` joined into one script.
    public var script: String { commandLines.joined(separator: "\n") }
}

// MARK: - Errors

public enum MigrationError: Error, LocalizedError, Sendable, Equatable {
    case orbStackNotRunning
    case dockerNotFound
    /// A docker command outside the read-only allowlist was about to run.
    case forbiddenDockerCommand(String)
    case insufficientDiskSpace(neededBytes: Int64, availableBytes: Int64)
    case notImportable(String)
    case dockerFailed(command: String, message: String)
    case loadFailed(String)
    /// Basket already holds the same image under this reference (content compared).
    case alreadyInBasket(String)
    /// Basket holds a different (or uncomparable) image under this reference; importing would repoint it.
    case nameConflict(reference: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .orbStackNotRunning:
            String(localized: "OrbStack's Docker engine isn't running. Start OrbStack yourself to migrate; Basket never launches it.", bundle: .main)
        case .dockerNotFound:
            String(localized: "The docker CLI that ships with OrbStack wasn't found.", bundle: .main)
        case .forbiddenDockerCommand(let command):
            String(localized: "Refusing to run `\(command)`: Basket only reads from OrbStack.", bundle: .main)
        case .insufficientDiskSpace(let needed, let available):
            String(localized: "Not enough free disk space: the export needs about \(needed.formatted(.byteCount(style: .file))), \(available.formatted(.byteCount(style: .file))) is free.", bundle: .main)
        case .notImportable(let reason):
            reason
        case .dockerFailed(let command, let message):
            String(localized: "`\(command)` failed: \(message)", bundle: .main)
        case .loadFailed(let message):
            String(localized: "Loading into Basket failed: \(message)", bundle: .main)
        case .alreadyInBasket(let reference):
            String(localized: "Basket already has the same image as \(reference).", bundle: .main)
        case .nameConflict(let reference, let reason):
            String(localized: "Basket already has a different image named \(reference): \(reason). Rename or delete it in Basket to import OrbStack's.", bundle: .main)
        }
    }
}

enum MigrationPlatform {
    static let host = HostPlatform.pullPlatform

    /// "linux/arm64", "linux/arm64/v8" → true.
    static func isHost(_ platform: String) -> Bool {
        platform == host || platform.hasPrefix(host + "/")
    }
}
