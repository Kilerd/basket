import SwiftUI
import BasketCore

struct ContainerDetailView: View {
    @Environment(AppStore.self) private var store
    var container: ContainerSummary

    typealias Tab = ContainerDetailTab

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch store.containerDetailTab {
                case .info: ContainerInfoView(container: container)
                case .logs: ContainerLogsView(containerID: container.id)
                case .inspect: InspectJSONView(identifier: "containers.detail.inspect", subject: container.id) { backend in
                    try await backend.inspectContainer(container.id)
                }
                case .stats: ContainerStatsView(container: container)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details for \(container.id)")
        .accessibilityIdentifier("containers.detail")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(container.state == .running ? Series.blue : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(container.id).font(.headline).lineLimit(1).truncationMode(.middle)
                StateBadge(state: container.state, pendingVerb: store.pending[container.id])
                    .font(.caption)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            Picker("Detail", selection: Bindable(store).containerDetailTab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("containers.detail.tabs")
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            Button("Shell", systemImage: "apple.terminal") { store.openShell(container: container.id) }
                .disabled(container.state != .running)
                .help("Open a shell in Terminal")
                .accessibilityIdentifier("containers.action.shell")
            if container.ports.count > 1 {
                Menu {
                    ForEach(container.ports, id: \.self) { port in
                        Button(Format.port(port)) { HostActions.openInBrowser(port) }
                    }
                } label: {
                    Label("Open", systemImage: "safari")
                }
                .fixedSize()
                .disabled(container.state != .running)
                .help("Open a published port in your browser")
                .accessibilityIdentifier("containers.action.open-port")
            } else {
                Button("Open", systemImage: "safari") {
                    if let port = container.ports.first { HostActions.openInBrowser(port) }
                }
                .disabled(container.ports.isEmpty || container.state != .running)
                .help(container.ports.first.map { String(localized: "Open localhost:\($0.hostPort) in your browser") }
                      ?? String(localized: "No published ports"))
                .accessibilityIdentifier("containers.action.open-port")
            }
            Button("Copy IP", systemImage: "doc.on.doc") {
                if let ip = container.ipv4Address { HostActions.copy(ip) }
            }
            .disabled(container.ipv4Address == nil)
            .help(container.ipv4Address.map { String(localized: "Copy \($0)", comment: "Help tag: copy this IP address") }
                  ?? String(localized: "No IP address"))
            .accessibilityIdentifier("containers.action.copy-ip")
            Button("Kill", systemImage: "bolt.fill") { Task { await store.killContainers([container.id]) } }
                .disabled(container.state != .running)
                .help("Send SIGKILL to the container")
                .accessibilityIdentifier("containers.action.kill")
        }
        .labelStyle(.titleAndIcon)
    }
}

// MARK: - Info

private struct ContainerInfoView: View {
    @Environment(AppStore.self) private var store
    var container: ContainerSummary

    var body: some View {
        let stats = store.latestStats[container.id]
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    InfoSection(title: "General") {
                        InfoRow(label: "Image", value: container.imageReference)
                        InfoRow(label: "Command", value: container.command.joined(separator: " "), monospaced: true)
                        InfoRow(label: "Platform", value: container.platform + (container.rosetta ? " (Rosetta)" : ""))
                        ComposeServiceRow(container: container)
                        InfoRow(label: "Created", value: Format.dateTime(container.createdAt))
                        InfoRow(label: "Started", value: container.state == .running ? Format.relative(container.startedAt) : "—")
                    }
                    InfoSection(title: "Resources") {
                        InfoRow(label: "CPUs", value: "\(container.cpus)")
                        InfoRow(label: "Memory limit", value: Format.memory(container.memoryLimitBytes))
                        InfoRow(label: "Processes", value: stats.map { "\($0.processCount)" } ?? "—")
                        ContainerActivityRows(container: container)
                    }
                    // Short values: a fixed width, so General and Network get room for long ones.
                    // 250 pt fits the English labels; longer ones (German, French) widen it.
                    .frame(width: InfoRow.sectionWidth(
                        labels: ["CPUs", "Memory limit", "Processes", "Activity", "Memory Saver"],
                        valueWidth: 130, minimum: 250))
                    InfoSection(title: "Network") {
                        InfoRow(label: "IP address", value: container.ipv4Address ?? "—", monospaced: true)
                        InfoRow(label: "Hostname", value: container.hostname ?? "—")
                        InfoRow(label: "Networks", value: container.networks.joined(separator: ", "))
                        InfoRow(label: "Ports", value: Format.ports(container.ports))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                ContainerMemorySection(container: container)
                HStack(alignment: .top, spacing: 12) {
                    InfoSection(title: "Mounts") {
                        if container.mounts.isEmpty {
                            Text("No mounts").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(container.mounts, id: \.self) { m in
                            InfoRow(verbatimLabel: m.destination, value: m.readOnly
                                    ? String(localized: "\(m.source) (\(m.kind), read-only)", comment: "A mount: source (kind, e.g. “volume” or “bind”)")
                                    : "\(m.source) (\(m.kind))")
                        }
                    }
                    InfoSection(title: "Environment") {
                        if container.environment.isEmpty {
                            Text("No variables").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(container.environment, id: \.self) { entry in
                            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                            InfoRow(verbatimLabel: parts.first ?? entry, value: parts.count > 1 ? parts[1] : "", monospaced: true)
                        }
                    }
                    let labels = container.labels.filter { !ComposeLabels.isManaged($0.key) }
                    if !labels.isEmpty {
                        InfoSection(title: "Labels") {
                            ForEach(labels.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                InfoRow(verbatimLabel: key, value: value, monospaced: true)
                            }
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }
}
