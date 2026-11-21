import Foundation

/// Reads a Compose file: YAML → variable interpolation (`.env` next to the file, overridden by the
/// process environment) → typed `ComposeFile`. Keys apple/container can't express become warnings;
/// structural mistakes (wrong types, undefined volumes/networks/services) throw `ComposeError`.
public enum ComposeLoader {
    /// File names Compose looks for, in its order of preference.
    public static let defaultFileNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]

    public static func load(
        fileAt url: URL, environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ComposeFile {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ComposeError.unreadableFile(path: url.path, detail: error.localizedDescription)
        }
        var file = try load(yaml: text, workingDirectory: url.deletingLastPathComponent(), environment: environment)
        file.configFile = url
        return file
    }

    /// `workingDirectory` resolves relative paths and holds the optional `.env`.
    public static func load(yaml: String, workingDirectory: URL, environment: [String: String] = [:]) throws -> ComposeFile {
        let root: YAMLValue
        do {
            root = try YAMLParser.parse(yaml)
        } catch let error as YAMLError {
            throw ComposeError.yaml(error)
        }
        guard case .mapping(let top) = root else {
            throw ComposeError.invalid(at: String(localized: "(top level)", bundle: .main, comment: "Location in a compose file: the file as a whole"),
                                       root.isNull ? "the file is empty" : "expected a mapping with “services:”")
        }

        var variables = try dotEnv(in: workingDirectory, environment: environment)
        for (key, value) in environment { variables[key] = value }
        var unset: [String] = []
        let interpolated = try ComposeInterpolation.interpolate(root, path: "", unset: &unset) { variables[$0] }
        var file = ComposeFile(workingDirectory: workingDirectory, environment: variables)
        for name in unset {
            file.warnings.append(ComposeWarning(
                .warning, "Variables",
                "\(name) isn't set, so it's replaced by an empty string. Set it in .env next to the compose file."))
        }

        var context = Context(file: file)
        try context.decode(interpolated.mapping ?? top)
        return context.file
    }

    /// Variables from `.env` in `directory` (none if the file doesn't exist).
    static func dotEnv(in directory: URL, environment: [String: String]) throws -> [String: String] {
        let url = directory.appendingPathComponent(".env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for entry in try ComposeDotEnv.parse(text, file: ".env", lookup: { environment[$0] }) {
            if let value = entry.value { result[entry.key] = value }
        }
        return result
    }
}

// MARK: - Decoding

private struct Context {
    var file: ComposeFile

    mutating func decode(_ top: YAMLMapping) throws {
        for entry in top.entries {
            let path = entry.key
            switch entry.key {
            case "name":
                file.name = try string(entry.value, path)
            case "services", "networks", "volumes", "version":
                break
            case "secrets", "configs":
                if entry.value.mapping?.isEmpty == false {
                    file.warnings.append(ComposeWarning(
                        .warning, entry.key == "secrets" ? "Top-level secrets" : "Top-level configs",
                        "apple/container has no \(entry.key); services that use them won't see the files."))
                }
            case "include":
                file.warnings.append(ComposeWarning(
                    .warning, key: "include", "Included compose files aren't read; only this file's services are planned."))
            default:
                if !entry.key.hasPrefix("x-") {
                    file.warnings.append(ComposeWarning(.warning, "Unknown key", "Top-level “\(entry.key)” isn't part of the Compose format; ignored."))
                }
            }
        }
        if let networks = top["networks"], !networks.isNull {
            for entry in try mapping(networks, "networks").entries {
                file.networks.append(try network(entry.key, entry.value, "networks.\(entry.key)"))
                resourceWarnings(isNetwork: true, entry.key, entry.value, defaultDriver: "bridge")
            }
        }
        if let volumes = top["volumes"], !volumes.isNull {
            for entry in try mapping(volumes, "volumes").entries {
                file.volumes.append(try volume(entry.key, entry.value, "volumes.\(entry.key)"))
                resourceWarnings(isNetwork: false, entry.key, entry.value, defaultDriver: "local")
            }
        }
        guard let services = top["services"], let serviceMap = services.mapping, !serviceMap.isEmpty else {
            throw ComposeError.invalid(at: "services", "the file defines no services")
        }
        for entry in serviceMap.entries {
            file.services.append(try service(entry.key, entry.value))
        }
        try validateReferences()
    }

