import Foundation

/// Deterministic `ContainerBackend` serving raw CLI JSON from a directory (see `FixtureState` for the
/// file list). Mutations change the in-memory state only, so the UI reflects them for the session.
public actor FixtureBackend: ContainerBackend {
    public nonisolated let directory: URL
    private var state: FixtureState

    public init(directory: URL) {
        self.directory = directory
        state = FixtureState.load(from: directory)
    }

    private func requireRunning() throws {
        try requireCLI()
        guard state.isRunning else { throw BackendError.systemNotRunning }
    }

    /// `cli-missing` fixtures: what `CLIBackend` throws when no `container` binary is found.
    private func requireCLI() throws {
        if state.cliMissing {
            throw BackendError.cliNotFound(searched: ["/opt/homebrew/bin/container", "/usr/local/bin/container"])
        }
    }

    /// Marker file of a fixture set without the `container` CLI.
    public static let cliMissingMarker = FixtureState.cliMissingMarker

    /// False for a `cli-missing` fixture set until `simulateCLIInstall()`.
    public var isCLIInstalled: Bool { !state.cliMissing }

    /// Fixture-only: the `container` CLI "was installed" (onboarding's Install step). The system
    /// stays as the fixture describes it (usually not running yet).
    public func simulateCLIInstall() {
        state.cliMissing = false
    }

    private func failure(_ command: String, _ message: String) -> BackendError {
        .commandFailed(command: "container \(command)", exitCode: 1, stderr: message)
    }

    // MARK: System

    public func systemStatus() async throws -> SystemStatus {
        try requireCLI()
        return state.systemStatus
    }

    public func startSystem() async throws {
        try requireCLI()
        state.isRunning = true
        // `system start` always brings up the builtin network.
        if !state.networks.contains(where: \.isBuiltin) {
            state.networks.insert(
                NetworkSummary(
                    name: "default", mode: "nat", ipv4Subnet: "192.168.64.0/24", ipv4Gateway: "192.168.64.1",
                    isBuiltin: true, createdAt: Date(), labels: [ResourceLabels.role: "builtin"]),
                at: 0)
        }
    }

    public func stopSystem() async throws {
        try requireCLI()
        for index in state.containers.indices where state.containers[index].summary.state == .running {
            stop(at: index)
        }
        state.containers.removeAll { $0.removeOnExit && $0.summary.state != .running }
        for index in state.machines.indices { state.machines[index].state = .stopped }
        state.isRunning = false
    }

    public func diskUsage() async throws -> DiskUsage {
        try requireRunning()
        return state.diskUsage
    }

    public func systemProperties() async throws -> SystemProperties {
        try requireRunning()
        return (state.properties ?? RawSystemProperties()).toProperties()
    }

    /// Footprints of running containers/machines only (stopping one releases its VM), plus unattributed VMs.
    public func hostMemoryFootprints() async throws -> [HostMemoryFootprint] {
        try requireCLI()
        guard state.isRunning else { return [] }
        let running = Set(state.containers.filter { $0.summary.state == .running }.map(\.summary.id))
            .union(state.machines.filter { $0.state == .running }.map(\.id))
        return state.footprints.filter { $0.ownerID.map(running.contains) ?? true }
    }

    // MARK: Containers

    public func listContainers() async throws -> [ContainerSummary] {
        try requireRunning()
        // Fixtures know exactly which containers were run with `--rm`.
        return state.containers.map { container in
            var summary = container.summary
            summary.removeOnStop = container.removeOnExit
            return summary
        }
    }

    public func containerStats() async throws -> [ContainerStats] {
        try requireRunning()
        let now = Date()
        let elapsed = now.timeIntervalSince(state.loadedAt)
        return state.containers.filter { $0.summary.state == .running }.map { container in
            let summary = container.summary
            let raw = state.stats[summary.id] ?? RawStats(
                id: summary.id, cpuUsageUsec: 120_000, cpuUtilization: 0.004,
                memoryUsageBytes: min(summary.memoryLimitBytes, 24 * 1_048_576),
                memoryLimitBytes: summary.memoryLimitBytes, networkRxBytes: 4_096, networkTxBytes: 1_024,
                blockReadBytes: 2_621_440, blockWriteBytes: 8_192, numProcesses: 1)
            var stats = raw.toStats(sampledAt: now)
            // Advance CPU time at the reported rate so `cpuPercent(since:)` matches `reportedCPUPercent`.
            stats.cpuUsageMicros += Int64(elapsed * (raw.cpuUtilization ?? 0) * 1_000_000)
            return stats
        }
    }

    public func inspectContainer(_ id: String) async throws -> String {
        try requireRunning()
        guard let index = state.index(ofContainer: id) else { throw failure("inspect \(id)", "container not found: \(id)") }
        let container = state.containers[index]
        if let json = container.rawJSON,
           var object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
            var status = object["status"] as? [String: Any] ?? [:]
            status["state"] = container.summary.state.rawValue
            if let started = container.summary.startedAt {
                status["startedDate"] = started.formatted(.iso8601)
            }
            object["status"] = status
            return Self.pretty([object])
        }
        let encoded = (try? RawJSON.encoder().encode([RawContainer(summary: container.summary)])) ?? Data("[]".utf8)
        return String(decoding: encoded, as: UTF8.self)
    }

    public func startContainer(_ id: String) async throws {
        try requireRunning()
        guard let index = state.index(ofContainer: id) else { throw failure("start \(id)", "container not found: \(id)") }
        guard state.containers[index].summary.state != .running else { return }
        state.containers[index].summary.state = .running
        state.containers[index].summary.startedAt = Date()
        // A started VM gets an address on each of its networks again.
        if state.containers[index].summary.ipv4Address == nil {
            var addresses: [String: String] = [:]
            for network in state.containers[index].summary.networks {
                addresses[network] = nextAddress(on: network, reserved: Array(addresses.values))
            }
            state.containers[index].summary.networkAddresses = addresses
            state.containers[index].summary.ipv4Address = state.containers[index].summary.networks.first.flatMap { addresses[$0] }
        }
        ensureFootprint(for: state.containers[index].summary)
    }

    public func stopContainers(_ ids: [String]) async throws {
        try requireRunning()
        let indices = try ids.map { id in
            guard let index = state.index(ofContainer: id) else { throw failure("stop \(id)", "container not found: \(id)") }
            return index
        }
        indices.forEach(stop(at:))
        state.containers.removeAll { $0.removeOnExit && $0.summary.state != .running }
    }

    public func killContainers(_ ids: [String]) async throws {
        try await stopContainers(ids)
    }

    private func stop(at index: Int) {
        state.containers[index].summary.state = .stopped
        // Like the CLI: a stopped container has no network attachment, hence no address.
        state.containers[index].summary.ipv4Address = nil
        state.containers[index].summary.networkAddresses = [:]
    }

    public func deleteContainers(_ ids: [String], force: Bool) async throws {
        try requireRunning()
        for id in ids {
            guard let index = state.index(ofContainer: id) else { throw failure("delete \(id)", "container not found: \(id)") }
            if state.containers[index].summary.state == .running && !force {
                throw failure("delete \(id)", "container \(id) is running; stop it first or use --force")
            }
        }
        state.containers.removeAll { ids.contains($0.summary.id) }
    }

    public func pruneContainers() async throws {
        try requireRunning()
        state.containers.removeAll { $0.summary.state != .running }
    }

    public func run(_ spec: RunSpec) async throws -> String {
        try requireRunning()
        let number = state.nextCounter()
        let id = spec.name.flatMap { $0.isEmpty ? nil : $0 }
            ?? String(format: "%08x-b45c-4e7a-9d1f-%012x", 0xb45c_0000 + number, number)
        guard state.index(ofContainer: id) == nil else { throw failure("run", "container with id \(id) already exists") }

        let reference = normalizeImageReference(spec.image)
        if state.index(ofImage: reference) == nil { addImage(reference, platform: spec.platform) }

        var mounts: [MountInfo] = []
        for volume in spec.volumes {
            let parts = volume.split(separator: ":").map(String.init)
            guard parts.count >= 2 else { continue }
            let readOnly = parts.count > 2 && parts[2] == "ro"
            if parts[0].hasPrefix("/") || parts[0].hasPrefix(".") || parts[0].hasPrefix("~") {
                mounts.append(MountInfo(source: parts[0], destination: parts[1], kind: "bind", readOnly: readOnly))
            } else {
                if !state.volumes.contains(where: { $0.name == parts[0] }) { addVolume(parts[0], size: nil) }
                mounts.append(MountInfo(source: parts[0], destination: parts[1], kind: "volume", readOnly: readOnly))
            }
        }

        let network = spec.network.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        let networks = [network] + spec.additionalNetworks.filter { !$0.isEmpty && $0 != network }
        for name in networks where !state.networks.contains(where: { $0.name == name }) && !state.networks.isEmpty {
            throw failure("run", "network \(name) not found")
        }
        var addresses: [String: String?] = [:]
        for name in networks { addresses[name] = nextAddress(on: name, reserved: addresses.values.compactMap { $0 }) }
        let now = Date()
        var summary = ContainerSummary(
            id: id, imageReference: reference, state: .running,
            command: (spec.entrypoint.map { [$0] } ?? []) + spec.command, createdAt: now, startedAt: now,
            cpus: spec.cpus ?? state.defaultContainerCPUs,
            memoryLimitBytes: spec.memory.flatMap(parseByteSize) ?? state.defaultContainerMemory,
            ports: spec.ports.compactMap(Self.parsePort), ipv4Address: addresses[network] ?? nil, hostname: id,
            networks: networks, labels: spec.labels, mounts: mounts,
            platform: spec.platform.map { $0.split(separator: "/").prefix(2).joined(separator: "/") } ?? HostPlatform.pullPlatform,
            rosetta: spec.rosetta,
            environment: ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"] + spec.environment)
        summary.networkAddresses = addresses.compactMapValues { $0 }
        state.containers.append(
            FixtureState.Container(
                summary: summary, rawJSON: nil, diskBytes: state.containerDiskBytes, removeOnExit: spec.removeOnExit))
        ensureFootprint(for: summary)
        return id
    }

    public func logs(_ id: String, tail: Int?) async throws -> String {
        try requireRunning()
        guard state.index(ofContainer: id) != nil else { throw failure("logs \(id)", "container not found: \(id)") }
        let lines = logLines(for: id)
        let selected = tail.map { Array(lines.suffix(max($0, 0))) } ?? lines
        return selected.isEmpty ? "" : selected.joined(separator: "\n") + "\n"
    }

    private func logLines(for id: String) -> [String] {
        let url = directory.appendingPathComponent("logs-\(id).txt")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
                .reversed().drop(while: \.isEmpty).reversed()
        }
        return []
    }

    /// Existing log lines, then stays open (like `--follow`) until the consumer cancels.
    public nonisolated func followLogs(_ id: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await self.logs(id, tail: 200)
                    for line in text.split(whereSeparator: \.isNewline) { continuation.yield(String(line)) }
                    while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
                } catch is CancellationError {
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Records the call (see `execCalls`) and prints nothing; the container must be running.
    public func exec(_ id: String, command: [String], user: String?) async throws -> String {
        try requireRunning()
        let line = (["exec"] + (user.map { ["--user", $0] } ?? []) + [id] + command).joined(separator: " ")
        guard let index = state.index(ofContainer: id) else { throw failure(line, "container not found: \(id)") }
        guard state.containers[index].summary.state == .running else {
            throw failure(line, "container \(id) is not running")
        }
        state.execCalls.append(FixtureExecCall(containerID: id, command: command, user: user))
        return ""
    }

    /// Every `exec` so far, oldest first (fixture-only, for tests).
    public var execCalls: [FixtureExecCall] { state.execCalls }

    public nonisolated func shellCommandLine(forContainer id: String) -> String {
        "'container' exec -it \(shellQuoteIfNeeded(id)) sh -c "
            + shellQuote("command -v bash >/dev/null && exec bash || exec sh")
    }

    // MARK: Images

    public func listImages() async throws -> [ImageSummary] {
        try requireRunning()
        return state.images.map(\.summary)
    }

    public func inspectImage(_ reference: String) async throws -> String {
        try requireRunning()
        guard let index = state.index(ofImage: reference) ?? state.index(ofImage: normalizeImageReference(reference))
        else { throw failure("image inspect \(reference)", "image not found: \(reference)") }
        let image = state.images[index]
        if let json = image.rawJSON, let object = try? JSONSerialization.jsonObject(with: json) {
            return Self.pretty([object])
        }
        let encoded = (try? RawJSON.encoder().encode([RawImage(summary: image.summary)])) ?? Data("[]".utf8)
        return String(decoding: encoded, as: UTF8.self)
    }

    public nonisolated func pullImage(_ reference: String, platform: String?) -> AsyncThrowingStream<String, Error> {
        let lines = [
            "[1/2] Fetching image [0s]", "[1/2] Fetching image 1 of 3 blobs [0s]",
            "[1/2] Fetching image 3 of 3 blobs [1s]", "[2/2] Unpacking image [1s]", "[2/2] Unpacking image [2s]",
        ]
        return cannedStream(lines) { backend in
            try await backend.completePull(reference, platform: platform)
            return []
        }
    }

    private func completePull(_ reference: String, platform: String?) throws {
        try requireRunning()
        let normalized = normalizeImageReference(reference)
        if state.index(ofImage: normalized) == nil { addImage(normalized, platform: platform) }
    }

    public func deleteImages(_ references: [String], force: Bool) async throws {
        try requireRunning()
        for reference in references {
            guard let index = state.index(ofImage: reference) ?? state.index(ofImage: normalizeImageReference(reference))
            else {
                if force { continue }
                throw failure("image delete \(reference)", "image not found: \(reference)")
            }
            state.images.remove(at: index)
        }
    }

    public func pruneImages(all: Bool) async throws {
        try requireRunning()
        guard all else { return }  // Fixture images are all tagged: nothing dangling.
        let used = Set(state.containers.map(\.summary.imageReference))
        state.images.removeAll { !used.contains($0.summary.reference) }
    }

    public func tagImage(_ source: String, as target: String) async throws {
        try requireRunning()
        guard let index = state.index(ofImage: source) ?? state.index(ofImage: normalizeImageReference(source)) else {
            throw failure("image tag \(source) \(target)", "image not found: \(source)")
        }
        var copy = state.images[index]
        copy.summary.reference = normalizeImageReference(target)
        copy.rawJSON = nil
        state.images.removeAll { $0.summary.reference == copy.summary.reference }
        state.images.append(copy)
    }

    /// Writes a synthetic OCI archive (see `ImageArchive.writeSynthetic`) with the matching variants.
    public func saveImage(_ reference: String, platform: String?, to archive: URL) async throws {
        try requireRunning()
        guard let index = state.index(ofImage: reference) ?? state.index(ofImage: normalizeImageReference(reference)) else {
            throw failure("image save \(reference)", "image not found: \(reference)")
        }
        let image = state.images[index].summary
        let variants = image.variants.filter { variant in platform.map { ImageSlimmer.matches(variant.platform, $0) } ?? true }
        guard !variants.isEmpty else {
            throw failure("image save \(reference)", "image does not provide the specified platform \(platform ?? "")")
        }
        do {
            try ImageArchive.writeSynthetic(reference: image.reference, variants: variants, to: archive)
        } catch {
            throw failure("image save \(reference)", "cannot write \(archive.path): \(error.localizedDescription)")
        }
    }

    /// Reads an archive written by `saveImage`; an existing reference is repointed, like the CLI does.
    public func loadImage(from archive: URL) async throws -> [String] {
        try requireRunning()
        let inspected: ImageArchive
        do { inspected = try ImageArchive.inspect(archive) } catch {
            throw failure("image load --input \(archive.path)", error.localizedDescription)
        }
        guard let name = inspected.references.first, !inspected.manifests.isEmpty else {
            throw failure("image load --input \(archive.path)", "the archive contains no image")
        }
        let reference = normalizeImageReference(name)
        let variants = inspected.manifests.map {
            ImageVariant(
                platform: $0.platform, digest: $0.digest,
                sizeBytes: Int64($0.annotations[ImageArchive.fixtureSizeAnnotation] ?? "") ?? 0)
        }
        let total = variants.reduce(0) { $0 + $1.sizeBytes }
        let existing = state.index(ofImage: reference)
        let summary = ImageSummary(
            reference: reference, digest: inspected.indexDigest ?? existing.map { state.images[$0].summary.digest } ?? "",
            createdAt: existing.flatMap { state.images[$0].summary.createdAt } ?? Date(), variants: variants,
            hostVariantSizeBytes: variants.first { ImageSlimmer.matches($0.platform, HostPlatform.pullPlatform) }?.sizeBytes ?? 0,
            totalSizeBytes: total)
        let image = FixtureState.Image(summary: summary, rawJSON: nil, diskBytes: Int64(Double(total) * state.imageDiskRatio))
        if let existing { state.images[existing] = image } else { state.images.append(image) }
        return [reference]
    }

    private func addImage(_ reference: String, platform: String?) {
        let size = 3_000_000 + stableHash(reference) % 60_000_000
        let platformString = platform ?? "linux/arm64/v8"
        let digest = String(format: "sha256:%064x", stableHash(reference + platformString))
        let summary = ImageSummary(
            reference: reference, digest: String(format: "sha256:%064x", stableHash(reference)), createdAt: Date(),
            variants: [ImageVariant(platform: platformString, digest: digest, sizeBytes: size)],
            hostVariantSizeBytes: platformString.hasPrefix(HostPlatform.pullPlatform) ? size : 0, totalSizeBytes: size)
        state.images.append(
            FixtureState.Image(summary: summary, rawJSON: nil, diskBytes: Int64(Double(size) * state.imageDiskRatio)))
    }

    // MARK: Volumes

    public func listVolumes() async throws -> [VolumeSummary] {
        try requireRunning()
        return state.volumes
    }

    public func createVolume(name: String, size: String?) async throws {
        try await createVolume(name: name, size: size, labels: [:])
    }

    public func createVolume(name: String, size: String?, labels: [String: String]) async throws {
        try requireRunning()
        guard !state.volumes.contains(where: { $0.name == name }) else {
            throw failure("volume create \(name)", "volume \(name) already exists")
        }
        addVolume(name, size: size, labels: labels)
    }

    private func addVolume(_ name: String, size: String?, labels: [String: String] = [:]) {
        state.volumes.append(
            VolumeSummary(
                name: name, capacityBytes: size.flatMap(parseByteSize) ?? 512 << 30,
                allocatedBytes: 34_603_008,  // a fresh sparse ext4 image (metadata only)
                source: "/Users/demo/Library/Application Support/com.apple.container/volumes/\(name)/volume.img",
                createdAt: Date(), labels: labels))
    }

    public func deleteVolumes(_ names: [String]) async throws {
        try requireRunning()
        for name in names where !state.volumes.contains(where: { $0.name == name }) {
            throw failure("volume delete \(name)", "volume not found: \(name)")
        }
        let inUse = Set(state.containers.flatMap { $0.summary.mounts.filter { $0.kind == "volume" }.map(\.source) })
        if let busy = names.first(where: inUse.contains) {
            throw failure("volume delete \(busy)", "volume \(busy) is in use by a container")
        }
        state.volumes.removeAll { names.contains($0.name) }
    }

    public func pruneVolumes() async throws {
        try requireRunning()
        let inUse = Set(state.containers.flatMap { $0.summary.mounts.filter { $0.kind == "volume" }.map(\.source) })
        state.volumes.removeAll { !inUse.contains($0.name) }
    }

    // MARK: Networks

    public func listNetworks() async throws -> [NetworkSummary] {
        try requireRunning()
        return state.networks
    }

    public func createNetwork(name: String, subnet: String?) async throws {
        try await createNetwork(name: name, subnet: subnet, labels: [:])
    }

    public func createNetwork(name: String, subnet: String?, labels: [String: String]) async throws {
        try requireRunning()
        guard !state.networks.contains(where: { $0.name == name }) else {
            throw failure("network create \(name)", "network \(name) already exists")
        }
        let third = 64 + state.networks.count + state.nextCounter() % 100
        let resolvedSubnet = subnet.flatMap { $0.isEmpty ? nil : $0 } ?? "192.168.\(third).0/24"
        let gateway = resolvedSubnet.split(separator: "/").first.map { address -> String in
            var octets = address.split(separator: ".").map(String.init)
            if octets.count == 4 { octets[3] = "1" }
            return octets.joined(separator: ".")
        }
        state.networks.append(
            NetworkSummary(
                name: name, mode: "nat", ipv4Subnet: resolvedSubnet, ipv4Gateway: gateway, createdAt: Date(), labels: labels))
    }

    public func deleteNetworks(_ names: [String]) async throws {
        try requireRunning()
        for name in names {
            guard let network = state.networks.first(where: { $0.name == name }) else {
                throw failure("network delete \(name)", "network not found: \(name)")
            }
            if network.isBuiltin { throw failure("network delete \(name)", "cannot delete builtin network \(name)") }
        }
        state.networks.removeAll { names.contains($0.name) }
    }

    private func nextAddress(on network: String, reserved: [String] = []) -> String? {
        guard let subnet = state.networks.first(where: { $0.name == network })?.ipv4Subnet,
              let base = subnet.split(separator: "/").first
        else { return nil }
        let prefix = base.split(separator: ".").prefix(3).joined(separator: ".")
        let taken = Set(state.containers.flatMap { [$0.summary.ipv4Address].compactMap { $0 } + $0.summary.networkAddresses.values } + reserved)
        return (2...254).lazy.map { "\(prefix).\($0)" }.first { !taken.contains($0) }
    }

    // MARK: Machines

    public func listMachines() async throws -> [MachineSummary] {
        try requireRunning()
        return state.machines
    }

    public nonisolated func createMachine(
        image: String, name: String?, cpus: Int?, memory: String?
    ) -> AsyncThrowingStream<String, Error> {
        let lines = ["[0/3] [0s]", "[1/3] Fetching image [0s]", "[2/3] Unpacking image [1s]", "[3/3] Booting machine [2s]"]
        return cannedStream(lines) { backend in
            [try await backend.completeMachine(image: image, name: name, cpus: cpus, memory: memory)]
        }
    }

    private func completeMachine(image: String, name: String?, cpus: Int?, memory: String?) throws -> String {
        try requireRunning()
        let reference = normalizeImageReference(image)
        let base = name.flatMap { $0.isEmpty ? nil : $0 }
            ?? reference.split(separator: "/").last.map { String($0.split(separator: ":")[0]) } ?? "machine"
        if name != nil, state.index(ofMachine: base) != nil {
            throw failure("machine create", "container machine \(base) already exists")
        }
        var id = base
        var suffix = 2
        while state.index(ofMachine: id) != nil {
            id = "\(base)-\(suffix)"
            suffix += 1
        }
        let machine = MachineSummary(
            id: id, image: reference, state: .running, cpus: cpus ?? state.defaultMachineCPUs,
            memoryBytes: memory.flatMap(parseByteSize) ?? state.defaultMachineMemory,
            isDefault: state.machines.isEmpty, homeMount: state.properties?.machine?.homeMount ?? "rw",
            ipv4Address: nextAddress(on: "default"), diskBytes: 47_448_064, createdAt: Date())
        state.machines.append(machine)
        state.footprints.append(
            HostMemoryFootprint(ownerID: id, pid: 70_000 + Int32(state.nextCounter()), footprintBytes: 296_484_864))
        return id
    }

    public func startMachine(_ id: String) async throws {
        try requireRunning()
        guard let index = state.index(ofMachine: id) else { throw failure("machine run", "container machine not found: \(id)") }
        state.machines[index].state = .running
        if !state.footprints.contains(where: { $0.ownerID == id }) {
            state.footprints.append(
                HostMemoryFootprint(ownerID: id, pid: 70_000 + Int32(state.nextCounter()), footprintBytes: 296_484_864))
        }
    }

    public func stopMachine(_ id: String) async throws {
        try requireRunning()
        guard let index = state.index(ofMachine: id) else { throw failure("machine stop \(id)", "container machine not found: \(id)") }
        state.machines[index].state = .stopped
    }

    public func deleteMachine(_ id: String) async throws {
        try requireRunning()
        guard let index = state.index(ofMachine: id) else { throw failure("machine delete \(id)", "container machine not found: \(id)") }
        let wasDefault = state.machines[index].isDefault
        state.machines.remove(at: index)
        state.footprints.removeAll { $0.ownerID == id }
        if wasDefault, !state.machines.isEmpty { state.machines[0].isDefault = true }
    }

    public func setDefaultMachine(_ id: String) async throws {
        try requireRunning()
        guard state.index(ofMachine: id) != nil else {
            throw failure("machine set-default \(id)", "container machine not found: \(id)")
        }
        for index in state.machines.indices { state.machines[index].isDefault = state.machines[index].id == id }
    }

    public nonisolated func shellCommandLine(forMachine id: String) -> String {
        "'container' machine run --name \(shellQuoteIfNeeded(id))"
    }

    // MARK: Helpers

    private func ensureFootprint(for container: ContainerSummary) {
        guard !state.footprints.contains(where: { $0.ownerID == container.id }) else { return }
        // A small Linux guest costs the host roughly 180–260 MB regardless of its memory limit.
        let footprint = min(container.memoryLimitBytes, 180 * 1_048_576 + stableHash(container.id) % (80 * 1_048_576))
        state.footprints.append(
            HostMemoryFootprint(ownerID: container.id, pid: 60_000 + Int32(state.nextCounter()), footprintBytes: footprint))
    }

    /// Yields `lines` ~40 ms apart, then runs `completion` (whose returned lines are yielded last).
    private nonisolated func cannedStream(
        _ lines: [String], completion: @escaping @Sendable (FixtureBackend) async throws -> [String]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.requireRunning()
                    for line in lines {
                        try await Task.sleep(for: .milliseconds(40))
                        continuation.yield(line)
                    }
                    for line in try await completion(self) { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func parsePort(_ spec: String) -> PortMapping? {
        let (body, proto) = spec.split(separator: "/").count == 2
            ? (String(spec.split(separator: "/")[0]), String(spec.split(separator: "/")[1]))
            : (spec, "tcp")
        let parts = body.split(separator: ":").map(String.init)
        switch parts.count {
        case 2:
            guard let host = Int(parts[0]), let container = Int(parts[1]) else { return nil }
            return PortMapping(hostAddress: "0.0.0.0", hostPort: host, containerPort: container, proto: proto)
        case 3:
            guard let host = Int(parts[1]), let container = Int(parts[2]) else { return nil }
            return PortMapping(hostAddress: parts[0], hostPort: host, containerPort: container, proto: proto)
        default:
            return nil
        }
    }

    private static func pretty(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
