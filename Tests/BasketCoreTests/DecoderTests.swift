import Foundation
import Testing
@testable import BasketCore

@Suite("Decoders vs real container 1.7.1 output")
struct DecoderTests {
    func containers(_ file: String) throws -> [ContainerSummary] {
        try RawJSON.decodeList(RawContainer.self, from: TestFixtures.real(file), command: "list").map { $0.toSummary() }
    }

    @Test func containerList() throws {
        let list = try containers("container-list.json")
        let probe = try #require(list.first)
        #expect(list.count == 1)
        #expect(probe.id == "probe-alpine")
        #expect(probe.imageReference == "docker.io/library/alpine:latest")
        #expect(probe.state == .running)
        #expect(probe.command == ["sleep", "3600"])
        #expect(probe.createdAt == TestFixtures.date("2026-11-20T04:18:45Z"))
        #expect(probe.startedAt == TestFixtures.date("2026-11-20T04:18:51Z"))
        #expect(probe.cpus == 1)
        #expect(probe.memoryLimitBytes == 268_435_456)
        #expect(probe.ports == [PortMapping(hostAddress: "0.0.0.0", hostPort: 18080, containerPort: 80, proto: "tcp")])
        #expect(probe.ipv4Address == "192.168.64.2")
        #expect(probe.hostname == "probe-alpine")
        #expect(probe.networks == ["default"])
        #expect(probe.platform == "linux/arm64")
        #expect(probe.rosetta == false)
        #expect(probe.environment.first?.hasPrefix("PATH=") == true)
        #expect(probe.mounts.isEmpty)
    }

    @Test func containerWithMountsNetworkAndLabels() throws {
        let rich = try #require(try containers("container-list-rich.json").first { $0.id == "basket-test-mounts" })
        #expect(rich.ipv4Address == "192.168.65.2")
        #expect(rich.networks == ["basket-test-net"])
        #expect(rich.labels == ["app": "basket"])
        #expect(rich.cpus == 2)
        #expect(rich.memoryLimitBytes == 512 * 1_048_576)
        #expect(rich.ports.first?.hostAddress == "127.0.0.1")
        #expect(rich.environment.contains("FOO=bar"))
        let mounts = Dictionary(uniqueKeysWithValues: rich.mounts.map { ($0.destination, $0) })
        #expect(mounts["/data"] == MountInfo(source: "basket-test-vol", destination: "/data", kind: "volume", readOnly: false))
        #expect(mounts["/host"] == MountInfo(source: "/tmp/basket-probe", destination: "/host", kind: "bind", readOnly: true))
        #expect(mounts["/scratch"]?.kind == "tmpfs")
    }

    @Test func containerInspectDecodesLikeList() throws {
        let inspected = try containers("container-inspect.json")
        #expect(inspected == (try containers("container-list.json")))
        #expect(try containers("container-inspect-rich.json").first?.mounts.count == 3)
    }

    @Test func stats() throws {
        let sampledAt = Date()
        let stats = try RawJSON.decodeList(RawStats.self, from: TestFixtures.real("stats.json"), command: "stats")
            .map { $0.toStats(sampledAt: sampledAt) }
        let probe = try #require(stats.first)
        #expect(probe.id == "probe-alpine")
        #expect(probe.cpuUsageMicros == 3552)
        #expect(probe.memoryUsageBytes == 1_974_272)
        #expect(probe.memoryLimitBytes == 268_435_456)
        #expect(probe.networkRxBytes == 23939)
        #expect(probe.networkTxBytes == 602)
        #expect(probe.blockReadBytes == 1_679_360)
        #expect(probe.processCount == 1)
        #expect(probe.reportedCPUPercent == 0)
        #expect(probe.sampledAt == sampledAt)

        let rich = try RawJSON.decodeList(RawStats.self, from: TestFixtures.real("stats-rich.json"), command: "stats")
        let mounts = try #require(rich.first { $0.id == "basket-test-mounts" }).toStats(sampledAt: sampledAt)
        #expect(abs(mounts.reportedCPUPercent! - 0.02879135697065957) < 1e-12)
        #expect(rich.count == 3)  // includes the machine's backing container
    }

