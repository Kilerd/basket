import Foundation

public struct ComposePlanOptions: Sendable {
    /// Overrides `name:` / `COMPOSE_PROJECT_NAME` / the directory name.
    public var projectName: String?
    /// Memory for services without a limit. Every container is its own VM, so "unlimited" isn't a thing.
    public var defaultMemory: String
    /// CPUs for services without `cpus`; nil = the container system's default.
    public var defaultCPUs: Int?
    /// Profiles to enable in addition to `COMPOSE_PROFILES`.
    public var activeProfiles: Set<String>
    /// Missing bind sources are created by `up` (like Compose); injected for tests.
    public var hostPathExists: @Sendable (String) -> Bool
    public var homeDirectory: String

    public init(
        projectName: String? = nil, defaultMemory: String = "512M", defaultCPUs: Int? = nil,
        activeProfiles: Set<String> = [],
        hostPathExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.projectName = projectName
        self.defaultMemory = defaultMemory
        self.defaultCPUs = defaultCPUs
        self.activeProfiles = activeProfiles
        self.hostPathExists = hostPathExists
        self.homeDirectory = homeDirectory
    }
}

/// What `up` will do for one compose file: resources to create and one `container run` per service.
public struct ComposePlan: Sendable, Hashable {
    public struct Network: Sendable, Hashable {
        public var key: String
        public var name: String
        public var external: Bool
        public var subnet: String?
        public var labels: [String: String]
    }

    public struct Volume: Sendable, Hashable {
        public var key: String
        public var name: String
        public var external: Bool
        public var labels: [String: String]
    }

    public struct Service: Sendable, Hashable, Identifiable {
        public var name: String
        public var spec: RunSpec
        public var containerName: String { spec.name ?? name }
        public var id: String { name }
        /// Services started before this one.
        public var dependsOn: [String]
        /// Names the project's containers resolve to this one (service name first).
        public var hostNames: [String]
        public var memoryBytes: Int64
        /// No limit in the file; `ComposePlanOptions.defaultMemory` applies.
        public var memoryIsDefault: Bool
        /// Host directories `up` creates for bind mounts that don't exist yet.
        public var bindDirectories: [String]
        /// "8080→80", for the plan table.
        public var portsSummary: String
    }

    public struct Resources: Sendable, Hashable {
        public var services: Int
        /// Σ memory limits: what the guests may use.
        public var memoryLimitBytes: Int64
        /// Σ estimated VM overhead (see `MemoryInsights.Model`), paid on top of guest usage.
        public var overheadBytes: Int64
        /// Σ explicit CPUs (services using the system default are counted in `defaultCPUServices`).
        public var cpus: Int
        public var defaultCPUServices: Int
    }

    public var project: String
    public var workingDirectory: String
    public var configFiles: [String]
    public var networks: [Network]
    public var volumes: [Volume]
    /// In start order (dependencies first).
    public var services: [Service]
    /// Services left out because their profile isn't active.
    public var skippedServices: [String]
    public var warnings: [ComposeWarning]
    public var resources: Resources

    /// The plan as `container` command lines, in execution order.
    public func commandLines(cli: String = "container") -> [String] {
        var lines: [String] = []
        for network in networks where !network.external {
            let subnet = network.subnet.map { ["--subnet", $0] } ?? []
            lines.append(Self.line(cli, ["network", "create"] + subnet + CLIBackend.labelArguments(network.labels) + [network.name]))
        }
        for volume in volumes where !volume.external {
            lines.append(Self.line(cli, ["volume", "create"] + CLIBackend.labelArguments(volume.labels) + [volume.name]))
        }
        for service in services {
            lines.append(Self.line(cli, CLIBackend.runArguments(service.spec)))
        }
        if !services.isEmpty {
            lines.append("# then, in each container: \(cli) exec --user 0 <name> sh -c '…' — writes the service names into /etc/hosts")
        }
        return lines
    }

    public func commandLine(for service: Service, cli: String = "container") -> String {
        Self.line(cli, CLIBackend.runArguments(service.spec))
    }

    static func line(_ cli: String, _ arguments: [String]) -> String {
        ([cli] + arguments.map(shellQuoteIfNeeded)).joined(separator: " ")
    }
}

