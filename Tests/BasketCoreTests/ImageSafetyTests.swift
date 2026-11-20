import CryptoKit
import Foundation
import Testing
@testable import BasketCore

private let alpine = "docker.io/library/alpine:latest"

@Suite("ImageArchive")
struct ImageArchiveTests {
    @Test func syntheticArchiveRoundTrips() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let url = directory.url.appendingPathComponent("a.tar")
        let variants = [
            ImageVariant(platform: "linux/arm64/v8", digest: "sha256:" + String(repeating: "a", count: 64), sizeBytes: 5_000_000),
            ImageVariant(platform: "linux/amd64", digest: "sha256:" + String(repeating: "b", count: 64), sizeBytes: 4_000_000),
        ]
        try ImageArchive.writeSynthetic(reference: "docker.io/library/demo:1", variants: variants, to: url)
        let archive = try ImageArchive.inspect(url)
        #expect(archive.references == ["docker.io/library/demo:1"])
        #expect(archive.manifests.map(\.platform) == ["linux/arm64/v8", "linux/amd64"])
        #expect(archive.manifests.first?.annotations[ImageArchive.fixtureSizeAnnotation] == "5000000")
        #expect(archive.indexDigest?.hasPrefix("sha256:") == true)
        #expect(archive.fileSize > 9_000_000)
        // The variant bytes are holes: the file claims 9 MB but allocates almost nothing.
        let allocated = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0
        #expect(allocated < 1_000_000)
    }

    /// The layout `container image save` 1.7.1 writes: `./`-prefixed names, a nested index and an
    /// attestation manifest next to the platform one.
    @Test func readsCLIStyleLayoutAndSkipsAttestations() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let url = directory.url.appendingPathComponent("cli.tar")
        let inner = Data("""
            {"schemaVersion":2,"manifests":[
              {"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:1111","size":1025,
               "platform":{"architecture":"arm64","os":"linux","variant":"v8"}},
              {"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:2222","size":800,
               "platform":{"architecture":"unknown","os":"unknown"},
               "annotations":{"vnd.docker.reference.type":"attestation-manifest"}}]}
            """.utf8)
        let index = Data("""
            {"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.index.v1+json",
             "digest":"sha256:abcd","size":\(inner.count),
             "annotations":{"org.opencontainers.image.ref.name":"docker.io/library/demo:2"}}]}
            """.utf8)
        var tar = try TarWriter(url: url)
        try tar.append("./oci-layout", Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8))
        try tar.append("./blobs/sha256/abcd", inner)
        try tar.appendSparse("./blobs/sha256/1111", size: 4_000)
        try tar.append("./index.json", index)
        try tar.close()

        let archive = try ImageArchive.inspect(url)
        #expect(archive.references == ["docker.io/library/demo:2"])
        #expect(archive.manifests.map(\.platform) == ["linux/arm64/v8"])
        #expect(archive.indexDigest == "sha256:abcd")
    }

    @Test func rejectsMissingEmptyAndForeignFiles() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        #expect(throws: ImageArchive.Invalid.self) { try ImageArchive.inspect(directory.url.appendingPathComponent("none.tar")) }
        let empty = directory.url.appendingPathComponent("empty.tar")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        #expect(throws: ImageArchive.Invalid.self) { try ImageArchive.inspect(empty) }
        let garbage = directory.url.appendingPathComponent("garbage.tar")
        FileManager.default.createFile(atPath: garbage.path, contents: Data(repeating: 0x41, count: 4096))
        #expect(throws: ImageArchive.Invalid.self) { try ImageArchive.inspect(garbage) }
        let noIndex = directory.url.appendingPathComponent("noindex.tar")
        var tar = try TarWriter(url: noIndex)
        try tar.append("oci-layout", Data(repeating: 0x20, count: 2048))
        try tar.close()
        #expect(throws: ImageArchive.Invalid(reason: "the archive has no index.json")) { try ImageArchive.inspect(noIndex) }
    }
}

