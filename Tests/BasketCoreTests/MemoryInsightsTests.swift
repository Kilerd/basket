import Foundation
import Testing
@testable import BasketCore

@Suite struct MemoryInsightsTests {
    static let MiB = MemoryInsights.mebibyte
    static let MB = Int64(1_000_000)

    private func running(_ id: String, limit: Int64) -> ContainerSummary {
        ContainerSummary(id: id, imageReference: "docker.io/library/alpine:latest", state: .running, memoryLimitBytes: limit)
    }

    private func stats(_ id: String, used: Int64, limit: Int64) -> ContainerStats {
        ContainerStats(id: id, cpuUsageMicros: 0, memoryUsageBytes: used, memoryLimitBytes: limit)
    }

    private func insights(limit: Int64, used: Int64, host: Int64, id: String = "c") -> MemoryInsights {
        MemoryInsights(
            containers: [running(id, limit: limit)], stats: [id: stats(id, used: used, limit: limit)],
            footprints: [HostMemoryFootprint(ownerID: id, pid: 1, footprintBytes: host)])
    }

    @Test func overheadCurveMatchesMeasuredIdleVMs() {
        let model = MemoryInsights.Model.measured
        // Measured idle footprints (guest ~2 MB): 240 MB, 287 MB, 312 MB.
        for (limit, measured) in [(256 * Self.MiB, 240 * Self.MiB), (1024 * Self.MiB, 287 * Self.MiB), (2048 * Self.MiB, 312 * Self.MiB)] {
            let estimate = model.overheadBytes(forLimit: limit) + 2 * Self.MiB
            #expect(abs(estimate - measured) <= 3 * Self.MiB, "limit \(limit): \(estimate) vs \(measured)")
        }
        #expect(model.overheadBytes(forLimit: 0) == 238 * Self.MiB)
        #expect(model.overheadBytes(forLimit: 64 * Self.MiB) == 238 * Self.MiB)
    }

    @Test(arguments: [
        (256 * MiB, 240 * MiB), (1024 * MiB, 287 * MiB), (2048 * MiB, 312 * MiB),
        // A bit of noise either side of the curve.
        (1024 * MiB, 330 * MiB), (2048 * MiB, 280 * MiB),
    ])
    func freshIdleVMIsNotStranded(limit: Int64, host: Int64) throws {
        let result = insights(limit: limit, used: 2 * Self.MiB, host: host)
        let c = try #require(result["c"])
        #expect(!c.isStranded)
        #expect(result.totals.strandedBytes == 0)
        #expect(result.stranded.isEmpty)
    }

    @Test func freedGuestMemoryIsStranded() throws {
        // Measured: guest allocated 500 MB and freed it; host stayed at 778 MB with 55 MB in use.
        let result = insights(limit: 1024 * Self.MiB, used: 55 * Self.MiB, host: 778 * Self.MiB)
        let c = try #require(result["c"])
        #expect(c.isStranded)
        #expect(c.overheadBytes == 288 * Self.MiB)
        #expect(c.strandedBytes == (778 - 288 - 55) * Self.MiB)
        #expect(result.totals.strandedBytes == c.strandedBytes)
        #expect(result.totals.strandedCount == 1)
    }

    @Test func partsAlwaysAddUpToTheFootprint() throws {
        for (used, host) in [(Int64(2), Int64(240)), (55, 778), (900, 600), (0, 100), (150, 1229)] {
            let result = insights(limit: 1024 * Self.MiB, used: used * Self.MiB, host: host * Self.MiB)
            let c = try #require(result["c"])
            #expect(c.guestInUseBytes + c.overheadBytes + c.strandedBytes == c.hostFootprintBytes)
            #expect(c.guestInUseBytes >= 0 && c.overheadBytes >= 0 && c.strandedBytes >= 0)
        }
    }

    @Test func busyGuestIsNotStranded() {
        // The guest really uses the memory: nothing to reclaim.
        let result = insights(limit: 2048 * Self.MiB, used: 1200 * Self.MiB, host: 1530 * Self.MiB)
        #expect(result["c"]?.isStranded == false)
    }

    @Test func smallRemainderBelowThresholdIsNotFlagged() {
        // 100 MiB above the model: under the 128 MiB minimum.
        let small = insights(limit: 1024 * Self.MiB, used: 10 * Self.MiB, host: (288 + 10 + 100) * Self.MiB)
        #expect(small["c"]?.strandedBytes == 100 * Self.MiB)
        #expect(small["c"]?.isStranded == false)
        // 233 MiB stranded on a 4 GiB footprint: over 128 MiB but under 10 %.
        let relative = insights(limit: 8192 * Self.MiB, used: 3500 * Self.MiB, host: 4096 * Self.MiB)
        #expect(relative["c"]?.strandedBytes == 233 * Self.MiB)
        #expect(relative["c"]?.isStranded == false)
    }

