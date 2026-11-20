import Foundation
import Testing
@testable import BasketCore

/// CLIBackend against fake `container` scripts that replay real 1.7.1 output (no real CLI involved).
@Suite("CLIBackend with a fake CLI")
struct CLIBackendTests {
    func fakeRunningCLI(_ directory: TemporaryDirectory) throws -> String {
        let fixtures = shellQuote(TestFixtures.realDirectory.path)
        let log = shellQuote(directory.url.appendingPathComponent("calls.log").path)
        return try directory.script("container", """
            FIX=\(fixtures)
            echo "$*" >> \(log)
            case "$*" in
              "list --all --format json") cat "$FIX/container-list.json" ;;
              "stats --no-stream --format json") cat "$FIX/stats.json" ;;
              "image list --format json") cat "$FIX/image-list.json" ;;
              "volume list --format json") cat "$FIX/volume-list.json" ;;
              "network list --format json") cat "$FIX/network-list.json" ;;
              "system status --format json") cat "$FIX/system-status.json" ;;
              "system df --format json") cat "$FIX/system-df.json" ;;
              "system property list --format json") cat "$FIX/system-property.json" ;;
              "machine list --format json") cat "$FIX/machine-list.json" ;;
              "machine inspect basket-test-m") cat "$FIX/machine-inspect.json" ;;
              "inspect probe-alpine") cat "$FIX/container-inspect.json" ;;
              "logs -n 5 probe-alpine") printf 'a\\nb\\n' ;;
              "run "*) echo "fake-id" ;;
              "image pull "*) printf '[1/2] Fetching image [0s]\\r[2/2] Unpacking image [1s]\\n' >&2 ;;
              "stop "*|"delete "*|"image delete "*|"volume create "*|"network create "*|"machine stop "*) ;;
              *) echo "Error: unexpected arguments: $*" >&2; exit 1 ;;
            esac
            """)
    }

    func fakeStoppedCLI(_ directory: TemporaryDirectory) throws -> String {
        try directory.script("container", """
            case "$*" in
              "system status --format json") echo '{"status":"not running"}'; exit 1 ;;
              "--version") echo "container CLI version 1.7.1 (build: release, commit: unspeci)" ;;
              "machine "*) printf 'Error: Plugins are unavailable. Start the container system services and retry:\\n\\n    container system start\\n' >&2; exit 64 ;;
              *) printf 'Error: interrupted: "XPC connection error: Connection invalid"\\nEnsure container system service has been started with `container system start`.\\n' >&2; exit 1 ;;
            esac
            """)
    }

