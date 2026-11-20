import Foundation

/// In-memory world served by `FixtureBackend`, loaded from raw CLI JSON files.
///
/// Files (all optional; same names as `Tests/BasketCoreTests/Fixtures/`):
/// `system-status.json`, `system-version.json`, `system-property.json`, `system-df.json`,
/// `container-list.json`, `stats.json`, `image-list.json`, `volume-list.json`, `network-list.json`,
/// `machine-list.json`, `machine-inspect.json` (array; adds image/home mount), `logs-<id>.txt`.
/// Fixture-only extensions (not CLI output):
/// - `host-footprints.json`: `[{"ownerID": "web", "pid": 41210, "footprintBytes": 231735296}]`
///   (`ownerID` may be null for an unattributed VM).
/// - `volume-allocations.json`: `{"<volume name>": <allocated bytes>}`; otherwise the volume's
///   `source` is stat'ed if it exists.
/// - `cli-missing` (any content): simulates a Mac without the `container` CLI — every call throws
///   `BackendError.cliNotFound` until `FixtureBackend.simulateCLIInstall()`.
struct FixtureState: Sendable {
    static let cliMissingMarker = "cli-missing"

    struct Container: Sendable {
        var summary: ContainerSummary
        /// Original `container list` element, for `inspect`.
        var rawJSON: Data?
        var diskBytes: Int64
        var removeOnExit = false
    }

    struct Image: Sendable {
        var summary: ImageSummary
        var rawJSON: Data?
        var diskBytes: Int64
    }

    var isRunning: Bool
    var cliMissing = false
    var status: RawSystemStatus?
    var versions: [RawVersion]
    var properties: RawSystemProperties?
    var containers: [Container]
    var stats: [String: RawStats]
    var images: [Image]
    var volumes: [VolumeSummary]
    var networks: [NetworkSummary]
    var machines: [MachineSummary]
    var footprints: [HostMemoryFootprint]
    /// Disk cost of a newly created container (average of the fixture's containers).
    var containerDiskBytes: Int64
    /// On-disk bytes per byte of image size (df includes unpacked snapshots).
    var imageDiskRatio: Double
    let loadedAt: Date
    var counter = 0
    var execCalls: [FixtureExecCall] = []

    static func load(from directory: URL) -> FixtureState {
        func data(_ name: String) -> Data? { try? Data(contentsOf: directory.appendingPathComponent(name)) }
        func decode<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
            data(name).flatMap { try? RawJSON.decoder().decode(type, from: $0) }
        }
        func list<T: Decodable>(_ type: T.Type, _ name: String) -> [(T, Data)] {
            guard let data = data(name),
                  let elements = try? JSONSerialization.jsonObject(with: data) as? [Any]
            else { return [] }
            return elements.compactMap { element in
                guard let json = try? JSONSerialization.data(withJSONObject: element),
                      let value = try? RawJSON.decoder().decode(type, from: json)
                else { return nil }
                return (value, json)
            }
        }

        let status = decode(RawSystemStatus.self, "system-status.json")
        let df = decode(RawDiskUsage.self, "system-df.json")

        let rawContainers = list(RawContainer.self, "container-list.json")
        let dfContainers = df?.containers
        let perContainer: Int64 = {
            guard let size = dfContainers?.sizeInBytes, let total = dfContainers?.total, total > 0 else {
                return 250 * 1_048_576
            }
            return size / Int64(total)
        }()
        let containers = rawContainers.map { raw, json in
            Container(summary: raw.toSummary(), rawJSON: json, diskBytes: perContainer)
        }

        let rawImages = list(RawImage.self, "image-list.json")
        let imageSummaries = rawImages.map { $0.0.toSummary() }
        let imageBytes = imageSummaries.reduce(Int64(0)) { $0 + $1.totalSizeBytes }
        let ratio: Double = {
            guard let size = df?.images?.sizeInBytes, size > 0, imageBytes > 0 else { return 1 }
            return Double(size) / Double(imageBytes)
        }()
        let images = zip(rawImages, imageSummaries).map { raw, summary in
            Image(summary: summary, rawJSON: raw.1, diskBytes: Int64(Double(summary.totalSizeBytes) * ratio))
        }

        let allocations = decode([String: Int64].self, "volume-allocations.json") ?? [:]
        let volumes = list(RawVolume.self, "volume-list.json").map { raw, _ in
            raw.toSummary(
                allocatedBytes: allocations[raw.configuration.name]
                    ?? raw.configuration.source.flatMap(allocatedBytes(atPath:)))
        }

        let inspected = Dictionary(
            list(RawMachine.self, "machine-inspect.json").map { ($0.0.id, $0.0) }, uniquingKeysWith: { a, _ in a })
        let machines = list(RawMachine.self, "machine-list.json").map { raw, _ in
            (inspected[raw.id].map { raw.merging($0) } ?? raw).toSummary()
        }

        struct RawFootprint: Decodable {
            var ownerID: String?
            var pid: Int32
            var footprintBytes: Int64
        }
        let footprints = (decode([RawFootprint].self, "host-footprints.json") ?? []).map {
            HostMemoryFootprint(ownerID: $0.ownerID, pid: $0.pid, footprintBytes: $0.footprintBytes)
        }

