import Foundation
import Synchronization

/// `ContainerBackend` that shells out to apple/container's `container` CLI (`--format json`).
public final class CLIBackend: ContainerBackend {
    private let explicitPath: String?
    /// App root reported by the last `system status` (bundles live under it); nil = the default.
    private let reportedAppRoot = Mutex<String?>(nil)

    /// `cliPath` nil = locate the binary (see `CLIRunner.locateContainerCLI`). Never throws: a missing
    /// CLI surfaces from each call as `BackendError.cliNotFound`.
    public init(cliPath: String? = nil) {
        explicitPath = cliPath
    }

    /// Resolved on every call so installing the CLI while the app runs just works (a few `stat`s).
    func runner() throws -> CLIRunner {
        CLIRunner(executableURL: try CLIRunner.locateContainerCLI(explicitPath: explicitPath))
    }

    /// Resolved path, or plain `container` (left to the shell's PATH) when it can't be found.
    var displayPath: String {
        (try? CLIRunner.locateContainerCLI(explicitPath: explicitPath).path) ?? "container"
    }

    // MARK: Plumbing

    /// Runs and returns stdout; non-zero exits become `systemNotRunning` / `commandFailed`.
    @discardableResult
    func output(_ arguments: [String], timeout: Duration? = .seconds(30)) async throws -> Data {
        let runner = try runner()
        let result = try await runner.run(arguments, timeout: timeout)
        guard result.exitCode == 0 else {
            throw CLIErrorClassifier.error(
                command: runner.commandLine(arguments), exitCode: result.exitCode,
                stderr: result.stderrText.isEmpty ? result.stdoutText : result.stderrText)
        }
        return result.stdout
    }

    func list<T: Decodable>(_ type: T.Type, _ arguments: [String], timeout: Duration? = .seconds(30)) async throws -> [T] {
        let runner = try runner()
        let result = try await runner.run(arguments, timeout: timeout)
        let command = runner.commandLine(arguments)
        // `image list` exits non-zero after printing the images it could read; keep the partial list.
        if result.exitCode != 0 {
            let partial = result.stdout.trimmingWhitespace()
            if partial.first == UInt8(ascii: "["), let items = try? RawJSON.decodeList(type, from: partial, command: command),
               !CLIErrorClassifier.isSystemNotRunning(result.stderrText) {
                return items
            }
            throw CLIErrorClassifier.error(command: command, exitCode: result.exitCode, stderr: result.stderrText)
        }
        return try RawJSON.decodeList(type, from: result.stdout, command: command)
    }