    // MARK: Top-level networks and volumes

    func network(_ key: String, _ value: YAMLValue, _ path: String) throws -> ComposeNetwork {
        var network = ComposeNetwork(key: key)
        guard !value.isNull else { return network }
        let map = try mapping(value, path)
        network.name = try map["name"].flatMap { try string($0, "\(path).name") }
        if let external = map["external"] {
            if let flag = external.bool {
                network.external = flag
            } else if let nested = external.mapping {
                network.external = true
                network.name = try nested["name"].flatMap { try string($0, "\(path).external.name") } ?? network.name
            }
        }
        network.labels = try keyValueMap(map["labels"], "\(path).labels")
        if let config = map["ipam"]?["config"]?.sequence?.first {
            network.subnet = try config["subnet"].flatMap { try string($0, "\(path).ipam.config[0].subnet") }
        }
        return network
    }

    /// Driver options apple/container can't honour, reported once per network/volume.
    mutating func resourceWarnings(isNetwork: Bool, _ key: String, _ value: YAMLValue, defaultDriver: String) {
        guard let map = value.mapping, map["external"]?.bool != true else { return }
        if let driver = map["driver"]?.scalarText, driver != defaultDriver {
            file.warnings.append(isNetwork
                ? ComposeWarning(.warning, "Network driver", "Network “\(key)” asks for the \(driver) driver; Basket creates a regular network.")
                : ComposeWarning(.warning, "Volume driver", "Volume “\(key)” asks for the \(driver) driver; Basket creates a regular volume."))
        }
        if map["driver_opts"]?.mapping?.isEmpty == false {
            file.warnings.append(isNetwork
                ? ComposeWarning(.info, "Network options", "driver_opts of network “\(key)” are ignored.")
                : ComposeWarning(.info, "Volume options", "driver_opts of volume “\(key)” are ignored."))
        }
        if map["internal"]?.bool == true {
            file.warnings.append(ComposeWarning(.warning, "Internal network", "Network “\(key)” is internal in the file, but Basket's networks can reach the internet."))
        }
    }

    func volume(_ key: String, _ value: YAMLValue, _ path: String) throws -> ComposeVolume {
        var volume = ComposeVolume(key: key)
        guard !value.isNull else { return volume }
        let map = try mapping(value, path)
        volume.name = try map["name"].flatMap { try string($0, "\(path).name") }
        if let external = map["external"] {
            if let flag = external.bool {
                volume.external = flag
            } else if let nested = external.mapping {
                volume.external = true
                volume.name = try nested["name"].flatMap { try string($0, "\(path).external.name") } ?? volume.name
            }
        }
        volume.labels = try keyValueMap(map["labels"], "\(path).labels")
        return volume
    }

    // MARK: Services

