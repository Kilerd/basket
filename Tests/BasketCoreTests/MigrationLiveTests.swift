import Foundation
import Testing
@testable import BasketCore

/// Against the user's real OrbStack (read-only: list/inspect/save) and the real `container` CLI.
/// Opt in with `BASKET_MIGRATION_LIVE=1` while OrbStack is running. Imports one small public image
/// and recreates one container as `basket-test-mig-*`, then removes everything it created in Basket.
@Suite(
    "Migration (live OrbStack → container)",
    .enabled(if: ProcessInfo.processInfo.environment["BASKET_MIGRATION_LIVE"] == "1"),
    .serialized)
struct MigrationLiveTests {
    let migrator = OrbStackMigrator.host()
    let backend = CLIBackend()

    func log(_ message: String) { print("[migration-live] \(message)") }

    /// Images Basket already lists under an OrbStack reference: logs the content verdict for each.
    @Test func comparesNameMatchesByContent() async throws {
        let images = try await migrator.listImages()
        let basket = try await backend.listImages()
        let presence = await migrator.basketPresence(of: images, basket: basket, backend: backend)
        let matches = images.filter { presence[$0.id]?.nameIsTaken == true }
        for image in matches { log("\(image.reference ?? image.imageID): \(String(describing: presence[image.id]!))") }
        log("\(matches.count) name matches, \(matches.filter { presence[$0.id] == .identical }.count) identical")
    }

    @Test func engineIsUpAndListsReadOnly() async throws {
        #expect(OrbStackEngine.isUp())
        guard case .ready(let version) = await migrator.status() else {
            Issue.record("OrbStack isn't ready")
            return
        }
        let clock = ContinuousClock()
        var images: [OrbStackImage] = []
        let listing = try await clock.measure { images = try await migrator.listImages() }
        var containers: [OrbStackContainer] = []
        let listingContainers = try await clock.measure { containers = try await migrator.listContainers() }
        log("docker \(version ?? "?"): \(images.count) images (\(images.filter(\.isDangling).count) dangling) in \(listing), \(containers.count) containers in \(listingContainers)")
        #expect(!images.isEmpty)
        let host = images.filter(\.isHostNative).count
        log("platforms: \(host) host-native, \(images.filter { $0.platform != nil && !$0.isHostNative }.count) foreign-only, \(images.filter { $0.platform == nil }.count) unknown")
    }

    @Test func importsASmallImageHostOnlyThenRemovesIt() async throws {
        let images = try await migrator.listImages()
        let before = try await backend.listImages()
        let basket = OrbStackMigrator.basketReferences(before)
        let candidate = try #require(
            images.first { $0.reference == "busybox:latest" && $0.isHostNative && !OrbStackMigrator.nameIsTaken($0, basket: basket) }
                ?? images.filter { $0.isHostNative && !$0.isUntagged && $0.sizeBytes < 20_000_000 && !OrbStackMigrator.nameIsTaken($0, basket: basket) }
                    .min { $0.sizeBytes < $1.sizeBytes },
            "a small host-native image that isn't in Basket yet")
        let reference = try #require(candidate.basketReference)
        let start = ContinuousClock.now
        var archive: Int64 = 0
        for try await step in migrator.importImage(candidate, into: backend) {
            if case .done(_, let bytes) = step.phase { archive = bytes }
        }
        let elapsed = ContinuousClock.now - start
        let after = try await backend.listImages()
        let imported = try #require(after.first { $0.reference == reference })
        log("imported \(candidate.reference ?? "") (\(candidate.sizeBytes) B in OrbStack) as \(reference): archive \(archive) B, "
            + "variants \(imported.variants.map(\.platform)), \(imported.totalSizeBytes) B in Basket, \(elapsed)")
        #expect(imported.variants.allSatisfy { $0.platform.hasPrefix("linux/arm64") })
        #expect(imported.hostVariantSizeBytes > 0 && imported.totalSizeBytes == imported.hostVariantSizeBytes)
        let strays = Set(after.map(\.reference)).subtracting(before.map(\.reference)).subtracting([reference])
        #expect(strays.isEmpty, "no attestation leftovers: \(strays)")

