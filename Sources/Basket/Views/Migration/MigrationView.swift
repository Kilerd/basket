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
        guard model.status?.isReady == true else { return "Read-only" }
        return "\(model.images.count) images · \(model.containers.count) containers in OrbStack"
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
            noResults(noun: "Images")
        } else {
            MigrationImagesTable(rows: rows)
        }
    }

    @ViewBuilder private var containersBody: some View {
        let rows = store.migration.containerRows
        if rows.isEmpty {
            noResults(noun: "Containers")
        } else {
            MigrationContainersTable(rows: rows)
        }
    }

    @ViewBuilder private func noResults(noun: String) -> some View {
        let query = store.search(.migration).trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            SectionEmptyState(section: .migration, title: "No \(noun) in OrbStack", systemImage: "tray",
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
                    await store.refresh([.images, .containers])
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
                  ? "No unused OrbStack image is verified to be identical in Basket yet"
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
            parts.append("Imported \(session.count) image\(session.count == 1 ? "" : "s") this session (\(Format.disk(session.bytes)) copied)")
        }
        if !model.recreated.isEmpty {
            parts.append("\(model.recreated.count) container\(model.recreated.count == 1 ? "" : "s") recreated")
        }
        parts.append("\(inBasket) of \(tagged.count) tagged images already in Basket")
        let conflicts = model.nameConflicts.filter { !$0.isUntagged }.count
        if conflicts > 0 { parts.append("\(conflicts) name conflict\(conflicts == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func detail(_ reclaim: (references: [String], bytes: Int64)) -> String {
        let never = "Basket never deletes anything from OrbStack."
        guard !reclaim.references.isEmpty else {
            return "Import images, check they work in Basket, then remove them in OrbStack to get the disk back. \(never)"
        }
        let count = reclaim.references.count
        return "Once you've verified \(count == 1 ? "it" : "them") in Basket, removing \(count) image\(count == 1 ? "" : "s") in OrbStack could free up to \(Format.disk(reclaim.bytes)) (docker --context orbstack image rm, or OrbStack's Images list). \(never)"
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
                .help(importable ? "Import into Basket" : row.image.isDangling ? "Dangling images have no name to import under"
                      : MigrationModel.skipReason(row.image, presence: model.basketPresence(row.image)) ?? "Not importable")
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
            .width(min: 140, ideal: 250)
            TableColumn("Tag", value: \.tag) { row in
                Text(row.image.tag ?? (row.image.isDangling ? "<none>" : Format.shortDigest(row.image.reference.map { String($0.split(separator: "@").last ?? "") } ?? "")))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 60, ideal: 160)
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
            .width(min: 70, ideal: 110)
            TableColumn("Used By", value: \.usedBy) { row in
                Text(row.usedBy == 0 ? "Unused" : "\(row.usedBy) container\(row.usedBy == 1 ? "" : "s")")
                    .foregroundStyle(row.usedBy == 0 ? .secondary : .primary)
            }
            .width(min: 70, ideal: 90)
            TableColumn("In Basket", value: \.basketOrder) { row in
                MigrationImageStatus(row: row)
            }
            // Room for the longest status pill in German and French ("Nicht verglichen").
            .width(min: 120, ideal: 140)
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
            Text("Dangling").foregroundStyle(.secondary)
        case .notInBasket:
            Text("—").foregroundStyle(.secondary)
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
            .width(min: 120, ideal: 270)
            TableColumn("State", value: \.stateOrder) { row in
                HStack(spacing: 5) {
                    Image(systemName: row.container.isRunning ? "play.circle.fill" : "stop.circle")
                        .foregroundStyle(row.container.isRunning ? .green : .secondary)
                        .accessibilityHidden(true)
                    Text(row.container.isRunning ? "Running" : row.container.state.capitalized)
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
            .width(min: 80, ideal: 170)
            TableColumn("In Basket") { row in
                if let recreated = model.recreated[row.id] {
                    Pill(text: "\(recreated.basketID)", systemImage: "checkmark.circle.fill", tint: .green)
                        .help("Recreated in Basket as \(recreated.basketID)")
                } else {
                    Text("—").foregroundStyle(.secondary)
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
}
