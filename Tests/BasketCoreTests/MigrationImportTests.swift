import Darwin
import Foundation
import Testing
@testable import BasketCore

/// Image import (docker save → container image load) and container recreation against fake
/// `docker`/`container` scripts and the fixture backend.
@Suite("OrbStack migration: import and recreate")
struct MigrationImportTests {
    let busybox = OrbStackImage(
        imageID: "sha256:a46257e0", repository: "busybox", tag: "latest", reference: "busybox:latest",
        sizeBytes: 6_139_453, platform: "linux/arm64/v8")

    /// Fake docker: `save` writes `bytes` to the -o path (or fails with `saveStderr`), logs every call.
    func fakeDocker(_ directory: TemporaryDirectory, saveBody: String? = nil) throws -> URL {
        let log = shellQuote(directory.url.appendingPathComponent("docker.log").path)
        let body = saveBody ?? #"dd if=/dev/zero of="$out" bs=1024 count=64 2>/dev/null"#
        return URL(fileURLWithPath: try directory.script("docker", """
            echo "$*" >> \(log)
            out=""; prev=""
            for arg in "$@"; do
              if [ "$prev" = "-o" ]; then out="$arg"; fi
              prev="$arg"
            done
            case "$3" in
              save) \(body) ;;
              *) echo "unexpected: $*" >&2; exit 1 ;;
            esac
            """))
    }

    /// Fake container CLI: `image load` prints what it loaded (plus an attestation stray).
    func fakeContainer(_ directory: TemporaryDirectory, loadBody: String? = nil) throws -> String {
        let log = shellQuote(directory.url.appendingPathComponent("container.log").path)
        let body = loadBody ?? #"printf 'docker.io/library/busybox:latest\nuntagged@sha256:72610e75\n'"#
        return try directory.script("container", """
            echo "$*" >> \(log)
            case "$*" in
              "image list --format json") echo '[]' ;;
              "image load --input "*) \(body) ;;
              "image delete "*|"volume create "*) ;;
              "volume list --format json") echo '[]' ;;
              "run "*) echo "basket-test-mig-x" ;;
              *) echo "Error: unexpected arguments: $*" >&2; exit 1 ;;
            esac
            """)
    }

