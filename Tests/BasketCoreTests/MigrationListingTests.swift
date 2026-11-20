import Foundation
import Testing
@testable import BasketCore

/// Docker access policy, OrbStack listing (raw docker 29 output captured from OrbStack, read-only)
/// and container → `container run` planning.
@Suite("OrbStack migration: policy and listing")
struct MigrationListingTests {
    static var demo: URL { TestFixtures.set("demo") }
    var migrator: OrbStackMigrator { .fixtures(Self.demo) }

    // MARK: Read-only allowlist

    @Test(arguments: [
        ["image", "ls", "--all", "--format", "json"], ["image", "inspect", "sha256:abc"],
        ["image", "inspect", "--platform", "linux/amd64", "sha256:abc"], ["ps", "--all", "--format", "json"],
        ["inspect", "--type", "container", "abc"], ["version", "--format", "json"],
        ["save", "--platform", "linux/arm64", "-o", "/tmp/x.tar", "busybox:latest"],
    ])
    func readOnlyCommandsAreAllowed(_ command: [String]) throws {
        try DockerReadOnlyPolicy.validate(["--context", "orbstack"] + command)
    }

    @Test(arguments: [
        ["rm", "abc"], ["rmi", "busybox"], ["stop", "abc"], ["start", "abc"], ["restart", "abc"], ["kill", "abc"],
        ["run", "busybox"], ["create", "busybox"], ["exec", "abc", "sh"], ["pull", "busybox"], ["push", "busybox"],
        ["tag", "a", "b"], ["image", "rm", "busybox"], ["image", "prune", "-a"], ["image", "tag", "a", "b"],
        ["container", "rm", "abc"], ["container", "prune"], ["system", "prune", "-a"], ["volume", "rm", "v"],
        ["volume", "prune"], ["network", "rm", "n"], ["context", "use", "default"], ["builder", "prune"],
        ["save", "busybox"],  // to stdout: not allowed
        ["image", "ls", "--host", "tcp://elsewhere"], ["ps", "-H", "unix:///var/run/other.sock"],
        ["inspect", "--context=default", "abc"],
        // Attached short forms and `=` forms of the global options.
        ["image", "ls", "-Htcp://elsewhere"], ["ps", "-Hunix:///var/run/other.sock"], ["image", "ls", "--host=tcp://x"],
        ["ps", "--config=/tmp/other"], ["ps", "--config", "/tmp/other"], ["image", "ls", "-cdefault"],
        ["version", "--tlsverify=true"], ["version", "--tlscacert=/tmp/ca.pem"],
    ])
    func everythingElseIsForbidden(_ command: [String]) {
        #expect(throws: MigrationError.self) { try DockerReadOnlyPolicy.validate(["--context", "orbstack"] + command) }
    }

    @Test func onlyTheOrbStackContextIsAllowed() {
        #expect(throws: MigrationError.self) { try DockerReadOnlyPolicy.validate(["image", "ls"]) }
        #expect(throws: MigrationError.self) { try DockerReadOnlyPolicy.validate(["--context", "default", "image", "ls"]) }
        #expect(throws: MigrationError.self) { try DockerReadOnlyPolicy.validate(["--context", "orbstack"]) }
    }

    @Test func forbiddenCommandsNeverReachDocker() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let log = directory.url.appendingPathComponent("docker.log")
        let docker = try directory.script("docker", "echo \"$*\" >> \(shellQuote(log.path))")
        let migrator = OrbStackMigrator(docker: ProcessDockerClient(executableURL: URL(fileURLWithPath: docker)), presence: .always)

        for command in [["rmi", "busybox"], ["image", "prune", "-a"], ["stop", "abc"], ["context", "use", "default"]] {
            await #expect(throws: MigrationError.self) { _ = try await migrator.docker(command) }
        }
        #expect(!FileManager.default.fileExists(atPath: log.path), "docker was never executed")

