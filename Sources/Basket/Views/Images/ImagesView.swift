import SwiftUI
import BasketCore

struct ImagesView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let rows = store.imageRows
        VStack(spacing: 0) {
            RecoveryArchivesStrip()
            ListSectionBody(section: .images, isEmpty: rows.isEmpty) {
                let selected = selectedRow(rows)
                DetailSplit(showsBottom: selected != nil) {
                    ImagesTable(rows: rows)
                } bottom: {
                    if let selected { ImageDetailView(row: selected) }
                }
            } empty: {
                SectionEmptyState(
                    section: .images, title: "No Images", systemImage: "square.stack.3d.up",
                    message: "Pull an image to run containers from it. Basket pulls only this Mac's platform by default to save disk."
                ) {
                    Button("Pull Image…") { store.activeSheet = .pullImage("") }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("images.action.pull-empty")
                }
            }
        }
        .navigationTitle("Images")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
    }

    private func selectedRow(_ rows: [ImageRow]) -> ImageRow? {
        guard store.imageSelection.count == 1, let id = store.imageSelection.first else { return nil }
        return rows.first { $0.id == id }
    }

    private var subtitle: String {
        let total = store.images.reduce(Int64(0)) { $0 + $1.totalSizeBytes }
        return "\(store.images.count) image\(store.images.count == 1 ? "" : "s") · \(Format.disk(total))"
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let ids = Array(store.imageSelection)
        ToolbarItemGroup {
            ToolbarActionButton(title: "Pull Image", systemImage: "arrow.down.circle", identifier: "images.action.pull",
                                help: "Pull Image (⌘N)") {
                store.activeSheet = .pullImage("")
            }
            .disabled(store.availability != .running)
            ToolbarActionButton(title: "Run", systemImage: "play.fill", identifier: "images.action.run",
                                help: "Run a container from this image") {
                if let id = ids.first { store.runImage(id) }
            }
            .disabled(ids.count != 1)
            ToolbarActionButton(title: "Delete", systemImage: "trash", identifier: "images.action.delete", help: "Delete (⌫)") {
                store.confirmDeleteImages(ids)
            }
            .disabled(ids.isEmpty)
            ToolbarActionButton(title: "Remove Unused", systemImage: "sparkles", identifier: "images.action.prune",
                                help: "Remove images no container or machine uses") {
                store.confirmPruneImages()
            }
            RefreshButton(section: .images)
        }
        CommonToolbarItems(section: .images)
    }
}

private struct ImagesTable: View {
    @Environment(AppStore.self) private var store
    var rows: [ImageRow]

