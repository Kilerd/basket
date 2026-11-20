import Foundation

/// The platform Basket runs on (Apple silicon only).
enum HostPlatform {
    static let os = "linux"
    static let architecture = "arm64"
    static let pullPlatform = "linux/arm64"
}

extension RawContainer {
    var resolvedID: String { id ?? configuration.id ?? "" }

    func toSummary() -> ContainerSummary {
        let config = configuration
        let primary = status?.networks?.first
        let process = config.initProcess
        return ContainerSummary(
            id: resolvedID,
            imageReference: config.image?.reference ?? "",
            state: ContainerState(rawCLIValue: status?.state ?? "unknown"),
            command: [process?.executable].compactMap { $0 } + (process?.arguments ?? []),
            createdAt: config.creationDate,
            startedAt: status?.startedDate,
            cpus: config.resources?.cpus ?? 0,
            memoryLimitBytes: config.resources?.memoryInBytes ?? 0,
            ports: (config.publishedPorts ?? []).map {
                PortMapping(
                    hostAddress: $0.hostAddress ?? "0.0.0.0", hostPort: $0.hostPort ?? 0,
                    containerPort: $0.containerPort ?? 0, proto: $0.proto ?? "tcp", count: $0.count ?? 1)
            },
            ipv4Address: primary?.ipv4Address.map(stripPrefixLength),
            hostname: primary?.hostname ?? config.networks?.first?.options?.hostname,
            networks: (config.networks ?? []).compactMap(\.network),
            labels: config.labels ?? [:],
            mounts: (config.mounts ?? []).map(\.mountInfo),
            platform: [config.platform?.os, config.platform?.architecture].compactMap { $0 }.joined(separator: "/"),
            rosetta: config.rosetta ?? false,
            environment: process?.environment ?? [],
            networkAddresses: Dictionary(
                (status?.networks ?? []).compactMap { attachment in
                    attachment.network.flatMap { network in attachment.ipv4Address.map { (network, stripPrefixLength($0)) } }
                },
                uniquingKeysWith: { first, _ in first }))
    }
}

extension RawContainer.Mount {
    var mountInfo: MountInfo {
        let kind = type?.kind ?? "unknown"
        let readOnly = (options ?? []).contains { $0 == "ro" || $0 == "readonly" }
        switch kind {
        case "volume":
            return MountInfo(
                source: type?.volumeName ?? source ?? "", destination: destination ?? "", kind: "volume",
                readOnly: readOnly)
        case "virtiofs":
            return MountInfo(source: source ?? "", destination: destination ?? "", kind: "bind", readOnly: readOnly)
        default:
            return MountInfo(source: source ?? "", destination: destination ?? "", kind: kind, readOnly: readOnly)
        }
    }
}

/// "192.168.64.2/24" -> "192.168.64.2"
func stripPrefixLength(_ address: String) -> String {
    address.split(separator: "/", maxSplits: 1).first.map(String.init) ?? address
}

extension RawStats {
    func toStats(sampledAt: Date) -> ContainerStats {
        ContainerStats(
            id: id, sampledAt: sampledAt, cpuUsageMicros: cpuUsageUsec ?? 0,
            memoryUsageBytes: memoryUsageBytes ?? 0, memoryLimitBytes: memoryLimitBytes ?? 0,
            networkRxBytes: networkRxBytes ?? 0, networkTxBytes: networkTxBytes ?? 0,
            blockReadBytes: blockReadBytes ?? 0, blockWriteBytes: blockWriteBytes ?? 0,
            processCount: numProcesses ?? 0, reportedCPUPercent: cpuUtilization.map { $0 * 100 },
            cpuCounterKnown: cpuUsageUsec != nil, networkCountersKnown: networkRxBytes != nil && networkTxBytes != nil)
    }
}

extension RawImage {
    func toSummary() -> ImageSummary {
        let all = variants ?? []
        let platformVariants = all.filter { !($0.platform?.isAttestation ?? true) }
        let host = platformVariants.first {
            $0.platform?.os == HostPlatform.os && $0.platform?.architecture == HostPlatform.architecture
        }
        return ImageSummary(
            reference: configuration.name,
            digest: configuration.descriptor?.digest ?? id.map { "sha256:\($0)" } ?? "",
            createdAt: configuration.creationDate,
            variants: platformVariants.map {
                ImageVariant(platform: $0.platform?.fullString ?? "", digest: $0.digest ?? "", sizeBytes: $0.size ?? 0)
            },
            hostVariantSizeBytes: host?.size ?? 0,
            // Attestation manifests are stored too, so they count toward the on-disk total.
            totalSizeBytes: all.reduce(0) { $0 + ($1.size ?? 0) })
    }
}

extension RawVolume {
    func toSummary(allocatedBytes: Int64?) -> VolumeSummary {
        let config = configuration
        return VolumeSummary(
            name: config.name, driver: config.driver ?? "local", format: config.format ?? "ext4",
            capacityBytes: config.sizeInBytes ?? 0, allocatedBytes: allocatedBytes, source: config.source ?? "",
            createdAt: config.creationDate, labels: config.labels ?? [:])
    }
}

enum ResourceLabels {
    static let role = "com.apple.container.resource.role"
    static let plugin = "com.apple.container.plugin"
}