    mutating func service(_ name: String, _ value: YAMLValue) throws -> ComposeService {
        let base = "services.\(name)"
        guard let map = value.mapping else {
            throw ComposeError.invalid(at: base, "expected a mapping, found \(value.kindPhrase)")
        }
        var s = ComposeService(name: name)
        var environment: [(key: String, value: String?)] = []
        var envFiles: [(path: String, required: Bool)] = []
        var memoryFromDeploy: Int64?

        func warn(_ topic: LocalizedStringResource, _ message: LocalizedStringResource) { s.warnings.append(ComposeWarning(.warning, service: name, topic, message)) }
        func note(_ topic: LocalizedStringResource, _ message: LocalizedStringResource) { s.warnings.append(ComposeWarning(.info, service: name, topic, message)) }
        // Topic = the Compose key itself, never translated.
        func warn(key: String, _ message: LocalizedStringResource) { s.warnings.append(ComposeWarning(.warning, service: name, key: key, message)) }
        func note(key: String, _ message: LocalizedStringResource) { s.warnings.append(ComposeWarning(.info, service: name, key: key, message)) }

        for entry in map.entries {
            let key = entry.key, v = entry.value, path = "\(base).\(key)"
            switch key {
            case "image":
                s.image = try string(v, path)
            case "build":
                if let context = v.scalarText {
                    s.build = .init(context: context, dockerfile: nil)
                } else {
                    let build = try mapping(v, path)
                    s.build = .init(
                        context: try build["context"].flatMap { try string($0, "\(path).context") } ?? ".",
                        dockerfile: try build["dockerfile"].flatMap { try string($0, "\(path).dockerfile") })
                }
            case "command":
                s.command = try command(v, path)
            case "entrypoint":
                s.entrypoint = try command(v, path)
            case "environment":
                environment = try keyValues(v, path)
            case "env_file":
                envFiles = try self.envFiles(v, path)
            case "ports":
                s.ports = try list(v, path).enumerated().map { try port($0.element, "\(path)[\($0.offset)]") }
            case "expose":
                break  // Every port is reachable from the project's other containers anyway.
            case "volumes":
                s.mounts = try list(v, path).enumerated().map { try mount($0.element, "\(path)[\($0.offset)]") }
            case "tmpfs":
                for item in try stringList(v, path) {
                    let target = String(item.split(separator: ":", maxSplits: 1).first ?? "")
                    if item.contains(":") { note(key: "tmpfs", "Options of the tmpfs at \(target) (\(String(item.dropFirst(target.count + 1)))) aren't supported; it's mounted with defaults.") }
                    s.tmpfs.append(target)
                }
            case "networks":
                s.networks = try serviceNetworks(v, path, warn: warn)
            case "network_mode":
                s.networkMode = try string(v, path)
                warn(key: "network_mode", "network_mode “\(s.networkMode ?? "")” isn't supported; the service joins the project network instead.")
            case "depends_on":
                s.dependsOn = try dependencies(v, path)
            case "links":
                for item in try stringList(v, path) {
                    let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
                    s.links.append(ComposeLink(parts[0], parts.count > 1 ? parts[1] : parts[0]))
                }
            case "external_links":
                warn(key: "external_links", "Links to containers outside the project aren't supported.")
            case "container_name":
                s.containerName = try string(v, path)
            case "hostname":
                s.hostname = try string(v, path)
                note(key: "hostname", "The container keeps its own name as hostname; “\(s.hostname ?? "")” is added to /etc/hosts of the project's containers.")
            case "working_dir":
                s.workingDir = try string(v, path)
            case "user":
                s.user = try string(v, path)
            case "labels":
                s.labels = try keyValueMap(v, path)
            case "cpus":
                s.cpus = try number(v, path)
            case "cpu_count":
                s.cpus = try number(v, path)
            case "mem_limit":
                s.memoryBytes = try byteSize(v, path)
            case "mem_reservation":
                note(key: "mem_reservation", "Nothing is reserved up front: each container is its own VM with its memory limit.")
            case "memswap_limit", "mem_swappiness":
                note(key: key, "Container VMs have no swap; \(key) is ignored.")
            case "deploy":
                memoryFromDeploy = try deploy(v, path, service: &s)
            case "platform":
                s.platform = try string(v, path)
            case "profiles":
                s.profiles = try stringList(v, path)
            case "restart":
                let policy = try string(v, path) ?? "no"
                if policy != "no" {
                    warn("Restart policy", "restart: \(policy) isn't supported; Basket doesn't restart containers that exit or after a reboot.")
                }
            case "healthcheck":
                let disabled = v["disable"]?.bool == true || v["test"]?.sequence?.first?.string == "NONE"
                if !disabled {
                    warn("Healthcheck", "Healthchecks aren't supported; the container never reports healthy or unhealthy.")
                }
            case "privileged":
                if v.bool == true { warn("Privileged", "Privileged mode isn't supported; add the specific capabilities with cap_add instead.") }
            case "cap_add":
                s.capAdd = try stringList(v, path)
            case "cap_drop":
                s.capDrop = try stringList(v, path)
            case "read_only":
                s.readOnly = try bool(v, path)
            case "init":
                s.initProcess = try bool(v, path)
            case "dns":
                s.dns = try stringList(v, path)
            case "dns_search":
                s.dnsSearch = try stringList(v, path)
            case "shm_size":
                if let bytes = try byteSize(v, path) { s.shmSize = ComposePlanner.memoryFlag(bytes) }
            case "ulimits":
                s.ulimits = try ulimits(v, path)
            case "stdin_open":
                s.stdinOpen = try bool(v, path)
            case "tty":
                s.tty = try bool(v, path)
            case "extra_hosts":
                s.extraHosts = try extraHosts(v, path)
            case "logging":
                note(key: "logging", "Logs stay with the container (Logs tab); the logging driver is ignored.")
            case "stop_signal", "stop_grace_period":
                note(key: key, "\(key) isn't supported; stopping sends SIGTERM and waits the CLI's default time.")
            case "pull_policy":
                let policy = try string(v, path) ?? "missing"
                if policy != "missing", policy != "if_not_present" {
                    note(key: "pull_policy", "pull_policy: \(policy) isn't supported; `container run` pulls the image only when it's missing.")
                }
            case "devices", "device_cgroup_rules", "gpus":
                warn("Devices", "Device access (\(key)) isn't supported by apple/container.")
            case "secrets", "configs":
                warn(key == "secrets" ? "Secrets" : "Configs", "\(key) aren't supported; mount the files with volumes instead.")
            case "extends":
                warn(key: "extends", "extends isn't supported; copy the base service's settings or use YAML anchors.")
            case "scale":
                if (v.int ?? 1) > 1 { warn("Replicas", "Only one container per service is run (scale: \(v.scalarText ?? "")).") }
            case "volumes_from":
                warn(key: "volumes_from", "volumes_from isn't supported; declare the shared volumes on each service.")
            case "dns_opt":
                note(key: "dns_opt", "DNS options aren't passed to the container.")
            case "sysctls", "security_opt", "pid", "ipc", "uts", "userns_mode", "cgroup", "cgroup_parent", "oom_kill_disable",
                 "oom_score_adj", "runtime", "isolation", "storage_opt", "blkio_config", "cpu_shares", "cpu_quota",
                 "cpu_period", "cpuset", "cpu_rt_runtime", "cpu_rt_period", "cpu_percent", "pids_limit", "mac_address",
                 "group_add", "credential_spec", "post_start", "pre_stop", "domainname", "use_api_socket", "label_file":
                warn(key: key, "\(key) isn't supported by apple/container; ignored.")
            case "annotations", "attach", "develop", "provider", "models":
                break
            default:
                if !key.hasPrefix("x-") { warn("Unknown key", "“\(key)” isn't part of the Compose format; ignored.") }
            }
        }

        if s.memoryBytes == nil { s.memoryBytes = memoryFromDeploy }
        guard s.image != nil || s.build != nil else {
            throw ComposeError.invalid(at: base, "the service needs an “image” (or a “build”)")
        }
        s.environment = try mergeEnvironment(envFiles: envFiles, environment: environment, service: name, notes: &s.warnings)
        return s
    }

