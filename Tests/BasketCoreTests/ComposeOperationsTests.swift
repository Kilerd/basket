import Foundation
import Synchronization
import Testing
@testable import BasketCore

/// Collects progress lines from `@Sendable` callbacks.
final class ProgressLog: Sendable {
    private let storage = Mutex<[String]>([])
    var lines: [String] { storage.withLock { $0 } }
    func append(_ line: String) { storage.withLock { $0.append(line) } }
}

@Suite("Compose operations")
struct ComposeOperationsTests {
    static let yaml = """
        name: basket-test-ops
        services:
          db:
            image: redis:7-alpine
            volumes: [data:/data]
            extra_hosts: ["metrics:10.0.0.5"]
          app:
            image: alpine
            command: ["sleep", "600"]
            depends_on: [db]
            networks: [default, back]
          side:
            image: alpine
            networks: [back]
        networks:
          back:
        volumes:
          data:
        """

    func setup() throws -> (FixtureBackend, ComposeOperations, ComposePlan, [String]) {
        let backend = FixtureBackend(directory: TestFixtures.set("empty"))
        let created = Mutex<[String]>([])
        var ops = ComposeOperations(backend: backend)
        ops.createDirectory = { path in created.withLock { $0.append(path) } }
        let file = try ComposeLoader.load(yaml: Self.yaml, workingDirectory: URL(fileURLWithPath: "/Users/demo/ops"))
        let plan = try ComposePlanner.plan(file, options: ComposePlanOptions(hostPathExists: { _ in true }))
        return (backend, ops, plan, created.withLock { $0 })
    }

    @Test func upCreatesEverythingAndWritesHosts() async throws {
        let (backend, ops, plan, _) = try setup()
        let log = ProgressLog()
        try await ops.up(plan, progress: log.append)

        #expect(log.lines.first == "Creating network basket-test-ops_default")
        #expect(log.lines.contains("Creating volume basket-test-ops_data"))
        #expect(log.lines.last == "Project basket-test-ops is up (3 services)")

        let networks = try await backend.listNetworks()
        let defaultNetwork = try #require(networks.first { $0.name == "basket-test-ops_default" })
        #expect(defaultNetwork.labels[ComposeLabels.project] == "basket-test-ops")
        #expect(try await backend.listVolumes().first { $0.name == "basket-test-ops_data" }?.labels[ComposeLabels.volume] == "data")

        let containers = try await backend.listContainers()
        #expect(containers.map(\.id) == ["basket-test-ops-db-1", "basket-test-ops-app-1", "basket-test-ops-side-1"])
        let app = try #require(containers.first { $0.id == "basket-test-ops-app-1" })
        #expect(app.networks == ["basket-test-ops_default", "basket-test-ops_back"])
        #expect(app.labels[ComposeLabels.service] == "app")
        #expect(app.memoryLimitBytes == 512 << 20)
        #expect(app.networkAddresses.count == 2)

        // /etc/hosts of every running service, as root, with the services it shares a network with.
        let calls = await backend.execCalls
        #expect(Set(calls.map(\.containerID)) == ["basket-test-ops-app-1", "basket-test-ops-db-1", "basket-test-ops-side-1"])
        #expect(calls.allSatisfy { $0.user == "0" && $0.command.prefix(2) == ["sh", "-c"] && $0.command.last == "/etc/hosts" })
        let blocks = Dictionary(uniqueKeysWithValues: calls.map { ($0.containerID, $0.command[4]) })
        let db = try #require(containers.first { $0.id == "basket-test-ops-db-1" })
        let side = try #require(containers.first { $0.id == "basket-test-ops-side-1" })
        let appBlock = try #require(blocks["basket-test-ops-app-1"])
        #expect(appBlock.contains("\(db.ipv4Address!)\tdb basket-test-ops-db-1\n"))
        #expect(appBlock.contains("\(side.ipv4Address!)\tside basket-test-ops-side-1\n"))
        let dbBlock = try #require(blocks["basket-test-ops-db-1"])
        #expect(dbBlock.contains("\(app.networkAddresses["basket-test-ops_default"]!)\tapp basket-test-ops-app-1\n"))
        #expect(!dbBlock.contains("side"))  // no shared network
        #expect(dbBlock.contains("10.0.0.5\tmetrics\n"))
        #expect(blocks["basket-test-ops-side-1"]?.contains("\(app.networkAddresses["basket-test-ops_back"]!)\tapp ") == true)
    }