        // The imported copy verifies by content (same platform manifest), so a second import is skipped
        // and — when no OrbStack container uses it — it is offered for cleanup.
        let presence = await migrator.basketPresence(of: [candidate], basket: after, backend: backend)
        log("presence of \(candidate.reference ?? "") after import: \(String(describing: presence[candidate.id]))")
        #expect(presence[candidate.id] == .identical)
        await #expect(throws: MigrationError.alreadyInBasket(reference)) {
            for try await _ in migrator.importImage(candidate, into: backend) {}
        }
        if candidate.containerCount == 0 {
            #expect(OrbStackMigrator.reclaimable(images.filter { $0.imageID == candidate.imageID }, presence: presence)
                .references.contains(candidate.reference ?? ""))
        }
        // Content, not names: OrbStack's image compared with an unrelated Basket image is a conflict.
        if let other = after.first(where: { $0.reference != reference && !$0.reference.hasPrefix("untagged@") }) {
            let source = try #require(try await migrator.orbStackIdentity(candidate))
            let text = try await backend.inspectImage(other.reference)
            let unrelated = try JSONDecoder().decode([RawBasketImageInspect].self, from: Data(text.utf8)).first?.identities ?? []
            let verdict = ImageContentComparison.compare(source, with: unrelated)
            log("\(candidate.reference ?? "") vs Basket's \(other.reference): \(verdict)")
            if case .nameConflict = verdict {} else { Issue.record("expected a conflict, got \(verdict)") }
        }
        let scratch = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
        #expect(scratch.allSatisfy { !$0.hasPrefix("basket-orbstack-import-") }, "archive removed")

        try await backend.deleteImages([reference], force: false)
        #expect(try await backend.listImages().contains { $0.reference == reference } == false)
    }

    @Test func recreatesARedisContainerThenRemovesIt() async throws {
        let containers = try await migrator.listContainers()
        let images = try await migrator.listImages()
        let source = try #require(containers.first { $0.image == "redis:7" && !$0.isRunning } ?? containers.first { $0.image.hasPrefix("redis") },
                                  "a redis container in OrbStack")
        let image = images.first { $0.imageID == source.imageID && !$0.isUntagged }
        let name = "basket-test-mig-redis"
        let plan = RecreationPlanner.plan(for: source, image: image, options: RecreationOptions(name: name))
        log("plan for \(source.name) (\(source.image)):\n" + plan.script)
        for warning in plan.warnings { log("  \(warning.severity == .warning ? "warning" : "note"): \(warning.topic): \(warning.message)") }

        let imagesBefore = Set(try await backend.listImages().map(\.reference))
        let volumesBefore = Set(try await backend.listVolumes().map(\.name))
        let start = ContinuousClock.now
        let id = try await migrator.recreate(plan, sourceImage: image, into: backend) { self.log("  \($0)") }
        log("recreated as \(id) in \(ContinuousClock.now - start)")

        var running = false
        for _ in 0..<40 {
            if try await backend.listContainers().first(where: { $0.id == id })?.state == .running { running = true; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(running)
        let logs = try await backend.logs(id, tail: 20)
        log("logs:\n" + logs)
        #expect(logs.contains("Ready to accept connections"))
        if plan.runSpec.ports.contains("6379:6379") {
            let shell = CLIRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
            let ping = try await shell.run(["-c", #"(printf 'PING\r\n'; sleep 1) | nc -w 3 127.0.0.1 6379"#], timeout: .seconds(10))
            log("PING via the published port: \(ping.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))")
            #expect(ping.stdoutText.contains("PONG"))
        }
        if let footprint = try await backend.hostMemoryFootprints().first(where: { $0.ownerID == id }) {
            log("host footprint \(footprint.footprintBytes / 1_048_576) MB")
        }

        try await backend.deleteContainers([id], force: true)
        // Only what this test created (other lanes may be creating resources concurrently).
        let createdImages = imagesBefore.contains(plan.image) ? [] : [plan.image]
        if !createdImages.isEmpty { try await backend.deleteImages(createdImages, force: false) }
        let createdVolumes = plan.volumes.filter { !volumesBefore.contains($0) }
        if !createdVolumes.isEmpty { try await backend.deleteVolumes(createdVolumes) }
        #expect(try await backend.listContainers().contains { $0.id == id } == false)
        log("cleaned up: container \(id), images \(createdImages.sorted()), volumes \(createdVolumes.sorted())")
    }
}
