import SwiftUI
import BasketCore

struct ContainersView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let table = store.containerGroups
        ListSectionBody(section: .containers, isEmpty: table.groups.isEmpty && table.standalone.isEmpty) {
            let selected = selectedContainer
            let project = selectedProject
            DetailSplit(showsBottom: selected != nil || project != nil) {
                ContainersTable(groups: table.groups, standalone: table.standalone)
            } bottom: {
                if let project {
                    ComposeProjectDetailView(project: project)
                } else if let selected {
                    ContainerDetailView(container: selected)
                }
            }
        } empty: {
            SectionEmptyState(
                section: .containers, title: "No Containers", systemImage: "shippingbox",
                message: "Run a container from an image. Each one gets its own lightweight VM with just the memory you give it."
            ) {
                Button("New Container…") { store.activeSheet = .newContainer(.defaults()) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("containers.action.new-empty")
            }
        }
        .navigationTitle("Containers")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
    }

    private var selectedProject: ComposeProject? {
        store.selectedComposeProject.flatMap(store.composeProject(named:))
    }

    private var selectedContainer: ContainerSummary? {
        guard store.containerSelection.count == 1, let id = store.containerSelection.first else { return nil }
        return store.containers.first { $0.id == id }
    }

    private var subtitle: String {
        let running = store.runningContainers.count
        return "\(running) running of \(store.containers.count)"
    }

    private var selection: [ContainerSummary] {
        store.containers.filter { store.containerSelection.contains($0.id) }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let selected = selection
        let ids = selected.map(\.id)
        // With a project header selected, the actions apply to the whole project.
        let project = selectedProject
        ToolbarItemGroup {
            ToolbarActionButton(title: "New Container", systemImage: "plus", identifier: "containers.action.new",
                                help: "New Container (⌘N)") {
                store.activeSheet = .newContainer(.defaults())
            }
            .disabled(store.availability != .running)
            ToolbarActionButton(title: "Compose Up", systemImage: "square.3.layers.3d", identifier: "containers.action.compose-up",
                                help: "Compose Up… (⇧⌘O): run a compose.yaml") {
                store.chooseComposeFile()
            }
            .disabled(store.availability != .running)
            ToolbarActionButton(title: "Start", systemImage: "play.fill", identifier: "containers.action.start") {
                if let project {
                    Task { await store.startComposeProject(project.name) }
                } else {
                    Task { await store.startContainers(selected.filter { $0.state != .running }.map(\.id)) }
                }
            }
            .disabled(project.map { $0.state == .running } ?? !selected.contains { $0.state != .running })
            ToolbarActionButton(title: "Stop", systemImage: "stop.fill", identifier: "containers.action.stop") {
                if let project {
                    store.stopComposeProject(project.name)
                } else {
                    Task { await store.stopContainers(selected.filter { $0.state == .running }.map(\.id)) }
                }
            }
            .disabled(project.map { $0.state == .stopped } ?? !selected.contains { $0.state == .running })
            ToolbarActionButton(title: "Restart", systemImage: "arrow.counterclockwise.circle",
                                identifier: "containers.action.restart") {
                if let project { store.confirmRestartComposeProject(project.name) } else { store.confirmRestartContainers(ids) }
            }
            .disabled(ids.isEmpty && project == nil)
            ToolbarActionButton(title: "Delete", systemImage: "trash", identifier: "containers.action.delete",
                                help: project == nil ? "Delete (⌫)" : "Down… (⌫): delete the project's containers and networks") {
                if let project { store.confirmComposeDown(project.name, removeVolumes: false) } else { store.confirmDeleteContainers(ids) }
            }
            .disabled(ids.isEmpty && project == nil)
            RefreshButton(section: .containers)
        }
        CommonToolbarItems(section: .containers)
    }
}

private struct ContainersTable: View {
    @Environment(AppStore.self) private var store
    var groups: [ContainerGroup]
    var standalone: [ContainerRow]