@Suite("ImageUsage")
struct ImageUsageTests {
    @Test func countsContainersAndMachinesWithNormalisedReferences() {
        let usage = ImageUsage(
            containers: [
                ContainerSummary(id: "web", imageReference: "nginx", state: .running),
                ContainerSummary(id: "job", imageReference: "docker.io/library/nginx:latest", state: .stopped),
            ],
            machines: [MachineSummary(id: "dev", image: "docker.io/library/ubuntu:24.04", state: .stopped)])
        #expect(usage.users(of: "docker.io/library/nginx:latest").containers == ["web", "job"])
        #expect(usage.users(of: "ubuntu:24.04").machines == ["dev"])
        #expect(usage.users(of: "ubuntu:24.04").description == "machine dev")
        #expect(usage.users(of: "nginx").description == "web and job")
        let images = ["docker.io/library/nginx:latest", "docker.io/library/ubuntu:24.04", "docker.io/library/redis:7"]
            .map { ImageSummary(reference: $0, digest: "") }
        #expect(usage.unused(images).map(\.reference) == ["docker.io/library/redis:7"])
    }
}

/// `ImageStore` over a FixtureBackend that records calls and can be told to misbehave.
actor ScriptedStore: ImageStore {
    enum Fault: Sendable {
        case saveFails, saveWritesGarbage, saveIgnoresPlatform
        case loadFailsCleanly, loadFailsAfterDeleting, loadKeepsEveryVariant, loadDropsHostVariant
    }

    let backend: FixtureBackend
    var faults: Set<Fault>
    private(set) var calls: [String] = []

    init(faults: Set<Fault> = []) {
        backend = FixtureBackend(directory: TestFixtures.set("demo"))
        self.faults = faults
    }

    func listImages() async throws -> [ImageSummary] {
        calls.append("list")
        return try await backend.listImages()
    }

    func saveImage(_ reference: String, platform: String?, to archive: URL) async throws {
        calls.append("save \(reference) \(platform ?? "all")")
        if faults.contains(.saveFails) {
            FileManager.default.createFile(atPath: archive.path, contents: Data("partial".utf8))
            throw BackendError.commandFailed(command: "container image save", exitCode: 1, stderr: "registry offline")
        }
        if faults.contains(.saveWritesGarbage) {
            FileManager.default.createFile(atPath: archive.path, contents: Data(repeating: 0, count: 8192))
            return
        }
        try await backend.saveImage(reference, platform: faults.contains(.saveIgnoresPlatform) ? nil : platform, to: archive)
    }

    func loadImage(from archive: URL) async throws -> [String] {
        calls.append("load")
        if faults.contains(.loadFailsCleanly) {
            throw BackendError.commandFailed(command: "container image load", exitCode: 1, stderr: "disk full")
        }
        if faults.contains(.loadFailsAfterDeleting) {
            try await backend.deleteImages([alpine], force: false)
            throw BackendError.commandFailed(command: "container image load", exitCode: 1, stderr: "interrupted")
        }
        if faults.contains(.loadKeepsEveryVariant) { return [alpine] }
        if faults.contains(.loadDropsHostVariant) {
            let full = directory(of: archive).appendingPathComponent("amd64.tar")
            try await backend.saveImage(alpine, platform: "linux/amd64", to: full)
            return try await backend.loadImage(from: full)
        }
        return try await backend.loadImage(from: archive)
    }

    func tagImage(_ source: String, as target: String) async throws {
        calls.append("tag \(target.contains(":basket-reclaim-") ? "temporary" : target)")
        try await backend.tagImage(source, as: target)
    }

    func deleteImages(_ references: [String], force: Bool) async throws {
        calls.append("delete " + references.map { $0.contains(":basket-reclaim-") ? "temporary" : $0 }.joined(separator: " "))
        try await backend.deleteImages(references, force: force)
    }

    private func directory(of url: URL) -> URL { url.deletingLastPathComponent() }
}

@Suite("ImageSlimmer")
struct ImageSlimmerTests {
    func slimmer(_ store: any ImageStore, _ directory: TemporaryDirectory, free: Int64? = 1 << 40) -> ImageSlimmer {
        ImageSlimmer(store: store, workDirectory: directory.url.appendingPathComponent("work"), availableBytes: { _ in free })
    }

