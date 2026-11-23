import SwiftUI
import BasketCore

struct VolumesView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let rows = store.volumeRows
        ListSectionBody(section: .volumes, isEmpty: rows.isEmpty) {
            VolumesTable(rows: rows)
        } empty: {
            SectionEmptyState(
                section: .volumes, title: "No Volumes", systemImage: "externaldrive",
                message: "Volumes keep data across container restarts. They are sparse: a \(Format.memory(512 << 30)) volume only uses what you write."
            ) {
                Button("New Volume…") { store.activeSheet = .newVolume }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("volumes.action.new-empty")
            }
        }
        .navigationTitle("Volumes")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
    }

    private var subtitle: String {
        let used = store.volumes.reduce(Int64(0)) { $0 + ($1.allocatedBytes ?? 0) }
        return String(localized: "\(store.volumes.count) volumes · \(Format.disk(used)) on disk", comment: "Volumes window subtitle: number of volumes and the disk space they use")
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let ids = Array(store.volumeSelection)
        let selected = store.volumes.first { ids.count == 1 && $0.name == ids.first }
        ToolbarItemGroup {
            ToolbarActionButton(title: "New Volume", systemImage: "plus", identifier: "volumes.action.new",
                                help: "New Volume (⌘N)") {
                store.activeSheet = .newVolume
            }
            .disabled(store.availability != .running)
            ToolbarActionButton(title: "Show in Finder", systemImage: "folder", identifier: "volumes.action.reveal",
                                help: "Reveal the volume's disk image in Finder") {
                if let selected { HostActions.revealInFinder(selected.source) }
            }
            .disabled(selected?.source.isEmpty ?? true)
            ToolbarActionButton(title: "Delete", systemImage: "trash", identifier: "volumes.action.delete", help: "Delete (⌫)") {
                store.confirmDeleteVolumes(ids)
            }
            .disabled(ids.isEmpty)
            ToolbarActionButton(title: "Remove Unused", systemImage: "sparkles", identifier: "volumes.action.prune",
                                help: "Remove volumes no container mounts") {
                store.confirmPruneVolumes()
            }
            RefreshButton(section: .volumes)
        }
        CommonToolbarItems(section: .volumes)
    }
}

private struct VolumesTable: View {
    @Environment(AppStore.self) private var store
    var rows: [VolumeRow]

    var body: some View {
        @Bindable var store = store
        Table(rows, selection: $store.volumeSelection, sortOrder: $store.volumeSort) {
            TableColumn("Name", value: \.name) { row in
                Text(row.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("volumes.row.\(row.id)")
            }
            .width(min: 120, ideal: 180)
            TableColumn("On Disk", value: \.allocated) { row in
                NumericCell(row.allocated < 0 ? "—" : Format.disk(row.allocated), isPlaceholder: row.allocated < 0)
                    .help("Space the sparse disk image actually occupies on your Mac")
            }
            .width(min: 80, ideal: 100)
            .alignment(.numeric)
            TableColumn("Capacity", value: \.capacity) { row in
                // Capacities are set in binary units ("512G"), so show them that way.
                NumericCell(row.capacity > 0 ? Format.memory(row.capacity) : "—", isPlaceholder: true)
                    .help("Maximum size; unused space takes no room on disk")
            }
            .width(min: 70, ideal: 90)
            .alignment(.numeric)
            TableColumn("Format") { row in
                Text(row.summary.format).foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 60)
            TableColumn("Used By") { row in
                Text(row.usedBy.isEmpty ? String(localized: "Unused", comment: "Nothing uses it (an image or a volume)") : row.usedByText)
                    .foregroundStyle(row.usedBy.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 140)
            TableColumn("Created", value: \.created) { row in
                Text(Format.relative(row.summary.createdAt)).foregroundStyle(.secondary)
                    .help(Format.dateTime(row.summary.createdAt))
            }
            .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first, let volume = store.volumes.first(where: { $0.name == id }) {
                Button("Show in Finder", systemImage: "folder") { HostActions.revealInFinder(volume.source) }
                    .disabled(volume.source.isEmpty)
                Button("Copy Name", systemImage: "doc.on.doc") { HostActions.copy(volume.name) }
                Button("Copy Mount Argument", systemImage: "doc.on.doc") { HostActions.copy("\(volume.name):/data") }
                Divider()
            }
            if !ids.isEmpty {
                Button("Delete…", systemImage: "trash", role: .destructive) { store.confirmDeleteVolumes(Array(ids)) }
            }
        }
        .onDeleteCommand { store.confirmDeleteVolumes(Array(store.volumeSelection)) }
        .accessibilityIdentifier("volumes.list")
    }
}

struct NewVolumeSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var size = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        SheetScaffold(
            title: "New Volume",
            subtitle: "Volumes are sparse disk images: they only take the space you actually write.",
            identifier: "sheet.new-volume", height: 340
        ) {
            Section {
                TextField("Name", text: $name, prompt: Text(verbatim: "my-data"))
                    .accessibilityIdentifier("new-volume.name")
                TextField("Size", text: $size, prompt: Text("Default (512G, sparse)"))
                    .accessibilityIdentifier("new-volume.size")
            } footer: {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.warningText).font(.callout)
                }
            }
        } footer: {
            if isWorking { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("new-volume.cancel")
            Button("Create") { create() }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || name.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("new-volume.create")
        }
    }

    private func create() {
        let name = name.trimmingCharacters(in: .whitespaces)
        let size = size.trimmingCharacters(in: .whitespaces)
        isWorking = true
        error = nil
        Task {
            do {
                try await store.backend.createVolume(name: name, size: size.isEmpty ? nil : size)
                await store.refresh([.volumes, .disk])
                store.volumeSelection = [name]
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}