    @Test func onlyRunningContainersWithStatsAndAttributedFootprintsCount() {
        let containers = [
            running("a", limit: 1024 * Self.MiB),
            running("b", limit: 1024 * Self.MiB),
            ContainerSummary(id: "stopped", imageReference: "x", state: .stopped, memoryLimitBytes: 1024 * Self.MiB),
            running("nofootprint", limit: 1024 * Self.MiB),
        ]
        let stats = [
            "a": stats("a", used: 50 * Self.MiB, limit: 1024 * Self.MiB),
            "stopped": stats("stopped", used: 50 * Self.MiB, limit: 1024 * Self.MiB),
            "nofootprint": stats("nofootprint", used: 50 * Self.MiB, limit: 1024 * Self.MiB),
        ]
        let footprints = [
            HostMemoryFootprint(ownerID: "a", pid: 1, footprintBytes: 700 * Self.MiB),
            HostMemoryFootprint(ownerID: "b", pid: 2, footprintBytes: 700 * Self.MiB),
            HostMemoryFootprint(ownerID: "stopped", pid: 3, footprintBytes: 700 * Self.MiB),
            HostMemoryFootprint(ownerID: nil, pid: 4, footprintBytes: 700 * Self.MiB),
            HostMemoryFootprint(ownerID: "dev", pid: 5, footprintBytes: 1200 * Self.MiB),
        ]
        let result = MemoryInsights(containers: containers, stats: stats, footprints: footprints)
        #expect(result.containers.map(\.id) == ["a"])
        #expect(result.totals.hostFootprintBytes == 700 * Self.MiB)
    }

    @Test func limitFallsBackToStatsAndFootprintsAreSummedPerOwner() throws {
        let container = ContainerSummary(id: "c", imageReference: "x", state: .running)
        let result = MemoryInsights(
            containers: [container], stats: ["c": stats("c", used: 20 * Self.MiB, limit: 2048 * Self.MiB)],
            footprints: [
                HostMemoryFootprint(ownerID: "c", pid: 1, footprintBytes: 300 * Self.MiB),
                HostMemoryFootprint(ownerID: "c", pid: 2, footprintBytes: 300 * Self.MiB),
            ])
        let c = try #require(result["c"])
        #expect(c.memoryLimitBytes == 2048 * Self.MiB)
        #expect(c.hostFootprintBytes == 600 * Self.MiB)
        #expect(c.overheadBytes == 313 * Self.MiB)
        #expect(c.isStranded)
    }

    @Test func sortedByStrandedThenName() {
        let ids = ["b", "a", "c"]
        let hosts: [String: Int64] = ["a": 600, "b": 900, "c": 600]
        let result = MemoryInsights(
            containers: ids.map { running($0, limit: 1024 * Self.MiB) },
            stats: Dictionary(uniqueKeysWithValues: ids.map { ($0, stats($0, used: 10 * Self.MiB, limit: 1024 * Self.MiB)) }),
            footprints: ids.map { HostMemoryFootprint(ownerID: $0, pid: 1, footprintBytes: hosts[$0]! * Self.MiB) })
        #expect(result.containers.map(\.id) == ["b", "a", "c"])
        #expect(result.totals.strandedCount == 3)
        #expect(result.totals.hostFootprintBytes == 2100 * Self.MiB)
        #expect(result.totals.guestInUseBytes + result.totals.overheadBytes + result.totals.strandedBytes == 2100 * Self.MiB)
    }

    @Test func demoFixtureShowsOneStrandedContainer() async throws {
        let backend = FixtureBackend(directory: TestFixtures.set("demo"))
        let containers = try await backend.listContainers()
        let stats = Dictionary(uniqueKeysWithValues: try await backend.containerStats().map { ($0.id, $0) })
        let result = MemoryInsights(containers: containers, stats: stats, footprints: try await backend.hostMemoryFootprints())
        #expect(result.stranded.map(\.id) == ["postgres"])
        let postgres = try #require(result["postgres"])
        #expect(postgres.hostFootprintBytes > 1_200 * Self.MB)
        #expect(postgres.guestInUseBytes < 160 * Self.MB)
        #expect(postgres.strandedBytes > 700 * Self.MiB)
    }
}
