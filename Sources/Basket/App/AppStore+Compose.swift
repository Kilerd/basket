import AppKit
import UniformTypeIdentifiers
import BasketCore

/// A compose project in the containers table: a header row with the project's totals and its
/// (filtered, sorted) service rows.
struct ContainerGroup: Identifiable, Hashable {
    var project: ComposeProject
    var header: ContainerRow
    var members: [ContainerRow]
    var id: String { header.id }
}

extension AppStore {
    /// Header rows use ids that can't clash with container ids (those never contain a colon).
    static let composeRowPrefix = "compose:"

    static func composeRowID(_ project: String) -> String { composeRowPrefix + project }

    var composeProjects: [ComposeProject] { ComposeProject.group(containers).projects }

    func composeProject(named name: String) -> ComposeProject? {
        let members = containers.filter { ComposeProject.projectName(of: $0) == name }
        return members.isEmpty ? nil : ComposeProject(name: name, containers: members)
    }

    /// The containers table, OrbStack-style: compose projects first (sorted like their rows), then
    /// standalone containers. Search keeps a project when its name or any of its services match.
    var containerGroups: (groups: [ContainerGroup], standalone: [ContainerRow]) {
        let rows = containerRows
        var members: [String: [ContainerRow]] = [:]
        var standalone: [ContainerRow] = []
        for row in rows {
            if let project = ComposeProject.projectName(of: row.summary) {
                members[project, default: []].append(row)
            } else {
                standalone.append(row)
            }
        }
        let all = ComposeProject.group(containers).projects
        let groups = all.compactMap { project -> ContainerGroup? in
            guard let visible = members[project.name] else { return nil }
            return ContainerGroup(project: project, header: headerRow(for: project), members: visible)
        }
        let order = groups.map(\.header).sorted(using: containerSort).map(\.id)
        return (groups.sorted { order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! }, standalone)
    }

    /// Totals in the same units and slots as a container row, so the columns line up.
    func headerRow(for project: ComposeProject) -> ContainerRow {
        let host = hostMemoryByOwner
        let insights = memoryInsights
        let running = project.containers.filter { $0.state == .running }
        let cpu = running.compactMap { cpuPercent[$0.id] }
        let used = running.compactMap { latestStats[$0.id]?.memoryUsageBytes }
        let footprints = running.compactMap { host[$0.id] }
        let summary = ContainerSummary(
            id: Self.composeRowID(project.name), imageReference: "",
            state: project.state == .stopped ? .stopped : .running,
            labels: [ComposeLabels.project: project.name])
        return ContainerRow(
            summary: summary, image: "\(project.totalCount) service\(project.totalCount == 1 ? "" : "s")",
            stateOrder: project.state == .running ? 0 : project.state == .partial ? 1 : 3,
            portsText: project.containers.flatMap(\.ports).map(Format.port).joined(separator: ", "),
            cpu: cpu.isEmpty ? -1 : cpu.reduce(0, +),
            memoryUsed: used.isEmpty ? -1 : used.reduce(0, +),
            memoryLimit: project.containers.reduce(0) { $0 + $1.memoryLimitBytes },
            hostMemory: footprints.isEmpty ? -1 : footprints.reduce(0, +),
            strandedBytes: running.reduce(0) { total, c in
                total + (insights[c.id].flatMap { $0.isStranded ? $0.strandedBytes : nil } ?? 0)
            },
            project: project)
    }

    /// The table selection: containers, or one project header (`selectedComposeProject`).
    var containerTableSelection: Set<String> {
        get {
            var ids = containerSelection
            if let project = selectedComposeProject { ids.insert(Self.composeRowID(project)) }
            return ids
        }
        set {
            let containers = newValue.filter { !$0.hasPrefix(Self.composeRowPrefix) }
            let projects = newValue.filter { $0.hasPrefix(Self.composeRowPrefix) }.map { String($0.dropFirst(Self.composeRowPrefix.count)) }
            if !containers.isEmpty || projects.isEmpty {
                if selectedComposeProject != nil { selectedComposeProject = nil }
                if containerSelection != containers { containerSelection = containers }
            } else {
                if !containerSelection.isEmpty { containerSelection = [] }
                let project = projects.sorted().first
                if selectedComposeProject != project { selectedComposeProject = project }
            }
        }
    }

    // MARK: Compose Up

