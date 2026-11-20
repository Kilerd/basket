import Foundation

// Raw shapes of `container` 1.7.1 `--format json` output. Every field is optional and enums are
// plain strings so newer/older CLI builds degrade gracefully instead of failing to decode.
// Resources that 1.7.1 nests under `configuration` are also accepted flat (older builds).

struct RawPlatform: Codable, Sendable, Hashable {
    var os: String?
    var architecture: String?
    var variant: String?

    /// "linux/arm64/v8" (variant included when present).
    var fullString: String {
        [os ?? "unknown", architecture ?? "unknown", variant].compactMap { $0 }.joined(separator: "/")
    }

    var isAttestation: Bool { os == "unknown" || architecture == "unknown" }
}

struct RawDescriptor: Codable, Sendable, Hashable {
    var digest: String?
    var mediaType: String?
    var size: Int64?
}

struct RawImageDescription: Codable, Sendable, Hashable {
    var reference: String?
    var descriptor: RawDescriptor?
}

// MARK: - Containers (`list --all`, `inspect`)

struct RawContainer: Codable, Sendable {
    var id: String?
    var configuration: Configuration
    var status: Status?

    struct Configuration: Codable, Sendable {
        var id: String?
        var creationDate: Date?
        var image: RawImageDescription?
        var initProcess: InitProcess?
        var labels: [String: String]?
        var mounts: [Mount]?
        var networks: [NetworkRequest]?
        var platform: RawPlatform?
        var publishedPorts: [PublishedPort]?
        var resources: Resources?
        var rosetta: Bool?
        var runtimeHandler: String?
    }

    struct InitProcess: Codable, Sendable {
        var executable: String?
        var arguments: [String]?
        var environment: [String]?
        var workingDirectory: String?
        var terminal: Bool?
    }

    struct Mount: Codable, Sendable {
        var source: String?
        var destination: String?
        var options: [String]?
        var type: MountType?
    }

    /// `{"volume": {"name": ..., "format": ...}}`, `{"virtiofs": {}}`, `{"tmpfs": {}}`, `{"block": {...}}`.
    struct MountType: Codable, Sendable {
        var kind: String
        var volumeName: String?
        var format: String?

        init(kind: String, volumeName: String? = nil, format: String? = nil) {
            self.kind = kind
            self.volumeName = volumeName
            self.format = format
        }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let string = try? single.decode(String.self) {
                self.init(kind: string)
                return
            }
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            guard let key = container.allKeys.first else {
                self.init(kind: "unknown")
                return
            }
            let details = try? container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
            self.init(
                kind: key.stringValue,
                volumeName: try? details?.decodeIfPresent(String.self, forKey: AnyCodingKey("name")),
                format: try? details?.decodeIfPresent(String.self, forKey: AnyCodingKey("format")))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: AnyCodingKey.self)
            var details = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey(kind))
            try details.encodeIfPresent(volumeName, forKey: AnyCodingKey("name"))
            try details.encodeIfPresent(format, forKey: AnyCodingKey("format"))
        }
    }

    struct NetworkRequest: Codable, Sendable {
        var network: String?
        var options: Options?

        struct Options: Codable, Sendable {
            var hostname: String?
            var mtu: Int?
        }
    }

    struct PublishedPort: Codable, Sendable {
        var hostAddress: String?
        var hostPort: Int?
        var containerPort: Int?
        var proto: String?
        var count: Int?
    }

    struct Resources: Codable, Sendable {
        var cpus: Int?
        var memoryInBytes: Int64?
    }

    struct Status: Codable, Sendable {
        var state: String?
        var startedDate: Date?
        var networks: [Attachment]?
    }

    struct Attachment: Codable, Sendable {
        var network: String?
        var hostname: String?
        var ipv4Address: String?
        var ipv4Gateway: String?
        var ipv6Address: String?
        var macAddress: String?
    }

    init(id: String?, configuration: Configuration, status: Status?) {
        self.id = id
        self.configuration = configuration
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id, configuration, status, networks, startedDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        configuration = try container.decodeIfPresent(Configuration.self, forKey: .configuration)
            ?? Configuration(from: decoder)
        if let nested = try? container.decodeIfPresent(Status.self, forKey: .status) {
            status = nested
        } else {
            // Older builds: `"status": "running"` with `networks`/`startedDate` at the top level.
            status = Status(
                state: try? container.decodeIfPresent(String.self, forKey: .status),
                startedDate: try? container.decodeIfPresent(Date.self, forKey: .startedDate),
                networks: try? container.decodeIfPresent([Attachment].self, forKey: .networks))
        }
        if id == nil && configuration.id == nil {
            throw DecodingError.keyNotFound(
                CodingKeys.id, .init(codingPath: decoder.codingPath, debugDescription: "container without id"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(configuration, forKey: .configuration)
        try container.encodeIfPresent(status, forKey: .status)
    }
}

// MARK: - Stats (`stats --no-stream`)

struct RawStats: Codable, Sendable {
    var id: String
    var cpuUsageUsec: Int64?
    /// Fraction of one core (1.0 = one full core) measured by the CLI over its sampling window.
    var cpuUtilization: Double?
    var memoryUsageBytes: Int64?
    var memoryLimitBytes: Int64?
    var networkRxBytes: Int64?
    var networkTxBytes: Int64?
    var blockReadBytes: Int64?
    var blockWriteBytes: Int64?
    var numProcesses: Int?
}

// MARK: - Images (`image list`, `image inspect`)

struct RawImage: Codable, Sendable {
    var id: String?
    var configuration: Configuration
    var variants: [Variant]?

    struct Configuration: Codable, Sendable {
        var name: String
        var creationDate: Date?
        var descriptor: RawDescriptor?
    }

    struct Variant: Codable, Sendable {
        var digest: String?
        var platform: RawPlatform?
        var size: Int64?
    }

    init(id: String?, configuration: Configuration, variants: [Variant]?) {
        self.id = id
        self.configuration = configuration
        self.variants = variants
    }

    private enum CodingKeys: String, CodingKey { case id, configuration, variants }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        configuration = try container.decodeIfPresent(Configuration.self, forKey: .configuration)
            ?? Configuration(from: decoder)
        variants = (try? container.decodeIfPresent([Lossy<Variant>].self, forKey: .variants))?.compactMap(\.value)
    }
}

// MARK: - Volumes (`volume list`)

struct RawVolume: Codable, Sendable {
    var id: String?
    var configuration: Configuration

    struct Configuration: Codable, Sendable {
        var name: String
        var creationDate: Date?
        var driver: String?
        var format: String?
        var labels: [String: String]?
        var options: [String: String]?
        var sizeInBytes: Int64?
        var source: String?
    }

    init(id: String?, configuration: Configuration) {
        self.id = id
        self.configuration = configuration
    }

    private enum CodingKeys: String, CodingKey { case id, configuration }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        configuration = try container.decodeIfPresent(Configuration.self, forKey: .configuration)
            ?? Configuration(from: decoder)
    }
}

