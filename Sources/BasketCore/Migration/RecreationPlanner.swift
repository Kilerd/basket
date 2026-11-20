import Foundation

/// Maps a Docker container configuration (`docker inspect`) onto `container run` flags, collecting a
/// warning for everything apple/container 1.7 can't express.
public enum RecreationPlanner {
    public static func plan(
        for container: OrbStackContainer, image: OrbStackImage? = nil, options: RecreationOptions = RecreationOptions()
    ) -> RecreationPlan {
        var builder = Builder()
        let name = options.name.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } ?? container.name
        builder.arguments = ["run", "--detach", "--name", name]

        let reference = imageReference(container, image: image, builder: &builder)
        resources(container, options: options, builder: &builder)
        platform(container, image: image, builder: &builder)
        process(container, builder: &builder)
        ports(container, builder: &builder)
        mounts(container, options: options, builder: &builder)
        network(container, builder: &builder)
        security(container, builder: &builder)
        lifecycle(container, builder: &builder)

        var arguments = builder.arguments
        arguments.append(reference)
        arguments += builder.processArguments

        let spec = RunSpec(
            image: reference, name: name, command: builder.processArguments, cpus: builder.cpus, memory: builder.memory,
            ports: builder.ports, volumes: builder.volumeSpecs, environment: builder.environment, network: nil,
            removeOnExit: container.autoRemove, rosetta: false, platform: builder.platform)
        return RecreationPlan(
            name: name, image: reference, volumes: builder.volumes, runArguments: arguments, runSpec: spec,
            warnings: builder.warnings)
    }

    struct Builder {
        var arguments: [String] = []
        var processArguments: [String] = []
        var warnings: [MigrationWarning] = []
        var cpus: Int?
        var memory: String?
        var platform: String?
        var ports: [String] = []
        var volumes: [String] = []
        var volumeSpecs: [String] = []
        var environment: [String] = []

        mutating func flag(_ name: String, _ value: String) { arguments += [name, value] }
        mutating func warn(_ topic: String, _ message: String) { warnings.append(MigrationWarning(.warning, topic, message)) }
        mutating func note(_ topic: String, _ message: String) { warnings.append(MigrationWarning(.info, topic, message)) }
    }

    static func list(_ items: [String]) -> String { items.joined(separator: ", ") }

    // MARK: Sections

    static func imageReference(_ container: OrbStackContainer, image: OrbStackImage?, builder: inout Builder) -> String {
        let typed = container.image
        // Created from an image ID: use the image's name if OrbStack still has one.
        if typed.isEmpty || typed.hasPrefix("sha256:") || typed.allSatisfy(\.isHexDigit) {
            if let reference = image?.basketReference { return reference }
            builder.warn("Image", "The container was created from image ID \(typed); there is no name to run it by in Basket.")
            return typed
        }
        return normalizeImageReference(typed)
    }

    static func resources(_ container: OrbStackContainer, options: RecreationOptions, builder: inout Builder) {
        if container.cpuLimit > 0 {
            let cpus = max(1, Int(container.cpuLimit.rounded(.up)))
            builder.cpus = cpus
            builder.flag("--cpus", String(cpus))
            if Double(cpus) != container.cpuLimit {
                builder.note("CPUs", "Docker limited it to \(container.cpuLimit.formatted()) CPUs; Basket allocates whole CPUs (\(cpus)).")
            }
        }
        let memory: String
        if container.memoryLimitBytes > 0 {
            let mebibytes = (container.memoryLimitBytes + 1_048_575) / 1_048_576
            memory = mebibytes % 1024 == 0 ? "\(mebibytes / 1024)G" : "\(mebibytes)M"
        } else {
            memory = options.defaultMemory
            builder.note("Memory", "Docker had no memory limit. Every Basket container is its own VM, so it gets \(memory); raise it if the workload needs more.")
        }
        builder.memory = memory
        builder.flag("--memory", memory)
    }

    static func platform(_ container: OrbStackContainer, image: OrbStackImage?, builder: inout Builder) {
        guard let platform = image?.platform ?? container.imageDefaults?.platform, !MigrationPlatform.isHost(platform) else { return }
        let base = platform.split(separator: "/").prefix(2).joined(separator: "/")
        builder.platform = base
        builder.flag("--platform", base)
        builder.warn("Platform", "OrbStack only has the \(base) variant of this image, so it runs under Rosetta. Pull the \(MigrationPlatform.host) variant for native speed.")
    }

    static func process(_ container: OrbStackContainer, builder: inout Builder) {
        let defaults = container.imageDefaults
        if container.openStdin { builder.arguments.append("--interactive") }
        if container.tty { builder.arguments.append("--tty") }
        if let user = container.user, !user.isEmpty, user != (defaults?.user ?? "") { builder.flag("--user", user) }
        if let directory = container.workingDirectory, !directory.isEmpty, directory != (defaults?.workingDirectory ?? "") {
            builder.flag("--workdir", directory)
        }

        // Only variables the user set: the image supplies its own defaults again in Basket.
        let inherited = Set(defaults?.environment ?? [])
        var bare: [String] = []
        for variable in container.environment where !inherited.contains(variable) {
            // A bare `KEY` (no "=") means "not set" to Docker. `--env KEY` would instead copy KEY from
            // the environment of whatever runs `container run` (Basket itself, or the user's shell for
            // the copied command), and `--env KEY=` would set it to an empty string: leave it out.
            guard variable.contains("=") else {
                bare.append(variable)
                continue
            }
            builder.environment.append(variable)
            builder.flag("--env", variable)
        }
        if !bare.isEmpty {
            builder.warn("Environment", "Docker lists \(bare.joined(separator: ", ")) without a value, which leaves \(bare.count == 1 ? "it" : "them") unset; \(bare.count == 1 ? "it is" : "they are") left out rather than passed as --env \(bare.count == 1 ? "NAME" : "NAMES"), which would copy \(bare.count == 1 ? "a value" : "values") from the environment `container run` is started in.")
        }
        let imageLabels = defaults?.labels ?? [:]
        for (key, value) in container.labels.sorted(by: { $0.key < $1.key }) where imageLabels[key] != value {
            builder.flag("--label", "\(key)=\(value)")
        }

        let entrypoint = container.entrypoint ?? []
        let command = container.command ?? []
        guard let defaults else {
            // Image config unknown: spell out the whole process.
            if let first = entrypoint.first {
                builder.flag("--entrypoint", first)
                builder.processArguments = Array(entrypoint.dropFirst()) + command
            } else {
                builder.processArguments = command
            }
            return
        }
        if entrypoint != (defaults.entrypoint ?? []) {
            if let first = entrypoint.first {
                builder.flag("--entrypoint", first)
                builder.processArguments = Array(entrypoint.dropFirst()) + command
            } else if let first = command.first {
                // The entrypoint was cleared: run the command itself as the entrypoint.
                builder.flag("--entrypoint", first)
                builder.processArguments = Array(command.dropFirst())
            }
        } else if command != (defaults.command ?? []) {
            builder.processArguments = command
        }
    }

    static func ports(_ container: OrbStackContainer, builder: inout Builder) {
        var seen = Set<String>()
        var randomized: [String] = []
        var skipped: [String] = []
        for binding in container.ports {
            let hostPort = binding.hostPort ?? binding.containerPort
            if binding.hostPort == nil { randomized.append("\(binding.containerPort)") }
            let address: String
            switch binding.hostIP {
            case "", "0.0.0.0", "::": address = ""
            case let ip where ip.contains(":"):
                skipped.append("[\(ip)]:\(hostPort)")
                continue
            default: address = binding.hostIP + ":"
            }
            let spec = "\(address)\(hostPort):\(binding.containerPort)" + (binding.proto == "tcp" ? "" : "/\(binding.proto)")
            guard seen.insert(spec).inserted else { continue }
            builder.ports.append(spec)
            builder.flag("--publish", spec)
        }
        if !randomized.isEmpty {
            builder.note("Ports", "Docker picked random host ports for \(list(randomized)); Basket publishes them on the same port numbers.")
        }
        if !skipped.isEmpty {
            builder.warn("Ports", "IPv6-only bindings (\(list(skipped))) aren't recreated.")
        }
        if container.publishAll {
            // `-P` maps every exposed port to a random host port; Basket needs explicit ones.
            var published: [String] = []
            for exposed in container.exposedPorts {
                let parts = exposed.split(separator: "/")
                guard let port = parts.first.flatMap({ Int($0) }) else { continue }
                let proto = parts.count > 1 ? String(parts[1]) : "tcp"
                let spec = "\(port):\(port)" + (proto == "tcp" ? "" : "/\(proto)")
                guard seen.insert(spec).inserted else { continue }
                builder.ports.append(spec)
                builder.flag("--publish", spec)
                published.append(spec)
            }
            builder.note("Ports", published.isEmpty
                ? "Docker published all exposed ports (-P), but the image exposes none."
                : "Docker published all exposed ports on random host ports (-P); Basket publishes \(list(published)) on the same port numbers.")
        }
        if container.isRunning, !builder.ports.isEmpty {
            builder.warn("Ports", "The OrbStack container is running and holds \(list(builder.ports)). Stop it in OrbStack before starting the Basket copy, or change the ports.")
        }
    }

    static func mounts(_ container: OrbStackContainer, options: RecreationOptions, builder: inout Builder) {
        var anonymous: [String] = []
        var missing: [String] = []
        for mount in container.mounts {
            let suffix = mount.readOnly ? ":ro" : ""
            switch mount.kind {
            case .bind:
                if mount.source.hasSuffix("docker.sock") {
                    builder.warn("Docker socket", "\(mount.source) is mounted, but Basket has no Docker engine; the mount is left out.")
                } else if !options.hostPathExists(mount.source) {
                    missing.append(mount.source)
                } else {
                    let spec = "\(mount.source):\(mount.destination)\(suffix)"
                    builder.volumeSpecs.append(spec)
                    builder.flag("--volume", spec)
                }
            case .volume where mount.isAnonymousVolume:
                anonymous.append(mount.destination)
            case .volume:
                if let driver = mount.driver, !driver.isEmpty, driver != "local" {
                    builder.warn("Volumes", "Volume \(mount.source) uses the “\(driver)” driver; Basket creates a local volume instead.")
                }
                if !builder.volumes.contains(mount.source) { builder.volumes.append(mount.source) }
                let spec = "\(mount.source):\(mount.destination)\(suffix)"
                builder.volumeSpecs.append(spec)
                builder.flag("--volume", spec)
            case .tmpfs:
                builder.flag("--tmpfs", mount.destination)
                if let options = mount.options {
                    builder.note("tmpfs", "tmpfs options for \(mount.destination) (\(options)) aren't supported; Basket uses its defaults.")
                }
            case .other:
                builder.warn("Mounts", "The mount at \(mount.destination) isn't a bind, volume or tmpfs mount and is left out.")
            }
        }
        if !builder.volumes.isEmpty {
            builder.warn("Volume data", "Volume data isn't copied: Basket creates empty volumes named \(list(builder.volumes)). Copy the data over yourself if you need it.")
        }
        if !anonymous.isEmpty {
            builder.warn("Volume data", "Anonymous volumes at \(list(anonymous)) aren't recreated; their data stays in OrbStack and the container starts with what the image has there.")
        }
        if !missing.isEmpty {
            builder.warn("Bind mounts", "\(list(missing)) \(missing.count == 1 ? "doesn't" : "don't") exist on this Mac (\(missing.count == 1 ? "it may be a path" : "they may be paths") inside OrbStack's Linux machine), so \(missing.count == 1 ? "it is" : "they are") left out.")
        }
        if !container.volumesFrom.isEmpty {
            builder.warn("Volumes", "--volumes-from \(list(container.volumesFrom)) isn't supported.")
        }
    }

    static func network(_ container: OrbStackContainer, builder: inout Builder) {
        let mode = container.networkMode
        switch mode {
        case "", "bridge", "default":
            break
        case "host":
            builder.warn("Network", "Host networking isn't supported: the container gets its own IP on Basket's default network. Publish the ports it listens on instead.")
        case "none":
            builder.warn("Network", "Disabling networking isn't supported; the container joins Basket's default network.")
        case let other where other.hasPrefix("container:"):
            builder.warn("Network", "Sharing another container's network (\(other)) isn't supported.")
        default:
            builder.warn("Network", "Docker network “\(mode)” isn't recreated: the container joins Basket's default network, and other containers can't reach it by name.")
        }
        let shortID = String(container.id.prefix(12))
        let aliases = container.networks.flatMap { network, aliases in
            network == "bridge" ? [] : aliases.filter { $0 != container.name && $0 != shortID && $0 != container.id }
        }
        if !aliases.isEmpty { builder.warn("Network", "Network aliases (\(list(Array(Set(aliases)).sorted()))) aren't supported.") }
        if !container.links.isEmpty { builder.warn("Network", "Legacy links (\(list(container.links))) aren't supported.") }
        if !container.staticIPs.isEmpty { builder.warn("Network", "Static IP addresses (\(list(container.staticIPs))) aren't supported.") }
        if !container.extraHosts.isEmpty {
            builder.warn("Network", "Extra /etc/hosts entries (\(list(container.extraHosts))) aren't supported.")
        }
        for server in container.dns { builder.flag("--dns", server) }
        for domain in container.dnsSearch { builder.flag("--dns-search", domain) }
        for option in container.dnsOptions { builder.flag("--dns-option", option) }
    }

    static func security(_ container: OrbStackContainer, builder: inout Builder) {
        if container.privileged {
            builder.warn("Privileged", "Privileged mode isn't supported; the container runs unprivileged. Grant specific capabilities with --cap-add if it needs them.")
        }
        for capability in container.capAdd { builder.flag("--cap-add", capability) }
        for capability in container.capDrop { builder.flag("--cap-drop", capability) }
        if !container.devices.isEmpty {
            builder.warn("Devices", "Device passthrough (\(list(container.devices))) isn't supported.")
        }
        if container.gpuRequests > 0 {
            builder.warn("GPU", "GPU requests aren't supported: Linux containers on macOS have no GPU access.")
        }
        let options = container.securityOptions.filter { $0 != "label=disable" && $0 != "label:disable" }
        if !options.isEmpty { builder.warn("Security", "Security options (\(list(options))) are ignored.") }
        if !container.sharedNamespaces.isEmpty {
            builder.warn("Namespaces", "Sharing namespaces (\(list(container.sharedNamespaces))) isn't supported.")
        }
        if !container.sysctls.isEmpty {
            builder.warn("Sysctls", "Kernel parameters (\(list(container.sysctls.keys.sorted()))) aren't applied.")
        }
        for limit in container.ulimits { builder.flag("--ulimit", limit) }
    }

    static func lifecycle(_ container: OrbStackContainer, builder: inout Builder) {
        if container.initProcess { builder.arguments.append("--init") }
        if container.readOnlyRootFS { builder.arguments.append("--read-only") }
        if container.autoRemove { builder.arguments.append("--rm") }
        if container.restartPolicy != "no" {
            builder.warn("Restart policy", "Restart policy “\(container.restartPolicy)” isn't supported: Basket doesn't restart the container when it exits or after a reboot.")
        }
        if container.hasHealthcheck {
            builder.warn("Healthcheck", "The healthcheck isn't supported; Basket won't report the container's health.")
        }
        if let hostname = container.hostname, !hostname.isEmpty, !container.id.hasPrefix(hostname) {
            builder.warn("Hostname", "Custom hostname “\(hostname)” isn't supported; the container's hostname is its name.")
        }
    }
}
