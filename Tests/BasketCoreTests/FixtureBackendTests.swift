import Foundation
import Testing
@testable import BasketCore

@Suite("FixtureBackend")
struct FixtureBackendTests {
    func demo() -> FixtureBackend { FixtureBackend(directory: TestFixtures.set("demo")) }

    // MARK: demo

    @Test func demoServesRealisticState() async throws {
        let backend = demo()
        let status = try await backend.systemStatus()
        #expect(status.isRunning)
        #expect(status.cliVersion == "1.7.1" && status.serverVersion == "1.7.1")
        #expect(status.containersTotal == 10 && status.containersRunning == 7 && status.imagesTotal == 7)

        let containers = try await backend.listContainers()
        #expect(containers.map(\.id) == [
            "postgres", "redis", "web", "worker", "minio", "basket-test-old", "shop-web-1", "shop-api-1", "shop-db-1", "shop-cache-1",
        ])
        let postgres = try #require(containers.first { $0.id == "postgres" })
        #expect(postgres.state == .running)
        #expect(postgres.ports.first?.hostPort == 5432)
        #expect(postgres.mounts == [MountInfo(source: "pgdata", destination: "/var/lib/postgresql/data", kind: "volume", readOnly: false)])
        #expect(postgres.ipv4Address == "192.168.64.3")
        let web = try #require(containers.first { $0.id == "web" })
        #expect(web.ports == [PortMapping(hostAddress: "0.0.0.0", hostPort: 8080, containerPort: 80, proto: "tcp")])
        #expect(web.networks == ["dev-net"])
        #expect(containers.first { $0.id == "worker" }?.state == .stopped)

        let stats = try await backend.containerStats()
        #expect(Set(stats.map(\.id)) == ["postgres", "redis", "web", "minio", "shop-web-1", "shop-api-1", "shop-db-1"])
        #expect(abs((stats.first { $0.id == "postgres" }?.reportedCPUPercent ?? 0) - 2.13) < 1e-9)

        let images = try await backend.listImages()
        #expect(images.count == 7)
        let alpine = try #require(images.first { $0.reference == "docker.io/library/alpine:latest" })
        #expect(alpine.variants.count == 8 && alpine.hostVariantSizeBytes == 4_192_247)
        let ubuntu = try #require(images.first { $0.reference == "docker.io/library/ubuntu:24.04" })
        #expect(ubuntu.variants.count == 6 && ubuntu.totalSizeBytes > ubuntu.hostVariantSizeBytes * 5)
        #expect(images.first { $0.reference == "docker.io/library/postgres:16" }?.variants.count == 1)

        let volumes = try await backend.listVolumes()
        #expect(volumes.map(\.name) == ["pgdata", "minio-data", "scratch", "shop_pgdata"])
        #expect(volumes.allSatisfy { $0.capacityBytes == 549_755_813_888 })
        #expect(volumes.first?.allocatedBytes == 1_288_490_188)

        let networks = try await backend.listNetworks()
        #expect(networks.map(\.name) == ["default", "dev-net", "shop_default"])
        #expect(networks.map(\.isBuiltin) == [true, false, false])

        let machines = try await backend.listMachines()
        #expect(machines.map(\.id) == ["dev", "alpine-lab"])
        #expect(machines[0].state == .running && machines[0].isDefault && machines[0].image == "docker.io/library/ubuntu:24.04")
        #expect(machines[1].state == .stopped && machines[1].homeMount == "ro")

        let footprints = try await backend.hostMemoryFootprints()
        #expect(Set(footprints.compactMap(\.ownerID)) == ["postgres", "redis", "web", "minio", "dev", "shop-web-1", "shop-api-1", "shop-db-1"])
        #expect(footprints.contains { $0.ownerID == nil })

        let properties = try await backend.systemProperties()
        #expect(properties.machineMemory == "16gb")
    }

    @Test func demoDiskUsageMatchesFile() async throws {
        let usage = try await demo().diskUsage()
        let file = try RawJSON.decode(
            RawDiskUsage.self, from: Data(contentsOf: TestFixtures.set("demo").appendingPathComponent("system-df.json")),
            command: "").toDiskUsage()
        for (computed, expected) in [(usage.containers, file.containers), (usage.images, file.images), (usage.volumes, file.volumes)] {
            #expect(computed.total == expected.total)
            #expect(computed.active == expected.active)
            #expect(abs(computed.sizeBytes - expected.sizeBytes) < 1_000)
            #expect(abs(computed.reclaimableBytes - expected.reclaimableBytes) < 1_000)
        }
    }

    @Test func containerLifecycle() async throws {
        let backend = demo()
        try await backend.stopContainers(["web"])
        #expect(try await backend.listContainers().first { $0.id == "web" }?.state == .stopped)
        #expect(!(try await backend.containerStats()).contains { $0.id == "web" })
        #expect(!(try await backend.hostMemoryFootprints()).contains { $0.ownerID == "web" })
        #expect(try await backend.inspectContainer("web").contains("\"state\" : \"stopped\""))

        try await backend.startContainer("worker")
        #expect(try await backend.listContainers().first { $0.id == "worker" }?.state == .running)
        #expect(try await backend.hostMemoryFootprints().first { $0.ownerID == "worker" }?.footprintBytes == 243_269_632)

        await #expect(throws: BackendError.self) { try await backend.deleteContainers(["postgres"], force: false) }
        try await backend.deleteContainers(["postgres"], force: true)
        #expect(!(try await backend.listContainers()).contains { $0.id == "postgres" })

        try await backend.killContainers(["redis"])
        try await backend.pruneContainers()
        let remaining = try await backend.listContainers()
        #expect(remaining.allSatisfy { $0.state == .running })
        #expect(Set(remaining.map(\.id)) == ["worker", "minio", "shop-web-1", "shop-api-1", "shop-db-1"])
        #expect(try await backend.diskUsage().containers.total == 5)

        await #expect(throws: BackendError.self) { try await backend.stopContainers(["ghost"]) }
    }

    @Test func runCreatesARunningContainer() async throws {
        let backend = demo()
        let id = try await backend.run(RunSpec(
            image: "caddy", name: "edge", command: ["caddy", "run"], memory: "256M", ports: ["127.0.0.1:8443:443/tcp"],
            volumes: ["caddy-data:/data", "/Users/demo/site:/srv:ro"], network: "dev-net"))
        #expect(id == "edge")
        let edge = try #require(try await backend.listContainers().first { $0.id == "edge" })
        #expect(edge.state == .running)
        #expect(edge.imageReference == "docker.io/library/caddy:latest")
        #expect(edge.memoryLimitBytes == 256 * 1_048_576)
        #expect(edge.ports == [PortMapping(hostAddress: "127.0.0.1", hostPort: 8443, containerPort: 443, proto: "tcp")])
        #expect(edge.ipv4Address == "192.168.65.3")
        #expect(edge.mounts.map(\.kind) == ["volume", "bind"])
        #expect(try await backend.listImages().contains { $0.reference == "docker.io/library/caddy:latest" })
        #expect(try await backend.listVolumes().contains { $0.name == "caddy-data" })
        #expect(try await backend.containerStats().contains { $0.id == "edge" })
        #expect(try await backend.hostMemoryFootprints().contains { $0.ownerID == "edge" })
        #expect(try await backend.inspectContainer("edge").contains("\"caddy-data\""))

        let unnamed = try await backend.run(RunSpec(image: "alpine"))
        #expect(!unnamed.isEmpty && unnamed != "edge")
        await #expect(throws: BackendError.self) { _ = try await backend.run(RunSpec(image: "alpine", name: "edge")) }

        let removable = try await backend.run(RunSpec(image: "alpine", name: "once", removeOnExit: true))
        let listed = try await backend.listContainers()
        #expect(listed.first { $0.id == "once" }?.removeOnStop == true)
        #expect(listed.first { $0.id == "edge" }?.removeOnStop == false)
        try await backend.stopContainers([removable])
        #expect(!(try await backend.listContainers()).contains { $0.id == "once" })
    }

    @Test func logs() async throws {
        let backend = demo()
        let all = try await backend.logs("web", tail: nil)
        #expect(all.split(separator: "\n").count == 9)
        #expect(try await backend.logs("web", tail: 2).split(separator: "\n").count == 2)
        #expect(try await backend.logs("redis", tail: nil) == "")
        let followed = try await collect(backend.followLogs("worker"), limit: 5)
        #expect(followed.last == "[2026-11-19 22:40:02] INFO worker: shutdown complete")
        await #expect(throws: BackendError.self) { _ = try await backend.logs("ghost", tail: nil) }
    }

    @Test func images() async throws {
        let backend = demo()
        let lines = try await collect(backend.pullImage("docker.io/library/busybox:1.37", platform: nil))
        #expect(lines.count >= 3 && lines.last?.contains("Unpacking") == true)
        let busybox = try #require(try await backend.listImages().first { $0.reference == "docker.io/library/busybox:1.37" })
        #expect(busybox.variants.map(\.platform) == ["linux/arm64/v8"])
        #expect(busybox.hostVariantSizeBytes == busybox.totalSizeBytes)

        try await backend.tagImage("busybox:1.37", as: "mirror.local/busybox:stable")
        #expect(try await backend.listImages().contains { $0.reference == "mirror.local/busybox:stable" })
        #expect(try await backend.inspectImage("docker.io/library/alpine:latest").contains("\"variants\""))
        #expect(try await backend.inspectImage("mirror.local/busybox:stable").contains("linux"))

        try await backend.deleteImages(["docker.io/library/busybox:1.37", "mirror.local/busybox:stable"], force: false)
        await #expect(throws: BackendError.self) { try await backend.deleteImages(["ghost:1"], force: false) }
        try await backend.deleteImages(["ghost:1"], force: true)

        try await backend.pruneImages(all: true)  // ubuntu is the only unused image
        let left = try await backend.listImages().map(\.reference)
        #expect(left.count == 6 && !left.contains("docker.io/library/ubuntu:24.04"))
        #expect(try await backend.diskUsage().images.reclaimableBytes == 0)
    }

    @Test func volumesAndNetworks() async throws {
        let backend = demo()
        try await backend.createVolume(name: "cache", size: "10G")
        #expect(try await backend.listVolumes().first { $0.name == "cache" }?.capacityBytes == 10 << 30)
        await #expect(throws: BackendError.self) { try await backend.deleteVolumes(["pgdata"]) }  // in use
        try await backend.deleteVolumes(["cache"])
        try await backend.pruneVolumes()
        #expect(try await backend.listVolumes().map(\.name) == ["pgdata", "minio-data", "shop_pgdata"])

        try await backend.createNetwork(name: "lab", subnet: "10.7.0.0/24")
        let lab = try #require(try await backend.listNetworks().first { $0.name == "lab" })
        #expect(lab.ipv4Subnet == "10.7.0.0/24" && lab.ipv4Gateway == "10.7.0.1")
        await #expect(throws: BackendError.self) { try await backend.deleteNetworks(["default"]) }
        try await backend.deleteNetworks(["lab"])
        #expect(try await backend.listNetworks().map(\.name) == ["default", "dev-net", "shop_default"])
    }

    @Test func machines() async throws {
        let backend = demo()
        try await backend.setDefaultMachine("alpine-lab")
        try await backend.startMachine("alpine-lab")
        var machines = try await backend.listMachines()
        #expect(machines.map(\.isDefault) == [false, true])
        #expect(machines[1].state == .running)
        #expect(try await backend.hostMemoryFootprints().contains { $0.ownerID == "alpine-lab" })

        try await backend.stopMachine("dev")
        #expect(!(try await backend.hostMemoryFootprints()).contains { $0.ownerID == "dev" })

        let lines = try await collect(backend.createMachine(image: "ubuntu:24.04", name: "box", cpus: 2, memory: "4G"))
        #expect(lines.last == "box")
        let box = try #require(try await backend.listMachines().first { $0.id == "box" })
        #expect(box.cpus == 2 && box.memoryBytes == 4 << 30 && box.state == .running && !box.isDefault)

        try await backend.deleteMachine("alpine-lab")
        machines = try await backend.listMachines()
        #expect(machines.map(\.id) == ["dev", "box"])
        #expect(machines[0].isDefault)
        #expect(backend.shellCommandLine(forMachine: "dev") == "'container' machine run --name dev")
    }

    @Test func systemStopAndStart() async throws {
        let backend = demo()
        try await backend.stopSystem()
        #expect(!(try await backend.systemStatus()).isRunning)
        await #expect(throws: BackendError.systemNotRunning) { _ = try await backend.listContainers() }
        #expect(try await backend.hostMemoryFootprints().isEmpty)
        try await backend.startSystem()
        let containers = try await backend.listContainers()
        #expect(containers.count == 10 && containers.allSatisfy { $0.state != .running })
    }

    @Test func cpuPercentFromConsecutiveSamplesMatchesReported() async throws {
        let backend = demo()
        let first = try #require(try await backend.containerStats().first { $0.id == "postgres" })
        try await Task.sleep(for: .milliseconds(300))
        let second = try #require(try await backend.containerStats().first { $0.id == "postgres" })
        #expect(abs(second.cpuPercent(since: first) - 2.13) < 0.2)
    }

    @Test func demoHasAComposeProject() async throws {
        let backend = demo()
        let containers = try await backend.listContainers()
        let (projects, standalone) = ComposeProject.group(containers)
        #expect(projects.map(\.name) == ["shop"])
        #expect(standalone.map(\.id) == ["postgres", "redis", "web", "worker", "minio", "basket-test-old"])
        let shop = try #require(projects.first)
        #expect(shop.services == ["api", "cache", "db", "web"])
        #expect(shop.state == .partial && shop.runningCount == 3)
        #expect(shop.configFile?.path == "/Users/demo/projects/shop/compose.yaml")
        #expect(shop.startOrder.map(\.id) == ["shop-cache-1", "shop-db-1", "shop-api-1", "shop-web-1"])
        let db = try #require(containers.first { $0.id == "shop-db-1" })
        #expect(db.mounts.first?.source == "shop_pgdata")
        #expect(db.networkAddresses == ["shop_default": "192.168.66.2"])
        #expect(try await backend.listNetworks().first { $0.name == "shop_default" }?.labels[ComposeLabels.project] == "shop")
        #expect(try await backend.listVolumes().first { $0.name == "shop_pgdata" }?.labels[ComposeLabels.project] == "shop")

        // The plan sheet's file describes the same project.
        let file = try ComposeLoader.load(
            fileAt: TestFixtures.set("demo").appendingPathComponent("compose/shop/compose.yaml"), environment: [:])
        let plan = try ComposePlanner.plan(file)
        #expect(plan.project == "shop")
        #expect(plan.services.map(\.containerName) == ["shop-db-1", "shop-cache-1", "shop-api-1", "shop-web-1"])
        #expect(plan.services.map(\.memoryBytes) == [1 << 30, 256 << 20, 512 << 20, 256 << 20])
        #expect(plan.volumes.map(\.name) == ["shop_pgdata"])

        // Starting the stopped service brings it back with an address on the project network.
        try await backend.startContainer("shop-cache-1")
        let cache = try #require(try await backend.listContainers().first { $0.id == "shop-cache-1" })
        #expect(cache.ipv4Address?.hasPrefix("192.168.66.") == true && cache.networkAddresses.count == 1)
        try await backend.stopContainers(["shop-cache-1"])
        #expect(try await backend.listContainers().first { $0.id == "shop-cache-1" }?.ipv4Address == nil)
    }

    // MARK: empty / stopped / real

    @Test func emptySet() async throws {
        let backend = FixtureBackend(directory: TestFixtures.set("empty"))
        let status = try await backend.systemStatus()
        #expect(status.isRunning && status.containersTotal == 0 && status.imagesTotal == 0)
        #expect(try await backend.listContainers().isEmpty)
        #expect(try await backend.containerStats().isEmpty)
        #expect(try await backend.listImages().isEmpty)
        #expect(try await backend.listVolumes().isEmpty)
        #expect(try await backend.listMachines().isEmpty)
        #expect(try await backend.listNetworks().map(\.name) == ["default"])
        #expect(try await backend.hostMemoryFootprints().isEmpty)
        #expect(try await backend.diskUsage().totalBytes == 0)
    }

    @Test func stoppedSet() async throws {
        let backend = FixtureBackend(directory: TestFixtures.set("stopped"))
        let status = try await backend.systemStatus()
        #expect(!status.isRunning)
        #expect(status.cliVersion == "1.7.1")
        await #expect(throws: BackendError.systemNotRunning) { _ = try await backend.listContainers() }
        await #expect(throws: BackendError.systemNotRunning) { _ = try await backend.listImages() }
        await #expect(throws: BackendError.systemNotRunning) { _ = try await backend.diskUsage() }
        await #expect(throws: BackendError.systemNotRunning) { _ = try await backend.listMachines() }
        await #expect(throws: BackendError.systemNotRunning) { try await backend.stopContainers(["x"]) }
        await #expect(throws: BackendError.systemNotRunning) {
            _ = try await collect(backend.pullImage("alpine", platform: nil))
        }
        try await backend.startSystem()
        #expect(try await backend.systemStatus().isRunning)
        #expect(try await backend.listContainers().isEmpty)
        #expect(try await backend.listNetworks().map(\.name) == ["default"])
        let id = try await backend.run(RunSpec(image: "alpine", name: "first"))
        #expect(try await backend.listContainers().first { $0.id == id }?.ipv4Address == "192.168.64.2")
    }

    @Test func realCapturedOutputLoads() async throws {
        let backend = FixtureBackend(directory: TestFixtures.realDirectory)
        #expect(try await backend.listContainers().map(\.id) == ["probe-alpine"])
        #expect(try await backend.listImages().first?.variants.count == 8)
        #expect(try await backend.listMachines().first?.image == "docker.io/library/alpine:latest")
        #expect(try await backend.inspectContainer("probe-alpine").contains("\"runtimeHandler\""))
    }
}

