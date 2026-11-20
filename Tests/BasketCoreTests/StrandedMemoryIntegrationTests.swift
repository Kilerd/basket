import Foundation
import Testing
@testable import BasketCore

/// Real stranded-memory check. Opt in with `BASKET_STRAND_CONTAINER=<name>` naming a running
/// `basket-test-*` container whose guest allocated memory and freed it again. Restarts it.
@Suite(
    "Stranded memory (real container CLI)",
    .enabled(if: ProcessInfo.processInfo.environment["BASKET_STRAND_CONTAINER"]?.hasPrefix("basket-test-") == true),
    .serialized)
struct StrandedMemoryIntegrationTests {
    let backend = CLIBackend()
    let name = ProcessInfo.processInfo.environment["BASKET_STRAND_CONTAINER"] ?? ""

    private func insights() async throws -> MemoryInsights {
        let containers = try await backend.listContainers()
        let stats = Dictionary(uniqueKeysWithValues: try await backend.containerStats().map { ($0.id, $0) })
        return MemoryInsights(containers: containers, stats: stats, footprints: try await backend.hostMemoryFootprints())
    }

    private func report(_ label: String, _ b: MemoryInsights.Breakdown) {
        let mib = { (bytes: Int64) in String(format: "%.0f MiB", Double(bytes) / 1_048_576) }
        print("[strand] \(label): host \(mib(b.hostFootprintBytes)), guest \(mib(b.guestInUseBytes)), overhead \(mib(b.overheadBytes)), stranded \(mib(b.strandedBytes)), flagged \(b.isStranded)")
    }

    @Test func flaggedThenReclaimedByRestart() async throws {
        let container = try #require(try await backend.listContainers().first { $0.id == name })
        #expect(container.removeOnStop == false)
        let before = try #require(try await insights()[name])
        report("before", before)
        #expect(before.isStranded)

        let outcome = await MemoryReclaim.restart([name], using: backend)
        #expect(outcome.restarted == [name], "\(outcome)")
        // Let the fresh guest boot and settle before measuring.
        try await Task.sleep(for: .seconds(5))
        let after = try #require(try await insights()[name])
        report("after", after)
        #expect(!after.isStranded)
        #expect(after.hostFootprintBytes < before.hostFootprintBytes - before.strandedBytes / 2)
        print("[strand] returned \((before.hostFootprintBytes - after.hostFootprintBytes) / 1_048_576) MiB to macOS")
    }
}
