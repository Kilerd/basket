import Foundation
import Testing
@testable import BasketCore

/// "Already in Basket" by content: the comparison itself, and imports/recreations refusing to treat a
/// name match as the same image (fake `docker`/`container` scripts).
@Suite("OrbStack migration: content-based presence")
struct MigrationPresenceTests {
    static let config = ImageRuntimeConfig(environment: ["PATH=/bin"], command: ["sh"])

    func identity(
        _ platform: String = "linux/arm64/v8", digest: String? = "sha256:m1", layers: [String] = ["sha256:l1"],
        config: ImageRuntimeConfig = config, created: String? = "2026-05-14T12:00:00Z"
    ) -> ImageContentIdentity {
        ImageContentIdentity(platform: platform, manifestDigest: digest, diffIDs: layers, config: config, created: created)
    }

    // MARK: Comparison

    @Test func sameManifestIsIdentical() {
        #expect(ImageContentComparison.compare(identity(), with: [identity("linux/amd64", digest: "sha256:x"), identity()]) == .identical)
    }

    @Test func sameLayersConfigAndCreationAreIdenticalEvenWithAnotherManifest() {
        // e.g. re-compressed layers: a different manifest for the same content.
        let basket = identity(digest: "sha256:other", created: "2026-05-14T12:00:00.000Z")
        #expect(ImageContentComparison.compare(identity(digest: nil), with: [basket]) == .identical)
        #expect(ImageContentComparison.compare(identity(), with: [basket]) == .identical)
    }