extension RawNetwork {
    func toSummary() -> NetworkSummary {
        let labels = configuration?.labels ?? [:]
        return NetworkSummary(
            name: name ?? "", mode: configuration?.mode ?? "nat", ipv4Subnet: status?.ipv4Subnet,
            ipv4Gateway: status?.ipv4Gateway, ipv6Subnet: status?.ipv6Subnet,
            isBuiltin: labels[ResourceLabels.role] == "builtin" || name == "default",
            createdAt: configuration?.creationDate, labels: labels)
    }
}

extension RawSystemStatus {
    var isRunning: Bool { status.lowercased() == "running" }

    func toStatus() -> SystemStatus {
        SystemStatus(
            isRunning: isRunning, cliVersion: client?.version, serverVersion: server?.version,
            hostCPUs: host?.cpus, hostOS: host?.operatingSystem, appRoot: paths?.appRoot,
            installRoot: paths?.installRoot, containersRunning: resources?.containersRunning ?? 0,
            containersTotal: resources?.containersTotal ?? 0, imagesTotal: resources?.images ?? 0)
    }
}

extension RawDiskUsage {
    func toDiskUsage() -> DiskUsage {
        func map(_ category: Category?) -> DiskUsageCategory {
            DiskUsageCategory(
                total: category?.total ?? 0, active: category?.active ?? 0,
                sizeBytes: category?.sizeInBytes ?? 0, reclaimableBytes: category?.reclaimable ?? 0)
        }
        return DiskUsage(containers: map(containers), images: map(images), volumes: map(volumes))
    }
}

extension RawSystemProperties {
    func toProperties() -> SystemProperties {
        SystemProperties(
            containerCPUs: container?.cpus, containerMemory: container?.memory, machineCPUs: machine?.cpus,
            machineMemory: machine?.memory, machineHomeMount: machine?.homeMount, registryDomain: registry?.domain,
            kernelURL: kernel?.url, builderImage: build?.image, initImage: vminit?.image)
    }
}

extension RawMachine {
    func toSummary() -> MachineSummary {
        MachineSummary(
            id: id, image: image?.reference ?? "", state: ContainerState(rawCLIValue: status ?? "unknown"),
            cpus: cpus ?? 0, memoryBytes: memory ?? 0, isDefault: isDefault ?? false,
            homeMount: homeMount ?? "rw", ipv4Address: ipAddress.map(stripPrefixLength), diskBytes: diskSize,
            createdAt: createdDate)
    }
}

// MARK: - Domain → raw (FixtureBackend `inspect` output for synthesized resources)

extension RawContainer {
    init(summary: ContainerSummary) {
        let platform = summary.platform.split(separator: "/").map(String.init)
        let configuration = Configuration(
            id: summary.id, creationDate: summary.createdAt,
            image: RawImageDescription(reference: summary.imageReference, descriptor: nil),
            initProcess: InitProcess(
                executable: summary.command.first, arguments: Array(summary.command.dropFirst()),
                environment: summary.environment, workingDirectory: "/", terminal: false),
            labels: summary.labels,
            mounts: summary.mounts.map { mount in
                Mount(
                    source: mount.source, destination: mount.destination, options: mount.readOnly ? ["ro"] : [],
                    type: MountType(
                        kind: mount.kind == "bind" ? "virtiofs" : mount.kind,
                        volumeName: mount.kind == "volume" ? mount.source : nil,
                        format: mount.kind == "volume" ? "ext4" : nil))
            },
            networks: summary.networks.map {
                NetworkRequest(network: $0, options: .init(hostname: summary.hostname, mtu: 1280))
            },
            platform: RawPlatform(
                os: platform.first, architecture: platform.count > 1 ? platform[1] : nil,
                variant: platform.count > 2 ? platform[2] : nil),
            publishedPorts: summary.ports.map {
                PublishedPort(
                    hostAddress: $0.hostAddress, hostPort: $0.hostPort, containerPort: $0.containerPort,
                    proto: $0.proto, count: $0.count)
            },
            resources: Resources(cpus: summary.cpus, memoryInBytes: summary.memoryLimitBytes),
            rosetta: summary.rosetta, runtimeHandler: "container-runtime-linux")
        let attachments = summary.ipv4Address.map { address in
            [Attachment(
                network: summary.networks.first, hostname: summary.hostname, ipv4Address: "\(address)/24",
                ipv4Gateway: nil, ipv6Address: nil, macAddress: nil)]
        }
        self.init(
            id: summary.id, configuration: configuration,
            status: Status(state: summary.state.rawValue, startedDate: summary.startedAt, networks: attachments ?? []))
    }
}

extension RawImage {
    init(summary: ImageSummary) {
        self.init(
            id: summary.digest.replacingOccurrences(of: "sha256:", with: ""),
            configuration: Configuration(
                name: summary.reference, creationDate: summary.createdAt,
                descriptor: RawDescriptor(
                    digest: summary.digest, mediaType: "application/vnd.oci.image.index.v1+json", size: 1_609)),
            variants: summary.variants.map { variant in
                let parts = variant.platform.split(separator: "/").map(String.init)
                return Variant(
                    digest: variant.digest,
                    platform: RawPlatform(
                        os: parts.first, architecture: parts.count > 1 ? parts[1] : nil,
                        variant: parts.count > 2 ? parts[2] : nil),
                    size: variant.sizeBytes)
            })
    }
}