    func calls(_ directory: TemporaryDirectory) throws -> [String] {
        try String(contentsOf: directory.url.appendingPathComponent("calls.log"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    @Test func readsEverythingThroughTheCLI() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let backend = CLIBackend(cliPath: try fakeRunningCLI(directory))

        let status = try await backend.systemStatus()
        #expect(status.isRunning && status.cliVersion == "1.7.1")
        #expect(try await backend.listContainers().map(\.id) == ["probe-alpine"])
        #expect(try await backend.containerStats().first?.cpuUsageMicros == 3552)
        #expect(try await backend.listImages().first?.hostVariantSizeBytes == 4_192_247)
        #expect(try await backend.listVolumes().first?.capacityBytes == 549_755_813_888)
        #expect(try await backend.listNetworks().first?.isBuiltin == true)
        #expect(try await backend.diskUsage().images.total == 2)
        #expect(try await backend.systemProperties().containerMemory == "1gb")
        #expect(try await backend.logs("probe-alpine", tail: 5) == "a\nb\n")

        let machine = try #require(try await backend.listMachines().first)
        #expect(machine.image == "docker.io/library/alpine:latest")  // filled in from `machine inspect`

        let inspect = try await backend.inspectContainer("probe-alpine")
        #expect(inspect.hasPrefix("[\n") && inspect.contains("\"probe-alpine\""))
    }

    @Test func mutationArguments() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let backend = CLIBackend(cliPath: try fakeRunningCLI(directory))

        let id = try await backend.run(RunSpec(
            image: "nginx:latest", name: "web", command: ["nginx", "-g", "daemon off;"], cpus: 2, memory: "512M",
            ports: ["8080:80"], volumes: ["data:/data"], environment: ["A=B"], network: "dev", removeOnExit: true))
        #expect(id == "fake-id")
        let pulled = try await collect(backend.pullImage("alpine", platform: nil))
        #expect(pulled == ["[1/2] Fetching image [0s]", "[2/2] Unpacking image [1s]"])
        _ = try await collect(backend.pullImage("alpine", platform: "linux/amd64"))
        try await backend.stopContainers(["a", "b"])
        try await backend.deleteContainers(["a"], force: true)
        try await backend.deleteImages(["x"], force: false)
        try await backend.createVolume(name: "v", size: "10G")
        try await backend.createNetwork(name: "n", subnet: "10.9.0.0/24")
        try await backend.stopMachine("m")

        #expect(try calls(directory) == [
            "run --detach --progress none --name web --cpus 2 --memory 512M --publish 8080:80 --volume data:/data --env A=B --network dev --rm nginx:latest nginx -g daemon off;",
            "image pull --progress plain --platform linux/arm64 alpine",
            "image pull --progress plain --platform linux/amd64 alpine",
            "stop a b",
            "delete --force a",
            "image delete x",
            "volume create -s 10G v",
            "network create --subnet 10.9.0.0/24 n",
            "machine stop m",
        ])
    }

    @Test func failuresBecomeCommandFailed() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let backend = CLIBackend(cliPath: try fakeRunningCLI(directory))
        await #expect {
            try await backend.startContainer("nope")
        } throws: { error in
            guard case BackendError.commandFailed(let command, let code, let stderr) = error else { return false }
            return command == "container start nope" && code == 1 && stderr == "unexpected arguments: start nope"
        }
    }

    @Test func serviceNotRunning() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let backend = CLIBackend(cliPath: try fakeStoppedCLI(directory))

        let status = try await backend.systemStatus()
        #expect(!status.isRunning)
        #expect(status.cliVersion == "1.7.1")
        await #expect(throws: BackendError.systemNotRunning) { _ = try await backend.listContainers() }
        await #expect(throws: BackendError.systemNotRunning) { _ = try await backend.listImages() }
        await #expect(throws: BackendError.systemNotRunning) { try await backend.stopContainers(["x"]) }
        await #expect(throws: BackendError.systemNotRunning) { _ = try await backend.listMachines() }
        await #expect(throws: BackendError.systemNotRunning) {
            _ = try await collect(backend.pullImage("alpine", platform: nil))
        }
    }

    @Test func missingCLI() async throws {
        let backend = CLIBackend(cliPath: "/nonexistent/container")
        await #expect(throws: BackendError.cliNotFound(searched: ["/nonexistent/container"])) {
            _ = try await backend.listContainers()
        }
        await #expect(throws: BackendError.cliNotFound(searched: ["/nonexistent/container"])) {
            _ = try await collect(backend.followLogs("x"))
        }
        #expect(backend.shellCommandLine(forContainer: "x").hasPrefix("'container' exec -it x "))
    }

    @Test func shellCommandLines() {
        let backend = CLIBackend(cliPath: "/bin/sh")
        #expect(backend.shellCommandLine(forContainer: "probe-alpine")
            == "'/bin/sh' exec -it probe-alpine sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
        #expect(backend.shellCommandLine(forContainer: "it's") .contains(#" exec -it 'it'\''s' "#))
        #expect(backend.shellCommandLine(forMachine: "dev") == "'/bin/sh' machine run --name dev")
    }

    @Test func classifiesNotRunningStderr() {
        let xpc = "Error: interrupted: \"XPC connection error: Connection invalid\"\nEnsure container system service has been started with `container system start`."
        #expect(CLIErrorClassifier.error(command: "c", exitCode: 1, stderr: xpc) == .systemNotRunning)
        #expect(CLIErrorClassifier.error(command: "c", exitCode: 64, stderr: "Error: Plugins are unavailable. Start the container system services and retry:") == .systemNotRunning)
        #expect(CLIErrorClassifier.error(command: "c", exitCode: 1, stderr: "Error: notFound: \"no such container\"\n")
            == .commandFailed(command: "c", exitCode: 1, stderr: "notFound: \"no such container\""))
        #expect(CLIErrorClassifier.cleaned("[0/3] [0s]\nError: invalid memory value '512mb'.\nhint\n") == "invalid memory value '512mb'.\nhint")
        #expect(CLIErrorClassifier.cleaned("  plain failure \n") == "plain failure")
        #expect(CLIBackend.parseVersion("container CLI version 1.7.1 (build: release, commit: unspeci)") == "1.7.1")
    }

    @Test func machineArguments() {
        #expect(CLIBackend.createMachineArguments(image: "ubuntu:24.04", name: "dev", cpus: 4, memory: "8G")
            == ["machine", "create", "--progress", "plain", "--name", "dev", "--cpus", "4", "--memory", "8G", "ubuntu:24.04"])
        #expect(CLIBackend.createMachineArguments(image: "alpine", name: nil, cpus: nil, memory: nil)
            == ["machine", "create", "--progress", "plain", "alpine"])
    }

    @Test func machineContainerIDs() {
        #expect(HostMemorySampler.machineID(fromContainerID: "basket-test-m-32cb51") == "basket-test-m")
        #expect(HostMemorySampler.machineID(fromContainerID: "web") == "web")
        #expect(HostMemorySampler.ownerID(fromRuntimeArguments: [
            "/x/container-runtime-linux", "start", "--root", "/nonexistent/containers/probe-alpine", "--uuid", "probe-alpine",
        ]) == "probe-alpine")
        #expect(HostMemorySampler.ownerID(fromRuntimeArguments: ["start", "--root", "/nonexistent/web"]) == "web")
        #expect(HostMemorySampler.ownerID(fromRuntimeArguments: ["start"]) == nil)
    }

    @Test func machineBundleAttribution() throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let bundle = directory.url.appendingPathComponent("dev-ab12cd")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(#"{"id":"dev-ab12cd","labels":{"com.apple.container.plugin":"machine"}}"#.utf8)
            .write(to: bundle.appendingPathComponent("config.json"))
        #expect(HostMemorySampler.ownerID(fromRuntimeArguments: ["start", "--root", bundle.path, "--uuid", "dev-ab12cd"]) == "dev")
    }
}
