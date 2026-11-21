import SwiftUI
import BasketCore

/// Project-wide actions, shared by the header row's context menu.
struct ComposeProjectMenuItems: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    var project: ComposeProject

    var body: some View {
        if project.state != .running {
            Button("Start Project", systemImage: "play.fill") { Task { await store.startComposeProject(project.name) } }
        }
        if project.state != .stopped {
            Button("Stop Project", systemImage: "stop.fill") { openWindow.mainWindowThen { store.stopComposeProject(project.name) } }
        }
        Button("Restart Project…", systemImage: "arrow.counterclockwise.circle") {
            openWindow.mainWindowThen { store.confirmRestartComposeProject(project.name) }
        }
        Divider()
        Button("Reveal Compose File in Finder", systemImage: "folder") { store.revealComposeFile(project.name) }
            .disabled(!store.canRevealComposeFile(project))
        Button("Show Logs", systemImage: "text.alignleft") {
            store.selectedComposeProject = project.name
            store.containerSelection = []
            store.composeDetailTab = .logs
        }
        Button("Copy Project Name", systemImage: "doc.on.doc") { HostActions.copy(project.name) }
        Divider()
        Button("Down…", systemImage: "arrow.down.to.line", role: .destructive) {
            openWindow.mainWindowThen { store.confirmComposeDown(project.name, removeVolumes: false) }
        }
        if !store.composeVolumes(project.name).isEmpty {
            Button("Down and Delete Volumes…", systemImage: "trash", role: .destructive) {
                openWindow.mainWindowThen { store.confirmComposeDown(project.name, removeVolumes: true) }
            }
        }
    }
}

enum ComposeDetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview", logs = "Logs"
    var id: String { rawValue }
}

/// Detail pane for a selected compose project: totals, services, and merged logs.
struct ComposeProjectDetailView: View {
    @Environment(AppStore.self) private var store
    var project: ComposeProject

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch store.composeDetailTab {
                case .overview: ComposeOverview(project: project)
                case .logs: ComposeLogsView(project: project)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details for compose project \(project.name)")
        .accessibilityIdentifier("containers.detail")
    }

    private var pendingVerb: String? { project.containers.lazy.compactMap { store.pending[$0.id] }.first }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.3.layers.3d")
                .font(.title2)
                .foregroundStyle(project.state == .stopped ? Color.secondary : Series.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name).font(.headline).lineLimit(1).truncationMode(.middle)
                ComposeStateBadge(project: project, pendingVerb: pendingVerb).font(.caption)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            Picker("Detail", selection: Bindable(store).composeDetailTab) {
                ForEach(ComposeDetailTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("containers.detail.tabs")
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button("Start", systemImage: "play.fill") { Task { await store.startComposeProject(project.name) } }
                    .disabled(project.state == .running || pendingVerb != nil)
                    .help("Start every stopped service, dependencies first")
                    .accessibilityIdentifier("containers.action.project-start")
                Button("Stop", systemImage: "stop.fill") { store.stopComposeProject(project.name) }
                    .disabled(project.state == .stopped || pendingVerb != nil)
                    .help("Stop every running service")
                    .accessibilityIdentifier("containers.action.project-stop")
                Button("Restart", systemImage: "arrow.counterclockwise.circle") { store.confirmRestartComposeProject(project.name) }
                    .disabled(pendingVerb != nil)
                    .help("Restart every service and refresh the service names")
                    .accessibilityIdentifier("containers.action.project-restart")
                Button("Down", systemImage: "arrow.down.to.line") { store.confirmComposeDown(project.name, removeVolumes: false) }
                    .disabled(pendingVerb != nil)
                    .help("Stop and delete the project's containers and networks (volumes are kept)")
                    .accessibilityIdentifier("containers.action.project-down")
                Button("Reveal", systemImage: "folder") { store.revealComposeFile(project.name) }
                    .disabled(!store.canRevealComposeFile(project))
                    .help(project.configFile.map { "Show \($0.path) in Finder" } ?? "The compose file isn't known")
                    .accessibilityIdentifier("containers.action.project-reveal")
            }
            .labelStyle(.titleAndIcon)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Overview

private struct ComposeOverview: View {
    @Environment(AppStore.self) private var store
    var project: ComposeProject

    var body: some View {
        let host = store.hostMemoryByOwner
        let running = project.containers.filter { $0.state == .running }
        let limits = project.containers.reduce(Int64(0)) { $0 + $1.memoryLimitBytes }
        let used = running.compactMap { store.latestStats[$0.id]?.memoryUsageBytes }
        let footprint = running.compactMap { host[$0.id] }
        let networks = project.containers.flatMap(\.networks).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let volumes = store.composeVolumes(project.name)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    InfoSection(title: "Project") {
                        InfoRow(label: "Compose file", value: project.configFiles.joined(separator: ", "))
                        InfoRow(label: "Directory", value: project.workingDirectory ?? "—")
                        InfoRow(label: "Networks", value: networks.joined(separator: ", "))
                        InfoRow(label: "Volumes", value: volumes.isEmpty ? "—" : volumes.joined(separator: ", "))
                    }
                    InfoSection(title: "Memory") {
                        InfoRow(label: "Limits", value: "\(Format.memory(limits)) for \(project.totalCount) service\(project.totalCount == 1 ? "" : "s")")
                        InfoRow(label: "In use", value: used.isEmpty ? "—" : Format.memory(used.reduce(0, +)))
                        InfoRow(label: "On this Mac", value: footprint.isEmpty ? "—" : Format.memory(footprint.reduce(0, +)))
                        InfoRow(label: "CPUs", value: "\(running.reduce(0) { $0 + $1.cpus }) of \(project.containers.reduce(0) { $0 + $1.cpus }) running")
                    }
                    .frame(width: 280)
                }
                .fixedSize(horizontal: false, vertical: true)
                InfoSection(title: "Services") {
                    ForEach(project.startOrder, id: \.id) { container in
                        InfoRow(verbatimLabel: ComposeProject.serviceName(of: container), value: describe(container))
                    }
                }
                Label(
                    "Services find each other by name through entries Basket writes into /etc/hosts of each container when the project starts; apple/container has no DNS between containers.",
                    systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    private func describe(_ container: ContainerSummary) -> String {
        var parts = [container.state.title, container.id]
        if let ip = container.ipv4Address { parts.append(ip) }
        if !container.ports.isEmpty { parts.append(Format.ports(container.ports)) }
        parts.append(Format.memory(container.memoryLimitBytes) + " limit")
        return parts.joined(separator: " · ")
    }
}