    @Test func upTwiceReusesContainersAndRejectsForeignNames() async throws {
        let (backend, ops, plan, _) = try setup()
        try await ops.up(plan)
        try await backend.stopContainers(["basket-test-ops-db-1"])
        let log = ProgressLog()
        try await ops.up(plan, progress: log.append)
        #expect(log.lines.contains("Starting basket-test-ops-db-1"))
        #expect(log.lines.contains("basket-test-ops-app-1 is already running"))
        #expect(try await backend.listContainers().count == 3)

        _ = try await backend.run(RunSpec(image: "alpine", name: "foreign-db-1"))
        var clash = plan
        clash.services[0].spec.name = "foreign-db-1"
        await #expect(throws: BackendError.self) { try await ops.up(clash) }
    }

    @Test func stopStartRestartFollowDependencies() async throws {
        let (backend, ops, plan, _) = try setup()
        try await ops.up(plan)
        let log = ProgressLog()
        try await ops.stop(project: "basket-test-ops", progress: log.append)
        #expect(log.lines == ["Stopping basket-test-ops-side-1, basket-test-ops-app-1, basket-test-ops-db-1"])
        #expect(try await backend.listContainers().allSatisfy { $0.state == .stopped })

        let before = await backend.execCalls.count
        try await ops.start(project: "basket-test-ops", progress: log.append)
        #expect(log.lines.dropFirst().prefix(3) == ["Starting basket-test-ops-db-1", "Starting basket-test-ops-app-1", "Starting basket-test-ops-side-1"])
        #expect(try await backend.listContainers().allSatisfy { $0.state == .running })
        #expect(await backend.execCalls.count == before + 3)  // hosts rewritten after start

        try await ops.restart(project: "basket-test-ops")
        #expect(await backend.execCalls.count == before + 6)
    }

    @Test func downRemovesContainersAndNetworksAndOptionallyVolumes() async throws {
        let (backend, ops, plan, _) = try setup()
        try await ops.up(plan)
        _ = try await backend.run(RunSpec(image: "alpine", name: "bystander"))
        let log = ProgressLog()
        try await ops.down(project: "basket-test-ops", removeVolumes: false, progress: log.append)
        #expect(try await backend.listContainers().map(\.id) == ["bystander"])
        #expect(try await backend.listNetworks().map(\.name) == ["default"])
        #expect(try await backend.listVolumes().map(\.name) == ["basket-test-ops_data"])
        #expect(log.lines.last == "Project basket-test-ops is down")

        try await ops.up(plan)
        #expect(try await ops.projectVolumes("basket-test-ops") == ["basket-test-ops_data"])
        try await ops.down(project: "basket-test-ops", removeVolumes: true)
        #expect(try await backend.listVolumes().isEmpty)
    }

    @Test func downDeletesOnlyWhatWasApproved() async throws {
        let (backend, ops, plan, _) = try setup()
        try await ops.up(plan)
        // A container joined the project after the user confirmed: it stays.
        _ = try await backend.run(RunSpec(image: "alpine", name: "late-1", labels: [ComposeLabels.project: "basket-test-ops"]))
        let approval = ComposeDownApproval(
            containers: ["basket-test-ops-db-1", "basket-test-ops-app-1", "basket-test-ops-side-1"],
            networks: ["basket-test-ops_default"], volumes: [])
        try await ops.down(project: "basket-test-ops", removeVolumes: true, approved: approval)
        #expect(try await backend.listContainers().map(\.id) == ["late-1"])
        #expect(try await backend.listNetworks().map(\.name) == ["default", "basket-test-ops_back"])
        #expect(try await backend.listVolumes().map(\.name) == ["basket-test-ops_data"])
    }

