import Foundation
import Testing
@testable import BasketCore

/// Against the real `container` CLI and host. Opt in with `BASKET_INTEGRATION=1`. Every test creates
/// (and removes) its own `basket-test-*` resources — nothing pre-existing is assumed or touched.
@Suite(
    "Integration (real container CLI)",
    .enabled(if: ProcessInfo.processInfo.environment["BASKET_INTEGRATION"] == "1"),
    .serialized)
struct IntegrationTests {
    let backend = CLIBackend()
    static let alpine = "docker.io/library/alpine:latest"

    /// Runs a 256 MB alpine container `basket-test-integ-<suffix>` that sleeps, waits until it runs,
    /// hands its name to `body`, and deletes it afterwards (also when `body` throws).
    func withProbe<T>(_ suffix: String = "probe", removeOnExit: Bool = false, _ body: (String) async throws -> T) async throws -> T {
        let name = "basket-test-integ-\(suffix)"
        try? await backend.deleteContainers([name], force: true)
        _ = try await backend.run(RunSpec(
            image: Self.alpine, name: name, command: ["sh", "-c", "echo basket-ready; exec sleep 600"], memory: "256M",
            removeOnExit: removeOnExit))
        do {
            try await waitUntilRunning(name)
            let result = try await body(name)
            try? await backend.deleteContainers([name], force: true)
            return result
        } catch {
            try? await backend.deleteContainers([name], force: true)
            throw error
        }
    }