    func stream(_ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        do {
            return try runner().lines(arguments)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    // MARK: System

    public func systemStatus() async throws -> SystemStatus {
        let runner = try runner()
        let arguments = ["system", "status", "--format", "json"]
        // The CLI pings the apiserver for up to 10 s before reporting "not running".
        let result = try await runner.run(arguments, timeout: .seconds(20))
        if let raw = try? RawJSON.decoder().decode(RawSystemStatus.self, from: result.stdout.trimmingWhitespace()) {
            if raw.isRunning {
                let status = raw.toStatus()
                if let root = status.appRoot, !root.isEmpty { reportedAppRoot.withLock { $0 = root } }
                return status
            }
            return SystemStatus(isRunning: false, cliVersion: await cliVersion(runner))
        }
        let error = CLIErrorClassifier.error(
            command: runner.commandLine(arguments), exitCode: result.exitCode, stderr: result.stderrText)
        if error == .systemNotRunning || result.exitCode != 0 && result.stdout.isEmpty && result.stderrText.isEmpty {
            return SystemStatus(isRunning: false, cliVersion: await cliVersion(runner))
        }
        throw error
    }

    /// "container CLI version 1.7.1 (build: release, commit: …)" → "1.7.1"; works without the apiserver.
    private func cliVersion(_ runner: CLIRunner) async -> String? {
        guard let result = try? await runner.run(["--version"], timeout: .seconds(5)), result.exitCode == 0 else {
            return nil
        }
        return Self.parseVersion(result.stdoutText)
    }

    static func parseVersion(_ text: String) -> String? {
        guard let match = text.firstMatch(of: /version\s+([0-9][^\s(]*)/) else { return nil }
        return String(match.1)
    }

    public func startSystem() async throws {
        // May download the default kernel on first start.
        try await output(["system", "start", "--enable-kernel-install"], timeout: .seconds(600))
    }

    public func stopSystem() async throws {
        try await output(["system", "stop"], timeout: .seconds(120))
    }

    public func diskUsage() async throws -> DiskUsage {
        let arguments = ["system", "df", "--format", "json"]
        let data = try await output(arguments, timeout: .seconds(60))
        return try RawJSON.decode(RawDiskUsage.self, from: data, command: "container system df").toDiskUsage()
    }

    public func systemProperties() async throws -> SystemProperties {
        let data = try await output(["system", "property", "list", "--format", "json"])
        return try RawJSON.decode(RawSystemProperties.self, from: data, command: "container system property list")
            .toProperties()
    }

    public func hostMemoryFootprints() async throws -> [HostMemoryFootprint] {
        HostMemorySampler.containerVMFootprints()
    }

    // MARK: Containers

    public func listContainers() async throws -> [ContainerSummary] {
        let appRoot = reportedAppRoot.withLock { $0 }.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? ContainerBundleOptions.defaultAppRoot
        return try await list(RawContainer.self, ["list", "--all", "--format", "json"]).map {
            var summary = $0.toSummary()
            summary.removeOnStop = ContainerBundleOptions.removeOnStop(containerID: summary.id, appRoot: appRoot)
            return summary
        }
    }

    public func containerStats() async throws -> [ContainerStats] {
        // `--no-stream` samples twice ~2 s apart to compute `cpuUtilization`.
        let raw = try await list(RawStats.self, ["stats", "--no-stream", "--format", "json"], timeout: .seconds(30))
        let now = Date()
        return raw.map { $0.toStats(sampledAt: now) }
    }

    public func inspectContainer(_ id: String) async throws -> String {
        RawJSON.prettyPrinted(String(decoding: try await output(["inspect", id]), as: UTF8.self))
    }

    public func startContainer(_ id: String) async throws {
        try await output(["start", id], timeout: .seconds(120))
    }

    public func stopContainers(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await output(["stop"] + ids, timeout: .seconds(120))
    }

    public func killContainers(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await output(["kill"] + ids, timeout: .seconds(60))
    }

    public func deleteContainers(_ ids: [String], force: Bool) async throws {
        guard !ids.isEmpty else { return }
        try await output(["delete"] + (force ? ["--force"] : []) + ids, timeout: .seconds(120))
    }

    public func pruneContainers() async throws {
        try await output(["prune"], timeout: .seconds(120))
    }

    public func run(_ spec: RunSpec) async throws -> String {
        let data = try await output(Self.runArguments(spec), timeout: .seconds(900))
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard let id = lines.last.map({ $0.trimmingCharacters(in: .whitespaces) }), !id.isEmpty else {
            if let name = spec.name { return name }
            throw BackendError.decodingFailed(command: "container run", detail: String(localized: "it printed no container ID", bundle: .main))
        }
        return id
    }

    static func runArguments(_ spec: RunSpec) -> [String] {
        var arguments = ["run", "--detach", "--progress", "none"]
        if let name = spec.name, !name.isEmpty { arguments += ["--name", name] }
        if let cpus = spec.cpus { arguments += ["--cpus", String(cpus)] }
        if let memory = spec.memory, !memory.isEmpty { arguments += ["--memory", memory] }
        for port in spec.ports where !port.isEmpty { arguments += ["--publish", port] }
        for volume in spec.volumes where !volume.isEmpty { arguments += ["--volume", volume] }
        for variable in spec.environment where !variable.isEmpty { arguments += ["--env", variable] }
        if let network = spec.network, !network.isEmpty { arguments += ["--network", network] }
        for network in spec.additionalNetworks where !network.isEmpty { arguments += ["--network", network] }
        if spec.removeOnExit { arguments.append("--rm") }
        if spec.rosetta { arguments.append("--rosetta") }
        if let platform = spec.platform, !platform.isEmpty { arguments += ["--platform", platform] }
        for (key, value) in spec.labels.sorted(by: { $0.key < $1.key }) { arguments += ["--label", "\(key)=\(value)"] }
        if let entrypoint = spec.entrypoint { arguments += ["--entrypoint", entrypoint] }
        if let directory = spec.workingDirectory, !directory.isEmpty { arguments += ["--workdir", directory] }
        if let user = spec.user, !user.isEmpty { arguments += ["--user", user] }
        for cap in spec.capAdd { arguments += ["--cap-add", cap] }
        for cap in spec.capDrop { arguments += ["--cap-drop", cap] }
        for path in spec.tmpfs { arguments += ["--tmpfs", path] }
        if spec.readOnlyRootFilesystem { arguments.append("--read-only") }
        if spec.initProcess { arguments.append("--init") }
        for server in spec.dns { arguments += ["--dns", server] }
        for domain in spec.dnsSearch { arguments += ["--dns-search", domain] }
        if let size = spec.shmSize, !size.isEmpty { arguments += ["--shm-size", size] }
        for limit in spec.ulimits { arguments += ["--ulimit", limit] }
        if spec.interactive { arguments.append("--interactive") }
        if spec.tty { arguments.append("--tty") }
        arguments.append(spec.image)
        arguments += spec.command
        return arguments
    }

    public func exec(_ id: String, command: [String], user: String?) async throws -> String {
        let data = try await output(Self.execArguments(id, command: command, user: user), timeout: .seconds(60))
        return String(decoding: data, as: UTF8.self)
    }

    static func execArguments(_ id: String, command: [String], user: String?) -> [String] {
        ["exec"] + (user.map { ["--user", $0] } ?? []) + [id] + command
    }

    public func logs(_ id: String, tail: Int?) async throws -> String {
        let arguments = ["logs"] + (tail.map { ["-n", String($0)] } ?? []) + [id]
        return String(decoding: try await output(arguments, timeout: .seconds(60)), as: UTF8.self)
    }

    /// The last 200 lines, then new output until cancelled.
    public func followLogs(_ id: String) -> AsyncThrowingStream<String, Error> {
        stream(["logs", "--follow", "-n", "200", id])
    }

    public func followLogBatches(_ id: String) -> AsyncThrowingStream<LogBatch, Error> {
        do {
            return try runner().lineBatches(["logs", "--follow", "-n", "200", id])
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    public func shellCommandLine(forContainer id: String) -> String {
        "\(shellQuote(displayPath)) exec -it \(shellQuoteIfNeeded(id)) sh -c "
            + shellQuote("command -v bash >/dev/null && exec bash || exec sh")
    }

    // MARK: Images

    public func listImages() async throws -> [ImageSummary] {
        try await list(RawImage.self, ["image", "list", "--format", "json"], timeout: .seconds(60)).map { $0.toSummary() }
    }

    public func inspectImage(_ reference: String) async throws -> String {
        RawJSON.prettyPrinted(String(decoding: try await output(["image", "inspect", reference]), as: UTF8.self))
    }

    public func pullImage(_ reference: String, platform: String?) -> AsyncThrowingStream<String, Error> {
        stream(Self.pullArguments(reference, platform: platform))
    }

    /// nil platform = host platform only: a multi-arch pull stores every variant (~10 for alpine).
    static func pullArguments(_ reference: String, platform: String?) -> [String] {
        ["image", "pull", "--progress", "plain", "--platform", platform ?? HostPlatform.pullPlatform, reference]
    }

    public func deleteImages(_ references: [String], force: Bool) async throws {
        guard !references.isEmpty else { return }
        try await output(["image", "delete"] + (force ? ["--force"] : []) + references, timeout: .seconds(120))
    }

    public func pruneImages(all: Bool) async throws {
        try await output(["image", "prune"] + (all ? ["--all"] : []), timeout: .seconds(300))
    }

    public func tagImage(_ source: String, as target: String) async throws {
        try await output(["image", "tag", source, target])
    }

    public func saveImage(_ reference: String, platform: String?, to archive: URL) async throws {
        // Large images take minutes; cancelling the task stops the CLI.
        try await output(Self.saveArguments(reference, platform: platform, archive: archive), timeout: .seconds(3600))
    }

    static func saveArguments(_ reference: String, platform: String?, archive: URL) -> [String] {
        ["image", "save"] + (platform.map { ["--platform", $0] } ?? []) + ["--output", archive.path, reference]
    }

    public func loadImage(from archive: URL) async throws -> [String] {
        let data = try await output(["image", "load", "--input", archive.path], timeout: .seconds(3600))
        return Self.loadedReferences(String(decoding: data, as: UTF8.self))
    }

    /// `image load` prints each reference it loaded on its own line (after any progress output).
    static func loadedReferences(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" ") && !$0.hasPrefix("[") }
    }

    // MARK: Volumes

    public func listVolumes() async throws -> [VolumeSummary] {
        try await list(RawVolume.self, ["volume", "list", "--format", "json"]).map {
            $0.toSummary(allocatedBytes: $0.configuration.source.flatMap(allocatedBytes(atPath:)))
        }
    }

    public func createVolume(name: String, size: String?) async throws {
        try await createVolume(name: name, size: size, labels: [:])
    }

    public func createVolume(name: String, size: String?, labels: [String: String]) async throws {
        let sizeArguments = size.flatMap { $0.isEmpty ? nil : ["-s", $0] } ?? []
        try await output(["volume", "create"] + sizeArguments + Self.labelArguments(labels) + [name])
    }

    static func labelArguments(_ labels: [String: String]) -> [String] {
        labels.sorted { $0.key < $1.key }.flatMap { ["--label", "\($0.key)=\($0.value)"] }
    }

    public func deleteVolumes(_ names: [String]) async throws {
        guard !names.isEmpty else { return }
        try await output(["volume", "delete"] + names, timeout: .seconds(60))
    }

    public func pruneVolumes() async throws {
        try await output(["volume", "prune"], timeout: .seconds(120))
    }

    // MARK: Networks

    public func listNetworks() async throws -> [NetworkSummary] {
        try await list(RawNetwork.self, ["network", "list", "--format", "json"]).map { $0.toSummary() }
    }

    public func createNetwork(name: String, subnet: String?) async throws {
        try await createNetwork(name: name, subnet: subnet, labels: [:])
    }

    public func createNetwork(name: String, subnet: String?, labels: [String: String]) async throws {
        let subnetArguments = subnet.flatMap { $0.isEmpty ? nil : ["--subnet", $0] } ?? []
        try await output(["network", "create"] + subnetArguments + Self.labelArguments(labels) + [name])
    }

    public func deleteNetworks(_ names: [String]) async throws {
        guard !names.isEmpty else { return }
        try await output(["network", "delete"] + names)
    }

    // MARK: Machines

    public func listMachines() async throws -> [MachineSummary] {
        let machines = try await list(RawMachine.self, ["machine", "list", "--format", "json"])
        // `machine list` lacks image and home mount; `machine inspect` (one id per call) has them.
        return await withTaskGroup(of: (Int, RawMachine).self) { group in
            for (index, machine) in machines.enumerated() {
                group.addTask {
                    guard let data = try? await self.output(["machine", "inspect", machine.id], timeout: .seconds(10)),
                          let inspected = try? RawJSON.decodeList(RawMachine.self, from: data, command: "").first
                    else { return (index, machine) }
                    return (index, machine.merging(inspected))
                }
            }
            var merged = machines
            for await (index, machine) in group { merged[index] = machine }
            return merged.map { $0.toSummary() }
        }
    }

    public func createMachine(image: String, name: String?, cpus: Int?, memory: String?) -> AsyncThrowingStream<String, Error> {
        stream(Self.createMachineArguments(image: image, name: name, cpus: cpus, memory: memory))
    }

    static func createMachineArguments(image: String, name: String?, cpus: Int?, memory: String?) -> [String] {
        var arguments = ["machine", "create", "--progress", "plain"]
        if let name, !name.isEmpty { arguments += ["--name", name] }
        if let cpus { arguments += ["--cpus", String(cpus)] }
        if let memory, !memory.isEmpty { arguments += ["--memory", memory] }
        arguments.append(image)
        return arguments
    }

    public func startMachine(_ id: String) async throws {
        // There is no `machine start`; `machine run` boots the machine if needed, then runs `true`.
        try await output(["machine", "run", "--name", id, "--", "true"], timeout: .seconds(300))
    }

    public func stopMachine(_ id: String) async throws {
        try await output(["machine", "stop", id], timeout: .seconds(120))
    }

    public func deleteMachine(_ id: String) async throws {
        try await output(["machine", "delete", id], timeout: .seconds(120))
    }

    public func setDefaultMachine(_ id: String) async throws {
        try await output(["machine", "set-default", id])
    }

    /// `machine run` without a command opens an interactive login shell (TTY on by default).
    public func shellCommandLine(forMachine id: String) -> String {
        "\(shellQuote(displayPath)) machine run --name \(shellQuoteIfNeeded(id))"
    }
}
