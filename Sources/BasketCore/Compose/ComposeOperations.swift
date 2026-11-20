import Foundation

/// Runs compose plans and project-wide actions through any `ContainerBackend`. Progress is reported
/// as human-readable lines; failures throw after reporting what already happened.
public struct ComposeOperations: Sendable {
    public typealias Progress = @Sendable (String) -> Void

    public let backend: any ContainerBackend
    /// Creates missing bind-mount directories (injected for tests).
    public var createDirectory: @Sendable (String) throws -> Void

    public init(
        backend: any ContainerBackend,
        createDirectory: @escaping @Sendable (String) throws -> Void = {
            try FileManager.default.createDirectory(atPath: $0, withIntermediateDirectories: true)
        }
    ) {
        self.backend = backend
        self.createDirectory = createDirectory
    }

    // MARK: Up / down

    /// Creates missing networks and volumes, runs every service in order (existing containers of the
    /// project are started instead of recreated), then writes the service names into /etc/hosts.
    public func up(_ plan: ComposePlan, progress: Progress = { _ in }) async throws {
        let networks = Set(try await backend.listNetworks().map(\.name))
        for network in plan.networks {
            if networks.contains(network.name) { continue }
            if network.external {
                throw ComposeError.invalid(
                    path: "networks.\(network.key)",
                    message: "the external network \(network.name) doesn't exist; create it first (container network create \(network.name))")
            }
            progress("Creating network \(network.name)")
            try await backend.createNetwork(name: network.name, subnet: network.subnet, labels: network.labels)
        }
        let volumes = Set(try await backend.listVolumes().map(\.name))
        for volume in plan.volumes where !volumes.contains(volume.name) {
            if volume.external {
                throw ComposeError.invalid(
                    path: "volumes.\(volume.key)",
                    message: "the external volume \(volume.name) doesn't exist; create it first (container volume create \(volume.name))")
            }
            progress("Creating volume \(volume.name)")
            try await backend.createVolume(name: volume.name, size: nil, labels: volume.labels)
        }
        let existing = Dictionary(try await backend.listContainers().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for service in plan.services {
            for directory in service.bindDirectories {
                progress("Creating directory \(directory)")
                try createDirectory(directory)
            }
            let name = service.containerName
            if let container = existing[name] {
                guard ComposeProject.projectName(of: container) == plan.project else {
                    throw BackendError.commandFailed(
                        command: "container run --name \(name)", exitCode: 1,
                        stderr: "a container named \(name) already exists and isn't part of project \(plan.project); rename or delete it")
                }
                if container.state == .running {
                    progress("\(name) is already running")
                } else {
                    progress("Starting \(name)")
                    try await backend.startContainer(name)
                }
                continue
            }
            progress("Creating and starting \(name) (\(service.spec.image), \(service.spec.memory ?? "default memory"))")
            _ = try await backend.run(service.spec)
        }
        await refreshHosts(project: plan.project, progress: progress)
        progress("Project \(plan.project) is up (\(plan.services.count) service\(plan.services.count == 1 ? "" : "s"))")
    }

    /// Stops and deletes the project's containers and the networks it created; its volumes too when
    /// `removeVolumes` (their data is lost). External resources are never touched. `approved` limits
    /// it to what the user confirmed (anything that joined the project since is left alone).
    public func down(
        project: String, removeVolumes: Bool, approved: ComposeDownApproval? = nil, progress: Progress = { _ in }
    ) async throws {
        let containers = try await members(of: project).filter { approved?.containers.contains($0.id) ?? true }
        let running = containers.filter { $0.state == .running }.map(\.id)
        if !running.isEmpty {
            progress("Stopping \(running.joined(separator: ", "))")
            try await backend.stopContainers(running)
        }
        if !containers.isEmpty {
            progress("Deleting \(containers.map(\.id).joined(separator: ", "))")
            try await backend.deleteContainers(containers.map(\.id), force: true)
        }
        let networks = try await backend.listNetworks()
            .filter { !$0.isBuiltin && $0.labels[ComposeLabels.project] == project }.map(\.name)
            .filter { approved?.networks.contains($0) ?? true }
        if !networks.isEmpty {
            progress("Deleting network\(networks.count == 1 ? "" : "s") \(networks.joined(separator: ", "))")
            try await backend.deleteNetworks(networks)
        }
        if removeVolumes {
            let volumes = try await projectVolumes(project).filter { approved?.volumes.contains($0) ?? true }
            if !volumes.isEmpty {
                progress("Deleting volume\(volumes.count == 1 ? "" : "s") \(volumes.joined(separator: ", "))")
                try await backend.deleteVolumes(volumes)
            }
        }
        progress("Project \(project) is down")
    }

    /// Volumes Basket created for `project` (by label).
    public func projectVolumes(_ project: String) async throws -> [String] {
        try await backend.listVolumes().filter { $0.labels[ComposeLabels.project] == project }.map(\.name)
    }

    // MARK: Start / stop / restart

    /// Starts stopped services (all, or those in `only`) in dependency order, then refreshes
    /// /etc/hosts everywhere.
    public func start(project: String, only: Set<String>? = nil, progress: Progress = { _ in }) async throws {
        let members = try await members(of: project)
        for container in ComposeProject(name: project, containers: members).startOrder
        where container.state != .running && only.map({ $0.contains(container.id) }) != false {
            progress("Starting \(container.id)")
            try await backend.startContainer(container.id)
        }
        await refreshHosts(project: project, progress: progress)
    }

    /// Stops running services (all, or those in `only`), dependents first.
    public func stop(project: String, only: Set<String>? = nil, progress: Progress = { _ in }) async throws {
        let members = try await members(of: project)
        let running = ComposeProject(name: project, containers: members).startOrder.reversed()
            .filter { container in container.state == .running && only.map { $0.contains(container.id) } != false }
        guard !running.isEmpty else { return }
        progress("Stopping \(running.map(\.id).joined(separator: ", "))")
        try await backend.stopContainers(running.map(\.id))
    }

    /// Restarts services (all, or those in `only`) one at a time in dependency order, by the same
    /// rules as container restarts (`MemoryReclaim.restart`): each is stopped and started before the
    /// next is touched, its `--rm` status is re-read right before the stop (one started with `--rm`
    /// is skipped: stopping would delete it), a stopped one just starts, and a failure never leaves
    /// the rest down. Then /etc/hosts is rewritten in every running service. Throws only when the
    /// project can't be listed (nothing was touched); failures and skips are in the outcome.
    @discardableResult
    public func restart(
        project: String, only: Set<String>? = nil, progress: Progress = { _ in }
    ) async throws -> MemoryReclaim.Outcome {
        let members = try await members(of: project)
        let ids = ComposeProject(name: project, containers: members).startOrder.map(\.id)
            .filter { only?.contains($0) ?? true }
        let outcome = await MemoryReclaim.restart(ids, using: backend, onlyRunning: false, progress: progress)
        await refreshHosts(project: project, progress: progress)
        progress(outcome.report?.title ?? "Project \(project) restarted (\(ids.count) service\(ids.count == 1 ? "" : "s"))")
        return outcome
    }

    // MARK: Hosts

    /// Rewrites the Basket block in /etc/hosts of every running container of `project`. Containers
    /// without a shell (or that refuse) are reported and skipped; returns their ids.
    @discardableResult
    public func refreshHosts(project: String, progress: Progress = { _ in }) async -> [String] {
        guard let containers = try? await members(of: project) else { return [] }
        var failed: [String] = []
        for target in containers where target.state == .running {
            let block = ComposeHosts.block(ComposeHosts.entries(for: target, in: containers))
            do {
                _ = try await backend.exec(target.id, command: ComposeHosts.command(block: block), user: "0")
            } catch {
                failed.append(target.id)
                progress("Couldn't update /etc/hosts in \(target.id): \(Self.reason(error))")
            }
        }
        let updated = containers.filter { $0.state == .running }.count - failed.count
        if updated > 0 { progress("Service names written to /etc/hosts in \(updated) container\(updated == 1 ? "" : "s")") }
        return failed
    }

    func members(of project: String) async throws -> [ContainerSummary] {
        try await backend.listContainers().filter { ComposeProject.projectName(of: $0) == project }
    }

    private static func reason(_ error: Error) -> String {
        if case BackendError.commandFailed(_, _, let stderr) = error {
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "the command failed" }
            return trimmed.split(whereSeparator: \.isNewline).last.map(String.init) ?? trimmed
        }
        return error.localizedDescription
    }
}

/// What the user agreed `down` may delete (from the confirmation they saw).
public struct ComposeDownApproval: Sendable, Hashable {
    public var containers: Set<String>
    public var networks: Set<String>
    public var volumes: Set<String>

    public init(containers: Set<String>, networks: Set<String>, volumes: Set<String> = []) {
        self.containers = containers
        self.networks = networks
        self.volumes = volumes
    }
}