    func deploy(_ value: YAMLValue, _ path: String, service s: inout ComposeService) throws -> Int64? {
        guard !value.isNull else { return nil }
        let map = try mapping(value, path)
        var memory: Int64?
        if let limits = map["resources"]?["limits"] {
            memory = try limits["memory"].flatMap { try byteSize($0, "\(path).resources.limits.memory") }
            if s.cpus == nil, let cpus = try limits["cpus"].flatMap({ try number($0, "\(path).resources.limits.cpus") }) {
                s.cpus = cpus
            }
        }
        if map["resources"]?["reservations"] != nil {
            s.warnings.append(ComposeWarning(.info, service: s.name, "Reservations", "Nothing is reserved up front; the limits apply."))
        }
        if let replicas = map["replicas"]?.int, replicas > 1 {
            s.warnings.append(ComposeWarning(.warning, service: s.name, "Replicas", "Only one container per service is run (replicas: \(replicas))."))
        }
        if map["restart_policy"] != nil {
            s.warnings.append(ComposeWarning(.warning, service: s.name, "Restart policy", "deploy.restart_policy isn't supported; Basket doesn't restart containers that exit."))
        }
        return memory
    }

    /// env_file values first, then `environment` (which wins). Variables listed without a value
    /// take the value from the shell / `.env`, or are left out when unset there.
    func mergeEnvironment(
        envFiles: [(path: String, required: Bool)], environment: [(key: String, value: String?)], service: String,
        notes: inout [ComposeWarning]
    ) throws -> [String] {
        var keys: [String] = []
        var values: [String: String] = [:]
        func set(_ key: String, _ value: String?) {
            guard let value = value ?? file.environment[key] else {
                notes.append(ComposeWarning(.info, service: service, "Environment", "\(key) has no value here or in the shell environment, so it isn't passed."))
                return
            }
            if values[key] == nil { keys.append(key) }
            values[key] = value
        }
        for envFile in envFiles {
            let url = URL(fileURLWithPath: ComposePlanner.resolveHostPath(
                envFile.path, base: file.workingDirectory.path, home: NSHomeDirectory()))
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                if envFile.required {
                    throw ComposeError.unreadableFile(path: url.path, detail: String(localized: "env_file of service \(service) doesn't exist", bundle: .main))
                }
                continue
            }
            for entry in try ComposeDotEnv.parse(text, file: envFile.path, lookup: { file.environment[$0] }) {
                set(entry.key, entry.value)
            }
        }
        for entry in environment { set(entry.key, entry.value) }
        return keys.map { "\($0)=\(values[$0]!)" }
    }

    func envFiles(_ value: YAMLValue, _ path: String) throws -> [(path: String, required: Bool)] {
        if let single = value.scalarText { return [(single, true)] }
        return try list(value, path).enumerated().map { index, item in
            if let text = item.scalarText { return (text, true) }
            let map = try mapping(item, "\(path)[\(index)]")
            guard let file = try map["path"].flatMap({ try string($0, "\(path)[\(index)].path") }) else {
                throw ComposeError.invalid(at: "\(path)[\(index)]", "missing “path”")
            }
            return (file, map["required"]?.bool ?? true)
        }
    }

    func serviceNetworks(
        _ value: YAMLValue, _ path: String, warn: (LocalizedStringResource, LocalizedStringResource) -> Void
    ) throws -> [ComposeService.Network] {
        if case .sequence = value {
            return try stringList(value, path).map { .init(name: $0, aliases: [], ipv4Address: nil) }
        }
        return try mapping(value, path).entries.map { entry in
            let p = "\(path).\(entry.key)"
            var network = ComposeService.Network(name: entry.key, aliases: [], ipv4Address: nil)
            if let options = entry.value.mapping {
                network.aliases = try options["aliases"].map { try stringList($0, "\(p).aliases") } ?? []
                network.ipv4Address = try options["ipv4_address"].flatMap { try string($0, "\(p).ipv4_address") }
                if let address = network.ipv4Address {
                    warn("Static IP", "ipv4_address \(address) on \(entry.key) isn't supported; the network assigns an address.")
                }
            }
            return network
        }
    }

    func dependencies(_ value: YAMLValue, _ path: String) throws -> [ComposeService.Dependency] {
        if case .sequence = value {
            return try stringList(value, path).map { .init(service: $0, condition: "service_started", required: true) }
        }
        return try mapping(value, path).entries.map { entry in
            let options = entry.value.mapping
            return .init(
                service: entry.key,
                condition: try options?["condition"].flatMap { try string($0, "\(path).\(entry.key).condition") } ?? "service_started",
                required: options?["required"]?.bool ?? true)
        }
    }

    func ulimits(_ value: YAMLValue, _ path: String) throws -> [String] {
        try mapping(value, path).entries.map { entry in
            if let single = entry.value.int { return "\(entry.key)=\(single)" }
            let map = try mapping(entry.value, "\(path).\(entry.key)")
            guard let soft = map["soft"]?.int, let hard = map["hard"]?.int else {
                throw ComposeError.invalid(at: "\(path).\(entry.key)", "expected a number or soft/hard numbers")
            }
            return "\(entry.key)=\(soft):\(hard)"
        }
    }

    func extraHosts(_ value: YAMLValue, _ path: String) throws -> [ComposeLink] {
        if let map = value.mapping {
            return try map.entries.flatMap { entry -> [ComposeLink] in
                if let addresses = entry.value.sequence {
                    return addresses.compactMap { $0.scalarText.map { ComposeLink(entry.key, $0) } }
                }
                return [ComposeLink(entry.key, try string(entry.value, "\(path).\(entry.key)") ?? "")]
            }
        }
        return try stringList(value, path).enumerated().map { index, item in
            // "host=1.2.3.4" or "host:1.2.3.4" (an IPv6 address contains colons, so split at the first).
            let separator = item.firstIndex(of: "=") ?? item.firstIndex(of: ":")
            guard let separator else {
                throw ComposeError.invalid(at: "\(path)[\(index)]", "expected “host:address”, found “\(item)”")
            }
            var address = String(item[item.index(after: separator)...])
            if address.hasPrefix("["), address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
            return ComposeLink(String(item[..<separator]), address)
        }
    }

    // MARK: Ports and volumes

    func port(_ value: YAMLValue, _ path: String) throws -> ComposePort {
        if let map = value.mapping {
            guard let target = map["target"]?.scalarText else {
                throw ComposeError.invalid(at: path, "a port needs a “target”")
            }
            let published = map["published"]?.scalarText.flatMap { $0.isEmpty ? nil : $0 }
            let port = ComposePort(
                hostIP: try map["host_ip"].flatMap { try string($0, "\(path).host_ip") }, published: published,
                target: target, proto: try map["protocol"].flatMap { try string($0, "\(path).protocol") } ?? "tcp")
            try validate(port, path)
            return port
        }
        guard let text = value.scalarText else {
            throw ComposeError.invalid(at: path, "expected “[host:]port[:container]” or a mapping, found \(value.kindPhrase)")
        }
        var body = text
        var proto = "tcp"
        if let slash = body.lastIndex(of: "/") {
            proto = String(body[body.index(after: slash)...])
            body = String(body[..<slash])
        }
        var hostIP: String?
        if body.hasPrefix("["), let close = body.firstIndex(of: "]") {
            hostIP = String(body[body.index(after: body.startIndex)..<close])
            body = String(body[body.index(after: close)...])
            if body.hasPrefix(":") { body.removeFirst() }
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let port: ComposePort
        switch (parts.count, hostIP) {
        case (1, nil):
            port = ComposePort(published: nil, target: parts[0], proto: proto)
        case (2, nil):
            port = ComposePort(published: parts[0].isEmpty ? nil : parts[0], target: parts[1], proto: proto)
        case (3, nil):
            port = ComposePort(hostIP: parts[0], published: parts[1].isEmpty ? nil : parts[1], target: parts[2], proto: proto)
        case (2, _?):
            port = ComposePort(hostIP: hostIP, published: parts[0].isEmpty ? nil : parts[0], target: parts[1], proto: proto)
        default:
            throw ComposeError.invalid(at: path, "can't read the port “\(text)”")
        }
        try validate(port, path)
        return port
    }

    func validate(_ port: ComposePort, _ path: String) throws {
        let range = /[0-9]{1,5}(-[0-9]{1,5})?/
        guard port.target.wholeMatch(of: range) != nil, port.published.map({ $0.wholeMatch(of: range) != nil }) ?? true else {
            throw ComposeError.invalid(at: path, "ports must be numbers or ranges like 8000-8010")
        }
        guard ["tcp", "udp"].contains(port.proto.lowercased()) else {
            throw ComposeError.invalid(at: path, "protocol “\(port.proto)” isn't supported (tcp or udp)")
        }
    }

    func mount(_ value: YAMLValue, _ path: String) throws -> ComposeMount {
        if let map = value.mapping {
            guard let target = try map["target"].flatMap({ try string($0, "\(path).target") }) else {
                throw ComposeError.invalid(at: path, "a volume needs a “target”")
            }
            let source = try map["source"].flatMap { try string($0, "\(path).source") }
            let readOnly = map["read_only"]?.bool ?? false
            switch try map["type"].flatMap({ try string($0, "\(path).type") }) ?? (source.map(Self.isHostPath) == true ? "bind" : "volume") {
            case "bind":
                guard let source else { throw ComposeError.invalid(at: path, "a bind mount needs a “source”") }
                return ComposeMount(kind: .bind, source: source, target: target, readOnly: readOnly)
            case "volume":
                return ComposeMount(kind: .volume, source: source, target: target, readOnly: readOnly)
            case "tmpfs":
                return ComposeMount(kind: .tmpfs, source: nil, target: target)
            case let other:
                throw ComposeError.invalid(at: "\(path).type", "volume type “\(other)” isn't supported (bind, volume or tmpfs)")
            }
        }
        guard let text = value.scalarText, !text.isEmpty else {
            throw ComposeError.invalid(at: path, "expected “source:target[:ro]” or a mapping, found \(value.kindPhrase)")
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            return ComposeMount(kind: .volume, source: nil, target: parts[0])
        case 2, 3:
            let options = parts.count == 3 ? parts[2].split(separator: ",").map(String.init) : []
            let kind: ComposeMount.Kind = Self.isHostPath(parts[0]) ? .bind : .volume
            return ComposeMount(kind: kind, source: parts[0], target: parts[1], readOnly: options.contains("ro"))
        default:
            throw ComposeError.invalid(at: path, "can't read the volume “\(text)”")
        }
    }

    static func isHostPath(_ source: String) -> Bool {
        source.hasPrefix("/") || source.hasPrefix(".") || source.hasPrefix("~")
    }

    // MARK: References

    func validateReferences() throws {
        let names = Set(file.services.map(\.name))
        let volumes = Set(file.volumes.map(\.key))
        let networks = Set(file.networks.map(\.key))
        for service in file.services {
            let base = "services.\(service.name)"
            for dependency in service.dependsOn where !names.contains(dependency.service) {
                if dependency.required {
                    throw ComposeError.invalid(at: "\(base).depends_on", "depends on undefined service “\(dependency.service)”")
                }
            }
            for link in service.links where !names.contains(link.name) {
                throw ComposeError.invalid(at: "\(base).links", "links to undefined service “\(link.name)”")
            }
            for mount in service.mounts where mount.kind == .volume {
                if let source = mount.source, !volumes.contains(source) {
                    throw ComposeError.invalid(
                        at: "\(base).volumes", "uses volume “\(source)”, which isn't declared under the top-level “volumes:”")
                }
            }
            for network in service.networks ?? [] where network.name != "default" && !networks.contains(network.name) {
                throw ComposeError.invalid(
                    at: "\(base).networks", "uses network “\(network.name)”, which isn't declared under the top-level “networks:”")
            }
        }
    }

    // MARK: Typed accessors

    func string(_ value: YAMLValue, _ path: String) throws -> String? {
        if value.isNull { return nil }
        guard let text = value.scalarText else {
            throw ComposeError.invalid(at: path, "expected a string, found \(value.kindPhrase)")
        }
        return text
    }

    func bool(_ value: YAMLValue, _ path: String) throws -> Bool {
        if value.isNull { return false }
        guard let flag = value.bool else {
            if let text = value.scalarText { throw ComposeError.invalid(at: path, "expected true or false, found “\(text)”") }
            throw ComposeError.invalid(at: path, "expected true or false, found \(value.kindPhrase)")
        }
        return flag
    }

    func number(_ value: YAMLValue, _ path: String) throws -> Double? {
        if value.isNull { return nil }
        guard let number = value.double else {
            if let text = value.scalarText { throw ComposeError.invalid(at: path, "expected a number, found “\(text)”") }
            throw ComposeError.invalid(at: path, "expected a number, found \(value.kindPhrase)")
        }
        return number
    }

    func mapping(_ value: YAMLValue, _ path: String) throws -> YAMLMapping {
        if value.isNull { return YAMLMapping() }
        guard let map = value.mapping else { throw ComposeError.invalid(at: path, "expected a mapping, found \(value.kindPhrase)") }
        return map
    }

    func list(_ value: YAMLValue, _ path: String) throws -> [YAMLValue] {
        if value.isNull { return [] }
        guard let items = value.sequence else { throw ComposeError.invalid(at: path, "expected a list, found \(value.kindPhrase)") }
        return items
    }

    /// A list of scalars, or a single scalar.
    func stringList(_ value: YAMLValue, _ path: String) throws -> [String] {
        if let single = value.scalarText { return [single] }
        return try list(value, path).enumerated().map { index, item in
            guard let text = item.scalarText else {
                throw ComposeError.invalid(at: "\(path)[\(index)]", "expected a string, found \(item.kindPhrase)")
            }
            return text
        }
    }

    /// `command`/`entrypoint`: a string (split like a shell would) or a list.
    func command(_ value: YAMLValue, _ path: String) throws -> [String]? {
        if value.isNull { return nil }
        if case .string(let line) = value { return try ComposeShell.split(line, path: path) }
        return try stringList(value, path)
    }

    /// `["KEY=value", "KEY"]` or `{KEY: value, KEY: null}`; values keep their spelling (`true`, `8080`).
    func keyValues(_ value: YAMLValue, _ path: String) throws -> [(key: String, value: String?)] {
        if let map = value.mapping {
            return try map.entries.map { entry in
                if case .sequence = entry.value { throw ComposeError.invalid(at: "\(path).\(entry.key)", "expected a string, found \(entry.value.kindPhrase)") }
                if case .mapping = entry.value { throw ComposeError.invalid(at: "\(path).\(entry.key)", "expected a string, found \(entry.value.kindPhrase)") }
                return (entry.key, entry.value.scalarText)
            }
        }
        return try stringList(value, path).map { item in
            guard let eq = item.firstIndex(of: "=") else { return (item, nil) }
            return (String(item[..<eq]), String(item[item.index(after: eq)...]))
        }
    }

    func keyValueMap(_ value: YAMLValue?, _ path: String) throws -> [String: String] {
        guard let value else { return [:] }
        var result: [String: String] = [:]
        for entry in try keyValues(value, path) { result[entry.key] = entry.value ?? "" }
        return result
    }

    /// `512m`, `1g`, `1.5gb`, `268435456` → bytes (binary units).
    func byteSize(_ value: YAMLValue, _ path: String) throws -> Int64? {
        if value.isNull { return nil }
        if case .int(let bytes) = value { return Int64(bytes) }
        guard let text = value.scalarText else {
            throw ComposeError.invalid(at: path, "expected a size like 512m or 1g, found \(value.kindPhrase)")
        }
        guard let bytes = parseByteSize(text) else {
            throw ComposeError.invalid(at: path, "expected a size like 512m or 1g, found “\(text)”")
        }
        return bytes
    }
}