@Suite("CPU% math")
struct CPUPercentTests {
    let start = Date(timeIntervalSince1970: 1_000)

    func sample(_ micros: Int64, at offset: TimeInterval) -> ContainerStats {
        ContainerStats(id: "c", sampledAt: start.addingTimeInterval(offset), cpuUsageMicros: micros, memoryUsageBytes: 0, memoryLimitBytes: 0)
    }

    @Test func halfACore() {
        #expect(sample(1_500_000, at: 2).cpuPercent(since: sample(500_000, at: 0)) == 50)
    }

    @Test func multiCoreExceedsHundred() {
        #expect(sample(5_000_000, at: 2).cpuPercent(since: sample(0, at: 0)) == 250)
    }

    @Test func degenerateSamplesAreZero() {
        #expect(sample(100, at: 0).cpuPercent(since: sample(0, at: 0)) == 0)  // no time elapsed
        #expect(sample(0, at: 1).cpuPercent(since: sample(100, at: 0)) == 0)  // counter reset (restart)
        #expect(sample(100, at: 0).cpuPercent(since: sample(0, at: 1)) == 0)  // out of order
    }

    @Test func reportedUtilizationIsPercentOfOneCore() {
        let raw = RawStats(id: "c", cpuUsageUsec: 1, cpuUtilization: 1.5)
        #expect(raw.toStats(sampledAt: start).reportedCPUPercent == 150)
        #expect(RawStats(id: "c").toStats(sampledAt: start).reportedCPUPercent == nil)
    }
}

@Suite("Fixture helpers")
struct FixtureHelperTests {
    @Test(arguments: [
        ("512M", Int64(512) << 20), ("2G", Int64(2) << 30), ("1gb", Int64(1) << 30), ("16GiB", Int64(16) << 30),
        ("1073741824", Int64(1) << 30), ("1.5g", Int64(3) << 29),
    ])
    func byteSizes(_ text: String, _ bytes: Int64) {
        #expect(parseByteSize(text) == bytes)
    }

    @Test func references() {
        #expect(normalizeImageReference("nginx") == "docker.io/library/nginx:latest")
        #expect(normalizeImageReference("minio/minio") == "docker.io/minio/minio:latest")
        #expect(normalizeImageReference("ghcr.io/apple/x:1") == "ghcr.io/apple/x:1")
        #expect(normalizeImageReference("localhost:5000/app") == "localhost:5000/app:latest")
        #expect(normalizeImageReference("docker.io/library/alpine:latest") == "docker.io/library/alpine:latest")
    }
}