        return FixtureState(
            isRunning: status?.isRunning ?? true,
            cliMissing: FileManager.default.fileExists(atPath: directory.appendingPathComponent(cliMissingMarker).path),
            status: status,
            versions: decode([RawVersion].self, "system-version.json") ?? [],
            properties: decode(RawSystemProperties.self, "system-property.json"),
            containers: containers,
            stats: Dictionary(list(RawStats.self, "stats.json").map { ($0.0.id, $0.0) }, uniquingKeysWith: { a, _ in a }),
            images: images,
            volumes: volumes,
            networks: list(RawNetwork.self, "network-list.json").map { $0.0.toSummary() },
            machines: machines,
            footprints: footprints,
            containerDiskBytes: perContainer,
            imageDiskRatio: ratio,
            loadedAt: Date())
    }

    // MARK: Derived views

    var systemStatus: SystemStatus {
        guard isRunning else {
            return SystemStatus(isRunning: false, cliVersion: versions.first?.version ?? status?.client?.version)
        }
        var result = status?.isRunning == true ? status!.toStatus() : SystemStatus(isRunning: true)
        result.isRunning = true
        result.cliVersion = result.cliVersion ?? versions.first(where: { $0.appName == "container" })?.version ?? "1.7.1"
        result.serverVersion = result.serverVersion
            ?? versions.first(where: { $0.appName == "container-apiserver" })?.version ?? result.cliVersion
        result.containersTotal = containers.count
        result.containersRunning = containers.filter { $0.summary.state == .running }.count
        result.imagesTotal = images.count
        return result
    }

    var diskUsage: DiskUsage {
        let usedImages = Set(containers.map(\.summary.imageReference))
        let usedVolumes = Set(containers.flatMap { $0.summary.mounts.filter { $0.kind == "volume" }.map(\.source) })
        let running = containers.filter { $0.summary.state == .running }
        let idle = containers.filter { $0.summary.state != .running }
        let unusedImages = images.filter { !usedImages.contains($0.summary.reference) }
        let unusedVolumes = volumes.filter { !usedVolumes.contains($0.name) }
        return DiskUsage(
            containers: DiskUsageCategory(
                total: containers.count, active: running.count, sizeBytes: containers.reduce(0) { $0 + $1.diskBytes },
                reclaimableBytes: idle.reduce(0) { $0 + $1.diskBytes }),
            images: DiskUsageCategory(
                total: images.count, active: images.count - unusedImages.count,
                sizeBytes: images.reduce(0) { $0 + $1.diskBytes },
                reclaimableBytes: unusedImages.reduce(0) { $0 + $1.diskBytes }),
            volumes: DiskUsageCategory(
                total: volumes.count, active: volumes.count - unusedVolumes.count,
                sizeBytes: volumes.reduce(0) { $0 + ($1.allocatedBytes ?? 0) },
                reclaimableBytes: unusedVolumes.reduce(0) { $0 + ($1.allocatedBytes ?? 0) }))
    }

    func index(ofContainer id: String) -> Int? { containers.firstIndex { $0.summary.id == id } }
    func index(ofImage reference: String) -> Int? { images.firstIndex { $0.summary.reference == reference } }
    func index(ofMachine id: String) -> Int? { machines.firstIndex { $0.id == id } }

    var defaultContainerCPUs: Int { properties?.container?.cpus ?? 4 }
    var defaultContainerMemory: Int64 { properties?.container?.memory.flatMap(parseByteSize) ?? 1 << 30 }
    var defaultMachineCPUs: Int { properties?.machine?.cpus ?? 4 }
    var defaultMachineMemory: Int64 { properties?.machine?.memory.flatMap(parseByteSize) ?? 8 << 30 }

    mutating func nextCounter() -> Int {
        counter += 1
        return counter
    }
}

/// One `exec` served by `FixtureBackend`.
public struct FixtureExecCall: Sendable, Hashable {
    public var containerID: String
    public var command: [String]
    public var user: String?
}

// MARK: - Helpers shared by the fixture backend

/// "512M", "2G", "1gb", "16GiB", "1073741824" → bytes (binary units, like the CLI).
func parseByteSize(_ text: String) -> Int64? {
    let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
    guard let match = trimmed.wholeMatch(of: /([0-9]+(?:\.[0-9]+)?)\s*([kmgtp]?)(?:i?b)?/),
          let value = Double(match.1)
    else { return nil }
    let exponent = ["": 0, "k": 1, "m": 2, "g": 3, "t": 4, "p": 5][String(match.2)] ?? 0
    return Int64(value * pow(1024, Double(exponent)))
}

/// "nginx" → "docker.io/library/nginx:latest", "ghcr.io/a/b" → "ghcr.io/a/b:latest".
func normalizeImageReference(_ reference: String) -> String {
    var components = reference.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    let first = components.first ?? ""
    let hasRegistry = components.count > 1 && (first.contains(".") || first.contains(":") || first == "localhost")
    if !hasRegistry {
        if components.count == 1 { components.insert("library", at: 0) }
        components.insert("docker.io", at: 0)
    }
    var normalized = components.joined(separator: "/")
    let last = components.last ?? ""
    if !last.contains(":") && !normalized.contains("@") { normalized += ":latest" }
    return normalized
}

/// Stable (unlike `hashValue`) small hash for deterministic fake sizes.
func stableHash(_ text: String) -> Int64 {
    text.utf8.reduce(Int64(5381)) { ($0 &* 33 &+ Int64($1)) & 0x7fff_ffff }
}