    /// Asks for a compose file (or a folder holding one), then shows its plan.
    func chooseComposeFile() {
        let panel = NSOpenPanel()
        panel.title = "Compose Up"
        panel.message = "Choose a compose.yaml or docker-compose.yml, or the folder that holds it."
        panel.prompt = "Show Plan"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["yaml", "yml"].compactMap { UTType(filenameExtension: $0) } + [.folder]
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.showComposePlan(for: url)
        }
        if let window = mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    /// A folder resolves to the first default compose file name inside it.
    func showComposePlan(for url: URL) {
        var file = url
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let found = ComposeLoader.defaultFileNames.map({ url.appendingPathComponent($0) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) })
            else {
                showError("No compose file in “\(url.lastPathComponent)”", BackendError.unsupported(
                    "A folder without \(ComposeLoader.defaultFileNames.joined(separator: ", "))"))
                return
            }
            file = found
        }
        selectedSection = .containers
        activeSheet = .composePlan(file)
    }

    /// Planner defaults from Settings: memory is always set explicitly (each service is its own VM).
    var composePlanOptions: ComposePlanOptions {
        let defaults = UserDefaults.standard
        return ComposePlanOptions(
            defaultMemory: MemorySize.cliString(megabytes: max(128, defaults.integer(forKey: DefaultsKey.defaultMemoryMB))),
            defaultCPUs: max(1, defaults.integer(forKey: DefaultsKey.defaultCPUs)))
    }

    // MARK: Project actions

    private func memberIDs(_ project: String) -> [String] {
        containers.filter { ComposeProject.projectName(of: $0) == project }.map(\.id)
    }

    func startComposeProject(_ project: String) async {
        await perform("Starting", ids: memberIDs(project), refresh: [.containers, .stats, .footprints]) { backend in
            try await ComposeOperations(backend: backend).start(project: project)
        }
    }

    /// Stops right away unless a service was started with `--rm` (stopping deletes it) or might have been.
    func stopComposeProject(_ project: String) {
        guard let compose = composeProject(named: project) else { return }
        let running = compose.containers.filter { $0.state == .running }
        let deleted = running.filter { $0.removeOnStop == true }.map(\.id)
        let unknown = running.filter { $0.removeOnStop == nil }.map(\.id)
        guard deleted.isEmpty, unknown.isEmpty || compose.isBasketManaged else {
            confirmation = Confirmation(
                title: "Stop “\(project)”?",
                message: Self.removeOnStopNote(deleted: deleted, unknown: unknown),
                confirmLabel: deleted.isEmpty ? "Stop Anyway" : "Stop and Delete") { [weak self] in
                Task { await self?.stopComposeProject(project, confirmed: true) }
            }
            return
        }
        Task { await stopComposeProject(project, confirmed: true) }
    }

    private func stopComposeProject(_ project: String, confirmed: Bool) async {
        await perform("Stopping", ids: memberIDs(project), refresh: [.containers, .stats, .footprints]) { backend in
            try await ComposeOperations(backend: backend).stop(project: project)
        }
    }

    /// Like restarting containers: one service at a time, and services started with `--rm` are
    /// skipped (stopping would delete them); failures and skips end up in the banner.
    func confirmRestartComposeProject(_ project: String) {
        guard let compose = composeProject(named: project) else { return }
        let deleted = compose.containers.filter { $0.state == .running && $0.removeOnStop == true }.map(\.id)
        let unknown = compose.isBasketManaged
            ? [] : compose.containers.filter { $0.state == .running && $0.removeOnStop == nil }.map(\.id)
        let restartable = compose.containers.map(\.id).filter { !deleted.contains($0) }
        guard !restartable.isEmpty else { return }
        var message = ["Each service is stopped and started again in turn, in dependency order, then Basket rewrites the service names in /etc/hosts. If one doesn't come back, the others still restart. Published ports come back once the services run again; anything kept only in memory is lost."]
        if !deleted.isEmpty || !unknown.isEmpty {
            message.append(Self.removeOnStopNote(deleted: deleted, unknown: unknown, skipping: true))
        }
        confirmation = Confirmation(
            title: "Restart “\(project)”?", message: message.joined(separator: "\n\n"),
            confirmLabel: unknown.isEmpty ? "Restart" : "Restart Anyway", isDestructive: !unknown.isEmpty
        ) { [weak self] in
            Task {
                await self?.restart(restartable) { backend in
                    try await ComposeOperations(backend: backend).restart(project: project, only: Set(restartable))
                }
            }
        }
    }

    private static func removeOnStopNote(deleted: [String], unknown: [String], skipping: Bool = false) -> String {
        func names(_ list: [String]) -> String { list.map { "“\($0)”" }.joined(separator: ", ") }
        var parts: [String] = []
        if !deleted.isEmpty {
            parts.append(skipping
                ? "Skipped \(names(deleted)): started with --rm, so stopping would delete \(deleted.count == 1 ? "it" : "them")."
                : "\(names(deleted)) \(deleted.count == 1 ? "was" : "were") started with --rm: stopping deletes \(deleted.count == 1 ? "it" : "them") for good.")
        }
        if !unknown.isEmpty {
            parts.append("Basket can't tell whether \(names(unknown)) \(unknown.count == 1 ? "was" : "were") started with --rm. If so, stopping deletes \(unknown.count == 1 ? "it" : "them") for good.")
        }
        return parts.joined(separator: " ")
    }

    /// `down`: says exactly which containers, networks (and, if asked, volumes and their data) go.
    func confirmComposeDown(_ project: String, removeVolumes: Bool) {
        guard let compose = composeProject(named: project) else { return }
        let containers = compose.containers.map(\.id)
        let networks = self.networks.filter { $0.labels[ComposeLabels.project] == project && !$0.isBuiltin }.map(\.name)
        let volumes = composeVolumes(project)
        func list(_ items: [String]) -> String { items.joined(separator: ", ") }
        var message = ["Stops and deletes \(containers.count == 1 ? "its container" : "its \(containers.count) containers") (\(list(containers)))"
            + (networks.isEmpty ? "." : " and \(networks.count == 1 ? "the network" : "the networks") \(list(networks)).")]
        if removeVolumes {
            message.append(volumes.isEmpty
                ? "The project has no volumes to delete."
                : "Also deletes \(volumes.count == 1 ? "the volume" : "the volumes") \(list(volumes)) — the data in \(volumes.count == 1 ? "it" : "them") is lost for good.")
        } else {
            message.append(volumes.isEmpty ? "Images are kept." : "Images and the volumes \(list(volumes)) are kept, so Compose Up brings the data back.")
        }
        confirmation = Confirmation(
            title: removeVolumes ? "Delete “\(project)” and its volumes?" : "Take “\(project)” down?",
            message: message.joined(separator: "\n\n"),
            confirmLabel: removeVolumes ? "Delete Everything" : "Down"
        ) { [weak self] in
            let approved = ComposeDownApproval(
                containers: Set(containers), networks: Set(networks), volumes: removeVolumes ? Set(volumes) : [])
            Task { await self?.composeDown(project, removeVolumes: removeVolumes, approved: approved) }
        }
    }

    private func composeDown(_ project: String, removeVolumes: Bool, approved: ComposeDownApproval) async {
        if selectedComposeProject == project { selectedComposeProject = nil }
        await perform("Removing", ids: approved.containers.sorted(), refresh: [.containers, .stats, .footprints, .networks, .volumes, .disk]) { backend in
            try await ComposeOperations(backend: backend).down(project: project, removeVolumes: removeVolumes, approved: approved)
        }
    }

    /// Volumes Basket created for the project (labelled at `up`).
    func composeVolumes(_ project: String) -> [String] {
        volumes.filter { $0.labels[ComposeLabels.project] == project }.map(\.name)
    }

    func revealComposeFile(_ project: String) {
        guard let compose = composeProject(named: project) else { return }
        if let file = compose.configFile, FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else if let directory = compose.workingDirectory, FileManager.default.fileExists(atPath: directory) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
        } else {
            showError("Can't find the compose file", BackendError.unsupported(
                "Revealing \(compose.configFiles.first ?? compose.workingDirectory ?? project), which no longer exists on this Mac,"))
        }
    }

    func canRevealComposeFile(_ project: ComposeProject) -> Bool {
        [project.configFile?.path, project.workingDirectory].compactMap { $0 }.contains { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: Service discovery

    /// After containers start individually, their projects' /etc/hosts entries are rewritten (a
    /// restarted VM may come back with another address).
    func refreshComposeHosts(after ids: [String]) async {
        let projects = Set(containers.filter { ids.contains($0.id) }.compactMap(ComposeProject.projectName(of:)))
        guard !projects.isEmpty else { return }
        let operations = ComposeOperations(backend: backend)
        for project in projects.sorted() { await operations.refreshHosts(project: project) }
    }
}
