import SwiftUI
import BasketCore

/// "Migrate from OrbStack": OrbStack's images and containers (read-only), import into Basket and
/// container recreation, plus what OrbStack disk the user could free afterwards.
struct MigrationView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var model = store.migration
        VStack(spacing: 0) {
            content
            SectionStatusBar(section: .migration)
        }
        .navigationTitle(AppSection.migration.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .task { await model.loadIfNeeded() }
        // Re-compare whenever OrbStack's images or what Basket's references point at change.
        .task(id: model.presenceSignature) { await model.verifyPresence() }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .importProgress:
                MigrationImportSheet()
            case .recreate(let id):
                if let container = model.containers.first(where: { $0.id == id }) {
                    RecreateContainerSheet(container: container)
                }
            }
        }
    }

    private var subtitle: String {
        let model = store.migration
        guard model.status?.isReady == true else { return String(localized: "Read-only", comment: "Subtitle: Basket only reads OrbStack") }
        let images = String(localized: "\(model.images.count) images")
        let containers = String(localized: "\(model.containers.count) containers")
        return String(localized: "In OrbStack: \(images) · \(containers)", comment: "Window subtitle: “12 images · 5 containers”")
    }

    @ViewBuilder private var content: some View {
        let model = store.migration
        if let error = model.loadError {
            SectionEmptyState(section: .migration, title: "Couldn't Read OrbStack", systemImage: "exclamationmark.triangle",
                              message: "\(error)") {
                Button("Try Again") { Task { await model.refresh() } }
                    .accessibilityIdentifier("migration.action.retry")
            }
        } else {
            switch model.status {
            case .ready?:
                VStack(spacing: 0) {
                    MigrationHeader()
                    MigrationSummaryStrip()
                    Divider()
                    switch model.tab {
                    case .images: imagesBody
                    case .containers: containersBody
                    }
                }
            case .notRunning?:
                SectionEmptyState(
                    section: .migration, title: "OrbStack Isn't Running", systemImage: "moon.zzz",
                    message: "Start OrbStack to see its images and containers here. Basket only reads from OrbStack: it never starts, stops or changes it."
                ) {
                    Button("Check Again") { Task { await model.refresh() } }
                        .accessibilityIdentifier("migration.action.check")
                }
            case .notInstalled?:
                SectionEmptyState(
                    section: .migration, title: "OrbStack Isn't Installed", systemImage: "shippingbox",
                    message: "When OrbStack is installed and running, Basket can import its images (this Mac's platform only) and recreate its containers."
                )
            case .dockerUnavailable(let message)?:
                SectionEmptyState(section: .migration, title: "Can't Read OrbStack", systemImage: "exclamationmark.triangle",
                                  message: "\(message)") {
                    Button("Check Again") { Task { await model.refresh() } }
                        .accessibilityIdentifier("migration.action.check")
                }
            case nil:
                ProgressView("Reading OrbStack…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("migration.empty")
            }
        }
    }

    @ViewBuilder private var imagesBody: some View {
        let model = store.migration
        let rows = model.imageRows
        if rows.isEmpty {
            noResults(.images)
        } else {
            MigrationImagesTable(rows: rows)
        }
    }

    @ViewBuilder private var containersBody: some View {
        let rows = store.migration.containerRows
        if rows.isEmpty {
            noResults(.containers)
        } else {
            MigrationContainersTable(rows: rows)
        }
    }

    @ViewBuilder private func noResults(_ tab: MigrationModel.Tab) -> some View {
        let query = store.search(.migration).trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            SectionEmptyState(section: .migration,
                              title: tab == .images ? "No Images in OrbStack" : "No Containers in OrbStack", systemImage: "tray",
                              message: "There's nothing of this kind to migrate.")
        } else {
            SectionEmptyState(section: .migration, title: "No Results for “\(query)”", systemImage: "magnifyingglass",
                              message: "Check the spelling or try a different search.") {
                Button("Clear Search") { store.searchText[.migration] = "" }
                    .accessibilityIdentifier("migration.action.clear-search")
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let model = store.migration
        ToolbarItemGroup {
            if model.tab == .images {
                ToolbarActionButton(
                    title: "Import Selected", systemImage: "square.and.arrow.down", identifier: "migration.action.import",
                    help: store.availability == .running
                        ? "Import the checked images into Basket (this Mac's platform only)"
                        : "Start Basket's container system to import images"
                ) {
                    model.startImport()
                }
                .disabled(!model.canImport)
            } else {
                ToolbarActionButton(
                    title: "Recreate…", systemImage: "arrow.right.square", identifier: "migration.action.recreate",
                    help: "Preview the selected container in Basket and recreate it"
                ) {
                    model.previewSelectedContainer()
                }
                .disabled(model.selectedContainer == nil)
            }
            ToolbarActionButton(title: "Refresh", systemImage: "arrow.clockwise", identifier: "migration.action.refresh",
                                help: "Read OrbStack again (⌘R)") {
                Task {
                    await model.refresh()
                    // `.orbstack` too: OrbStack removed since the last poll closes this section.
                    await store.refresh([.images, .containers, .orbstack])
                }
            }
            .disabled(model.isLoading)
        }
        CommonToolbarItems(section: .migration)
    }
}

// MARK: - Header & summary

/// Images / Containers switch and list options.
private struct MigrationHeader: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var model = store.migration
        HStack(spacing: 12) {
            Picker("Show", selection: $model.tab) {
                Text("Images (\(model.images.filter(model.visible).count))").tag(MigrationModel.Tab.images)
                Text("Containers (\(model.containers.count))").tag(MigrationModel.Tab.containers)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("migration.tabs")
            Spacer(minLength: 12)
            if model.tab == .images {
                Toggle("Show untagged (\(model.images.filter(\.isUntagged).count))", isOn: $model.showUntagged)
                    .toggleStyle(.checkbox)
                    .help("Images without a tag: digest-only references and dangling layers. Dangling images can't be imported.")
                    .accessibilityIdentifier("migration.untagged")
                Button("Select All") { model.checkAllImportable() }
                    .help("Check every listed image whose name Basket doesn't have yet")
                    .accessibilityIdentifier("migration.action.select-all")
                Button("Select None") { model.checked = [] }
                    .disabled(model.checked.isEmpty)
                    .accessibilityIdentifier("migration.action.select-none")
            } else {
                Text("Select a container to preview how it runs in Basket.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// What was imported, and what OrbStack disk could be freed once the user has verified it.
private struct MigrationSummaryStrip: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.migration
        let reclaim = model.reclaimable
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(Series.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(model)).font(.callout.weight(.semibold))
                Text(detail(reclaim))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("migration.summary")
            Spacer(minLength: 12)
            Button("Copy Cleanup Command") {
                HostActions.copy(OrbStackMigrator.removalCommand(reclaim.references))
            }
            .disabled(reclaim.references.isEmpty)
            .help(reclaim.references.isEmpty
                  ? String(localized: "No unused OrbStack image is verified to be identical in Basket yet")
                  : OrbStackMigrator.removalCommand(reclaim.references))
            .accessibilityIdentifier("migration.action.copy-cleanup")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Series.blue.opacity(0.08))
        .overlay(alignment: .top) { Divider() }
    }

    private func headline(_ model: MigrationModel) -> String {
        let session = model.importedThisSession
        let tagged = model.images.filter { !$0.isUntagged }
        let inBasket = tagged.filter(model.isInBasket).count
        var parts: [String] = []
        if session.count > 0 {
            let copied = Format.disk(session.bytes)
            parts.append(String(localized: "Imported \(session.count) images this session (\(copied) copied)",
                                comment: "Migration summary"))
        }
        if !model.recreated.isEmpty {
            parts.append(String(localized: "\(model.recreated.count) containers recreated", comment: "Migration summary"))
        }
        parts.append(String(localized: "\(inBasket) of \(tagged.count) tagged images already in Basket", comment: "Migration summary"))
        let conflicts = model.nameConflicts.filter { !$0.isUntagged }.count
        if conflicts > 0 { parts.append(String(localized: "\(conflicts) name conflicts", comment: "Migration summary")) }
        return parts.joined(separator: " · ")
    }

    private func detail(_ reclaim: (references: [String], bytes: Int64)) -> String {
        guard !reclaim.references.isEmpty else {
            return String(localized: "Import images, check they work in Basket, then remove them in OrbStack to get the disk back. Basket never deletes anything from OrbStack.")
        }
        let size = Format.disk(reclaim.bytes)
        if reclaim.references.count == 1 {
            return String(localized: "Once you've verified it in Basket, removing this image in OrbStack could free up to \(size) (docker --context orbstack image rm, or OrbStack's Images list). Basket never deletes anything from OrbStack.")
        }
        return String(localized: "Once you've verified them in Basket, removing these \(reclaim.references.count) images in OrbStack could free up to \(size) (docker --context orbstack image rm, or OrbStack's Images list). Basket never deletes anything from OrbStack.")
    }
}

// MARK: - Tables

private struct MigrationImagesTable: View {
    @Environment(AppStore.self) private var store
    var rows: [MigrationImageRow]

    var body: some View {
        @Bindable var model = store.migration
        Table(rows, selection: $model.imageSelection, sortOrder: $model.imageSort) {
            TableColumn("Import") { row in
                let importable = model.isImportable(row.image)
                Toggle(isOn: Binding(get: { model.checked.contains(row.id) }, set: { model.setChecked(row.id, $0) })) {
                    Text("Import \(row.image.reference ?? row.image.imageID)")
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!importable || model.isImporting)
                .help(importable ? String(localized: "Import into Basket")
                      : row.image.isDangling ? String(localized: "Dangling images have no name to import under")
                      : MigrationModel.skipReason(row.image, presence: model.basketPresence(row.image))
                        ?? String(localized: "Not importable"))
                .frame(maxWidth: .infinity)
            }
            .width(52)
            TableColumn("Image", value: \.name) { row in
                Text(row.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.image.reference ?? row.image.imageID)
                    .accessibilityIdentifier("migration.row.\(row.id)")
            }
            .width(min: 140, ideal: 200)
            TableColumn("Tag", value: \.tag) { row in
                Text(row.image.tag ?? (row.image.isDangling ? "<none>" : Format.shortDigest(row.image.reference.map { String($0.split(separator: "@").last ?? "") } ?? "")))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 60, ideal: 145)
            TableColumn("Size", value: \.size) { row in
                Text(Format.disk(row.size)).monospacedDigit()
                    .help("Disk used in OrbStack; the import copies the compressed \(row.image.exportPlatform) layers only")
            }
            .width(min: 64, ideal: 76)
            TableColumn("Platform", value: \.platform) { row in
                HStack(spacing: 6) {
                    Text(row.platform)
                    if row.image.platform != nil, !row.image.isHostNative {
                        Pill(text: "Rosetta", tint: .orange)
                            .help("OrbStack only has the \(row.image.platform ?? "") variant; it runs under Rosetta in Basket")
                    }
                }
            }
            // "amd64" next to the Rosetta pill, neither of which is translated.
            .width(min: 112, ideal: 116)
            TableColumn("Used By", value: \.usedBy) { row in
                Group {
                    if row.usedBy == 0 {
                        Text("Unused", comment: "Image used by no container")
                    } else {
                        Text("\(row.usedBy) containers")
                    }
                }
                .foregroundStyle(row.usedBy == 0 ? .secondary : .primary)
                .lineLimit(1)
            }
            .width(min: 80, ideal: 95)
            TableColumn("In Basket", value: \.basketOrder) { row in
                MigrationImageStatus(row: row)
            }
            // Room for the longest status pill in German and French ("Nicht verglichen").
            .width(min: 120, ideal: 125)
            TableColumn("Created", value: \.created) { row in
                Text(Format.relative(row.image.createdAt)).foregroundStyle(.secondary)
                    .help(Format.dateTime(row.image.createdAt))
            }
            .width(min: 70, ideal: 100)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let importable = ids.filter { id in model.images.first { $0.id == id }.map(model.isImportable) ?? false }
            if !importable.isEmpty {
                Button("Check for Import", systemImage: "checkmark.square") { model.checked.formUnion(importable) }
            }
            if ids.count == 1, let reference = model.images.first(where: { $0.id == ids.first })?.reference {
                Button("Copy Reference", systemImage: "doc.on.doc") { HostActions.copy(reference) }
            }
        } primaryAction: { ids in
            for id in ids where model.images.first(where: { $0.id == id }).map(model.isImportable) ?? false {
                model.setChecked(id, !model.checked.contains(id))
            }
        }
        .accessibilityIdentifier("migration.list")
    }
}

private struct MigrationImageStatus: View {
    var row: MigrationImageRow

    var body: some View {
        switch row.status {
        case .imported:
            Pill(text: "Imported", systemImage: "checkmark.circle.fill", tint: .green)
                .help("Imported this session; same content as OrbStack's copy")
        case .inBasket:
            Pill(text: "In Basket", systemImage: "checkmark", tint: Series.blue)
                .help("Basket has the same image (compared by content, not just by name)")
        case .checking:
            // A spinner fits the column in every language (a "Comparing…" label didn't, #17); the
            // tooltip and VoiceOver say what is going on.
            ProgressView()
                .controlSize(.small)
                .help("Basket has an image with this name; comparing it with OrbStack's")
                .accessibilityLabel("Comparing with Basket")
        case .unverified(let reason):
            Pill(text: "Not compared", systemImage: "questionmark.circle", tint: .secondary)
                .help("Basket has an image with this name, but it couldn't be compared with OrbStack's: \(reason). It isn't imported or offered for cleanup.")
        case .nameConflict(let reason):
            Pill(text: "Name conflict", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                .help("Basket has a different image with this name: \(reason). It isn't imported or offered for cleanup; rename or delete Basket's to import OrbStack's.")
        case .dangling:
            Text("Dangling", comment: "An image with no name (dangling layers)").foregroundStyle(.secondary)
        case .notInBasket:
            Text(verbatim: "—").foregroundStyle(.secondary)
        }
    }
}

private struct MigrationContainersTable: View {
    @Environment(AppStore.self) private var store
    var rows: [MigrationContainerRow]

    var body: some View {
        @Bindable var model = store.migration
        Table(rows, selection: $model.containerSelection, sortOrder: $model.containerSort) {
            TableColumn("Name", value: \.name) { row in
                Text(row.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .accessibilityIdentifier("migration.row.\(row.name)")
            }
            .width(min: 110, ideal: 150)
            TableColumn("Image", value: \.image) { row in
                Text(row.image).lineLimit(1).truncationMode(.middle).help(row.image)
            }
            .width(min: 120, ideal: 230)
            TableColumn("State", value: \.stateOrder) { row in
                HStack(spacing: 5) {
                    Image(systemName: row.container.isRunning ? "play.circle.fill" : "stop.circle")
                        .foregroundStyle(row.container.isRunning ? .green : .secondary)
                        .accessibilityHidden(true)
                    Text(row.container.isRunning ? String(localized: "Running") : Self.stateTitle(row.container.state))
                }
                .help(row.container.status)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Ports", value: \.portsText) { row in
                Text(row.portsText.isEmpty ? "—" : row.portsText).foregroundStyle(row.portsText.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 110)
            TableColumn("Mounts", value: \.mountsText) { row in
                Text(row.mountsText.isEmpty ? "—" : row.mountsText).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(MigrationModel.mountsDetail(row.container.mounts))
            }
            .width(min: 80, ideal: 200)
            TableColumn("In Basket") { row in
                if let recreated = model.recreated[row.id] {
                    Pill(text: "\(recreated.basketID)", systemImage: "checkmark.circle.fill", tint: .green)
                        .help("Recreated in Basket as \(recreated.basketID)")
                } else {
                    Text(verbatim: "—").foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 110)
            TableColumn("Created", value: \.created) { row in
                Text(Format.relative(row.container.createdAt)).foregroundStyle(.secondary)
                    .help(Format.dateTime(row.container.createdAt))
            }
            .width(min: 70, ideal: 100)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first {
                Button("Preview & Recreate…", systemImage: "arrow.right.square") { model.sheet = .recreate(id) }
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { model.sheet = .recreate(id) }
        }
        .accessibilityIdentifier("migration.list")
    }

    /// Docker's container state ("exited", "paused", …) in the user's language.
    static func stateTitle(_ state: String) -> String {
        switch state.lowercased() {
        case "running": String(localized: "Running")
        case "exited": String(localized: "Exited", comment: "Docker container state")
        case "created": String(localized: "Created (state)", defaultValue: "Created", comment: "Container state: created but never started")
        case "paused": String(localized: "Paused", comment: "Docker container state")
        case "restarting": String(localized: "Restarting", comment: "Docker container state")
        case "removing": String(localized: "Removing", comment: "Docker container state")
        case "dead": String(localized: "Dead", comment: "Docker container state")
        default: state.capitalized
        }
    }
}