    @Test func upCreatesMissingBindDirectoriesAndChecksExternals() async throws {
        let backend = FixtureBackend(directory: TestFixtures.set("empty"))
        let created = Mutex<[String]>([])
        var ops = ComposeOperations(backend: backend)
        ops.createDirectory = { path in created.withLock { $0.append(path) } }
        let file = try ComposeLoader.load(
            yaml: "services:\n  a:\n    image: alpine\n    volumes: [./state:/state]\n", workingDirectory: URL(fileURLWithPath: "/Users/demo/bind"))
        try await ops.up(try ComposePlanner.plan(file, options: ComposePlanOptions(hostPathExists: { _ in false })))
        #expect(created.withLock { $0 } == ["/Users/demo/bind/state"])

        let external = try ComposeLoader.load(
            yaml: "services:\n  a:\n    image: alpine\n    networks: [corp]\nnetworks:\n  corp: {external: true}\n",
            workingDirectory: URL(fileURLWithPath: "/Users/demo/ext"))
        await #expect(throws: ComposeError.self) { try await ops.up(try ComposePlanner.plan(external)) }
    }

    @Test func hostsFailuresAreReportedNotThrown() async throws {
        let (backend, ops, plan, _) = try setup()
        try await ops.up(plan)
        try await backend.stopSystem()
        try await backend.startSystem()
        // Every container is stopped now: nothing to update, nothing fails.
        #expect(await ops.refreshHosts(project: "basket-test-ops").isEmpty)
    }
}

/// Regression for #1: a project restart stopped every service, then started them all, so one failing
/// start (e.g. a `--rm` service the stop had deleted) left the remaining services down.
@Suite("Compose restart per service")
struct ComposeRestartTests {
    static let project = "basket-test-rst"

    struct Service {
        var name: String
        var dependsOn: String? = nil
        var state = "running"
        /// Its bundle's options.json says `autoRemove` (started with `--rm`): `stop` deletes it.
        var removeOnStop = false
        /// `start` fails for it.
        var startFails = false
        var id: String { "\(ComposeRestartTests.project)-\(name)-1" }
    }

