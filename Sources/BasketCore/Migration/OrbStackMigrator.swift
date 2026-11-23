import Foundation

/// Reads OrbStack's images and containers (read-only), imports images into Basket keeping only the
/// host platform, and recreates containers as `container run` invocations.
///
/// OrbStack is only queried while it is already running; every docker command is checked against
/// `DockerReadOnlyPolicy` before it runs.
public struct OrbStackMigrator: Sendable {
    public let docker: (any OrbStackDockerClient)?
    public let presence: OrbStackPresence
    /// Where export archives go (one fresh subdirectory per import, always removed afterwards).
    public let temporaryDirectory: URL
    /// Free bytes on the volume holding `url` (injected for tests).
    public let freeSpace: @Sendable (URL) -> Int64?
    /// `docker save` has no overall time limit (archives can be many GB) but is stopped when the
    /// archive hasn't grown for this long.
    public let exportStallTimeout: Duration

    public init(
        docker: (any OrbStackDockerClient)?, presence: OrbStackPresence,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        freeSpace: @escaping @Sendable (URL) -> Int64? = OrbStackMigrator.availableCapacity,
        exportStallTimeout: Duration = .seconds(120)
    ) {
        self.docker = docker
        self.presence = presence
        self.temporaryDirectory = temporaryDirectory
        self.freeSpace = freeSpace
        self.exportStallTimeout = exportStallTimeout
    }

    /// Real OrbStack (docker located via `ProcessDockerClient.locate`, the app via `locator`).
    public static func host(locator: OrbStackLocator = .standardFolders) -> OrbStackMigrator {
        OrbStackMigrator(docker: ProcessDockerClient.locate().map(ProcessDockerClient.init), presence: .host(locator: locator))
    }

    /// Fixture mode: raw docker output from `directory`, OrbStack state from its `orbstack.json`.
    public static func fixtures(_ directory: URL) -> OrbStackMigrator {
        OrbStackMigrator(docker: FixtureDockerClient(directory: directory), presence: .fixture(directory))
    }

    public static func availableCapacity(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
    }

    // MARK: Docker plumbing

    /// Validates against the read-only allowlist, checks the engine is up, then runs docker. Reads
    /// get a short timeout; only `save` (watched for stalls instead) passes nil.
    func docker(_ arguments: [String], timeout: Duration? = .seconds(30)) async throws -> CLIResult {
        let full = ["--context", DockerReadOnlyPolicy.context] + arguments
        try DockerReadOnlyPolicy.validate(full)
        guard let docker else { throw MigrationError.dockerNotFound }
        guard await presence.isRunning() else { throw MigrationError.orbStackNotRunning }
        return try await docker.run(full, timeout: timeout)
    }

    /// Like `docker(_:)` but non-zero exits throw.
    func dockerOutput(_ arguments: [String], timeout: Duration? = .seconds(30)) async throws -> Data {
        let result = try await docker(arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            throw MigrationError.dockerFailed(command: Self.commandLine(arguments), message: Self.message(result))
        }
        return result.stdout
    }

    static func commandLine(_ arguments: [String]) -> String {
        (["docker", "--context", DockerReadOnlyPolicy.context] + arguments).map(shellQuoteIfNeeded).joined(separator: " ")
    }