    var body: some View {
        @Bindable var store = store
        Table(rows, selection: $store.imageSelection, sortOrder: $store.imageSort) {
            TableColumn("Name", value: \.name) { row in
                Text(row.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.summary.reference)
                    .accessibilityIdentifier("images.row.\(row.id)")
            }
            .width(min: 120, ideal: 200)
            TableColumn("Tag", value: \.tag) { row in
                Text(row.tag).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Size", value: \.hostSize) { row in
                NumericCell(row.hostSize > 0 ? Format.disk(row.hostSize) : "—", isPlaceholder: row.hostSize <= 0)
                    .help("Size of the \(store.hostPlatform) variant this Mac runs")
            }
            .width(min: 70, ideal: 80)
            .alignment(.numeric)
            TableColumn("On Disk", value: \.totalSize) { row in
                HStack(spacing: 6) {
                    // Fixed-width, right-aligned number so sizes line up whatever follows them.
                    Text(Format.disk(row.totalSize)).monospacedDigit()
                        .frame(minWidth: 64, alignment: .trailing)
                    if let verb = store.pending[row.id] {
                        ProgressView().controlSize(.mini)
                        Text(verb).foregroundStyle(.secondary).lineLimit(1)
                    } else if row.isBloated {
                        Pill(text: "\(row.variantCount) platforms", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                            .help("Stores \(row.variantCount) platform variants; \(Format.disk(row.extraBytes)) is for platforms this Mac doesn't need.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 170, ideal: 190)
            TableColumn("Used By", value: \.usedBy.count) { row in
                Text(row.usedBy.isEmpty ? "Unused" : row.usedBy.joined(separator: ", "))
                    .foregroundStyle(row.usedBy.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 130)
            TableColumn("Created", value: \.created) { row in
                Text(Format.relative(row.summary.createdAt)).foregroundStyle(.secondary)
                    .help(Format.dateTime(row.summary.createdAt))
            }
            .width(min: 70, ideal: 100)
            TableColumn("Digest") { row in
                Text(Format.shortDigest(row.summary.digest)).font(.body.monospaced()).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            ImageMenuItems(ids: Array(ids))
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { store.runImage(id) }
        }
        .onDeleteCommand { store.confirmDeleteImages(Array(store.imageSelection)) }
        .accessibilityIdentifier("images.list")
    }
}

private struct ImageMenuItems: View {
    @Environment(AppStore.self) private var store
    var ids: [String]

    var body: some View {
        if ids.count == 1, let id = ids.first {
            Button("Run…", systemImage: "play.fill") { store.runImage(id) }
            Button("Pull Again", systemImage: "arrow.down.circle") { store.activeSheet = .pullImage(id) }
            if let image = store.images.first(where: { $0.id == id }), ImageSlimmer.canSlim(image) {
                Button("Keep Only \(store.hostPlatform)…", systemImage: "scissors") { store.confirmSlimImage(id) }
                    .disabled(store.pending[id] != nil)
            }
            Button("Copy Reference", systemImage: "doc.on.doc") { HostActions.copy(id) }
            Divider()
        }
        if !ids.isEmpty {
            Button("Delete…", systemImage: "trash", role: .destructive) { store.confirmDeleteImages(ids) }
        }
    }
}

private struct ImageDetailView: View {
    @Environment(AppStore.self) private var store
    var row: ImageRow
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(Series.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ImageName(row.summary.reference).display).font(.headline).lineLimit(1)
                    Text(row.summary.reference).font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                }
                .layoutPriority(1)
                Spacer(minLength: 12)
                Picker("Detail", selection: $tab) {
                    Text("Platforms").tag(0)
                    Text("Inspect").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("images.detail.tabs")
                Spacer(minLength: 12)
                if ImageSlimmer.canSlim(row.summary) {
                    Button("Keep Only \(store.hostPlatform)…", systemImage: "scissors") { store.confirmSlimImage(row.id) }
                        .help("Remove the other platform variants; this Mac's is kept and nothing is downloaded")
                        .disabled(store.pending[row.id] != nil)
                        .accessibilityIdentifier("images.action.slim")
                }
                Button("Run…", systemImage: "play.fill") { store.runImage(row.id) }
                    .accessibilityIdentifier("images.action.run-detail")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if tab == 0 {
                variants
            } else {
                InspectJSONView(identifier: "images.detail.inspect", subject: row.id) { [id = row.id] backend in
                    try await backend.inspectImage(id)
                }
            }
        }
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details for \(row.summary.reference)")
        .accessibilityIdentifier("images.detail")
    }

    private var variants: some View {
        let host = store.hostPlatform
        let rows = row.summary.variants.sorted { $0.sizeBytes > $1.sizeBytes }.map(VariantRow.init)
        return Table(rows) {
            TableColumn("Platform") { (v: VariantRow) in
                HStack(spacing: 6) {
                    Text(v.platform)
                    if v.platform.hasPrefix(host) { Pill(text: "This Mac", tint: Series.blue) }
                }
            }
            TableColumn("Size") { (v: VariantRow) in NumericCell(Format.disk(v.sizeBytes)) }
                .alignment(.numeric)
            TableColumn("Digest") { (v: VariantRow) in
                Text(Format.shortDigest(v.digest)).font(.body.monospaced()).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("images.detail.platforms")
    }
}

private struct VariantRow: Identifiable {
    var variant: ImageVariant
    var id: String { variant.platform + variant.digest }
    var platform: String { variant.platform }
    var digest: String { variant.digest }
    var sizeBytes: Int64 { variant.sizeBytes }

    init(_ variant: ImageVariant) { self.variant = variant }
}

/// Archives an interrupted (or failed) "Keep only linux/arm64" kept so the image can't be lost:
/// restore one (`image load`) or delete it.
private struct RecoveryArchivesStrip: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let archives = store.recoveryArchives
        if !archives.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(archives.count == 1
                         ? "An image archive was kept after keeping one platform was interrupted"
                         : "\(archives.count) image archives were kept after keeping one platform was interrupted")
                        .font(.callout.weight(.semibold))
                } icon: {
                    Image(systemName: "archivebox.fill").foregroundStyle(.orange)
                }
                Text("Restore loads it back into Basket and deletes the archive once the image is listed. Check the image first: it may already be fine.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                ForEach(archives) { archive in
                    row(archive)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.orange.opacity(0.08))
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("images.recovery")
        }
    }

    private func row(_ archive: RecoveryArchive) -> some View {
        let busy = store.pending["archive:\(archive.id)"] != nil
        return HStack(spacing: 10) {
            Text(archive.title)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(archive.url.path)
            Text(detail(archive))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small) }
            Text(Format.disk(archive.sizeBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
            Button("Restore") { Task { await store.restoreRecoveryArchive(archive) } }
                .disabled(!archive.isReadable || busy || store.availability != .running)
                .help(archive.isReadable ? "container image load --input \(archive.url.path)" : "The archive can't be read; it can only be deleted")
                .accessibilityIdentifier("images.recovery.restore.\(archive.id)")
            Button("Delete…") { store.confirmDeleteRecoveryArchive(archive) }
                .disabled(busy)
                .accessibilityIdentifier("images.recovery.delete.\(archive.id)")
        }
        .font(.callout)
    }

    private func detail(_ archive: RecoveryArchive) -> String {
        var parts: [String] = []
        if !archive.isReadable { parts.append("unreadable archive \(archive.url.lastPathComponent)") }
        if !archive.platforms.isEmpty { parts.append(archive.platforms.joined(separator: ", ")) }
        if let modified = archive.modified { parts.append("kept \(Format.relative(modified))") }
        return parts.joined(separator: " · ")
    }
}