/// Turns a `ComposeFile` into a `ComposePlan` with Compose's naming (`<project>-<service>-1`,
/// `<project>_default`, `<project>_<volume>`) and labels.
public enum ComposePlanner {
    public static let defaultNetworkKey = "default"

    public static func plan(_ file: ComposeFile, options: ComposePlanOptions = ComposePlanOptions()) throws -> ComposePlan {
        let project = try projectName(file, override: options.projectName)
        var warnings = file.warnings
        let configFiles = file.configFile.map { [$0.path] } ?? []
        let workingDirectory = file.workingDirectory.path

        // Profiles: services with profiles only run when one is active, or when an active service needs them.
        let profiles = options.activeProfiles.union(
            (file.environment["COMPOSE_PROFILES"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        var active = Set(file.services.filter { $0.profiles.isEmpty || !profiles.isDisjoint(with: $0.profiles) }.map(\.name))
        var queue = Array(active)
        while let name = queue.popLast() {
            guard let service = file.service(name) else { continue }
            for dependency in service.dependsOn.map(\.service) + service.links.map(\.name)
            where !active.contains(dependency) && file.service(dependency) != nil {
                active.insert(dependency)
                queue.append(dependency)
                warnings.append(ComposeWarning(.info, service: dependency, "Profiles", "Started although its profile isn't active, because \(name) depends on it."))
            }
        }
        let skipped = file.services.map(\.name).filter { !active.contains($0) }
        if !skipped.isEmpty {
            warnings.append(ComposeWarning(
                .info, "Profiles", "Not started (profile not active): \(skipped.localizedList). Set COMPOSE_PROFILES to include them."))
        }
        let ordered = try startOrder(file.services.filter { active.contains($0.name) })
        if ordered.isEmpty {
            throw ComposeError.invalid(at: "services", "every service belongs to an inactive profile")
        }

        // Networks the active services use: the default one first, then in declaration order.
        let used = Set(ordered.flatMap { ($0.networks ?? [.init(name: defaultNetworkKey, aliases: [], ipv4Address: nil)]).map(\.name) })
        let networkKeys = ([defaultNetworkKey] + file.networks.map(\.key)).reduce(into: [String]()) {
            if used.contains($1), !$0.contains($1) { $0.append($1) }
        }
        let networks = networkKeys.map { key -> ComposePlan.Network in
            let declared = file.networks.first { $0.key == key }
            let external = declared?.external ?? false
            let name = declared?.name ?? (external ? key : "\(project)_\(key)")
            var labels = declared?.labels ?? [:]
            if !external {
                labels[ComposeLabels.project] = project
                labels[ComposeLabels.network] = key
                labels[ComposeLabels.basket] = "1"
            }
            return .init(key: key, name: name, external: external, subnet: declared?.subnet, labels: labels)
        }
        let networkNames = Dictionary(uniqueKeysWithValues: networks.map { ($0.key, $0.name) })

        var volumes: [ComposePlan.Volume] = []
        func addVolume(key: String, declared: ComposeVolume?) -> String {
            let external = declared?.external ?? false
            let name = declared?.name ?? (external ? key : "\(project)_\(key)")
            if !volumes.contains(where: { $0.name == name }) {
                var labels = declared?.labels ?? [:]
                if !external {
                    labels[ComposeLabels.project] = project
                    labels[ComposeLabels.volume] = key
                    labels[ComposeLabels.basket] = "1"
                }
                volumes.append(.init(key: key, name: name, external: external, labels: labels))
            }
            return name
        }

        // Host names: service name, container name, network aliases, link aliases, hostname.
        var aliases: [String: [String]] = [:]
        for service in ordered {
            for link in service.links where link.value != link.name { aliases[link.name, default: []].append(link.value) }
        }

        let model = MemoryInsights.Model.measured
        var services: [ComposePlan.Service] = []
        var defaultMemoryServices: [String] = []
        var resources = ComposePlan.Resources(services: 0, memoryLimitBytes: 0, overheadBytes: 0, cpus: 0, defaultCPUServices: 0)
        let defaultMemoryBytes = parseByteSize(options.defaultMemory) ?? 512 << 20

        for service in ordered {
            var notes: [ComposeWarning] = service.warnings
            func warn(_ topic: LocalizedStringResource, _ message: LocalizedStringResource) { notes.append(ComposeWarning(.warning, service: service.name, topic, message)) }
            func note(_ topic: LocalizedStringResource, _ message: LocalizedStringResource) { notes.append(ComposeWarning(.info, service: service.name, topic, message)) }
            func warn(key: String, _ message: LocalizedStringResource) { notes.append(ComposeWarning(.warning, service: service.name, key: key, message)) }

            let containerName = service.containerName ?? "\(project)-\(service.name)-1"
            let image: String
            if let declared = service.image {
                image = declared
                if let build = service.build {
                    note("Build", "Basket doesn't build images; it runs \(declared). Build it first if it isn't in a registry: container build -t \(declared) \(build.context)")
                }
            } else {
                image = "\(project)-\(service.name)"
                let context = service.build?.context ?? "."
                warn("Build", "Basket doesn't build images. Build it first: container build -t \(image) \(context) — then Up runs it.")
            }

            var spec = RunSpec(image: image, name: containerName)
            if let entrypoint = service.entrypoint {
                spec.entrypoint = entrypoint.first ?? ""
                spec.command = Array(entrypoint.dropFirst()) + (service.command ?? [])
            } else {
                spec.command = service.command ?? []
            }

            // Resources: memory is always explicit (the VM's size), shown in the plan.
            let memoryBytes = service.memoryBytes ?? defaultMemoryBytes
            spec.memory = service.memoryBytes.map(memoryFlag) ?? options.defaultMemory
            if service.memoryBytes == nil { defaultMemoryServices.append(service.name) }
            if let cpus = service.cpus {
                let whole = max(1, Int(cpus.rounded(.up)))
                spec.cpus = whole
                if Double(whole) != cpus { note("CPUs", "cpus: \(YAMLValue.format(cpus)) is rounded up to \(whole): containers get whole CPUs.") }
                resources.cpus += whole
            } else if let cpus = options.defaultCPUs {
                spec.cpus = cpus
                resources.cpus += cpus
            } else {
                resources.defaultCPUServices += 1
            }
            resources.memoryLimitBytes += memoryBytes
            resources.overheadBytes += model.overheadBytes(forLimit: memoryBytes)

            // Ports.
            var portsSummary: [String] = []
            for port in service.ports {
                let (publish, summary) = try publishSpecs(port, service: service.name)
                spec.ports += publish
                portsSummary.append(summary)
                if port.published == nil {
                    note("Ports", "Port \(port.target) has no host port in the file; it's published on the same number (\(port.target)).")
                }
            }

            // Mounts.
            var bindDirectories: [String] = []
            for (index, mount) in service.mounts.enumerated() {
                switch mount.kind {
                case .bind:
                    let host = resolveHostPath(mount.source ?? "", base: file.workingDirectory.path, home: options.homeDirectory)
                    if !options.hostPathExists(host) {
                        bindDirectories.append(host)
                        note("Bind mount", "\(host) doesn't exist; Up creates it as an empty directory.")
                    }
                    spec.volumes.append("\(host):\(mount.target)" + (mount.readOnly ? ":ro" : ""))
                case .volume:
                    let name: String
                    if let key = mount.source {
                        name = addVolume(key: key, declared: file.volumes.first { $0.key == key })
                    } else {
                        let key = "\(service.name)_" + sanitize(mount.target, fallback: "data\(index)")
                        name = addVolume(key: key, declared: nil)
                        note("Anonymous volume", "\(mount.target) gets the named volume \(name), so it survives restarts; Down with volumes removes it.")
                    }
                    spec.volumes.append("\(name):\(mount.target)" + (mount.readOnly ? ":ro" : ""))
                case .tmpfs:
                    spec.tmpfs.append(mount.target)
                }
            }
            spec.tmpfs += service.tmpfs
            spec.environment = service.environment

            // Networks.
            let attached = (service.networks ?? [.init(name: defaultNetworkKey, aliases: [], ipv4Address: nil)])
            let names = attached.compactMap { networkNames[$0.name] }
            spec.network = names.first
            spec.additionalNetworks = Array(names.dropFirst())

            var hostNames = [service.name, containerName]
            if containerName != "\(project)-\(service.name)-1" { hostNames.append("\(project)-\(service.name)-1") }
            hostNames += [service.hostname].compactMap { $0 } + attached.flatMap(\.aliases) + (aliases[service.name] ?? [])
            hostNames = hostNames.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }

            // Labels: Compose's own, so other tools recognise the project, plus Basket's.
            var labels = service.labels
            labels[ComposeLabels.project] = project
            labels[ComposeLabels.service] = service.name
            labels[ComposeLabels.containerNumber] = "1"
            labels[ComposeLabels.oneoff] = "False"
            labels[ComposeLabels.workingDir] = workingDirectory
            if !configFiles.isEmpty { labels[ComposeLabels.configFiles] = configFiles.joined(separator: ",") }
            let dependencies = service.dependsOn.filter { active.contains($0.service) }
            if !dependencies.isEmpty {
                labels[ComposeLabels.dependsOn] = dependencies.map { "\($0.service):\($0.condition):false" }.joined(separator: ",")
            }
            labels[ComposeLabels.basket] = "1"
            let extraNames = hostNames.filter { $0 != service.name && $0 != containerName }
            if !extraNames.isEmpty { labels[ComposeLabels.aliases] = extraNames.joined(separator: ",") }
            if !service.extraHosts.isEmpty {
                labels[ComposeLabels.extraHosts] = service.extraHosts.map { "\($0.name)=\($0.value)" }.joined(separator: ",")
            }
            spec.labels = labels

            spec.workingDirectory = service.workingDir
            spec.user = service.user
            spec.capAdd = service.capAdd
            spec.capDrop = service.capDrop
            spec.readOnlyRootFilesystem = service.readOnly
            spec.initProcess = service.initProcess
            spec.dns = service.dns
            spec.dnsSearch = service.dnsSearch
            spec.shmSize = service.shmSize
            spec.ulimits = service.ulimits
            spec.interactive = service.stdinOpen
            spec.tty = service.tty
            if let platform = service.platform {
                spec.platform = platform
                if !platform.hasPrefix("linux/arm64") {
                    note("Platform", "\(platform) runs under Rosetta on this Mac, which is slower than a native arm64 image.")
                }
            }
            for dependency in dependencies where dependency.condition != "service_started" {
                warn(key: "depends_on", "\(dependency.service) is started first, but “\(dependency.condition)” can't be checked (no healthchecks); \(service.name) starts as soon as \(dependency.service) has started.")
            }

            warnings += notes
            services.append(.init(
                name: service.name, spec: spec, dependsOn: dependencies.map(\.service), hostNames: hostNames,
                memoryBytes: memoryBytes, memoryIsDefault: service.memoryBytes == nil, bindDirectories: bindDirectories,
                portsSummary: portsSummary.joined(separator: ", ")))
        }
        resources.services = services.count

        if !defaultMemoryServices.isEmpty {
            let memory = options.defaultMemory
            let message: LocalizedStringResource
            if defaultMemoryServices.count == 1 {
                message = "\(defaultMemoryServices[0]) sets no memory limit. Each container is its own VM, so it gets \(memory); set mem_limit to change it."
            } else if defaultMemoryServices.count == ordered.count {
                message = "No service sets a memory limit. Each container is its own VM, so they get \(memory) each; set mem_limit to change it."
            } else {
                message = "\(defaultMemoryServices.localizedList) set no memory limit. Each container is its own VM, so they get \(memory) each; set mem_limit to change it."
            }
            warnings.insert(ComposeWarning(.info, "Memory", message), at: 0)
        }
        warnings.insert(ComposeWarning(
            .info, "Service names",
            "apple/container has no DNS between containers. After starting the project Basket writes every service name into /etc/hosts of each container (container exec … sh). Images without a shell can't be updated, and the entries are only refreshed when Basket starts or restarts a container."),
            at: 0)

        return ComposePlan(
            project: project, workingDirectory: workingDirectory, configFiles: configFiles, networks: networks,
            volumes: volumes, services: services, skippedServices: skipped, warnings: warnings, resources: resources)
    }

    // MARK: Naming

    /// `options` → `COMPOSE_PROJECT_NAME` → `name:` → the directory, normalised like Compose:
    /// lower case, only `a-z 0-9 _ -`, no leading `_`/`-`.
    public static func projectName(_ file: ComposeFile, override: String? = nil) throws -> String {
        let candidates = [override, file.environment["COMPOSE_PROJECT_NAME"], file.name, file.workingDirectory.lastPathComponent]
        for candidate in candidates.compactMap({ $0 }) where !candidate.isEmpty {
            let normalized = normalizeProjectName(candidate)
            guard !normalized.isEmpty else { continue }
            return normalized
        }
        throw ComposeError.invalid(at: "name", "can't derive a project name; set “name:” in the file")
    }

    public static func normalizeProjectName(_ name: String) -> String {
        let kept = String(name.lowercased().unicodeScalars.filter {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        })
        return String(kept.drop { $0 == "_" || $0 == "-" })
    }

    // MARK: Order

    /// Dependencies first; otherwise file order. Throws on cycles.
    static func startOrder(_ services: [ComposeService]) throws -> [ComposeService] {
        let names = Set(services.map(\.name))
        var remaining = services
        var done: [ComposeService] = []
        var placed: Set<String> = []
        while !remaining.isEmpty {
            guard let index = remaining.firstIndex(where: { service in
                (service.dependsOn.map(\.service) + service.links.map(\.name)).allSatisfy { !names.contains($0) || placed.contains($0) }
            }) else {
                throw ComposeError.dependencyCycle(cycle(in: remaining))
            }
            let next = remaining.remove(at: index)
            done.append(next)
            placed.insert(next.name)
        }
        return done
    }

    private static func cycle(in services: [ComposeService]) -> [String] {
        let byName = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0) })
        var path: [String] = []
        var current = services[0].name
        while !path.contains(current), let service = byName[current] {
            path.append(current)
            guard let next = (service.dependsOn.map(\.service) + service.links.map(\.name)).first(where: { byName[$0] != nil }) else { break }
            current = next
        }
        guard let start = path.firstIndex(of: current) else { return path }
        return Array(path[start...]) + [current]
    }

    // MARK: Values

    /// Bytes → the CLI's `--memory` format, rounded up to whole MiB ("512M", "2G").
    public static func memoryFlag(_ bytes: Int64) -> String {
        let mebibytes = max(1, (bytes + 1_048_575) / 1_048_576)
        return mebibytes % 1024 == 0 ? "\(mebibytes / 1024)G" : "\(mebibytes)M"
    }

    /// `--publish` values for one port entry (ranges expand to one flag per port).
    static func publishSpecs(_ port: ComposePort, service: String) throws -> ([String], String) {
        func bounds(_ text: String) -> ClosedRange<Int>? {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard let low = parts.first else { return nil }
            let high = parts.count > 1 ? parts[1] : low
            return low <= high ? low...high : nil
        }
        guard let targets = bounds(port.target), let hosts = bounds(port.published ?? port.target),
              hosts.count == targets.count || hosts.count >= targets.count && targets.count == 1
        else {
            throw ComposeError.invalid(at: "services.\(service).ports", "can't map \(port.published ?? "?") to \(port.target)")
        }
        guard targets.count <= 100 else {
            throw ComposeError.invalid(at: "services.\(service).ports", "port range \(port.target) is larger than 100 ports")
        }
        let proto = port.proto.lowercased() == "udp" ? "/udp" : ""
        let ip = port.hostIP.map { $0.contains(":") ? "[\($0)]:" : "\($0):" } ?? ""
        let specs = zip(hosts, targets).map { "\(ip)\($0):\($1)\(proto)" }
        let summary = targets.count == 1
            ? "\(hosts.lowerBound)→\(targets.lowerBound)\(proto)"
            : "\(hosts.lowerBound)-\(hosts.lowerBound + targets.count - 1)→\(port.target)\(proto)"
        return (specs, summary)
    }

    static func resolveHostPath(_ source: String, base: String, home: String) -> String {
        var path = source
        if path == "~" || path.hasPrefix("~/") { path = home + path.dropFirst() }
        if !path.hasPrefix("/") { path = base + "/" + path }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// "/var/lib/data" → "var-lib-data" (volume names allow `[A-Za-z0-9_.-]`).
    static func sanitize(_ path: String, fallback: String) -> String {
        let parts = path.split(separator: "/").map { part in
            String(part.unicodeScalars.map { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == ".") ? Character($0) : "-" })
        }
        let joined = parts.joined(separator: "-")
        return joined.isEmpty ? fallback : joined
    }
}