    func archives(_ directory: TemporaryDirectory) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.url.appendingPathComponent("work").path)) ?? []
    }

    func image(_ store: ScriptedStore, _ reference: String = alpine) async throws -> ImageSummary? {
        try await store.backend.listImages().first { $0.reference == reference }
    }

    @Test func keepsOnlyTheHostVariantWithoutEverRemovingTheReference() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let store = ScriptedStore()
        let before = try #require(try await image(store))
        #expect(ImageSlimmer.canSlim(before))

        let steps = StepLog()
        let outcome = try await slimmer(store, directory).slim(alpine) { steps.append($0) }

        #expect(steps.all == ImageSlimmer.Step.allCases)
        // Save → load over the same reference → throwaway tag deleted. The image itself is never deleted.
        #expect(await store.calls == ["list", "save \(alpine) linux/arm64", "load", "list", "tag temporary", "delete temporary"])
        let after = try #require(try await image(store))
        #expect(after.variants.map(\.platform) == ["linux/arm64/v8"])
        #expect(after.totalSizeBytes == before.hostVariantSizeBytes)
        #expect(after.digest != before.digest)
        #expect(outcome.reclaimed && outcome.after.variants.count == 1)
        #expect(!ImageSlimmer.canSlim(after))
        #expect(try await store.backend.listImages().allSatisfy { !$0.reference.contains("basket-reclaim") })
        #expect(archives(directory).isEmpty)
    }

    @Test func failedSaveChangesNothing() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        for fault in [ScriptedStore.Fault.saveFails, .saveWritesGarbage, .saveIgnoresPlatform] {
            let store = ScriptedStore(faults: [fault])
            let before = try await image(store)
            await #expect {
                _ = try await slimmer(store, directory).slim(alpine)
            } throws: { error in
                guard case SlimError.saveFailed(let message) = error else { return false }
                return (error as? SlimError)?.errorDescription?.hasSuffix("Nothing was changed.") == true && !message.isEmpty
            }
            #expect(await store.calls.contains("load") == false, "\(fault)")
            #expect(try await image(store) == before, "\(fault)")
            #expect(archives(directory).isEmpty, "\(fault)")
        }
    }

    @Test func failedLoadWithTheOriginalIntactDropsTheArchive() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let store = ScriptedStore(faults: [.loadFailsCleanly])
        let before = try await image(store)
        await #expect {
            _ = try await slimmer(store, directory).slim(alpine)
        } throws: { error in
            guard case SlimError.loadFailed = error else { return false }
            return true
        }
        #expect(try await image(store) == before)
        #expect(archives(directory).isEmpty)
    }

    @Test func failedLoadAfterTheOriginalWentAwayKeepsTheArchiveAndSaysWhere() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let store = ScriptedStore(faults: [.loadFailsAfterDeleting])
        var kept: URL?
        do {
            _ = try await slimmer(store, directory).slim(alpine)
            Issue.record("expected a failure")
        } catch let error as SlimError {
            if case .needsRecovery(_, let archive) = error { kept = archive }
            let message = error.errorDescription ?? ""
            #expect(kept.map { message.contains($0.path) } == true)
            #expect(message.contains("container image load --input"))
        }
        let archive = try #require(kept)
        #expect(FileManager.default.fileExists(atPath: archive.path))
        // The kept archive restores the image (host variant only).
        _ = try await store.backend.loadImage(from: archive)
        #expect(try await image(store)?.variants.map(\.platform) == ["linux/arm64/v8"])
    }

    @Test func loadThatLosesTheHostVariantKeepsTheArchive() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let store = ScriptedStore(faults: [.loadDropsHostVariant])
        await #expect {
            _ = try await slimmer(store, directory).slim(alpine)
        } throws: { error in
            guard case SlimError.needsRecovery = error else { return false }
            return true
        }
        #expect(archives(directory).contains { $0.hasPrefix("alpine-latest-") })
    }

    @Test func cliKeepingEveryVariantIsReportedNotHidden() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let store = ScriptedStore(faults: [.loadKeepsEveryVariant])
        await #expect(throws: SlimError.notSlimmed(alpine)) { _ = try await slimmer(store, directory).slim(alpine) }
        #expect(await store.calls.contains { $0.hasPrefix("tag") || $0.hasPrefix("delete") } == false)
        #expect(archives(directory).isEmpty)
    }

    @Test func refusesWithoutAHostVariantOrSpace() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let store = ScriptedStore()
        // A single-platform image: nothing to remove.
        await #expect(throws: SlimError.nothingToRemove("docker.io/library/redis:7-alpine")) {
            _ = try await slimmer(store, directory).slim("docker.io/library/redis:7-alpine")
        }
        await #expect(throws: SlimError.imageNotFound("ghost:1")) { _ = try await slimmer(store, directory).slim("ghost:1") }
        await #expect {
            _ = try await slimmer(store, directory, free: 1_000).slim(alpine)
        } throws: { error in
            guard case SlimError.notEnoughSpace = error else { return false }
            return true
        }
        #expect(await store.calls.allSatisfy { $0 == "list" })

        let amd64Only = ImageSummary(
            reference: "x", digest: "", variants: [ImageVariant(platform: "linux/amd64", digest: "", sizeBytes: 1),
                                                   ImageVariant(platform: "linux/386", digest: "", sizeBytes: 1)],
            hostVariantSizeBytes: 0, totalSizeBytes: 2)
        #expect(!ImageSlimmer.canSlim(amd64Only))
    }

    @Test func temporaryReferenceStaysInTheSameRepository() {
        #expect(ImageSlimmer.repository(of: "docker.io/library/alpine:latest") == "docker.io/library/alpine")
        #expect(ImageSlimmer.repository(of: "localhost:5000/team/app:v1") == "localhost:5000/team/app")
        #expect(ImageSlimmer.repository(of: "localhost:5000/app@sha256:abc") == "localhost:5000/app")
        #expect(ImageSlimmer.temporaryReference(for: "basket-test-x:v1").hasPrefix("basket-test-x:basket-reclaim-"))
        #expect(ImageSlimmer.matches("linux/arm64/v8", "linux/arm64"))
        #expect(!ImageSlimmer.matches("linux/arm/v7", "linux/arm64"))
    }
}