    /// Fake `container`: `state/<id>` holds the state, `labels/<id>` the labels JSON and
    /// `root/containers/<id>/options.json` the `--rm` flag (the app root comes from `system status`).
    func fakeCLI(_ directory: TemporaryDirectory, _ services: [Service]) async throws -> CLIBackend {
        let files = FileManager.default
        let state = directory.url.appendingPathComponent("state"), labels = directory.url.appendingPathComponent("labels")
        let broken = directory.url.appendingPathComponent("broken"), root = directory.url.appendingPathComponent("root")
        for folder in [state, labels, broken] { try files.createDirectory(at: folder, withIntermediateDirectories: true) }
        for service in services {
            var serviceLabels = [
                ComposeLabels.project: Self.project, ComposeLabels.service: service.name, ComposeLabels.basket: "1",
            ]
            if let dependency = service.dependsOn { serviceLabels[ComposeLabels.dependsOn] = "\(dependency):service_started:false" }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try encoder.encode(serviceLabels).write(to: labels.appendingPathComponent(service.id))
            try Data(service.state.utf8).write(to: state.appendingPathComponent(service.id))
            let bundle = root.appendingPathComponent("containers").appendingPathComponent(service.id)
            try files.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data(#"{"autoRemove":\#(service.removeOnStop)}"#.utf8).write(to: bundle.appendingPathComponent("options.json"))
            if service.startFails { try Data().write(to: broken.appendingPathComponent(service.id)) }
        }
        let log = shellQuote(directory.url.appendingPathComponent("calls.log").path)
        let (s, l, b, r) = (shellQuote(state.path), shellQuote(labels.path), shellQuote(broken.path), shellQuote(root.path))
        let script = try directory.script("container", #"""
            case "$1" in exec) echo "exec $4" >> \#(log) ;; *) echo "$*" >> \#(log) ;; esac
            case "$1" in
              system) printf '{"status":"running","paths":{"appRoot":"%s/"}}\n' \#(r) ;;
              list)
                printf '['; sep=''
                for f in \#(s)/*; do
                  [ -e "$f" ] || continue
                  id=$(basename "$f")
                  printf '%s{"id":"%s","configuration":{"id":"%s","labels":%s},"status":{"state":"%s"}}' \
                    "$sep" "$id" "$id" "$(cat \#(l)/"$id")" "$(cat "$f")"
                  sep=','
                done
                printf ']\n' ;;
              stop)
                shift
                for id in "$@"; do
                  if grep -q '"autoRemove":true' \#(r)/containers/"$id"/options.json; then rm -f \#(s)/"$id"; else printf stopped > \#(s)/"$id"; fi
                done ;;
              start)
                if [ -e \#(b)/"$2" ]; then echo "Error: failed to bootstrap $2" >&2; exit 1; fi
                if [ -e \#(s)/"$2" ]; then printf running > \#(s)/"$2"; else echo "Error: container $2 not found" >&2; exit 1; fi ;;
              exec) ;;
              *) echo "Error: unexpected $*" >&2; exit 1 ;;
            esac
            """#)
        let backend = CLIBackend(cliPath: script)
        #expect(try await backend.systemStatus().isRunning)  // learns the app root, so `--rm` is known
        return backend
    }

    /// Stops and starts in the order they ran; `exec` = the /etc/hosts refresh.
    func calls(_ directory: TemporaryDirectory) -> (lifecycle: [String], hosts: [String]) {
        let lines = ((try? String(contentsOf: directory.url.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        return (lines.filter { $0.hasPrefix("stop ") || $0.hasPrefix("start ") },
                lines.filter { $0.hasPrefix("exec ") }.map { String($0.dropFirst(5)) })
    }

    @Test func oneServiceFailingToStartNeverLeavesTheOthersDown() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        // Dependency order (db → api → web) differs from name order (api, db, web).
        let db = Service(name: "db"), api = Service(name: "api", dependsOn: "db", startFails: true)
        let web = Service(name: "web", dependsOn: "api")
        let backend = try await fakeCLI(directory, [web, api, db])
        let log = ProgressLog()

        let outcome = try await ComposeOperations(backend: backend).restart(project: Self.project, progress: log.append)

        #expect(outcome.restarted == [db.id, web.id])
        #expect(outcome.failed == [.init(
            id: api.id, reason: "starting failed: `container start \(api.id)` failed (exit 1): failed to bootstrap \(api.id)")])
        #expect(outcome.skipped.isEmpty)
        // One service at a time, dependencies first, and the failure doesn't stop the run.
        #expect(calls(directory).lifecycle == [
            "stop \(db.id)", "start \(db.id)", "stop \(api.id)", "start \(api.id)", "stop \(web.id)", "start \(web.id)",
        ])
        let after = try await backend.listContainers()
        #expect(after.filter { $0.state == .running }.map(\.id).sorted() == [db.id, web.id])
        // /etc/hosts is rewritten afterwards in the services that are running.
        #expect(calls(directory).hosts.sorted() == [db.id, web.id])
        let report = try #require(outcome.report)
        #expect(report.title == "1 of 3 containers couldn't be restarted")
        #expect(report.detail.contains(api.id))
        #expect(log.lines.first == "Restarting \(db.id)")
        #expect(log.lines.contains { $0.hasPrefix("Couldn't restart \(api.id): starting failed") })
        #expect(log.lines.last == report.title)
    }

    @Test func removeOnStopServicesAreSkippedAndReported() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        // `jobs` turned out to be started with --rm after the user confirmed: it's never stopped.
        let db = Service(name: "db"), jobs = Service(name: "jobs", dependsOn: "db", removeOnStop: true)
        let web = Service(name: "web", dependsOn: "db", state: "stopped"), late = Service(name: "late")
        let backend = try await fakeCLI(directory, [db, jobs, web, late])

        // `late` joined the project after the confirmation: left alone.
        let outcome = try await ComposeOperations(backend: backend)
            .restart(project: Self.project, only: [db.id, jobs.id, web.id])

        #expect(outcome.restarted == [db.id, web.id])
        #expect(outcome.skipped == [.init(id: jobs.id, reason: "it was started with --rm, so stopping would delete it")])
        #expect(outcome.failed.isEmpty)
        // A stopped service just starts.
        #expect(calls(directory).lifecycle == ["stop \(db.id)", "start \(db.id)", "start \(web.id)"])
        let after = Dictionary(uniqueKeysWithValues: try await backend.listContainers().map { ($0.id, $0.state) })
        #expect(after == [db.id: .running, jobs.id: .running, web.id: .running, late.id: .running])
        #expect(calls(directory).hosts.sorted() == [db.id, jobs.id, late.id, web.id])
        let report = try #require(outcome.report)
        #expect(report.title == "Restarted 2 of 3 containers")
        #expect(report.detail == "\(jobs.id) was skipped: it was started with --rm, so stopping would delete it")
    }

    @Test func listingFailureThrowsBeforeAnythingIsTouched() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let cli = try directory.script("container", "echo \"$*\" >> \(shellQuote(directory.url.appendingPathComponent("calls.log").path)); echo 'Error: internal error' >&2; exit 1\n")
        await #expect(throws: BackendError.self) {
            try await ComposeOperations(backend: CLIBackend(cliPath: cli)).restart(project: Self.project)
        }
        #expect(calls(directory).lifecycle.isEmpty)
    }
}

@Suite("Compose /etc/hosts script")
struct ComposeHostsScriptTests {
    /// Runs the real script with /bin/sh against a temporary hosts file.
    func apply(_ block: String, to file: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = Array(ComposeHosts.command(block: block, file: file.path).dropFirst())
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func replacesTheBlockIdempotently() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        let hosts = temp.url.appendingPathComponent("hosts")
        let original = "127.0.0.1 localhost\n192.168.64.9 app-1\n"
        try original.write(to: hosts, atomically: true, encoding: .utf8)

        let first = ComposeHosts.block([.init(address: "192.168.64.3", names: ["db", "shop-db-1"])])
        try apply(first, to: hosts)
        try apply(first, to: hosts)
        #expect(try String(contentsOf: hosts, encoding: .utf8) == original + first)

        let second = ComposeHosts.block([
            .init(address: "192.168.64.4", names: ["db", "shop-db-1"]), .init(address: "192.168.64.5", names: ["cache"]),
        ])
        try apply(second, to: hosts)
        #expect(try String(contentsOf: hosts, encoding: .utf8) == original + second)
    }

    @Test func keepsLinesAfterAnOldBlockAndHandlesNoTrailingNewline() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        let hosts = temp.url.appendingPathComponent("hosts")
        try "127.0.0.1 localhost\n\(ComposeHosts.beginMarker)\n10.0.0.1\told\n\(ComposeHosts.endMarker)\n10.9.9.9 later"
            .write(to: hosts, atomically: true, encoding: .utf8)
        let block = ComposeHosts.block([.init(address: "10.0.0.2", names: ["new"])])
        try apply(block, to: hosts)
        #expect(try String(contentsOf: hosts, encoding: .utf8) == "127.0.0.1 localhost\n10.9.9.9 later\n" + block)
    }

    @Test func entriesUseTheSharedNetworkAddress() {
        func member(_ service: String, _ addresses: [(String, String)], state: ContainerState = .running) -> ContainerSummary {
            ContainerSummary(
                id: "p-\(service)-1", imageReference: "x", state: state, ipv4Address: addresses.first?.1,
                networks: addresses.map(\.0),
                labels: [ComposeLabels.project: "p", ComposeLabels.service: service, ComposeLabels.aliases: service == "db" ? "database" : ""],
                networkAddresses: Dictionary(uniqueKeysWithValues: addresses))
        }
        let web = member("web", [("p_front", "10.1.0.2")])
        let api = member("api", [("p_front", "10.1.0.3"), ("p_back", "10.2.0.3")])
        let db = member("db", [("p_back", "10.2.0.4")])
        let off = member("cache", [("p_back", "10.2.0.5")], state: .stopped)
        let all = [web, api, db, off]
        #expect(ComposeHosts.entries(for: web, in: all) == [
            .init(address: "10.1.0.3", names: ["api", "p-api-1"]), .init(address: "10.1.0.2", names: ["web", "p-web-1"]),
        ])
        #expect(ComposeHosts.entries(for: db, in: all) == [
            .init(address: "10.2.0.3", names: ["api", "p-api-1"]), .init(address: "10.2.0.4", names: ["db", "p-db-1", "database"]),
        ])
    }
}

@Suite("CLIBackend compose arguments")
struct ComposeCLIArgumentTests {
    @Test func runFlagsForComposeServices() {
        let spec = RunSpec(
            image: "redis:7-alpine", name: "shop-cache-1", command: ["--save", ""], memory: "256M",
            network: "shop_default", labels: ["b": "2", "a": "1"], entrypoint: "redis-server", workingDirectory: "/data",
            user: "999", additionalNetworks: ["shop_back"], capAdd: ["NET_ADMIN"], capDrop: ["MKNOD"], tmpfs: ["/run"],
            readOnlyRootFilesystem: true, initProcess: true, dns: ["1.1.1.1"], dnsSearch: ["local"], shmSize: "64M",
            ulimits: ["nofile=1024:2048"], interactive: true, tty: true)
        #expect(CLIBackend.runArguments(spec) == [
            "run", "--detach", "--progress", "none", "--name", "shop-cache-1", "--memory", "256M",
            "--network", "shop_default", "--network", "shop_back", "--label", "a=1", "--label", "b=2",
            "--entrypoint", "redis-server", "--workdir", "/data", "--user", "999", "--cap-add", "NET_ADMIN",
            "--cap-drop", "MKNOD", "--tmpfs", "/run", "--read-only", "--init", "--dns", "1.1.1.1", "--dns-search", "local",
            "--shm-size", "64M", "--ulimit", "nofile=1024:2048", "--interactive", "--tty", "redis:7-alpine", "--save", "",
        ])
    }

    @Test func execAndLabelledResourcesThroughAFakeCLI() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let log = shellQuote(directory.url.appendingPathComponent("calls.log").path)
        let cli = try directory.script("container", """
            printf '%s|' "$@" >> \(log); echo >> \(log)
            case "$1" in
              exec) echo "ran in $4" ;;
              network|volume) ;;
              *) exit 1 ;;
            esac
            """)
        let backend = CLIBackend(cliPath: cli)
        #expect(try await backend.exec("web", command: ["sh", "-c", "echo 'a b'"], user: "0") == "ran in web\n")
        try await backend.createNetwork(name: "shop_default", subnet: nil, labels: ["com.docker.compose.project": "shop"])
        try await backend.createVolume(name: "shop_data", size: nil, labels: ["dev.basket.compose": "1"])
        try await backend.createNetwork(name: "plain", subnet: "10.0.0.0/24")
        let calls = try String(contentsOf: directory.url.appendingPathComponent("calls.log"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(calls == [
            "exec|--user|0|web|sh|-c|echo 'a b'|",
            "network|create|--label|com.docker.compose.project=shop|shop_default|",
            "volume|create|--label|dev.basket.compose=1|shop_data|",
            "network|create|--subnet|10.0.0.0/24|plain|",
        ])
    }
}