    @Test func imageListExcludesAttestationsAndFindsHostVariant() throws {
        let raw = try RawJSON.decodeList(RawImage.self, from: TestFixtures.real("image-list.json"), command: "image list")
        let alpine = try #require(raw.first).toSummary()
        #expect(alpine.reference == "docker.io/library/alpine:latest")
        #expect(alpine.id == alpine.reference)
        #expect(alpine.digest == "sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf")
        #expect(alpine.createdAt == TestFixtures.date("2026-11-05T17:59:34Z"))
        #expect(alpine.variants.count == 8)
        #expect(!alpine.variants.contains { $0.platform.contains("unknown") })
        #expect(alpine.variants.map(\.platform).contains("linux/arm64/v8"))
        #expect(alpine.variants.map(\.platform).contains("linux/amd64"))
        #expect(alpine.hostVariantSizeBytes == 4_192_247)
        let everything = try #require(raw.first?.variants).reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        #expect(alpine.totalSizeBytes == everything)
        #expect(alpine.totalSizeBytes > alpine.hostVariantSizeBytes * 7)
    }

    @Test func imageInspectDecodes() throws {
        let raw = try RawJSON.decodeList(RawImage.self, from: TestFixtures.real("image-inspect.json"), command: "image inspect")
        #expect(raw.first?.toSummary().hostVariantSizeBytes == 4_192_247)
    }

    @Test func volumes() throws {
        let raw = try RawJSON.decodeList(RawVolume.self, from: TestFixtures.real("volume-list.json"), command: "volume list")
        let volume = try #require(raw.first).toSummary(allocatedBytes: 39_882_752)
        #expect(volume.name == "probe-vol")
        #expect(volume.driver == "local")
        #expect(volume.format == "ext4")
        #expect(volume.capacityBytes == 549_755_813_888)
        #expect(volume.allocatedBytes == 39_882_752)
        #expect(volume.source.hasSuffix("/volumes/probe-vol/volume.img"))
        #expect(volume.createdAt == TestFixtures.date("2026-11-20T04:20:26Z"))
        let inspected = try RawJSON.decodeList(RawVolume.self, from: TestFixtures.real("volume-inspect.json"), command: "")
        #expect(inspected.first?.configuration.name == "probe-vol")
    }