final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [ImageSlimmer.Step] = []
    func append(_ step: ImageSlimmer.Step) { lock.withLock { steps.append(step) } }
    var all: [ImageSlimmer.Step] { lock.withLock { steps } }
}

@Suite("Image save/load through the CLI")
struct CLIImageArchiveTests {
    @Test func argumentsAndLoadedReferences() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let log = directory.url.appendingPathComponent("calls.log").path
        let cli = try directory.script("container", """
            echo "$*" >> \(shellQuote(log))
            case "$1 $2" in
              "image save") echo "docker.io/library/demo:1" ;;
              "image load") printf 'Loading [1/2]\\ndocker.io/library/demo:1\\nuntagged@sha256:ab\\n' ;;
              *) echo "Error: unexpected" >&2; exit 1 ;;
            esac
            """)
        let backend = CLIBackend(cliPath: cli)
        let archive = directory.url.appendingPathComponent("my archive.tar")
        try await backend.saveImage("demo:1", platform: "linux/arm64", to: archive)
        #expect(try await backend.loadImage(from: archive) == ["docker.io/library/demo:1", "untagged@sha256:ab"])
        let calls = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(calls == [
            "image save --platform linux/arm64 --output \(archive.path) demo:1",
            "image load --input \(archive.path)",
        ])
    }

    @Test func fixtureBackendSavesOnlyTheRequestedPlatform() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let backend = FixtureBackend(directory: TestFixtures.set("demo"))
        let url = directory.url.appendingPathComponent("ubuntu.tar")
        try await backend.saveImage("ubuntu:24.04", platform: "linux/arm64", to: url)
        let archive = try ImageArchive.inspect(url)
        #expect(archive.references == ["docker.io/library/ubuntu:24.04"])
        #expect(archive.manifests.map(\.platform) == ["linux/arm64/v8"])
        await #expect(throws: BackendError.self) {
            try await backend.saveImage("redis:7-alpine", platform: "linux/s390x", to: url)
        }
        // Loading under an existing name repoints it.
        #expect(try await backend.loadImage(from: url) == ["docker.io/library/ubuntu:24.04"])
        let ubuntu = try #require(try await backend.listImages().first { $0.reference == "docker.io/library/ubuntu:24.04" })
        #expect(ubuntu.variants.count == 1 && ubuntu.hostVariantSizeBytes == ubuntu.totalSizeBytes)
    }
}

