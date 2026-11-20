import Foundation
import BasketCore

/// In-memory backend with plausible demo data. Used for SwiftUI previews and `BASKET_BACKEND=preview`.
actor PreviewBackend: ContainerBackend {
    private var running = true
    private var containers: [ContainerSummary]
    private var images: [ImageSummary]
    private var volumes: [VolumeSummary]
    private var networks: [NetworkSummary]
    private var machines: [MachineSummary]
    private let started = Date()

    init() {
        let now = Date()
        let mb: Int64 = 1 << 20
        containers = [
            ContainerSummary(
                id: "web", imageReference: "docker.io/library/nginx:1.27-alpine", state: .running,
                command: ["nginx", "-g", "daemon off;"], createdAt: now.addingTimeInterval(-7200),
                startedAt: now.addingTimeInterval(-3600), cpus: 2, memoryLimitBytes: 512 * mb,
                ports: [PortMapping(hostAddress: "0.0.0.0", hostPort: 8080, containerPort: 80, proto: "tcp")],
                ipv4Address: "192.168.64.2", hostname: "web", networks: ["default"], platform: "linux/arm64",
                environment: ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "NGINX_VERSION=1.27.3"]
            ),
            ContainerSummary(
                id: "postgres", imageReference: "docker.io/library/postgres:17", state: .running,
                command: ["docker-entrypoint.sh", "postgres"], createdAt: now.addingTimeInterval(-86400),
                startedAt: now.addingTimeInterval(-5400), cpus: 2, memoryLimitBytes: 1024 * mb,
                ports: [PortMapping(hostAddress: "127.0.0.1", hostPort: 5432, containerPort: 5432, proto: "tcp")],
                ipv4Address: "192.168.64.3", hostname: "postgres", networks: ["default"],
                mounts: [MountInfo(source: "pgdata", destination: "/var/lib/postgresql/data", kind: "volume", readOnly: false)],
                platform: "linux/arm64", environment: ["POSTGRES_PASSWORD=example", "PGDATA=/var/lib/postgresql/data"]
            ),
            ContainerSummary(
                id: "redis", imageReference: "docker.io/library/redis:7", state: .stopped,
                command: ["redis-server"], createdAt: now.addingTimeInterval(-172_800), cpus: 1,
                memoryLimitBytes: 256 * mb, networks: ["default"], platform: "linux/arm64"
            ),
        ]
        images = [
            ImageSummary(
                reference: "docker.io/library/nginx:1.27-alpine", digest: "sha256:4ff102c5d78d254a6f0da062b3cf39eaf07f01eec0927fd21e219d0af8bc0591",
                createdAt: now.addingTimeInterval(-1_000_000),
                variants: [ImageVariant(platform: "linux/arm64/v8", digest: "sha256:aa11", sizeBytes: 21 * mb)],
                hostVariantSizeBytes: 21 * mb, totalSizeBytes: 21 * mb
            ),
            ImageSummary(
                reference: "docker.io/library/postgres:17", digest: "sha256:87ec5e0a167dc7d4831729f9e1d2ee7b8597dcc49ccd9e43cc5f89e808d2adae",
                createdAt: now.addingTimeInterval(-2_000_000),
                variants: [ImageVariant(platform: "linux/arm64/v8", digest: "sha256:bb22", sizeBytes: 152 * mb)],
                hostVariantSizeBytes: 152 * mb, totalSizeBytes: 152 * mb
            ),
            ImageSummary(
                reference: "docker.io/library/alpine:latest", digest: "sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf",
                createdAt: now.addingTimeInterval(-1_300_000),
                variants: ["linux/amd64", "linux/arm/v6", "linux/arm/v7", "linux/arm64/v8", "linux/386",
                           "linux/ppc64le", "linux/riscv64", "linux/s390x"].map {
                    ImageVariant(platform: $0, digest: "sha256:\($0.hashValue)", sizeBytes: 4 * mb)
                },
                hostVariantSizeBytes: 4 * mb, totalSizeBytes: 32 * mb
            ),
            ImageSummary(
                reference: "docker.io/library/redis:7", digest: "sha256:cc33cc33",
                createdAt: now.addingTimeInterval(-3_000_000),
                variants: [ImageVariant(platform: "linux/arm64/v8", digest: "sha256:cc33", sizeBytes: 48 * mb)],
                hostVariantSizeBytes: 48 * mb, totalSizeBytes: 48 * mb
            ),
        ]
        let support = "/Users/me/Library/Application Support/com.apple.container/volumes"
        volumes = [
            VolumeSummary(name: "pgdata", capacityBytes: 512 << 30, allocatedBytes: 182 * mb,
                          source: "\(support)/pgdata/volume.img", createdAt: now.addingTimeInterval(-86400)),
            VolumeSummary(name: "scratch", capacityBytes: 512 << 30, allocatedBytes: 12 * mb,
                          source: "\(support)/scratch/volume.img", createdAt: now.addingTimeInterval(-3600)),
        ]
        networks = [
            NetworkSummary(name: "default", mode: "nat", ipv4Subnet: "192.168.64.0/24", ipv4Gateway: "192.168.64.1",
                           ipv6Subnet: "fdd3:eddd:e439:b198::/64", isBuiltin: true, createdAt: now.addingTimeInterval(-90000)),
            NetworkSummary(name: "backend", mode: "nat", ipv4Subnet: "192.168.100.0/24", ipv4Gateway: "192.168.100.1",
                           createdAt: now.addingTimeInterval(-4000)),
        ]
        machines = [
            MachineSummary(id: "dev", image: "ubuntu:24.04", state: .running, cpus: 4, memoryBytes: 4096 * mb,
                           isDefault: true, homeMount: "rw", ipv4Address: "192.168.64.10", diskBytes: 3_200_000_000),
            MachineSummary(id: "scratch-fedora", image: "fedora:41", state: .stopped, cpus: 2, memoryBytes: 2048 * mb),
        ]
    }

    private func requireRunning() throws {
        guard running else { throw BackendError.systemNotRunning }
    }

    // MARK: System

    func systemStatus() async throws -> SystemStatus {
        SystemStatus(
            isRunning: running, cliVersion: "1.7.1", serverVersion: running ? "1.7.1" : nil, hostCPUs: 10,
            hostOS: "Version 26.3 (Build 25D125)", appRoot: "/Users/me/Library/Application Support/com.apple.container/",
            installRoot: "/opt/homebrew/Cellar/container/1.7.1/",
            containersRunning: containers.filter { $0.state == .running }.count,
            containersTotal: containers.count, imagesTotal: images.count
        )
    }

    func startSystem() async throws { running = true }
    func stopSystem() async throws {
        running = false
        for i in containers.indices { containers[i].state = .stopped }
    }

    func diskUsage() async throws -> DiskUsage {
        try requireRunning()
        let usedImages = Set(containers.map(\.imageReference))
        let imageBytes = images.reduce(0) { $0 + $1.totalSizeBytes }
        let unusedImageBytes = images.filter { !usedImages.contains($0.reference) }.reduce(0) { $0 + $1.totalSizeBytes }
        let mountedVolumes = Set(containers.flatMap { $0.mounts.filter { $0.kind == "volume" }.map(\.source) })
        let volumeBytes = volumes.reduce(0) { $0 + ($1.allocatedBytes ?? 0) }
        let unusedVolumeBytes = volumes.filter { !mountedVolumes.contains($0.name) }.reduce(0) { $0 + ($1.allocatedBytes ?? 0) }
        let stopped = containers.filter { $0.state != .running }
        let mb: Int64 = 1 << 20
        return DiskUsage(
            containers: DiskUsageCategory(total: containers.count, active: containers.count - stopped.count,
                                          sizeBytes: Int64(containers.count) * 96 * mb, reclaimableBytes: Int64(stopped.count) * 96 * mb),
            images: DiskUsageCategory(total: images.count, active: usedImages.count, sizeBytes: imageBytes, reclaimableBytes: unusedImageBytes),
            volumes: DiskUsageCategory(total: volumes.count, active: mountedVolumes.count, sizeBytes: volumeBytes, reclaimableBytes: unusedVolumeBytes)
        )
    }

    func hostMemoryFootprints() async throws -> [HostMemoryFootprint] {
        try requireRunning()
        let mb: Int64 = 1 << 20
        var result: [HostMemoryFootprint] = []
        for (i, c) in containers.enumerated() where c.state == .running {
            result.append(HostMemoryFootprint(ownerID: c.id, pid: Int32(4000 + i), footprintBytes: (180 + Int64(i) * 70) * mb))
        }
        for (i, m) in machines.enumerated() where m.state == .running {
            result.append(HostMemoryFootprint(ownerID: m.id, pid: Int32(5000 + i), footprintBytes: 820 * mb))
        }
        return result
    }

    // MARK: Containers

    func listContainers() async throws -> [ContainerSummary] {
        try requireRunning()
        return containers
    }

    func containerStats() async throws -> [ContainerStats] {
        try requireRunning()
        let t = Date().timeIntervalSince(started)
        let mb: Int64 = 1 << 20
        return containers.enumerated().compactMap { i, c in
            guard c.state == .running else { return nil }
            let rate = 0.04 + Double(i) * 0.09
            return ContainerStats(
                id: c.id, cpuUsageMicros: Int64(t * rate * 1_000_000 + 5_000_000), memoryUsageBytes: (40 + Int64(i) * 55) * mb + Int64(t) % 7 * mb,
                memoryLimitBytes: c.memoryLimitBytes, networkRxBytes: Int64(t * 2048), networkTxBytes: Int64(t * 512),
                blockReadBytes: 12 * mb, blockWriteBytes: 3 * mb, processCount: 3 + i
            )
        }
    }

    func inspectContainer(_ id: String) async throws -> String {
        guard let c = containers.first(where: { $0.id == id }) else {
            throw BackendError.commandFailed(command: "container inspect \(id)", exitCode: 1, stderr: "not found")
        }
        return """
        [
          {
            "id" : "\(c.id)",
            "image" : "\(c.imageReference)",
            "state" : "\(c.state.rawValue)",
            "cpus" : \(c.cpus),
            "memoryInBytes" : \(c.memoryLimitBytes)
          }
        ]
        """
    }

    private func update(_ ids: [String], _ change: (inout ContainerSummary) -> Void) {
        for i in containers.indices where ids.contains(containers[i].id) { change(&containers[i]) }
    }

    func startContainer(_ id: String) async throws {
        try requireRunning()
        update([id]) { $0.state = .running; $0.startedAt = Date() }
    }

    func stopContainers(_ ids: [String]) async throws {
        try requireRunning()
        update(ids) { $0.state = .stopped }
    }

    func killContainers(_ ids: [String]) async throws {
        try requireRunning()
        update(ids) { $0.state = .stopped }
    }

    func deleteContainers(_ ids: [String], force: Bool) async throws {
        try requireRunning()
        containers.removeAll { ids.contains($0.id) && (force || $0.state != .running) }
    }

    func pruneContainers() async throws {
        containers.removeAll { $0.state != .running }
    }

    func run(_ spec: RunSpec) async throws -> String {
        try requireRunning()
        let id = spec.name ?? "container-\(Int.random(in: 1000...9999))"
        containers.append(ContainerSummary(
            id: id, imageReference: spec.image, state: .running, command: spec.command, createdAt: Date(),
            startedAt: Date(), cpus: spec.cpus ?? 1, memoryLimitBytes: 512 << 20, platform: "linux/arm64",
            environment: spec.environment
        ))
        return id
    }

    func logs(_ id: String, tail: Int?) async throws -> String {
        (1...40).map { "2026-11-20T10:\(String(format: "%02d", $0)):00Z \(id) log line \($0)" }.joined(separator: "\n")
    }

    nonisolated func followLogs(_ id: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var n = 0
                while !Task.isCancelled {
                    n += 1
                    continuation.yield("\(Date().formatted(.iso8601)) \(id) heartbeat \(n)")
                    try? await Task.sleep(for: .seconds(1))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated func shellCommandLine(forContainer id: String) -> String {
        "container exec -it \(id) sh"
    }

    // MARK: Images

    func listImages() async throws -> [ImageSummary] {
        try requireRunning()
        return images
    }

    func inspectImage(_ reference: String) async throws -> String {
        "[\n  {\n    \"name\" : \"\(reference)\"\n  }\n]"
    }

    nonisolated func pullImage(_ reference: String, platform: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for p in stride(from: 0, through: 100, by: 10) {
                    continuation.yield("Fetching \(reference) (\(platform ?? "linux/arm64")) \(p)%")
                    try? await Task.sleep(for: .milliseconds(150))
                }
                await self.addImage(reference)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func addImage(_ reference: String) {
        guard !images.contains(where: { $0.reference == reference }) else { return }
        images.append(ImageSummary(reference: reference, digest: "sha256:new", createdAt: Date(),
                                   hostVariantSizeBytes: 8 << 20, totalSizeBytes: 8 << 20))
    }

    func deleteImages(_ references: [String], force: Bool) async throws {
        images.removeAll { references.contains($0.reference) }
    }

    func pruneImages(all: Bool) async throws {
        let used = Set(containers.map(\.imageReference))
        images.removeAll { !used.contains($0.reference) }
    }

    func tagImage(_ source: String, as target: String) async throws {
        guard let image = images.first(where: { $0.reference == source }) else { return }
        var copy = image
        copy.reference = target
        images.append(copy)
    }

    // MARK: Volumes

    func listVolumes() async throws -> [VolumeSummary] {
        try requireRunning()
        return volumes
    }

    func createVolume(name: String, size: String?) async throws {
        volumes.append(VolumeSummary(name: name, capacityBytes: 512 << 30, allocatedBytes: 0, createdAt: Date()))
    }

    func deleteVolumes(_ names: [String]) async throws {
        volumes.removeAll { names.contains($0.name) }
    }

    func pruneVolumes() async throws {
        let mounted = Set(containers.flatMap { $0.mounts.map(\.source) })
        volumes.removeAll { !mounted.contains($0.name) }
    }

    // MARK: Networks

    func listNetworks() async throws -> [NetworkSummary] {
        try requireRunning()
        return networks
    }

    func createNetwork(name: String, subnet: String?) async throws {
        networks.append(NetworkSummary(name: name, ipv4Subnet: subnet, createdAt: Date()))
    }

    func deleteNetworks(_ names: [String]) async throws {
        networks.removeAll { names.contains($0.name) && !$0.isBuiltin }
    }

    // MARK: Machines

    func listMachines() async throws -> [MachineSummary] {
        try requireRunning()
        return machines
    }

    nonisolated func createMachine(image: String, name: String?, cpus: Int?, memory: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for step in ["Fetching \(image)", "Unpacking", "Booting machine", "Done"] {
                    continuation.yield(step)
                    try? await Task.sleep(for: .milliseconds(300))
                }
                await self.addMachine(image: image, name: name ?? "machine", cpus: cpus ?? 2)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func addMachine(image: String, name: String, cpus: Int) {
        machines.append(MachineSummary(id: name, image: image, state: .running, cpus: cpus, memoryBytes: 2 << 30))
    }

    func startMachine(_ id: String) async throws {
        for i in machines.indices where machines[i].id == id { machines[i].state = .running }
    }

    func stopMachine(_ id: String) async throws {
        for i in machines.indices where machines[i].id == id { machines[i].state = .stopped }
    }

    func deleteMachine(_ id: String) async throws {
        machines.removeAll { $0.id == id }
    }

    func setDefaultMachine(_ id: String) async throws {
        for i in machines.indices { machines[i].isDefault = machines[i].id == id }
    }

    nonisolated func shellCommandLine(forMachine id: String) -> String {
        "container machine run -n \(id)"
    }
}