    @Test func allocatedBytesUsesBlocksNotLogicalSize() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let path = directory.url.appendingPathComponent("sparse.img").path
        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.truncate(atOffset: 1 << 30)  // 1 GiB logical, nothing written
        try handle.close()
        let allocated = try #require(allocatedBytes(atPath: path))
        #expect(allocated < 1 << 20)
        #expect(allocatedBytes(atPath: directory.url.appendingPathComponent("missing").path) == nil)
    }

    @Test func networks() throws {
        let raw = try RawJSON.decodeList(RawNetwork.self, from: TestFixtures.real("network-list-rich.json"), command: "")
        let networks = Dictionary(uniqueKeysWithValues: raw.map { ($0.toSummary().name, $0.toSummary()) })
        let builtin = try #require(networks["default"])
        #expect(builtin.isBuiltin)
        #expect(builtin.mode == "nat")
        #expect(builtin.ipv4Subnet == "192.168.64.0/24")
        #expect(builtin.ipv4Gateway == "192.168.64.1")
        #expect(builtin.ipv6Subnet == "fdd3:eddd:e439:b198::/64")
        let custom = try #require(networks["basket-test-net"])
        #expect(!custom.isBuiltin)
        #expect(custom.ipv4Subnet == "192.168.65.0/24")
    }

    @Test func systemStatusRunningAndUnregistered() throws {
        let running = try RawJSON.decode(RawSystemStatus.self, from: TestFixtures.real("system-status.json"), command: "").toStatus()
        #expect(running.isRunning)
        #expect(running.cliVersion == "1.7.1")
        #expect(running.serverVersion == "1.7.1")
        #expect(running.hostCPUs == 10)
        #expect(running.hostOS == "Version 26.3 (Build 25D125)")
        #expect(running.appRoot?.hasSuffix("com.apple.container/") == true)
        #expect(running.installRoot == "/opt/homebrew/Cellar/container/1.7.1_2/")
        #expect(running.containersRunning == 1 && running.containersTotal == 1 && running.imagesTotal == 2)

        let unregistered = try RawJSON.decode(
            RawSystemStatus.self, from: TestFixtures.real("system-status-unregistered.json"), command: "")
        #expect(!unregistered.toStatus().isRunning)
    }

    @Test func diskUsage() throws {
        let usage = try RawJSON.decode(RawDiskUsage.self, from: TestFixtures.real("system-df.json"), command: "").toDiskUsage()
        #expect(usage.containers == DiskUsageCategory(total: 1, active: 1, sizeBytes: 253_063_168, reclaimableBytes: 0))
        #expect(usage.images == DiskUsageCategory(total: 2, active: 1, sizeBytes: 645_779_456, reclaimableBytes: 244_273_152))
        #expect(usage.volumes.total == 0)
        #expect(usage.totalBytes == 253_063_168 + 645_779_456)
        #expect(usage.reclaimableBytes == 244_273_152)
    }

    @Test func versionAndProperties() throws {
        let versions = try RawJSON.decode([RawVersion].self, from: TestFixtures.real("system-version.json"), command: "")
        #expect(versions.map(\.appName) == ["container", "container-apiserver"])
        #expect(versions.allSatisfy { $0.version == "1.7.1" })

        let properties = try RawJSON.decode(RawSystemProperties.self, from: TestFixtures.real("system-property.json"), command: "")
            .toProperties()
        #expect(properties.containerCPUs == 4)
        #expect(properties.containerMemory == "1gb")
        #expect(properties.machineCPUs == 5)
        #expect(properties.machineMemory == "16gb")
        #expect(properties.machineHomeMount == "rw")
        #expect(properties.registryDomain == "docker.io")
        #expect(properties.initImage == "ghcr.io/apple/containerization/vminit:0.54.0")
    }

    @Test func machines() throws {
        let list = try RawJSON.decodeList(RawMachine.self, from: TestFixtures.real("machine-list.json"), command: "")
        let inspect = try RawJSON.decodeList(RawMachine.self, from: TestFixtures.real("machine-inspect.json"), command: "")
        let listed = try #require(list.first)
        #expect(listed.image == nil && listed.homeMount == nil)
        let machine = listed.merging(try #require(inspect.first)).toSummary()
        #expect(machine.id == "basket-test-m")
        #expect(machine.state == .running)
        #expect(machine.isDefault)
        #expect(machine.cpus == 1)
        #expect(machine.memoryBytes == 1 << 30)
        #expect(machine.ipv4Address == "192.168.64.3")
        #expect(machine.image == "docker.io/library/alpine:latest")
        #expect(machine.homeMount == "rw")
        #expect(machine.diskBytes == 47_448_064)
        #expect(machine.createdAt == TestFixtures.date("2026-11-20T04:26:38Z"))
        #expect(inspect.first?.containerId == "basket-test-m-32cb51")
    }

    // MARK: Leniency

    @Test func legacyFlatContainerAndUnknownValues() throws {
        let json = """
        [{"configuration":{"id":"old","image":{"reference":"x:1"},"mounts":[{"source":"s","destination":"/d","type":{"weirdfs":{}}}]},
          "status":"paused","startedDate":"2026-01-02T03:04:05.123456Z",
          "networks":[{"network":"default","ipv4Address":"10.0.0.9/16"}]},
         {"configuration":{"image":{"reference":"broken"}}},
         {"id":"new-shape","configuration":{"id":"new-shape","creationDate":"2026-01-02T03:04:05Z"},"status":{"state":"stopping"}}]
        """
        let list = try RawJSON.decodeList(RawContainer.self, from: Data(json.utf8), command: "list").map { $0.toSummary() }
        #expect(list.map(\.id) == ["old", "new-shape"])  // the element without an id is skipped
        #expect(list[0].state == .unknown)
        #expect(list[0].ipv4Address == "10.0.0.9")
        #expect(abs(list[0].startedAt!.timeIntervalSince(TestFixtures.date("2026-01-02T03:04:05Z")) - 0.123456) < 0.001)
        #expect(list[0].mounts.first?.kind == "weirdfs")
        #expect(list[1].state == .stopping)
    }

    @Test(arguments: [
        "2026-11-05T18:00:28.583714131Z", "2026-11-05T18:00:28Z", "2026-11-05T18:00:28.5Z", "2026-11-05T19:00:28+01:00",
    ])
    func isoDates(_ text: String) throws {
        let date = try #require(RawJSON.parseDate(text))
        #expect(abs(date.timeIntervalSince(TestFixtures.date("2026-11-05T18:00:28Z"))) < 1)
    }

    @Test func emptyOutputIsEmptyList() throws {
        #expect(try RawJSON.decodeList(RawContainer.self, from: Data("\n".utf8), command: "list").isEmpty)
        #expect(throws: BackendError.self) {
            try RawJSON.decodeList(RawContainer.self, from: Data("not json".utf8), command: "list")
        }
    }

    @Test func prettyPrintedUnescapesSlashes() {
        let pretty = RawJSON.prettyPrinted(#"[{"b":1,"a":"application\/json"}]"#)
        #expect(pretty.contains("\"application/json\""))
        #expect(pretty.range(of: "\"a\"")!.lowerBound < pretty.range(of: "\"b\"")!.lowerBound)
        #expect(RawJSON.prettyPrinted("plain text\n") == "plain text")
    }
}