@Suite("ApprovedDeletion")
struct ApprovedDeletionTests {
    let volumes = [
        VolumeSummary(name: "data", source: "/Users/demo/volumes/data/volume.img"),
        VolumeSummary(name: "cache", source: "/Users/demo/volumes/cache/volume.img"),
    ]

    @Test func dropsWhateverChangedSinceTheConfirmation() {
        let approved = ApprovedDeletion(
            containers: ["old", "restarted"], images: ["docker.io/library/redis:7", "nginx", "ubuntu:24.04", "gone:1"],
            volumes: ["data", "cache"])
        let now = approved.revalidated(
            containers: [
                ContainerSummary(id: "old", imageReference: "docker.io/library/redis:7", state: .stopped),
                // Started after the user confirmed: kept, and so are its image and volume.
                ContainerSummary(id: "restarted", imageReference: "docker.io/library/nginx:latest", state: .running,
                                 mounts: [MountInfo(source: "/Users/demo/volumes/data/volume.img", destination: "/d", kind: "volume", readOnly: false)]),
            ],
            machines: [MachineSummary(id: "dev", image: "docker.io/library/ubuntu:24.04", state: .stopped)],
            images: ["docker.io/library/redis:7", "docker.io/library/nginx:latest", "docker.io/library/ubuntu:24.04"]
                .map { ImageSummary(reference: $0, digest: "") },
            volumes: volumes)
        #expect(now == ApprovedDeletion(containers: ["old"], images: ["docker.io/library/redis:7"], volumes: ["cache"]))
        #expect(approved.subtracting(now) == ApprovedDeletion(
            containers: ["restarted"], images: ["nginx", "ubuntu:24.04", "gone:1"], volumes: ["data"]))
    }

    @Test func aContainerCreatedAfterTheConfirmationProtectsItsImage() async throws {
        let backend = FixtureBackend(directory: TestFixtures.set("demo"))
        for try await _ in backend.pullImage("busybox:1.37", platform: nil) {}
        let approved = ApprovedDeletion(images: ["docker.io/library/busybox:1.37"])
        let unused = approved.revalidated(
            containers: try await backend.listContainers(), machines: try await backend.listMachines(),
            images: try await backend.listImages(), volumes: try await backend.listVolumes())
        #expect(unused == approved)
        _ = try await backend.run(RunSpec(image: "busybox:1.37", name: "late"))
        let now = approved.revalidated(
            containers: try await backend.listContainers(), machines: try await backend.listMachines(),
            images: try await backend.listImages(), volumes: try await backend.listVolumes())
        #expect(now.isEmpty)
        try await now.perform(on: backend)
        #expect(try await backend.listImages().contains { $0.reference == "docker.io/library/busybox:1.37" })
    }
}

/// The slim flow against the real CLI. Opt in with `BASKET_INTEGRATION=1`. Creates and removes only
/// `basket-test-safe-*` images; `alpine:latest` (which the first test's tag shares content with)
/// must come out unchanged.
@Suite(
    "Slim (real container CLI)",
    .enabled(if: ProcessInfo.processInfo.environment["BASKET_INTEGRATION"] == "1"),
    .serialized)
struct SlimIntegrationTests {
    let backend = CLIBackend()

    func image(_ reference: String) async throws -> ImageSummary? {
        try await backend.listImages().first { $0.reference == reference }
    }

    func describe(_ image: ImageSummary?) -> String {
        guard let image else { return "absent" }
        return "\(image.variants.count) variants (\(image.variants.map(\.platform).joined(separator: ", "))), "
            + "\(image.totalSizeBytes) bytes, digest \(image.digest.prefix(19))"
    }

    @Test func retaggedMultiArchImage() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let reference = "docker.io/library/basket-test-safe-it:v1"
        let alpineBefore = try #require(try await image(alpine))
        try await backend.tagImage(alpine, as: reference)
        defer { Task { try? await backend.deleteImages([reference], force: true) } }
        let before = try #require(try await image(reference))
        print("slim before:", describe(before))