    @Test func anyDifferenceIsANameConflict() {
        let source = identity(digest: "sha256:m1")
        #expect(ImageContentComparison.compare(source, with: [identity(digest: "sha256:m2", layers: ["sha256:l2"])])
            == .nameConflict("its layers differ"))
        var changed = Self.config
        changed.command = ["httpd"]
        #expect(ImageContentComparison.compare(source, with: [identity(digest: "sha256:m2", config: changed)])
            == .nameConflict("same layers, but its configuration differs"))
        #expect(ImageContentComparison.compare(source, with: [identity(digest: "sha256:m2", created: "2026-06-01T00:00:00Z")])
            == .nameConflict("same layers and configuration, but built at a different time"))
        #expect(ImageContentComparison.compare(source, with: [identity("linux/amd64")])
            == .nameConflict("Basket's copy has no linux/arm64/v8 variant; it has linux/amd64"))
        #expect(ImageContentComparison.compare(source, with: []) == .nameConflict("Basket's copy has no linux/arm64/v8 variant"))
    }

    @Test func missingLayerListsCantBeCompared() {
        let basket = identity(digest: "sha256:m2", layers: [])
        #expect(ImageContentComparison.compare(identity(), with: [basket]) == .unverified("their layer lists couldn't be read"))
    }

    @Test func platformsMatchOnOSArchitectureAndExplicitVariants() {
        #expect(ImageContentComparison.samePlatform("linux/arm64", "linux/arm64/v8"))
        #expect(ImageContentComparison.samePlatform("linux/arm/v7", "linux/arm/v7"))
        #expect(!ImageContentComparison.samePlatform("linux/arm/v6", "linux/arm/v7"))
        #expect(!ImageContentComparison.samePlatform("linux/amd64", "linux/arm64"))
        #expect(!ImageContentComparison.samePlatform("unknown/unknown", "linux/arm64"))
    }

    @Test func decodesBasketInspectOutput() throws {
        let data = try TestFixtures.real("image-inspect.json")
        let identities = try JSONDecoder().decode([RawBasketImageInspect].self, from: data).first?.identities ?? []
        let arm64 = try #require(identities.first { $0.platform == "linux/arm64/v8" })
        #expect(arm64.manifestDigest?.hasPrefix("sha256:") == true && arm64.diffIDs.count == 1)
        #expect(arm64.config.command == ["/bin/sh"] && arm64.created != nil)
        #expect(identities.allSatisfy { !$0.platform.hasPrefix("unknown") }, "attestations left out")
    }

    // MARK: Import and recreate against the CLI

    let busybox = OrbStackImage(
        imageID: "sha256:a46257e0", repository: "busybox", tag: "latest", reference: "busybox:latest",
        sizeBytes: 6_139_453, platform: "linux/arm64/v8")

    /// OrbStack's busybox: manifest `sha256:feed01`, one layer.
    static let dockerInspect = #"[{"Id":"sha256:feed01","RepoTags":["busybox:latest"],"Created":"2026-05-14T12:00:00Z","Config":{"Env":["PATH=/bin"],"Cmd":["sh"]},"Architecture":"arm64","Variant":"v8","Os":"linux","Size":6139453,"RootFS":{"Type":"layers","Layers":["sha256:1a1a"]},"Descriptor":{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:feed01","size":610}}]"#

    /// Basket's image list/inspect element named busybox:latest with the given arm64 manifest and layer.
    static func basketImage(manifest: String, layer: String) -> String {
        #"[{"configuration":{"name":"docker.io/library/busybox:latest","descriptor":{"digest":"sha256:cafe","mediaType":"application/vnd.oci.image.index.v1+json","size":500}},"id":"cafe","variants":[{"digest":"\#(manifest)","platform":{"architecture":"arm64","os":"linux","variant":"v8"},"size":2000000,"config":{"architecture":"arm64","os":"linux","created":"2026-05-14T12:00:00Z","config":{"Cmd":["sh"],"Env":["PATH=/bin"]},"rootfs":{"type":"layers","diff_ids":["\#(layer)"]}}}]}]"#
    }

    func fakes(_ directory: TemporaryDirectory, basket: String) throws -> (OrbStackMigrator, CLIBackend) {
        let dockerLog = shellQuote(directory.url.appendingPathComponent("docker.log").path)
        let docker = try directory.script("docker", """
            echo "$*" >> \(dockerLog)
            case "$*" in
              *"image inspect --platform"*) echo \(shellQuote(Self.dockerInspect)) ;;
              *" save "*) out=""; prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
                dd if=/dev/zero of="$out" bs=1024 count=8 2>/dev/null ;;
              *) echo "unexpected: $*" >&2; exit 1 ;;
            esac
            """)
        let containerLog = shellQuote(directory.url.appendingPathComponent("container.log").path)
        let container = try directory.script("container", """
            echo "$*" >> \(containerLog)
            case "$*" in
              "image list --format json"|"image inspect "*) echo \(shellQuote(basket)) ;;
              "volume list --format json") echo '[]' ;;
              "run "*) echo "basket-test-mig-x" ;;
              *) echo "Error: unexpected arguments: $*" >&2; exit 1 ;;
            esac
            """)
        let scratch = directory.url.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let migrator = OrbStackMigrator(
            docker: ProcessDockerClient(executableURL: URL(fileURLWithPath: docker)), presence: .always,
            temporaryDirectory: scratch, freeSpace: { _ in nil })
        return (migrator, CLIBackend(cliPath: container))
    }

    func log(_ directory: TemporaryDirectory, _ name: String) -> [String] {
        ((try? String(contentsOf: directory.url.appendingPathComponent(name), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func drain(_ stream: AsyncThrowingStream<ImportProgress, Error>) async throws {
        for try await _ in stream {}
    }

    @Test func importRefusesADifferentImageUnderTheSameName() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let (migrator, backend) = try fakes(directory, basket: Self.basketImage(manifest: "sha256:0ther", layer: "sha256:2b2b"))
        let presence = await migrator.basketPresence(of: [busybox], basket: try await backend.listImages(), backend: backend)
        #expect(presence[busybox.id] == .nameConflict("its layers differ"))
        await #expect(throws: MigrationError.nameConflict(reference: "docker.io/library/busybox:latest", reason: "its layers differ")) {
            try await drain(migrator.importImage(busybox, into: backend))
        }
        #expect(!log(directory, "docker.log").contains { $0.contains(" save ") }, "nothing exported")
        #expect(!log(directory, "container.log").contains { $0.hasPrefix("image load") }, "Basket's image not repointed")
        #expect(OrbStackMigrator.reclaimable([busybox], presence: presence).references.isEmpty)
    }

    @Test func importSkipsTheSameImage() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let (migrator, backend) = try fakes(directory, basket: Self.basketImage(manifest: "sha256:feed01", layer: "sha256:1a1a"))
        let presence = await migrator.basketPresence(of: [busybox], basket: try await backend.listImages(), backend: backend)
        #expect(presence[busybox.id] == .identical)
        await #expect(throws: MigrationError.alreadyInBasket("docker.io/library/busybox:latest")) {
            try await drain(migrator.importImage(busybox, into: backend))
        }
        #expect(!log(directory, "docker.log").contains { $0.contains(" save ") })
        #expect(OrbStackMigrator.reclaimable([busybox], presence: presence).references == ["busybox:latest"])
    }

    @Test func recreateRefusesToRunFromADifferentImageWithTheSameName() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let (migrator, backend) = try fakes(directory, basket: Self.basketImage(manifest: "sha256:0ther", layer: "sha256:2b2b"))
        let source = OrbStackContainer(id: "c0ffee", name: "box", image: "busybox:latest", imageID: busybox.imageID)
        let plan = RecreationPlanner.plan(for: source, image: busybox, options: RecreationOptions(name: "basket-test-mig-x"))
        await #expect(throws: MigrationError.self) {
            _ = try await migrator.recreate(plan, sourceImage: busybox, into: backend)
        }
        #expect(!log(directory, "container.log").contains { $0.hasPrefix("run ") }, "never ran")
    }

    // MARK: Scratch directories

    @Test func sweepRemovesOnlyDirectoriesOfDeadBasketsAndOldUnownedOnes() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let fileManager = FileManager.default
        func make(_ name: String, owner: Int32?, age: TimeInterval = 0) throws -> URL {
            let url = directory.url.appendingPathComponent(name)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(count: 16).write(to: url.appendingPathComponent("image.tar"))
            if let owner { try Data("\(owner)".utf8).write(to: url.appendingPathComponent(OrbStackMigrator.importOwnerFile)) }
            try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        let dead = try make("basket-orbstack-import-dead", owner: 999_999)
        let alive = try make("basket-orbstack-import-alive", owner: 4242)
        let mine = try make("basket-orbstack-import-mine", owner: getpid())
        let oldUnowned = try make("basket-orbstack-import-old", owner: nil, age: 7200)
        let newUnowned = try make("basket-orbstack-import-new", owner: nil, age: 60)
        let unrelated = try make("something-else", owner: 999_999)

        let removed = OrbStackMigrator.sweepImportDirectories(in: directory.url, isAlive: { $0 == 4242 })
        #expect(Set(removed.map(\.lastPathComponent)) == [dead.lastPathComponent, oldUnowned.lastPathComponent])
        for kept in [alive, mine, newUnowned, unrelated] { #expect(fileManager.fileExists(atPath: kept.path)) }

        let quitting = OrbStackMigrator.sweepImportDirectories(in: directory.url, includingOwn: true, isAlive: { $0 == 4242 })
        #expect(quitting.map(\.lastPathComponent) == [mine.lastPathComponent])
    }

    @Test func importDirectoriesRecordTheirOwnerAndAreRemovedAfterwards() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let made = try OrbStackMigrator.makeImportDirectory(in: directory.url)
        let owner = try String(contentsOf: made.appendingPathComponent(OrbStackMigrator.importOwnerFile), encoding: .utf8)
        #expect(owner == "\(getpid())")
        #expect(OrbStackMigrator.allocatedSize(of: made) == 0, "the owner file isn't counted as archive bytes")
    }
}
