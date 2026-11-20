import Foundation

// Typed view of a Compose file (the subset Basket can run on apple/container).
// `ComposeLoader` builds it from YAML; `ComposePlanner` turns it into `container` commands.

/// Something the plan can't carry over exactly, or worth knowing before `up`.
public struct ComposeWarning: Identifiable, Sendable, Hashable {
    public enum Severity: Sendable, Hashable { case info, warning }
    public var severity: Severity
    /// nil = the whole project.
    public var service: String?
    /// Short topic ("Restart policy", "Healthcheck").
    public var topic: String
    public var message: String
    public var id: String { "\(service ?? "")|\(topic)|\(message)" }

    public init(_ severity: Severity, service: String? = nil, _ topic: String, _ message: String) {
        self.severity = severity
        self.service = service
        self.topic = topic
        self.message = message
    }
}

public enum ComposeError: Error, LocalizedError, Sendable, Equatable {
    case yaml(YAMLError)
    /// `path` is the dotted location in the file ("services.web.ports[1]").
    case invalid(path: String, message: String)
    /// `${VAR:?message}` with VAR unset (or empty).
    case missingVariable(name: String, message: String, path: String)
    case unreadableFile(path: String, detail: String)
    case dependencyCycle([String])

    public var errorDescription: String? {
        switch self {
        case .yaml(let error): "Invalid YAML at \(error.localizedDescription)"
        case .invalid(let path, let message): "\(path): \(message)"
        case .missingVariable(let name, let message, let path):
            "\(path): required variable \(name) is not set" + (message.isEmpty ? "" : " (\(message))")
        case .unreadableFile(let path, let detail): "Can't read \(path): \(detail)"
        case .dependencyCycle(let services): "depends_on forms a cycle: \(services.joined(separator: " → "))"
        }
    }
}

public struct ComposeFile: Sendable, Hashable {
    /// Top-level `name:`.
    public var name: String?
    /// Directory holding the file (relative paths, `.env`, the default project name).
    public var workingDirectory: URL
    /// The compose file itself, when loaded from disk.
    public var configFile: URL?
    /// In file order.
    public var services: [ComposeService]
    public var networks: [ComposeNetwork]
    public var volumes: [ComposeVolume]
    /// Interpolation environment: `.env` next to the file, overridden by the process environment.
    public var environment: [String: String]
    /// File-level notes from loading (unset variables, unsupported top-level keys).
    public var warnings: [ComposeWarning]

    public init(
        name: String? = nil, workingDirectory: URL, configFile: URL? = nil, services: [ComposeService] = [],
        networks: [ComposeNetwork] = [], volumes: [ComposeVolume] = [], environment: [String: String] = [:],
        warnings: [ComposeWarning] = []
    ) {
        self.name = name
        self.workingDirectory = workingDirectory
        self.configFile = configFile
        self.services = services
        self.networks = networks
        self.volumes = volumes
        self.environment = environment
        self.warnings = warnings
    }

    public func service(_ name: String) -> ComposeService? { services.first { $0.name == name } }
}

public struct ComposeService: Sendable, Hashable {
    public struct Build: Sendable, Hashable {
        public var context: String
        public var dockerfile: String?
    }

    public struct Dependency: Sendable, Hashable {
        public var service: String
        /// "service_started", "service_healthy", "service_completed_successfully"
        public var condition: String
        public var required: Bool
    }

    public struct Network: Sendable, Hashable {
        /// Key in the top-level `networks:` (or "default").
        public var name: String
        public var aliases: [String]
        public var ipv4Address: String?
    }