// MARK: - Networks (`network list`)

struct RawNetwork: Codable, Sendable {
    var id: String?
    var configuration: Configuration?
    var status: Status?

    struct Configuration: Codable, Sendable {
        var name: String?
        var creationDate: Date?
        var labels: [String: String]?
        var mode: String?
        var plugin: String?
    }

    struct Status: Codable, Sendable {
        var ipv4Subnet: String?
        var ipv4Gateway: String?
        var ipv6Subnet: String?
    }

    var name: String? { configuration?.name ?? id }
}

// MARK: - System

struct RawSystemStatus: Codable, Sendable {
    var status: String
    var client: Component?
    var server: Component?
    var host: Host?
    var paths: Paths?
    var resources: Resources?

    struct Component: Codable, Sendable {
        var appName: String?
        var version: String?
        var build: String?
        var commit: String?
    }

    struct Host: Codable, Sendable {
        var architecture: String?
        var cpus: Int?
        var operatingSystem: String?
    }

    struct Paths: Codable, Sendable {
        var appRoot: String?
        var installRoot: String?
        var logRoot: String?
    }

    struct Resources: Codable, Sendable {
        var containersRunning: Int?
        var containersTotal: Int?
        var images: Int?
    }
}

struct RawDiskUsage: Codable, Sendable {
    var containers: Category?
    var images: Category?
    var volumes: Category?

    struct Category: Codable, Sendable {
        var total: Int?
        var active: Int?
        var sizeInBytes: Int64?
        var reclaimable: Int64?
    }
}

struct RawVersion: Codable, Sendable {
    var appName: String?
    var version: String?
    var buildType: String?
    var commit: String?
}

struct RawSystemProperties: Codable, Sendable {
    var build: Build?
    var container: Resources?
    var machine: Machine?
    var kernel: Kernel?
    var registry: Registry?
    var vminit: VMInit?

    struct Build: Codable, Sendable {
        var cpus: Int?
        var image: String?
        var memory: String?
        var rosetta: Bool?
    }

    struct Resources: Codable, Sendable {
        var cpus: Int?
        var memory: String?
    }

    struct Machine: Codable, Sendable {
        var cpus: Int?
        var memory: String?
        var homeMount: String?
        var virtualization: Bool?
    }

    struct Kernel: Codable, Sendable {
        var binaryPath: String?
        var url: String?
        var digest: String?
    }

    struct Registry: Codable, Sendable {
        var domain: String?
    }

    struct VMInit: Codable, Sendable {
        var image: String?
    }
}

// MARK: - Machines (`machine list --format json` and `machine inspect`)

struct RawMachine: Codable, Sendable {
    var id: String
    var status: String?
    var isDefault: Bool?
    var ipAddress: String?
    var cpus: Int?
    var memory: Int64?
    var diskSize: Int64?
    var createdDate: Date?
    // `machine inspect` only:
    var startedDate: Date?
    var containerId: String?
    var homeMount: String?
    var image: RawImageDescription?
    var platform: RawPlatform?

    private enum CodingKeys: String, CodingKey {
        case id, status, ipAddress, cpus, memory, diskSize, createdDate, startedDate, containerId, homeMount
        case image, platform
        case isDefault = "default"
    }

    init(
        id: String, status: String? = nil, isDefault: Bool? = nil, ipAddress: String? = nil, cpus: Int? = nil,
        memory: Int64? = nil, diskSize: Int64? = nil, createdDate: Date? = nil, startedDate: Date? = nil,
        containerId: String? = nil, homeMount: String? = nil, image: RawImageDescription? = nil,
        platform: RawPlatform? = nil
    ) {
        self.id = id
        self.status = status
        self.isDefault = isDefault
        self.ipAddress = ipAddress
        self.cpus = cpus
        self.memory = memory
        self.diskSize = diskSize
        self.createdDate = createdDate
        self.startedDate = startedDate
        self.containerId = containerId
        self.homeMount = homeMount
        self.image = image
        self.platform = platform
    }

    /// Fills the fields `machine list` lacks from a `machine inspect` result.
    func merging(_ inspect: RawMachine) -> RawMachine {
        var merged = self
        merged.startedDate = startedDate ?? inspect.startedDate
        merged.containerId = containerId ?? inspect.containerId
        merged.homeMount = homeMount ?? inspect.homeMount
        merged.image = image ?? inspect.image
        merged.platform = platform ?? inspect.platform
        merged.ipAddress = ipAddress ?? inspect.ipAddress
        return merged
    }
}