        _ = try await migrator.docker(["version"])
        #expect(try String(contentsOf: log, encoding: .utf8) == "--context orbstack version\n")
    }

    @Test func dockerIsNeverCalledWhileOrbStackIsStopped() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let log = directory.url.appendingPathComponent("docker.log")
        let docker = try directory.script("docker", "echo \"$*\" >> \(shellQuote(log.path))")
        let client = ProcessDockerClient(executableURL: URL(fileURLWithPath: docker))
        let stopped = OrbStackPresence(isInstalled: { true }, isRunning: { false })
        let migrator = OrbStackMigrator(docker: client, presence: stopped)

        #expect(await migrator.status() == .notRunning)
        await #expect(throws: MigrationError.orbStackNotRunning) { _ = try await migrator.listImages() }
        await #expect(throws: MigrationError.orbStackNotRunning) { _ = try await migrator.listContainers() }
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(await OrbStackMigrator(docker: client, presence: .absent).status() == .notInstalled)
        #expect(await OrbStackMigrator(docker: nil, presence: .always).status()
            == .dockerUnavailable(MigrationError.dockerNotFound.localizedDescription))
    }

    @Test func fixtureSetsDescribeOrbStackState() async {
        #expect(await migrator.status() == .ready(dockerVersion: "29.8.2"))
        #expect(await OrbStackMigrator.fixtures(TestFixtures.set("stopped")).status() == .notRunning)
        #expect(await OrbStackMigrator.fixtures(TestFixtures.set("empty")).status() == .notInstalled)
    }

    // MARK: Images

    @Test func listsEveryImageWithItsPlatform() async throws {
        let images = try await migrator.listImages()
        #expect(images.count == 38)
        #expect(images.filter(\.isDangling).count == 4)
        #expect(images.filter { $0.isUntagged && !$0.isDangling }.count == 4)
        #expect(Set(images.map(\.id)).count == images.count, "row ids are unique")

        let busybox = try #require(images.first { $0.reference == "busybox:latest" })
        #expect(busybox.platform == "linux/arm64/v8" && busybox.isHostNative)
        #expect(busybox.sizeBytes == 6_139_453)  // exact, from `image inspect`
        #expect(busybox.containerCount == 1)
        #expect(busybox.exportPlatform == "linux/arm64")
        #expect(busybox.basketReference == "docker.io/library/busybox:latest")
        #expect(busybox.createdAt == TestFixtures.date("2026-05-14T12:00:00Z"))

        // amd64-only image.
        let amd64 = try #require(images.first { $0.reference == "demo-app:amd64" })
        #expect(amd64.platform == "linux/amd64" && !amd64.isHostNative && amd64.exportPlatform == "linux/amd64")

        // Index whose host variant isn't in OrbStack: resolved by the `--platform linux/amd64` pass.
        let redis = try #require(images.first { $0.reference == "redis:7-alpine" })
        #expect(redis.platform == "linux/amd64" && redis.sizeBytes == 58_419_988)
        #expect(redis.containerCount == 1)

        let digestOnly = try #require(images.first { $0.reference?.hasPrefix("python@sha256:") == true })
        #expect(digestOnly.tag == nil && digestOnly.isUntagged && !digestOnly.isDangling)
        #expect(digestOnly.platform == "linux/amd64")
        #expect(digestOnly.basketReference?.hasPrefix("docker.io/library/python@sha256:") == true)
    }

    @Test func platformPassPairsResultsByRequestOrder() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        // Three ids; the middle one has no amd64 variant (docker names it on stderr, omits it from stdout).
        let docker = try directory.script("docker", #"""
            echo '[{"Id":"sha256:m1","Os":"linux","Architecture":"amd64","Size":10},{"Id":"sha256:m3","Os":"linux","Architecture":"amd64","Size":30}]'
            echo 'Error response from daemon: image with reference sha256:b was found but does not provide the specified platform (linux/amd64)' >&2
            exit 1
            """#)
        let migrator = OrbStackMigrator(docker: ProcessDockerClient(executableURL: URL(fileURLWithPath: docker)), presence: .always)
        let resolved = try await migrator.resolve(["sha256:a", "sha256:b", "sha256:c"], platform: "linux/amd64")
        #expect(resolved.map(\.0) == ["sha256:a", "sha256:c"])
        #expect(resolved.map { $0.1.Size } == [10, 30])
    }

    @Test func parsesDockerSizesAndDates() {
        #expect(DockerFormat.parseSize("76.5MB") == 76_500_000)
        #expect(DockerFormat.parseSize("907kB") == 907_000)
        #expect(DockerFormat.parseSize("26.9GB") == 26_900_000_000)
        #expect(DockerFormat.parseSize("0B") == 0)
        #expect(DockerFormat.parseSize("N/A") == nil)
        #expect(DockerFormat.parseDate("2026-11-19 14:04:55 +0900 JST") == TestFixtures.date("2026-11-19T05:04:55Z"))
        #expect(DockerFormat.meaningfulDate("0001-01-01T00:00:00Z") == nil)
    }

    /// Regression: "already in Basket" used to be a name match, so an unrelated image Basket held
    /// under the same reference made the import skip OrbStack's copy and put it in the cleanup command.
    @Test func alreadyInBasketIsDecidedByContentAndOnlyVerifiedCopiesAreReclaimable() async throws {
        let images = try await migrator.listImages()
        let backend = FixtureBackend(directory: Self.demo)
        let presence = await migrator.basketPresence(of: images, basket: try await backend.listImages(), backend: backend)
        func state(_ reference: String) -> BasketPresence? { images.first { $0.reference == reference }.flatMap { presence[$0.id] } }

        let named = images.filter { presence[$0.id]?.nameIsTaken == true }.compactMap(\.reference).sorted()
        #expect(named == ["alpine:latest", "python:3.12-slim", "redis:7-alpine", "ubuntu:24.04"])
        // Same layers, config and creation time as Basket's alpine (the manifest digests aren't comparable here).
        #expect(state("alpine:latest") == .identical)
        // OrbStack only has amd64 python/redis; Basket's copies are arm64-only. ubuntu's layers differ.
        #expect(state("python:3.12-slim") == .nameConflict("Basket's copy has no linux/amd64 variant; it has linux/arm64/v8"))
        #expect(state("redis:7-alpine") == .nameConflict("Basket's copy has no linux/amd64 variant; it has linux/arm64/v8"))
        #expect(state("ubuntu:24.04") == .nameConflict("its layers differ"))
        #expect(state("busybox:latest") == .absent)

        // python:3.12-slim is unused in OrbStack but only a name match: it must not be in the command.
        let reclaim = OrbStackMigrator.reclaimable(images, presence: presence)
        #expect(reclaim.references == ["alpine:latest"])
        #expect(reclaim.bytes == 14_612_480)
        #expect(OrbStackMigrator.removalCommand(reclaim.references) == "docker --context orbstack image rm alpine:latest")

        // Every reference of an image ID must be verified (two gitleaks tags share one image).
        let gitleaks = images.filter { $0.reference?.contains("gitleaks") == true }
        #expect(gitleaks.count == 2 && gitleaks[0].imageID == gitleaks[1].imageID)
        let one = [gitleaks[0].id: BasketPresence.identical, gitleaks[1].id: .absent]
        #expect(OrbStackMigrator.reclaimable(gitleaks, presence: one).references.isEmpty)
        let conflict = [gitleaks[0].id: BasketPresence.identical, gitleaks[1].id: .nameConflict("its layers differ")]
        #expect(OrbStackMigrator.reclaimable(gitleaks, presence: conflict).references.isEmpty)
        let unverified = [gitleaks[0].id: BasketPresence.identical, gitleaks[1].id: .unverified("timed out")]
        #expect(OrbStackMigrator.reclaimable(gitleaks, presence: unverified).references.isEmpty)
        let both = [gitleaks[0].id: BasketPresence.identical, gitleaks[1].id: .identical]
        let reclaimBoth = OrbStackMigrator.reclaimable(gitleaks, presence: both)
        #expect(reclaimBoth.references == ["ghcr.io/gitleaks/gitleaks:v8.30.1", "zricethezav/gitleaks:v8.30.1"])
        #expect(reclaimBoth.bytes == gitleaks[0].sizeBytes, "one image ID counted once")
    }

    // MARK: Containers

    @Test func listsContainersWithTheirConfiguration() async throws {
        let containers = try await migrator.listContainers()
        #expect(containers.count == 10)
        let redis = try #require(containers.first { $0.name == "cache" })
        #expect(redis.isRunning && redis.image == "redis:7-alpine")
        #expect(redis.ports == [OrbStackPortBinding(hostIP: "", hostPort: 59022, containerPort: 6379, proto: "tcp")])
        #expect(redis.command == ["redis-server", "--databases", "256"] && redis.entrypoint == ["docker-entrypoint.sh"])
        #expect(redis.mounts.count == 1 && redis.mounts[0].isAnonymousVolume && redis.mounts[0].destination == "/data")
        #expect(redis.imageDefaults?.command == ["redis-server"])
        #expect(redis.imageDefaults?.platform == "linux/amd64", "OrbStack lacks the host variant of redis:7-alpine")
        #expect(redis.imageDefaults?.workingDirectory == "/data")
        #expect(redis.labels["org.testcontainers"] == "true")

        let sandbox = try #require(containers.first { $0.name == "sandbox" })
        #expect(sandbox.privileged && sandbox.initProcess)
        #expect(sandbox.mounts.contains(OrbStackMount(kind: .tmpfs, source: "", destination: "/scratch", readOnly: false, options: "size=2g")))

        let builder = try #require(containers.first { $0.name == "gpu-builder" })
        #expect(builder.mounts == [OrbStackMount(kind: .volume, source: "build-cache", destination: "/work", readOnly: false, driver: "local")])
        #expect(builder.state == "exited")

        let worker = try #require(containers.first { $0.name == "acme-worker-1" })
        #expect(worker.memoryLimitBytes == 512 * 1_048_576 && worker.cpuLimit == 1.5)
        #expect(worker.networks["acme_default"] == ["acme-worker-1", "worker"])

        let tests = containers.filter { $0.name.hasPrefix("redis-test-") }
        #expect(tests.count == 3 && tests.allSatisfy { $0.ports.first?.hostPort == nil }, "random host ports, not running")
    }

    // MARK: Planning

    func container(_ name: String) async throws -> OrbStackContainer {
        try #require(try await migrator.listContainers().first { $0.name == name })
    }

    func image(_ reference: String) async throws -> OrbStackImage {
        try #require(try await migrator.listImages().first { $0.reference == reference })
    }

    @Test func plansTheRunningRedisContainer() async throws {
        let plan = RecreationPlanner.plan(
            for: try await container("cache"), image: try await image("redis:7-alpine"),
            options: RecreationOptions(name: "basket-test-mig-redis"))
        #expect(plan.name == "basket-test-mig-redis")
        #expect(plan.image == "docker.io/library/redis:7-alpine")
        #expect(plan.runArguments == [
            "run", "--detach", "--name", "basket-test-mig-redis", "--memory", "1G", "--platform", "linux/amd64",
            "--label", "org.testcontainers=true", "--label", "org.testcontainers.lang=python",
            "--label", "org.testcontainers.session-id=00000000-1111-4222-8333-444455556666",
            "--label", "org.testcontainers.version=4.14.1", "--publish", "59022:6379",
            "docker.io/library/redis:7-alpine", "redis-server", "--databases", "256",
        ])
        #expect(plan.volumes.isEmpty)
        let topics = plan.warnings.map(\.topic)
        #expect(topics.contains("Platform") && topics.contains("Volume data") && topics.contains("Ports") && topics.contains("Memory"))
        #expect(plan.warnings.first { $0.topic == "Memory" }?.severity == .info)
        #expect(plan.runSpec.command == ["redis-server", "--databases", "256"])
        #expect(plan.runSpec.ports == ["59022:6379"] && plan.runSpec.memory == "1G" && plan.runSpec.platform == "linux/amd64")
        #expect(plan.commandLines == [
            "container run --detach --name basket-test-mig-redis --memory 1G --platform linux/amd64 "
                + "--label org.testcontainers=true --label org.testcontainers.lang=python "
                + "--label org.testcontainers.session-id=00000000-1111-4222-8333-444455556666 "
                + "--label org.testcontainers.version=4.14.1 --publish 59022:6379 "
                + "docker.io/library/redis:7-alpine redis-server --databases 256",
        ])
    }

    @Test func composeServiceWithANamedVolume() async throws {
        let plan = RecreationPlanner.plan(for: try await container("acme-db-1"))
        #expect(plan.volumes == ["acme_pgdata"])
        #expect(plan.runArguments.contains("acme_pgdata:/var/lib/postgresql/data"))
        #expect(plan.runSpec.environment == ["POSTGRES_USER=acme", "POSTGRES_PASSWORD=change-me", "POSTGRES_DB=acme"])
        #expect(plan.runSpec.ports == ["127.0.0.1:5432:5432"])
        #expect(plan.commandLines.first == "container volume create acme_pgdata")
        let topics = Set(plan.warnings.map(\.topic))
        #expect(topics.isSuperset(of: ["Volume data", "Restart policy", "Healthcheck", "Network", "Ports"]))
        #expect(plan.warnings.contains { $0.message.contains("acme_default") })
        #expect(plan.warnings.contains { $0.message.contains("Network aliases (db)") })
        #expect(!plan.runArguments.contains("--entrypoint"), "same entrypoint and command as the image")
    }

    @Test func missingBindSourcesAreLeftOut() async throws {
        let source = try await container("debug-shell")
        let missing = RecreationPlanner.plan(for: source, options: RecreationOptions(hostPathExists: { _ in false }))
        #expect(!missing.runArguments.contains("--volume"))
        #expect(missing.warnings.contains {
            $0.topic == "Bind mounts" && $0.message.contains("/Users/demo/Projects/acme/scripts, /tmp/debug-run.Xb12 don't exist")
        })
        #expect(missing.runSpec.environment == ["DEMO_MODE=restore", "DEMO_TIMEOUT=60"])
        #expect(missing.runArguments.suffix(6) == ["docker.io/library/busybox:latest", "/bin/sh", "/scripts/entry.sh", "--", "/bin/sh", "/scripts/test/fake-app.sh"])

        let present = RecreationPlanner.plan(for: source, options: RecreationOptions(hostPathExists: { _ in true }))
        #expect(present.runSpec.volumes == ["/Users/demo/Projects/acme/scripts:/scripts:ro", "/tmp/debug-run.Xb12:/run-control"])
        #expect(!present.warnings.contains { $0.topic == "Bind mounts" })
    }

    @Test func privilegedContainerWithInitAndTmpfs() async throws {
        let plan = RecreationPlanner.plan(for: try await container("sandbox"), options: RecreationOptions(hostPathExists: { _ in true }))
        #expect(plan.runArguments.contains("--init"))
        #expect(plan.runArguments.contains("--tmpfs") && plan.runArguments.contains("/scratch"))
        #expect(plan.warnings.contains { $0.topic == "Privileged" })
        #expect(plan.warnings.contains { $0.topic == "tmpfs" && $0.severity == .info })
        #expect(!plan.warnings.contains { $0.topic == "Security" }, "label=disable is an SELinux no-op")
    }

    @Test func limitsCapabilitiesAndHosts() async throws {
        let plan = RecreationPlanner.plan(for: try await container("acme-worker-1"))
        let arguments = plan.runArguments
        #expect(arguments.contains("--cpus") && arguments[arguments.firstIndex(of: "--cpus")! + 1] == "2")
        #expect(plan.runSpec.memory == "512M" && plan.runSpec.cpus == 2)
        #expect(arguments.contains("NET_ADMIN"))
        #expect(plan.runSpec.environment == ["QUEUE_URL=redis://cache:6379/0", "API_TOKEN=<redacted>"])
        #expect(plan.warnings.contains { $0.topic == "CPUs" && $0.severity == .info })
        #expect(plan.warnings.contains { $0.message.contains("host.docker.internal:host-gateway") })
        #expect(arguments.suffix(5) == ["docker.io/acme/worker:dev", "--queue", "default", "--concurrency", "4"])
    }

    /// Regression: a bare Docker `Env` entry ("KEY", which Docker treats as unset) became `--env KEY`,
    /// which makes `container run` copy KEY from Basket's own environment.
    @Test func bareEnvironmentEntriesAreLeftOutWithAWarning() {
        let source = OrbStackContainer(
            id: "abc", name: "app", image: "busybox", environment: ["PATH=/bin", "HOME", "EMPTY=", "SECRET_TOKEN"],
            imageDefaults: .init(environment: ["PATH=/bin"], entrypoint: nil, command: ["sh"], workingDirectory: "/", user: "",
                                 platform: "linux/arm64"))
        let plan = RecreationPlanner.plan(for: source)
        #expect(plan.runSpec.environment == ["EMPTY="])
        let envFlags = plan.runArguments.indices.filter { plan.runArguments[$0] == "--env" }.map { plan.runArguments[$0 + 1] }
        #expect(envFlags == ["EMPTY="])
        #expect(!plan.script.contains("--env HOME") && !plan.script.contains("SECRET_TOKEN "))
        let warning = plan.warnings.first { $0.topic == "Environment" }
        #expect(warning?.severity == .warning && warning?.message.contains("HOME, SECRET_TOKEN") == true)
    }

    @Test func unsupportedSettingsBecomeWarnings() {
        var source = OrbStackContainer(
            id: "0123456789abcdef", name: "api", image: "ghcr.io/acme/api:2", state: "running",
            ports: [
                OrbStackPortBinding(hostIP: "127.0.0.1", hostPort: 8080, containerPort: 80, proto: "tcp"),
                OrbStackPortBinding(hostIP: "", hostPort: nil, containerPort: 53, proto: "udp"),
            ],
            environment: ["PATH=/bin", "TOKEN=<redacted>"], entrypoint: ["/bin/api", "--serve"], command: ["--port", "80"],
            workingDirectory: "/srv", user: "1000:1000", restartPolicy: "always", memoryLimitBytes: 512 * 1_048_576,
            cpuLimit: 1.5, networkMode: "backend", networks: ["backend": ["api", "0123456789ab", "api.internal"]],
            initProcess: false, hostname: "api-host", hasHealthcheck: true, privileged: false, capAdd: ["NET_ADMIN"],
            capDrop: ["MKNOD"], devices: ["/dev/fuse"], gpuRequests: 1, dns: ["1.1.1.1"], extraHosts: ["db:10.0.0.2"],
            links: ["/db:/api/db"], securityOptions: ["seccomp=unconfined"], ulimits: ["nofile=1024:2048"],
            sysctls: ["net.core.somaxconn": "1024"], staticIPs: ["172.20.0.5"], sharedNamespaces: ["pid=host"],
            imageDefaults: .init(environment: ["PATH=/bin"], entrypoint: ["/bin/api"], command: [], workingDirectory: "/", user: "",
                                 platform: "linux/arm64"))
        let plan = RecreationPlanner.plan(for: source)
        let topics = Set(plan.warnings.map(\.topic))
        for topic in ["Restart policy", "Healthcheck", "Network", "Devices", "GPU", "Security", "Namespaces", "Sysctls", "Hostname", "Ports"] {
            #expect(topics.contains(topic), "\(topic)")
        }
        #expect(plan.warnings.contains { $0.message.contains("api.internal") }, "network alias")
        #expect(!plan.warnings.contains { $0.message.contains("0123456789ab)") })
        let arguments = plan.runArguments
        func value(after flag: String) -> [String] {
            arguments.indices.filter { arguments[$0] == flag && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
        }
        #expect(value(after: "--cpus") == ["2"] && value(after: "--memory") == ["512M"])
        #expect(value(after: "--publish") == ["127.0.0.1:8080:80", "53:53/udp"])
        #expect(value(after: "--env") == ["TOKEN=<redacted>"])
        #expect(value(after: "--entrypoint") == ["/bin/api"])
        #expect(value(after: "--workdir") == ["/srv"] && value(after: "--user") == ["1000:1000"])
        #expect(value(after: "--cap-add") == ["NET_ADMIN"] && value(after: "--cap-drop") == ["MKNOD"])
        #expect(value(after: "--dns") == ["1.1.1.1"] && value(after: "--ulimit") == ["nofile=1024:2048"])
        #expect(arguments.suffix(4) == ["ghcr.io/acme/api:2", "--serve", "--port", "80"])
        #expect(!arguments.contains("--platform"))

        // No image defaults known: spell out the whole process, keep all variables.
        source.imageDefaults = nil
        source.entrypoint = nil
        let explicit = RecreationPlanner.plan(for: source)
        #expect(explicit.runArguments.suffix(3) == ["ghcr.io/acme/api:2", "--port", "80"])
        #expect(explicit.runSpec.environment == ["PATH=/bin", "TOKEN=<redacted>"])

        // `-P`: every exposed port on the same host port number.
        var publishAll = OrbStackContainer(id: "abc", name: "r", image: "redis:7", publishAll: true, exposedPorts: ["6379/tcp", "53/udp"])
        var allPlan = RecreationPlanner.plan(for: publishAll)
        #expect(allPlan.runSpec.ports == ["6379:6379", "53:53/udp"])
        #expect(allPlan.warnings.contains { $0.topic == "Ports" && $0.severity == .info })
        publishAll.exposedPorts = []
        allPlan = RecreationPlanner.plan(for: publishAll)
        #expect(allPlan.runSpec.ports.isEmpty)

        // Docker had a memory limit in whole GiB.
        source.memoryLimitBytes = 2 << 30
        #expect(RecreationPlanner.plan(for: source).runSpec.memory == "2G")
    }
}