        let slimmer = ImageSlimmer(store: BackendImageStore(backend), workDirectory: directory.url.appendingPathComponent("work"))
        let outcome = try await slimmer.slim(reference)
        let after = try #require(try await image(reference))
        print("slim after:", describe(after), "reclaimed:", outcome.reclaimed)
        #expect(after.variants.map(\.platform) == ["linux/arm64/v8"])
        #expect(after.hostVariantSizeBytes == before.hostVariantSizeBytes)
        #expect(after.totalSizeBytes == before.hostVariantSizeBytes)
        #expect(try await image(alpine) == alpineBefore)
        #expect(try await backend.listImages().allSatisfy { !$0.reference.contains("basket-reclaim") })
        try await backend.deleteImages([reference], force: false)
    }

    /// A locally loaded image that no registry has (so a delete-and-pull would lose it), with two
    /// unshared variants: slimming must keep it and give the other variant's bytes back.
    @Test func localOnlyImageAndDiskReclaim() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let reference = "docker.io/library/basket-test-safe-local-it:v1"
        let archive = directory.url.appendingPathComponent("multi.tar")
        try Self.writeTwoPlatformArchive(reference: reference, layerBytes: 6 << 20, to: archive)
        _ = try await backend.loadImage(from: archive)
        defer { Task { try? await backend.deleteImages([reference], force: true) } }
        let content = try #require(try await backend.systemStatus().appRoot).appending("/content")
        let before = try #require(try await image(reference))
        let contentBefore = Self.allocatedBytes(content)
        print("local slim before:", describe(before), "content store:", contentBefore)

        let slimmer = ImageSlimmer(store: BackendImageStore(backend), workDirectory: directory.url.appendingPathComponent("work"))
        let outcome = try await slimmer.slim(reference)
        let after = try #require(try await image(reference))
        let contentAfter = Self.allocatedBytes(content)
        print("local slim after:", describe(after), "content store:", contentAfter, "reclaimed:", outcome.reclaimed)
        #expect(after.variants.map(\.platform) == ["linux/arm64/v8"])
        #expect(contentBefore - contentAfter > 5 << 20)
        try await backend.deleteImages([reference], force: false)
    }

    static func allocatedBytes(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// A real OCI archive (valid digests) with linux/arm64 and linux/amd64 variants of random data.
    static func writeTwoPlatformArchive(reference: String, layerBytes: Int, to url: URL) throws {
        var blobs: [(String, Data)] = []
        func blob(_ data: Data) -> (digest: String, size: Int) {
            let digest = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            blobs.append((digest, data))
            return (digest, data.count)
        }
        func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        var manifests: [[String: Any]] = []
        for (architecture, variant) in [("arm64", "v8"), ("amd64", nil)] as [(String, String?)] {
            let layerURL = url.deletingLastPathComponent().appendingPathComponent("layer-\(architecture).tar")
            var layer = try TarWriter(url: layerURL)
            try layer.append("payload-\(architecture).bin", Data((0..<layerBytes).map { _ in UInt8.random(in: 0...255) }))
            try layer.close()
            let layerData = try Data(contentsOf: layerURL)
            let layerBlob = blob(layerData)
            var config: [String: Any] = [
                "architecture": architecture, "os": "linux", "config": ["Cmd": ["/bin/true"]],
                "rootfs": ["type": "layers", "diff_ids": [layerBlob.digest]],
            ]
            if let variant { config["variant"] = variant }
            let configBlob = blob(try json(config))
            let manifest = blob(try json([
                "schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "config": ["mediaType": "application/vnd.oci.image.config.v1+json", "digest": configBlob.digest, "size": configBlob.size],
                "layers": [["mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": layerBlob.digest, "size": layerBlob.size]],
            ]))
            var platform = ["architecture": architecture, "os": "linux"]
            if let variant { platform["variant"] = variant }
            manifests.append([
                "mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": manifest.digest, "size": manifest.size,
                "platform": platform,
            ])
        }
        let inner = blob(try json(["schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": manifests]))
        let names = Dictionary(uniqueKeysWithValues: ImageArchive.referenceAnnotations.map { ($0, reference) })
        let index = try json([
            "schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json",
            "manifests": [["mediaType": "application/vnd.oci.image.index.v1+json", "digest": inner.digest, "size": inner.size, "annotations": names]],
        ])
        var tar = try TarWriter(url: url)
        try tar.append("oci-layout", Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8))
        for (digest, data) in blobs { try tar.append(ImageArchive.blobPath(digest), data) }
        try tar.append("index.json", index)
        try tar.close()
    }
}