    func waitUntilRunning(_ name: String) async throws {
        for _ in 0..<40 {
            if try await backend.listContainers().first(where: { $0.id == name })?.state == .running { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        Issue.record("\(name) never reached running")
    }

    @Test func systemIsRunning() async throws {
        let status = try await backend.systemStatus()
        #expect(status.isRunning)
        #expect(status.cliVersion != nil && status.hostCPUs ?? 0 > 0)
        let usage = try await backend.diskUsage()
        #expect(usage.images.total >= 1)
        #expect(try await backend.systemProperties().containerCPUs != nil)
    }

    @Test func listsAProbeAndAttributesItsVMFootprint() async throws {
        try await withProbe { name in
            let probe = try #require(try await backend.listContainers().first { $0.id == name })
            #expect(probe.state == .running)
            #expect(probe.ipv4Address?.contains("/") == false)
            #expect(probe.removeOnStop == false)

            let footprints = try await backend.hostMemoryFootprints()
            let vm = try #require(footprints.first { $0.ownerID == name })
            // `footprint -p <vm pid>` reports ~230–265 MB for a 256 MB alpine container.
            #expect(vm.footprintBytes > 100 * 1_048_576 && vm.footprintBytes < 600 * 1_048_576)
            #expect(footprints.filter { $0.ownerID == name }.count == 1)
        }
    }

    @Test func readsImagesNetworksVolumesMachinesAndStats() async throws {
        try await withProbe { name in
            let alpine = try #require(try await backend.listImages().first { $0.reference == Self.alpine })
            #expect(alpine.hostVariantSizeBytes > 0)
            #expect(try await backend.listNetworks().contains { $0.name == "default" && $0.isBuiltin })
            _ = try await backend.listVolumes()
            _ = try await backend.listMachines()
            let stats = try await backend.containerStats()
            let probe = try #require(stats.first { $0.id == name })
            #expect(probe.memoryLimitBytes == 268_435_456)
            #expect(probe.cpuCounterKnown && probe.networkCountersKnown)
            #expect(try await backend.inspectContainer(name).contains("\"\(name)\""))
            #expect(try await backend.inspectImage(Self.alpine).contains("\"variants\""))
            #expect(try await backend.logs(name, tail: 10).contains("basket-ready"))
        }
    }

    /// Restarts run per container, re-read `--rm` right before stopping, and one problem never
    /// leaves the others down (`basket-test-integ-fix-*`, one started with `--rm`).
    @Test func restartIsPerContainerAndNeverStopsARemoveOnStopContainer() async throws {
        try await withProbe("fix-plain") { plain in
            try await withProbe("fix-rm", removeOnExit: true) { removed in
                let before = try await backend.listContainers()
                #expect(before.first { $0.id == removed }?.removeOnStop == true)
                #expect(before.first { $0.id == plain }?.removeOnStop == false)
                let startedBefore = before.first { $0.id == plain }?.startedAt

                let ids = [removed, "basket-test-integ-fix-missing", plain]
                let outcome = await MemoryReclaim.restart(ids, using: backend)
                print("[integration] restart outcome: \(outcome)")
                #expect(outcome.restarted == [plain])
                #expect(outcome.skipped.map(\.id) == [removed, "basket-test-integ-fix-missing"])
                #expect(outcome.failed.isEmpty)

                let after = try await backend.listContainers()
                #expect(after.first { $0.id == removed }?.state == .running, "the --rm container was left alone")
                let restarted = try #require(after.first { $0.id == plain })
                #expect(restarted.state == .running)
                if let startedBefore, let startedAfter = restarted.startedAt { #expect(startedAfter > startedBefore) }
            }
        }
    }

    @Test func containerLifecycleWithVolumeAndNetwork() async throws {
        let name = "basket-test-integ-life"
        try? await backend.deleteContainers([name], force: true)
        try? await backend.deleteVolumes(["\(name)-vol"])
        try? await backend.deleteNetworks(["\(name)-net"])

        try await backend.createVolume(name: "\(name)-vol", size: "1G")
        try await backend.createNetwork(name: "\(name)-net", subnet: nil)
        do {
            let id = try await backend.run(RunSpec(
                image: "docker.io/library/alpine:latest", name: name,
                command: ["sh", "-c", "echo basket-ready; exec sleep 300"], memory: "256M",
                volumes: ["\(name)-vol:/data"], network: "\(name)-net"))
            #expect(id == name)

            let container = try #require(try await backend.listContainers().first { $0.id == name })
            #expect(container.state == .running)
            #expect(container.mounts.first?.kind == "volume" && container.mounts.first?.source == "\(name)-vol")
            #expect(container.networks == ["\(name)-net"])

            let volume = try #require(try await backend.listVolumes().first { $0.name == "\(name)-vol" })
            #expect(volume.capacityBytes == 1 << 30)
            #expect((volume.allocatedBytes ?? 0) > 0 && (volume.allocatedBytes ?? 0) < volume.capacityBytes)

            #expect(try await backend.hostMemoryFootprints().contains { $0.ownerID == name })

            let followed = try await collect(backend.followLogs(name), limit: 1)
            #expect(followed == ["basket-ready"])

            try await backend.stopContainers([name])
            #expect(try await backend.listContainers().first { $0.id == name }?.state == .stopped)
            try await backend.deleteContainers([name], force: false)
            #expect(!(try await backend.listContainers()).contains { $0.id == name })
        } catch {
            try? await backend.deleteContainers([name], force: true)
            try? await backend.deleteVolumes(["\(name)-vol"])
            try? await backend.deleteNetworks(["\(name)-net"])
            throw error
        }
        try await backend.deleteVolumes(["\(name)-vol"])
        try await backend.deleteNetworks(["\(name)-net"])
    }

    @Test func hostOnlyPullStreamsProgress() async throws {
        // alpine is already present, so this only re-resolves the arm64 manifest.
        let lines = try await collect(backend.pullImage("docker.io/library/alpine:latest", platform: nil))
        #expect(lines.contains { $0.contains("Fetching image") })
    }

    @Test func orbStackSnapshotIsReadOnlyAndPlausible() async throws {
        let snapshot = await OrbStackInspector().snapshot()
        if FileManager.default.fileExists(atPath: "/Applications/OrbStack.app") {
            #expect(snapshot.isInstalled)
            #expect(snapshot.dataPath != nil)
            if snapshot.isRunning { #expect(snapshot.memoryFootprintBytes > 0) }
        } else {
            #expect(!snapshot.isInstalled)
        }
    }
}

@Suite("OrbStackInspector fixtures")
struct OrbStackInspectorFixtureTests {
    @Test func demoSnapshot() async {
        let snapshot = await OrbStackInspector(fixturesDirectory: TestFixtures.set("demo")).snapshot()
        #expect(snapshot == OrbStackSnapshot(
            isInstalled: true, isRunning: true, memoryFootprintBytes: 2_254_857_830,
            dataPath: "/Users/demo/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data",
            dataAllocatedBytes: 148_176_371_712, dockerImageCount: 87))
    }

    @Test func emptyAndStoppedSnapshots() async {
        #expect(await OrbStackInspector(fixturesDirectory: TestFixtures.set("empty")).snapshot() == .notInstalled)
        let stopped = await OrbStackInspector(fixturesDirectory: TestFixtures.set("stopped")).snapshot()
        #expect(stopped.isInstalled && !stopped.isRunning && stopped.dockerImageCount == nil)
        #expect(await OrbStackInspector(fixturesDirectory: TestFixtures.realDirectory).snapshot() == .notInstalled)
    }

    @Test func dataUsageIsStatBased() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let image = directory.url.appendingPathComponent("data.img.raw")
        FileManager.default.createFile(atPath: image.path, contents: Data(count: 1 << 20))
        let handle = try FileHandle(forWritingTo: image)
        try handle.truncate(atOffset: 64 << 30)  // 64 GiB logical, 1 MiB written
        try handle.close()
        try FileManager.default.createDirectory(
            at: directory.url.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        let usage = try #require(OrbStackInspector.dataUsage(directory: directory.url.path))
        #expect(usage.bytes >= 1 << 20 && usage.bytes < 8 << 20)
    }
}