    func lines(_ directory: TemporaryDirectory, _ name: String) -> [String] {
        ((try? String(contentsOf: directory.url.appendingPathComponent(name), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func migrator(_ directory: TemporaryDirectory, docker: URL, free: Int64? = nil, stall: Duration = .seconds(120)) throws -> OrbStackMigrator {
        let scratch = directory.url.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return OrbStackMigrator(
            docker: ProcessDockerClient(executableURL: docker), presence: .always, temporaryDirectory: scratch,
            freeSpace: { _ in free }, exportStallTimeout: stall)
    }

    func scratchIsEmpty(_ directory: TemporaryDirectory) -> Bool {
        let scratch = directory.url.appendingPathComponent("scratch")
        return ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).isEmpty
    }

    func collectProgress(_ stream: AsyncThrowingStream<ImportProgress, Error>) async throws -> [ImportProgress] {
        var steps: [ImportProgress] = []
        for try await step in stream { steps.append(step) }
        return steps
    }

    @Test func importsTheHostVariantAndRemovesTheArchive() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let migrator = try migrator(directory, docker: try fakeDocker(directory))
        let backend = CLIBackend(cliPath: try fakeContainer(directory))

        let steps = try await collectProgress(migrator.importImage(busybox, into: backend))
        #expect(steps.first?.phase == .checking)
        guard case .done(let references, let archiveBytes)? = steps.last?.phase else {
            Issue.record("no done step: \(steps)")
            return
        }
        #expect(references == ["docker.io/library/busybox:latest"])
        #expect(archiveBytes == 65_536)
        #expect(steps.contains { if case .loading(65_536) = $0.phase { true } else { false } })

        let save = try #require(lines(directory, "docker.log").first)
        #expect(save.hasPrefix("--context orbstack save --platform linux/arm64 -o "))
        #expect(save.hasSuffix("/image.tar busybox:latest"))
        let containerCalls = lines(directory, "container.log")
        #expect(containerCalls.contains { $0.hasPrefix("image load --input ") && $0.hasSuffix("/image.tar") })
        #expect(containerCalls.contains("image delete untagged@sha256:72610e75"), "attestation stray removed")
        #expect(scratchIsEmpty(directory))
    }

    @Test func amd64OnlyImagesExportTheirOwnPlatform() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let migrator = try migrator(directory, docker: try fakeDocker(directory))
        var image = busybox
        image.platform = "linux/amd64"
        _ = try await collectProgress(migrator.importImage(image, into: CLIBackend(cliPath: try fakeContainer(directory))))
        #expect(lines(directory, "docker.log").first?.contains("save --platform linux/amd64 ") == true)
    }

    @Test func unknownPlatformFallsBackToAMD64() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let docker = try fakeDocker(directory, saveBody: #"""
            case "$*" in
              *"--platform linux/arm64 "*) echo 'Error response from daemon: no suitable export target found: image with reference busybox:latest was found but does not provide the specified platform (linux/arm64)' >&2; exit 1 ;;
              *) dd if=/dev/zero of="$out" bs=1024 count=8 2>/dev/null ;;
            esac
            """#)
        var image = busybox
        image.platform = nil
        let migrator = try migrator(directory, docker: docker)
        _ = try await collectProgress(migrator.importImage(image, into: CLIBackend(cliPath: try fakeContainer(directory))))
        let saves = lines(directory, "docker.log")
        #expect(saves.count == 2)
        #expect(saves[0].contains("--platform linux/arm64 ") && saves[1].contains("--platform linux/amd64 "))
        #expect(scratchIsEmpty(directory))
    }

    @Test func exportFailureCleansUp() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let docker = try fakeDocker(directory, saveBody: #"""
            dd if=/dev/zero of="$out.partial" bs=1024 count=4 2>/dev/null; echo 'Error response from daemon: boom' >&2; exit 1
            """#)
        let migrator = try migrator(directory, docker: docker)
        await #expect {
            _ = try await collectProgress(migrator.importImage(busybox, into: CLIBackend(cliPath: try fakeContainer(directory))))
        } throws: { error in
            guard case MigrationError.dockerFailed(_, let message) = error else { return false }
            return message == "boom"
        }
        #expect(lines(directory, "docker.log").count == 1, "a known platform is not retried")
        #expect(lines(directory, "container.log") == ["image list --format json"], "only the name check, never loaded")
        #expect(scratchIsEmpty(directory))
    }

    @Test func loadFailureCleansUp() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let migrator = try migrator(directory, docker: try fakeDocker(directory))
        let container = try fakeContainer(directory, loadBody: #"echo 'Error: invalid archive' >&2; exit 1"#)
        await #expect(throws: MigrationError.loadFailed("invalid archive")) {
            _ = try await collectProgress(migrator.importImage(busybox, into: CLIBackend(cliPath: container)))
        }
        #expect(scratchIsEmpty(directory))
    }

    @Test func refusesWhenTheDiskIsTooFull() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let migrator = try migrator(directory, docker: try fakeDocker(directory), free: 100_000_000)
        await #expect(throws: MigrationError.insufficientDiskSpace(
            neededBytes: 6_139_453 + OrbStackMigrator.diskHeadroomBytes, availableBytes: 100_000_000)) {
            _ = try await collectProgress(migrator.importImage(busybox, into: CLIBackend(cliPath: try fakeContainer(directory))))
        }
        #expect(lines(directory, "docker.log").isEmpty, "nothing exported")
        #expect(scratchIsEmpty(directory))
    }

    @Test func danglingImagesAreNotImportable() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let dangling = OrbStackImage(imageID: "sha256:aa94", repository: "<none>", tag: nil, reference: nil, sizeBytes: 1)
        let migrator = try migrator(directory, docker: try fakeDocker(directory))
        await #expect(throws: MigrationError.self) {
            _ = try await collectProgress(migrator.importImage(dangling, into: CLIBackend(cliPath: try fakeContainer(directory))))
        }
        #expect(lines(directory, "docker.log").isEmpty)
    }

    func waitForExit(_ pid: Int32) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    @Test func cancellingKillsDockerAndRemovesThePartialArchive() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let pidFile = directory.url.appendingPathComponent("save.pid")
        let docker = try fakeDocker(directory, saveBody: """
            echo $$ > \(shellQuote(pidFile.path)); dd if=/dev/zero of="$out" bs=1024 count=32 2>/dev/null; exec sleep 30
            """)
        let migrator = try migrator(directory, docker: docker)
        let stream = migrator.importImage(busybox, into: CLIBackend(cliPath: try fakeContainer(directory)))
        let sawBytes = AsyncStream<Void>.makeStream()
        let consumer = Task {
            for try await step in stream {
                if case .exporting(let bytes) = step.phase, bytes > 0 { sawBytes.continuation.yield() }
            }
        }
        var iterator = sawBytes.stream.makeAsyncIterator()
        _ = await iterator.next()
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let start = ContinuousClock.now
        consumer.cancel()
        _ = await consumer.result
        // The fake export sleeps 30 s: well under that proves cancellation stopped it.
        #expect(ContinuousClock.now - start < .seconds(15))
        #expect(try await waitForExit(pid))
        // The import task removes its directory as it unwinds, just after the consumer saw the end.
        #expect(try await waitUntil { scratchIsEmpty(directory) })
        #expect(lines(directory, "container.log") == ["image list --format json"], "only the name check, never loaded")
    }

    func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }

    @Test func aStalledExportIsStopped() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let docker = try fakeDocker(directory, saveBody: "exec sleep 30")
        let migrator = try migrator(directory, docker: docker, stall: .milliseconds(600))
        let start = ContinuousClock.now
        await #expect {
            _ = try await collectProgress(migrator.importImage(busybox, into: CLIBackend(cliPath: try fakeContainer(directory))))
        } throws: { error in
            guard case MigrationError.dockerFailed(_, let message) = error else { return false }
            return message.contains("no progress")
        }
        // Far below the script's 30 s sleep (process launches are slow while the whole suite runs).
        #expect(ContinuousClock.now - start < .seconds(15))
        #expect(scratchIsEmpty(directory))
    }

    // MARK: Fixture mode

    @Test func fixtureImportAddsTheImageToTheFixtureBackend() async throws {
        let demo = TestFixtures.set("demo")
        let backend = FixtureBackend(directory: demo)
        let migrator = OrbStackMigrator.fixtures(demo)
        let image = try #require(try await migrator.listImages().first { $0.reference == "busybox:latest" })
        let steps = try await collectProgress(migrator.importImage(image, into: backend))
        guard case .done(let references, let archiveBytes)? = steps.last?.phase else {
            Issue.record("no done step: \(steps)")
            return
        }
        #expect(references == ["docker.io/library/busybox:latest"])
        #expect(archiveBytes > image.sizeBytes / 2, "a synthetic archive about the image's size")
        let basket = try await backend.listImages()
        let imported = try #require(basket.first { $0.reference == "docker.io/library/busybox:latest" })
        #expect(imported.variants.map(\.platform) == ["linux/arm64/v8"])
        // The fake save names the same platform manifest `image inspect --platform` reports, so the
        // imported copy verifies as identical (and a second import is skipped).
        #expect(await migrator.basketPresence(of: [image], basket: basket, backend: backend)[image.id] == .identical)
        await #expect(throws: MigrationError.alreadyInBasket("docker.io/library/busybox:latest")) {
            _ = try await collectProgress(migrator.importImage(image, into: backend))
        }
    }

    /// Regression (#19): the export watchdog reports through the same progress handler and wasn't
    /// awaited, so under load an "exporting" update could arrive after "loading" or even "done". A
    /// slow handler for the watchdog's updates (the archive size) makes that window wide every run.
    @Test func exportProgressNeverArrivesAfterTheExportEnds() async throws {
        let demo = TestFixtures.set("demo")
        let migrator = OrbStackMigrator.fixtures(demo)
        let image = try #require(try await migrator.listImages().first { $0.reference == "busybox:latest" })
        let phases = PhaseLog()
        try await migrator.performImport(image, backend: FixtureBackend(directory: demo)) { step in
            if case .exporting(let bytes) = step.phase, bytes > 0 { Thread.sleep(forTimeInterval: 0.3) }
            phases.append(step.phase)
        }
        let all = phases.all
        let loading = try #require(all.firstIndex { if case .loading = $0 { true } else { false } }, "\(all)")
        #expect(all[..<loading].contains { if case .exporting(let bytes) = $0 { bytes > 0 } else { false } },
                "the watchdog's update was delivered before the import moved on: \(all)")
        #expect(!all[loading...].contains { if case .exporting = $0 { true } else { false } }, "\(all)")
        #expect({ if case .done? = all.last { true } else { false } }(), "\(all)")
    }

    /// Regression: an unrelated image Basket holds under the same name made the import skip
    /// OrbStack's copy as "already in Basket". Now it's a name conflict and nothing is exported.
    @Test func fixtureImportRefusesANameConflict() async throws {
        let demo = TestFixtures.set("demo")
        let backend = FixtureBackend(directory: demo)
        let migrator = OrbStackMigrator.fixtures(demo)
        let ubuntu = try #require(try await migrator.listImages().first { $0.reference == "ubuntu:24.04" })
        await #expect(throws: MigrationError.nameConflict(reference: "docker.io/library/ubuntu:24.04", reason: "its layers differ")) {
            _ = try await collectProgress(migrator.importImage(ubuntu, into: backend))
        }
        let after = try await backend.listImages().first { $0.reference == "docker.io/library/ubuntu:24.04" }
        #expect(after?.variants.count == 6, "Basket's own ubuntu is untouched")
    }

    @Test func recreateImportsTheImageCreatesVolumesAndRuns() async throws {
        let demo = TestFixtures.set("demo")
        let backend = FixtureBackend(directory: demo)
        let migrator = OrbStackMigrator.fixtures(demo)
        let source = try #require(try await migrator.listContainers().first { $0.name == "gpu-builder" })
        let image = try await migrator.listImages().first { $0.imageID == source.imageID }
        let plan = RecreationPlanner.plan(for: source, image: image, options: RecreationOptions(name: "basket-test-mig-build"))
        let messages = MessageLog()
        let id = try await migrator.recreate(plan, sourceImage: image, into: backend) { messages.append($0) }
        #expect(id == "basket-test-mig-build")
        #expect(try await backend.listVolumes().contains { $0.name == "build-cache" })
        let created = try #require(try await backend.listContainers().first { $0.id == id })
        #expect(created.imageReference == "docker.io/pytorch/manylinux2_28-builder:cuda12.8")
        #expect(created.mounts.contains(MountInfo(source: "build-cache", destination: "/work", kind: "volume", readOnly: false)))
        #expect(created.platform == "linux/amd64", "OrbStack only has the amd64 variant")
        #expect(messages.all.contains("Creating volume build-cache") && messages.all.last == "Starting basket-test-mig-build")
        let imported = try #require(try await backend.listImages().first { $0.reference == created.imageReference })
        #expect(imported.variants.map(\.platform) == ["linux/amd64"])
    }

    @Test func recreateRunsTheFullArgumentListThroughTheCLI() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let backend = CLIBackend(cliPath: try fakeContainer(directory))
        let source = OrbStackContainer(
            id: "c0ffee", name: "web", image: "busybox", entrypoint: ["/bin/sh"], command: ["-c", "sleep 1"],
            mounts: [OrbStackMount(kind: .volume, source: "web-data", destination: "/data", readOnly: false, driver: "local")])
        let plan = RecreationPlanner.plan(for: source, options: RecreationOptions(name: "basket-test-mig-x"))
        let id = try await OrbStackMigrator(docker: nil, presence: .absent).recreate(plan, sourceImage: nil, into: backend)
        #expect(id == "basket-test-mig-x")
        let calls = lines(directory, "container.log")
        #expect(calls.contains("volume create web-data"))
        #expect(calls.last == "run --progress none --detach --name basket-test-mig-x --memory 1G --entrypoint /bin/sh "
            + "--volume web-data:/data docker.io/library/busybox:latest -c sleep 1")
    }

    // MARK: Engine check

    @Test func socketProbeNeedsAListeningSocket() throws {
        let path = "/tmp/bk-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        #expect(!OrbStackEngine.socketAcceptsConnections(path), "missing")
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        #expect(!OrbStackEngine.socketAcceptsConnections(path), "regular file")
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8)
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        #expect(!OrbStackEngine.socketAcceptsConnections(path), "bound but not listening")
        try #require(listen(fd, 4) == 0)
        #expect(OrbStackEngine.socketAcceptsConnections(path))
    }
}

final class MessageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func append(_ message: String) { lock.withLock { messages.append(message) } }
    var all: [String] { lock.withLock { messages } }
}

final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [ImportPhase] = []
    func append(_ phase: ImportPhase) { lock.withLock { phases.append(phase) } }
    var all: [ImportPhase] { lock.withLock { phases } }
}