    public var name: String
    public var image: String?
    public var build: Build?
    /// nil = the image's default.
    public var command: [String]?
    public var entrypoint: [String]?
    /// "KEY=value" after `env_file` and `environment` are merged (environment wins).
    public var environment: [String]
    public var ports: [ComposePort]
    public var mounts: [ComposeMount]
    /// nil = attached to the project's default network.
    public var networks: [Network]?
    public var networkMode: String?
    public var dependsOn: [Dependency]
    /// `links: ["db:database"]` → (db, database)
    public var links: [ComposeLink]
    public var containerName: String?
    public var hostname: String?
    public var workingDir: String?
    public var user: String?
    public var labels: [String: String]
    public var cpus: Double?
    public var memoryBytes: Int64?
    public var platform: String?
    public var profiles: [String]
    public var capAdd: [String]
    public var capDrop: [String]
    public var tmpfs: [String]
    public var readOnly: Bool
    public var initProcess: Bool
    public var dns: [String]
    public var dnsSearch: [String]
    public var shmSize: String?
    public var ulimits: [String]
    public var stdinOpen: Bool
    public var tty: Bool
    /// `extra_hosts`: (hostname, address)
    public var extraHosts: [ComposeLink]
    /// Notes found while reading this service (unsupported keys, adjusted values).
    public var warnings: [ComposeWarning]

    public init(name: String) {
        self.name = name
        environment = []
        ports = []
        mounts = []
        dependsOn = []
        links = []
        labels = [:]
        profiles = []
        capAdd = []
        capDrop = []
        tmpfs = []
        readOnly = false
        initProcess = false
        dns = []
        dnsSearch = []
        ulimits = []
        stdinOpen = false
        tty = false
        extraHosts = []
        warnings = []
    }
}

/// A (name, value) pair: `links` (service, alias) or `extra_hosts` (hostname, address).
public struct ComposeLink: Sendable, Hashable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

public struct ComposePort: Sendable, Hashable {
    public var hostIP: String?
    /// "8080" or a range "8000-8010"; nil = not published on a fixed host port.
    public var published: String?
    /// "80" or a range "8000-8010".
    public var target: String
    /// "tcp" or "udp"
    public var proto: String

    public init(hostIP: String? = nil, published: String?, target: String, proto: String = "tcp") {
        self.hostIP = hostIP
        self.published = published
        self.target = target
        self.proto = proto
    }
}

public struct ComposeMount: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case bind, volume, tmpfs }
    public var kind: Kind
    /// Host path as written (bind), the top-level volume key (volume), nil = anonymous volume / tmpfs.
    public var source: String?
    public var target: String
    public var readOnly: Bool

    public init(kind: Kind, source: String?, target: String, readOnly: Bool = false) {
        self.kind = kind
        self.source = source
        self.target = target
        self.readOnly = readOnly
    }
}

public struct ComposeNetwork: Sendable, Hashable {
    public var key: String
    /// Explicit `name:` (used as is, not prefixed with the project).
    public var name: String?
    public var external: Bool
    public var subnet: String?
    public var labels: [String: String]

    public init(key: String, name: String? = nil, external: Bool = false, subnet: String? = nil, labels: [String: String] = [:]) {
        self.key = key
        self.name = name
        self.external = external
        self.subnet = subnet
        self.labels = labels
    }
}

public struct ComposeVolume: Sendable, Hashable {
    public var key: String
    public var name: String?
    public var external: Bool
    public var labels: [String: String]

    public init(key: String, name: String? = nil, external: Bool = false, labels: [String: String] = [:]) {
        self.key = key
        self.name = name
        self.external = external
        self.labels = labels
    }
}

/// Labels Compose puts on what it creates (Basket uses the same keys, so tools agree).
public enum ComposeLabels {
    public static let project = "com.docker.compose.project"
    public static let service = "com.docker.compose.service"
    public static let containerNumber = "com.docker.compose.container-number"
    public static let workingDir = "com.docker.compose.project.working_dir"
    public static let configFiles = "com.docker.compose.project.config_files"
    public static let dependsOn = "com.docker.compose.depends_on"
    public static let network = "com.docker.compose.network"
    public static let volume = "com.docker.compose.volume"
    public static let oneoff = "com.docker.compose.oneoff"
    /// Marks resources Basket created from a compose file.
    public static let basket = "dev.basket.compose"
    /// Extra host names for /etc/hosts (container_name, network aliases, links), comma-separated.
    public static let aliases = "dev.basket.compose.aliases"
    /// `extra_hosts` as "host=address" pairs, comma-separated.
    public static let extraHosts = "dev.basket.compose.extra-hosts"
}