    static func message(_ result: CLIResult) -> String {
        let text = result.stderrText.isEmpty ? result.stdoutText : result.stderrText
        return text.replacingOccurrences(of: "Error response from daemon: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Status

    public func status() async -> MigrationSourceStatus {
        guard await presence.isInstalled() else { return .notInstalled }
        guard await presence.isRunning() else { return .notRunning }
        guard docker != nil else { return .dockerUnavailable(MigrationError.dockerNotFound.localizedDescription) }
        do {
            let data = try await dockerOutput(["version", "--format", "json"], timeout: .seconds(10))
            let version = try? JSONDecoder().decode(RawDockerVersion.self, from: data.trimmingWhitespace())
            return .ready(dockerVersion: version?.Server?.Version)
        } catch MigrationError.orbStackNotRunning {
            return .notRunning
        } catch {
            return .dockerUnavailable(error.localizedDescription)
        }
    }

    // MARK: Images

    /// Every image OrbStack has (dangling and untagged ones included; callers hide them by default).
    public func listImages() async throws -> [OrbStackImage] {
        let lines = DockerFormat.decodeLines(
            RawDockerImageLine.self,
            from: try await dockerOutput(["image", "ls", "--all", "--digests", "--no-trunc", "--format", "json"]))
        let resolved = try await inspectImages(Array(Set(lines.compactMap(\.ID))).sorted())
        return lines.compactMap { line -> OrbStackImage? in
            guard let id = line.ID else { return nil }
            let repository = line.Repository ?? "<none>"
            let tag = line.Tag.flatMap { $0 == "<none>" || $0.isEmpty ? nil : $0 }
            let digest = (line.Digest.flatMap { $0 == "<none>" || $0.isEmpty ? nil : $0 }) ?? id
            let reference: String? = repository == "<none>" ? nil
                : tag.map { "\(repository):\($0)" } ?? "\(repository)@\(digest)"
            let image = resolved[id]
            let platform = image.flatMap(DockerFormat.platform(of:))
            return OrbStackImage(
                imageID: id, repository: repository, tag: tag, reference: reference,
                sizeBytes: platform != nil ? image?.Size ?? 0 : DockerFormat.parseSize(line.Size) ?? 0,
                createdAt: DockerFormat.parseDate(image?.Created) ?? DockerFormat.parseDate(line.CreatedAt),
                containerCount: Int(line.Containers ?? "") ?? 0, platform: platform)
        }
    }

    /// `image inspect` per image ID, for the platform an import would export: docker's default
    /// resolution (the host variant when OrbStack has it, else the only one), and for multi-platform
    /// indexes without local host content — where docker can't pick one and returns an empty config —
    /// the linux/amd64 variant (in practice what's there: pulled for, or by, an x86 workflow).
    func inspectImages(_ ids: [String]) async throws -> [String: RawDockerImage] {
        guard !ids.isEmpty else { return [:] }
        let result = try await docker(["image", "inspect"] + ids)
        let inspected = try DockerFormat.decodeArray(RawDockerImage.self, from: result.stdout, command: "docker image inspect")
        var images: [String: RawDockerImage] = [:]
        var unresolved: [String] = []
        for image in inspected {
            guard let id = image.Id else { continue }
            images[id] = image
            if DockerFormat.platform(of: image) == nil || (image.Size ?? 0) == 0 { unresolved.append(id) }
        }
        for (id, image) in try await resolve(unresolved, platform: "linux/amd64") {
            var merged = image
            merged.Created = merged.Created ?? images[id]?.Created
            images[id] = merged
        }
        return images
    }

    /// `image inspect --platform` for `ids`; the results are in request order, minus the ids docker
    /// reported as not providing the platform (named in stderr).
    func resolve(_ ids: [String], platform: String) async throws -> [(String, RawDockerImage)] {
        guard !ids.isEmpty else { return [] }
        let result = try await docker(["image", "inspect", "--platform", platform] + ids)
        let images = (try? DockerFormat.decodeArray(RawDockerImage.self, from: result.stdout, command: "docker image inspect")) ?? []
        let stderr = result.stderrText
        let found = ids.filter { !stderr.contains($0) }
        guard found.count == images.count else { return [] }  // can't pair them up safely
        return zip(found, images).filter { _, image in
            DockerFormat.platform(of: image) != nil && (image.Size ?? 0) > 0
        }
    }

    // MARK: Containers

    /// Every OrbStack container (any state) with its full configuration.
    public func listContainers() async throws -> [OrbStackContainer] {
        let lines = DockerFormat.decodeLines(
            RawDockerPSLine.self, from: try await dockerOutput(["ps", "--all", "--no-trunc", "--format", "json"]))
        let ids = lines.compactMap(\.ID)
        guard !ids.isEmpty else { return [] }
        let inspected = try DockerFormat.decodeArray(
            RawDockerContainer.self,
            from: try await docker(["inspect", "--type", "container"] + ids).stdout, command: "docker inspect")
        let images = try await inspectImages(Array(Set(inspected.compactMap(\.Image))).sorted())
        let byID = Dictionary(inspected.compactMap { raw in raw.Id.map { ($0, raw) } }, uniquingKeysWith: { first, _ in first })
        return lines.compactMap { line in
            guard let id = line.ID, let raw = byID[id] else { return nil }
            return Self.container(raw, line: line, image: raw.Image.flatMap { images[$0] })
        }
    }

    static func container(_ raw: RawDockerContainer, line: RawDockerPSLine?, image: RawDockerImage?) -> OrbStackContainer {
        let config = raw.Config
        let host = raw.HostConfig
        let name = (raw.Name ?? line?.Names ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var ports: [OrbStackPortBinding] = []
        let actual = raw.NetworkSettings?.Ports ?? [:]
        for (key, bindings) in (host?.PortBindings ?? [:]).sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: "/")
            guard let containerPort = parts.first.flatMap({ Int($0) }) else { continue }
            let proto = parts.count > 1 ? String(parts[1]) : "tcp"
            for binding in bindings ?? [] {
                var hostPort = binding.HostPort.flatMap { Int($0) }
                if hostPort == nil || hostPort == 0 {
                    // A random port Docker assigned at start: reuse it if the container is running.
                    hostPort = (actual[key] ?? nil)?.compactMap { $0.HostPort.flatMap { Int($0) } }.first
                }
                ports.append(OrbStackPortBinding(hostIP: binding.HostIp ?? "", hostPort: hostPort, containerPort: containerPort, proto: proto))
            }
        }

        var mounts: [OrbStackMount] = (raw.Mounts ?? []).map { mount in
            let kind = OrbStackMount.Kind(rawValue: mount.Type ?? "") ?? .other
            let source = kind == .volume ? (mount.Name ?? mount.Source ?? "") : (mount.Source ?? "")
            return OrbStackMount(
                kind: kind, source: source, destination: mount.Destination ?? "",
                readOnly: !(mount.RW ?? true), driver: mount.Driver)
        }
        for (path, options) in (host?.Tmpfs ?? [:]).sorted(by: { $0.key < $1.key })
        where !mounts.contains(where: { $0.destination == path }) {
            mounts.append(OrbStackMount(kind: .tmpfs, source: "", destination: path, readOnly: false, options: options.isEmpty ? nil : options))
        }

        var cpu = Double(host?.NanoCpus ?? 0) / 1e9
        if cpu == 0, let quota = host?.CpuQuota, quota > 0 {
            cpu = Double(quota) / Double((host?.CpuPeriod).flatMap { $0 > 0 ? $0 : nil } ?? 100_000)
        }

        var shared: [String] = []
        for (label, mode) in [("pid", host?.PidMode), ("ipc", host?.IpcMode), ("uts", host?.UTSMode), ("userns", host?.UsernsMode)] {
            if let mode, mode == "host" || mode.hasPrefix("container:") { shared.append("\(label)=\(mode)") }
        }
        let networkMode = host?.NetworkMode ?? "bridge"
        var networks: [String: [String]] = [:]
        var staticIPs: [String] = []
        for (network, endpoint) in raw.NetworkSettings?.Networks ?? [:] {
            networks[network] = endpoint.Aliases ?? []
            for address in [endpoint.IPAMConfig?.IPv4Address, endpoint.IPAMConfig?.IPv6Address].compactMap({ $0 }) where !address.isEmpty {
                staticIPs.append(address)
            }
        }
        let healthcheck = config?.Healthcheck?.Test ?? []

        let defaults = image.map { image in
            OrbStackContainer.ImageDefaults(
                environment: image.Config?.Env ?? [], entrypoint: image.Config?.Entrypoint, command: image.Config?.Cmd,
                workingDirectory: image.Config?.WorkingDir, user: image.Config?.User, labels: image.Config?.Labels ?? [:],
                platform: DockerFormat.platform(of: image))
        }

        return OrbStackContainer(
            id: raw.Id ?? line?.ID ?? name, name: name, image: config?.Image ?? line?.Image ?? "",
            imageID: raw.Image ?? "", state: raw.State?.Status ?? line?.State ?? "unknown", status: line?.Status ?? "",
            createdAt: DockerFormat.meaningfulDate(raw.Created) ?? DockerFormat.parseDate(line?.CreatedAt),
            ports: ports, environment: config?.Env ?? [], entrypoint: config?.Entrypoint, command: config?.Cmd,
            workingDirectory: config?.WorkingDir, user: config?.User, labels: config?.Labels ?? [:], mounts: mounts,
            restartPolicy: host?.RestartPolicy?.Name.flatMap { $0.isEmpty ? nil : $0 } ?? "no",
            memoryLimitBytes: host?.Memory ?? 0, cpuLimit: cpu, networkMode: networkMode, networks: networks,
            tty: config?.Tty ?? false, openStdin: config?.OpenStdin ?? false, autoRemove: host?.AutoRemove ?? false,
            initProcess: host?.Init ?? false, readOnlyRootFS: host?.ReadonlyRootfs ?? false,
            hostname: config?.Hostname, hasHealthcheck: !healthcheck.isEmpty && healthcheck != ["NONE"],
            privileged: host?.Privileged ?? false, capAdd: host?.CapAdd ?? [], capDrop: host?.CapDrop ?? [],
            devices: (host?.Devices ?? []).compactMap(\.PathOnHost),
            gpuRequests: (host?.DeviceRequests ?? []).count, dns: host?.Dns ?? [], dnsSearch: host?.DnsSearch ?? [],
            dnsOptions: host?.DnsOptions ?? [], extraHosts: host?.ExtraHosts ?? [], links: host?.Links ?? [],
            securityOptions: host?.SecurityOpt ?? [],
            ulimits: (host?.Ulimits ?? []).compactMap { limit in
                guard let name = limit.Name else { return nil }
                return "\(name)=\(limit.Soft ?? 0):\(limit.Hard ?? limit.Soft ?? 0)"
            },
            sysctls: host?.Sysctls ?? [:], staticIPs: staticIPs.sorted(), sharedNamespaces: shared,
            volumesFrom: host?.VolumesFrom ?? [], publishAll: host?.PublishAllPorts ?? false,
            exposedPorts: (config?.ExposedPorts ?? [:]).keys.sorted(), imageDefaults: defaults)
    }

    // MARK: Cross-referencing with Basket

    /// Basket references (normalized) currently in Basket's image list.
    public static func basketReferences(_ images: [ImageSummary]) -> Set<String> {
        Set(images.map { normalizeImageReference($0.reference) })
    }

    /// Whether Basket lists an image under `image`'s reference. A name match alone says nothing about
    /// the content: see `basketPresence(of:basket:backend:)`.
    public static func nameIsTaken(_ image: OrbStackImage, basket: Set<String>) -> Bool {
        image.basketReference.map(basket.contains) ?? false
    }

    /// What deleting the OrbStack copies of images verified to be in Basket could free: images no
    /// OrbStack container uses whose every reference has identical content in Basket (`presence`,
    /// keyed by `OrbStackImage.id`). Name-only matches never count. Sizes are per image ID (layers
    /// shared with other images are freed only when nothing else uses them, so this is an upper bound).
    public static func reclaimable(_ images: [OrbStackImage], presence: [String: BasketPresence]) -> (references: [String], bytes: Int64) {
        let byID = Dictionary(grouping: images, by: \.imageID)
        var references: [String] = []
        var bytes: Int64 = 0
        for (_, group) in byID.sorted(by: { $0.key < $1.key }) {
            let named = group.filter { !$0.isDangling }
            guard !named.isEmpty, group.allSatisfy({ $0.containerCount == 0 }),
                  named.allSatisfy({ presence[$0.id] == .identical })
            else { continue }
            references += named.compactMap(\.reference)
            bytes += group.map(\.sizeBytes).max() ?? 0
        }
        return (references.sorted(), bytes)
    }

    /// The command a user can run to delete `references` from OrbStack (Basket never runs it).
    public static func removalCommand(_ references: [String]) -> String {
        (["docker", "--context", DockerReadOnlyPolicy.context, "image", "rm"] + references.map(shellQuoteIfNeeded))
            .joined(separator: " ")
    }
}