    var body: some View {
        @Bindable var store = store
        Table(visibleRows, selection: $store.containerTableSelection, sortOrder: $store.containerSort) {
            TableColumn("Name", value: \.name) { row in
                ContainerNameCell(row: row, grouped: !groups.isEmpty, isLastService: lastServices.contains(row.id))
            }
            .width(min: 140, ideal: 190)
            TableColumn("Image", value: \.image) { row in
                Text(row.image).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(row.project == nil ? row.summary.imageReference : row.image)
            }
            .width(min: 110, ideal: 160)
            TableColumn("State", value: \.stateOrder) { row in
                if let project = row.project {
                    ComposeStateBadge(project: project, pendingVerb: project.containers.lazy.compactMap { store.pending[$0.id] }.first)
                } else {
                    StateBadge(state: row.summary.state, pendingVerb: store.pending[row.id])
                }
            }
            .width(min: 100, ideal: 110)
            TableColumn("Ports", value: \.portsText) { row in
                Text(row.portsText).foregroundStyle(row.portsText.isEmpty ? .secondary : .primary).lineLimit(1)
                    .help(row.portsText)
            }
            .width(min: 70, ideal: 100)
            TableColumn("CPU", value: \.cpu) { row in
                CPUCell(percent: row.cpu, idleFor: row.idleFor)
            }
            .width(min: 70, ideal: 76)
            .alignment(.numeric)
            TableColumn("Memory", value: \.memoryUsed) { row in
                MemoryUsageCell(used: row.memoryUsed, limit: row.memoryLimit)
            }
            .width(min: MemoryUsageCell.minimumWidth, ideal: 200)
            .alignment(.numeric)
            TableColumn("Host Memory", value: \.hostMemory) { row in
                HostMemoryCell(bytes: row.hostMemory, strandedBytes: row.strandedBytes)
            }
            .width(min: 90, ideal: 110)
            .alignment(.numeric)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let projects = ids.filter { $0.hasPrefix(AppStore.composeRowPrefix) }
            if let id = projects.first, ids.count == 1,
               let project = store.composeProject(named: String(id.dropFirst(AppStore.composeRowPrefix.count))) {
                ComposeProjectMenuItems(project: project)
            } else {
                ContainerMenuItems(ids: Array(ids.subtracting(projects)))
            }
        }
        .onDeleteCommand {
            if let project = store.selectedComposeProject {
                store.confirmComposeDown(project, removeVolumes: false)
            } else {
                store.confirmDeleteContainers(Array(store.containerSelection))
            }
        }
        .accessibilityIdentifier("containers.list")
    }

    private var lastServices: Set<String> { Set(groups.compactMap(\.members.last?.id)) }

    /// Project headers, their services unless collapsed, then standalone containers.
    private var visibleRows: [ContainerRow] {
        groups.flatMap { group in
            [group.header] + (store.collapsedComposeProjects.contains(group.project.name) ? [] : group.members)
        } + standalone
    }
}

/// Shared by the table's context menu and the menu bar extra.
struct ContainerMenuItems: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    var ids: [String]

    var body: some View {
        let items = store.containers.filter { ids.contains($0.id) }
        let running = items.filter { $0.state == .running }
        let stopped = items.filter { $0.state != .running }
        if !stopped.isEmpty {
            Button("Start", systemImage: "play.fill") { Task { await store.startContainers(stopped.map(\.id)) } }
        }
        if !running.isEmpty {
            Button("Stop", systemImage: "stop.fill") { Task { await store.stopContainers(running.map(\.id)) } }
            Button("Restart…", systemImage: "arrow.counterclockwise.circle") {
                openWindow.mainWindowThen { store.confirmRestartContainers(running.map(\.id)) }
            }
            Button("Kill", systemImage: "bolt.fill") { Task { await store.killContainers(running.map(\.id)) } }
        }
        if items.count == 1, let c = items.first {
            MemoryMenuItems(container: c)
            Divider()
            Button("Open Shell in Terminal", systemImage: "apple.terminal") { store.openShell(container: c.id) }
                .disabled(c.state != .running)
            ForEach(c.ports, id: \.self) { port in
                Button("Open localhost:\(port.hostPort) in Browser", systemImage: "safari") { HostActions.openInBrowser(port) }
            }
            if let ip = c.ipv4Address {
                Button("Copy IP Address (\(ip))", systemImage: "doc.on.doc") { HostActions.copy(ip) }
            }
            Button("Copy Name", systemImage: "doc.on.doc") { HostActions.copy(c.id) }
        }
        if !items.isEmpty {
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) {
                openWindow.mainWindowThen { store.confirmDeleteContainers(items.map(\.id)) }
            }
        }
    }
}
