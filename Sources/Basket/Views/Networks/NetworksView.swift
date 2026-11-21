import SwiftUI
import BasketCore

struct NetworksView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let rows = store.networkRows
        ListSectionBody(section: .networks, isEmpty: rows.isEmpty) {
            NetworksTable(rows: rows)
        } empty: {
            SectionEmptyState(
                section: .networks, title: "No Networks", systemImage: "network",
                message: "Create a network to give a group of containers their own subnet."
            ) {
                Button("New Network…") { store.activeSheet = .newNetwork }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("networks.action.new-empty")
            }
        }
        .navigationTitle("Networks")
        .navigationSubtitle("\(store.networks.count) networks")
        .toolbar { toolbar }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            ToolbarActionButton(title: "New Network", systemImage: "plus", identifier: "networks.action.new",
                                help: "New Network (⌘N)") {
                store.activeSheet = .newNetwork
            }
            .disabled(store.availability != .running)
            ToolbarActionButton(title: "Delete", systemImage: "trash", identifier: "networks.action.delete",
                                help: "Delete (⌫). The built-in default network can't be deleted.") {
                store.confirmDeleteNetworks(Array(store.networkSelection))
            }
            .disabled(!store.canDeleteSelection)
            RefreshButton(section: .networks)
        }
        CommonToolbarItems(section: .networks)
    }
}

private struct NetworksTable: View {
    @Environment(AppStore.self) private var store
    var rows: [NetworkRow]

    var body: some View {
        @Bindable var store = store
        Table(rows, selection: $store.networkSelection, sortOrder: $store.networkSort) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    Text(row.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .accessibilityIdentifier("networks.row.\(row.id)")
                    if row.summary.isBuiltin { Pill(text: "Built-in", systemImage: "lock.fill") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 120, ideal: 180)
            TableColumn("Mode", value: \.mode) { row in Text(row.mode.uppercased() == "NAT" ? "NAT" : row.mode) }
                .width(min: 50, ideal: 70)
            TableColumn("Subnet", value: \.subnet) { row in
                Text(row.subnet.isEmpty ? "—" : row.subnet).font(.body.monospaced())
            }
            .width(min: 110, ideal: 150)
            TableColumn("Gateway", value: \.gateway) { row in
                Text(row.gateway.isEmpty ? "—" : row.gateway).font(.body.monospaced()).foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 130)
            TableColumn("IPv6") { row in
                Text(row.summary.ipv6Subnet ?? "—").font(.body.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 100, ideal: 200)
            TableColumn("Containers", value: \.attached) { row in Text(Format.count(row.attached)).monospacedDigit() }
                .width(min: 70, ideal: 80)
            TableColumn("Created", value: \.created) { row in
                Text(Format.relative(row.summary.createdAt)).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first, let n = store.networks.first(where: { $0.name == id }), let subnet = n.ipv4Subnet {
                Button("Copy Subnet", systemImage: "doc.on.doc") { HostActions.copy(subnet) }
            }
            let deletable = store.networks.filter { ids.contains($0.name) && !$0.isBuiltin }
            if !deletable.isEmpty {
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive) { store.confirmDeleteNetworks(deletable.map(\.name)) }
            }
        }
        .onDeleteCommand { store.confirmDeleteNetworks(Array(store.networkSelection)) }
        .accessibilityIdentifier("networks.list")
    }
}

struct NewNetworkSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var subnet = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        SheetScaffold(
            title: "New Network",
            subtitle: "Containers on the same network can reach each other by IP address.",
            identifier: "sheet.new-network", height: 340
        ) {
            Section {
                TextField("Name", text: $name, prompt: Text(verbatim: "backend"))
                    .accessibilityIdentifier("new-network.name")
                TextField("Subnet", text: $subnet, prompt: Text("Automatic (e.g. 192.168.100.0/24)"))
                    .accessibilityIdentifier("new-network.subnet")
            } footer: {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                }
            }
        } footer: {
            if isWorking { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("new-network.cancel")
            Button("Create") { create() }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || name.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("new-network.create")
        }
    }

    private func create() {
        let name = name.trimmingCharacters(in: .whitespaces)
        let subnet = subnet.trimmingCharacters(in: .whitespaces)
        isWorking = true
        error = nil
        Task {
            do {
                try await store.backend.createNetwork(name: name, subnet: subnet.isEmpty ? nil : subnet)
                await store.refresh([.networks])
                store.networkSelection = [name]
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}
