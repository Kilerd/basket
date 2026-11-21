import AppKit
import Observation
import BasketCore

/// State and actions of "Migrate from OrbStack": OrbStack's images and containers (read-only),
/// imports into Basket and container recreation. Owned by `AppStore` (`store.migration`).
@Observable @MainActor
final class MigrationModel {
    enum Tab: String, CaseIterable, Identifiable {
        case images = "Images", containers = "Containers"
        var id: String { rawValue }
    }

    enum Sheet: Identifiable {
        case importProgress
        /// OrbStack container id.
        case recreate(String)

        var id: String {
            switch self {
            case .importProgress: "migration-import"
            case .recreate: "migration-recreate"
            }
        }
    }

    enum ItemState: Equatable {
        case queued, checking, exporting(Int64), loading(Int64)
        case done(references: [String], archiveBytes: Int64)
        case skipped(String), failed(String), cancelled

        var isFinished: Bool {
            switch self {
            case .done, .skipped, .failed, .cancelled: true
            default: false
            }
        }
    }

    struct ImportItem: Identifiable, Equatable {
        let image: OrbStackImage
        var state: ItemState
        var id: String { image.id }
    }

    /// One container recreated this session.
    struct Recreated: Equatable {
        var basketID: String
        var image: String
    }

    @ObservationIgnored let migrator: OrbStackMigrator
    @ObservationIgnored weak var store: AppStore?

    var tab = Tab.images
    var sheet: Sheet?
    var status: MigrationSourceStatus?
    var images: [OrbStackImage] = []
    var containers: [OrbStackContainer] = []
    var loaded = false
    var isLoading = false
    var loadError: String?
    var showUntagged = false
    /// Image row ids ticked for import.
    var checked: Set<String> = []
    var imageSelection: Set<String> = []
    var containerSelection: String?
    var imageSort = [KeyPathComparator(\MigrationImageRow.name)]
    var containerSort = [KeyPathComparator(\MigrationContainerRow.name)]

    var importItems: [ImportItem] = []
    var isImporting = false
    @ObservationIgnored private var importTask: Task<Void, Never>?
    /// Recreations under way (each may be importing an image first).
    private(set) var activeRecreations = 0
    @ObservationIgnored private var recreateTasks: [UUID: Task<String, Error>] = [:]
    /// OrbStack row id → content comparison with Basket's image of the same reference, valid while
    /// `key` (OrbStack image ID + Basket digest) still matches. See `basketPresence(_:)`.
    private(set) var presenceCache: [String: (key: String, value: BasketPresence)] = [:]
    /// Bumped whenever `presenceCache` is cleared, so the comparison task restarts even when
    /// OrbStack's images read back unchanged.
    private var presenceGeneration = 0
    /// Image row id → what was imported this session.
    var imported: [String: ItemState] = [:]
    /// OrbStack container id → the Basket container made from it.
    var recreated: [String: Recreated] = [:]

    init(migrator: OrbStackMigrator) {
        self.migrator = migrator
    }

    // MARK: Loading

    /// Reads OrbStack's status, then (when its engine is up) its images and containers.
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            loaded = true
        }
        let migrator = self.migrator
        // Re-read means re-compare: OrbStack may have changed under the same image IDs' names.
        presenceCache = [:]
        presenceGeneration += 1
        let status = await migrator.status()
        self.status = status
        guard status.isReady else {
            images = []
            containers = []
            loadError = nil
            return
        }
        do {
            async let images = migrator.listImages()
            async let containers = migrator.listContainers()
            (self.images, self.containers) = try await (images, containers)
            loadError = nil
            let ids = Set(self.images.map(\.id))
            checked.formIntersection(ids)
            imageSelection.formIntersection(ids)
            if let selected = containerSelection, !self.containers.contains(where: { $0.id == selected }) { containerSelection = nil }
        } catch MigrationError.orbStackNotRunning {
            self.status = .notRunning
        } catch {
            loadError = error.localizedDescription
        }
    }

    func loadIfNeeded() async {
        if !loaded { await refresh() }
    }

    // MARK: Derived

    var basketReferences: Set<String> { OrbStackMigrator.basketReferences(store?.images ?? []) }

    /// Basket reference → digest of what it points at now.
    var basketDigests: [String: String] {
        Dictionary((store?.images ?? []).map { (ImageUsage.normalized($0.reference), $0.digest) }, uniquingKeysWith: { first, _ in first })
    }

    /// Whether Basket has `image`, by content: `.absent` when Basket doesn't list its reference, nil
    /// while the two are still being compared (a name match alone never counts as "in Basket").
    func basketPresence(_ image: OrbStackImage, digests: [String: String]? = nil) -> BasketPresence? {
        guard let reference = image.basketReference, let digest = (digests ?? basketDigests)[reference] else { return .absent }
        guard let cached = presenceCache[image.id], cached.key == Self.presenceKey(image, digest) else { return nil }
        return cached.value
    }

    func isInBasket(_ image: OrbStackImage) -> Bool {
        basketPresence(image) == .identical
    }

    /// Only images whose name Basket doesn't hold yet: a load would repoint Basket's image.
    func isImportable(_ image: OrbStackImage) -> Bool {
        !image.isDangling && basketPresence(image) == .absent
    }

    private static func presenceKey(_ image: OrbStackImage, _ basketDigest: String) -> String {
        "\(image.imageID)|\(basketDigest)"
    }

    /// Changes whenever OrbStack's images or what Basket's references point at change.
    var presenceSignature: Int {
        var hasher = Hasher()
        hasher.combine(presenceGeneration)
        for image in images { hasher.combine(image.id); hasher.combine(image.imageID) }
        for image in store?.images ?? [] { hasher.combine(image.reference); hasher.combine(image.digest) }
        return hasher.finalize()
    }

    /// Compares every OrbStack image whose reference Basket lists with Basket's copy (content: platform
    /// manifest, or layers + config + creation time) unless already compared against the same digests.
    func verifyPresence() async {
        guard let store, status?.isReady == true, !images.isEmpty else { return }
        let basket = store.images
        let digests = basketDigests
        let pending = images.filter { image in
            guard let reference = image.basketReference, let digest = digests[reference] else { return false }
            return presenceCache[image.id]?.key != Self.presenceKey(image, digest)
        }
        guard !pending.isEmpty else { return }
        let migrator = self.migrator
        let backend = store.backend
        for image in pending {
            if Task.isCancelled { return }
            guard let reference = image.basketReference, let digest = digests[reference] else { continue }
            let result = await migrator.basketPresence(of: [image], basket: basket, backend: backend)[image.id] ?? .absent
            presenceCache[image.id] = (Self.presenceKey(image, digest), result)
        }
    }

    /// Whether some image Basket lists under the same reference hasn't been compared yet.
    var hasPendingComparisons: Bool {
        let digests = basketDigests
        return images.contains { basketPresence($0, digests: digests) == nil }
    }

    var canImport: Bool {
        !isImporting && store?.availability == .running && checkedImages.contains(where: isImportable)
    }

    var checkedImages: [OrbStackImage] {
        imageRows.map(\.image).filter { checked.contains($0.id) } + images.filter { checked.contains($0.id) && !visible($0) }
    }

    func visible(_ image: OrbStackImage) -> Bool { showUntagged || !image.isUntagged }

    var hiddenUntaggedCount: Int { showUntagged ? 0 : images.filter(\.isUntagged).count }

    /// Only images verified identical in Basket: never a name-only match.
    var reclaimable: (references: [String], bytes: Int64) {
        let digests = basketDigests
        var presence: [String: BasketPresence] = [:]
        for image in images { presence[image.id] = basketPresence(image, digests: digests) }
        return OrbStackMigrator.reclaimable(images, presence: presence.compactMapValues { $0 })
    }

    /// Images Basket holds a different image for under the same name.
    var nameConflicts: [OrbStackImage] {
        let digests = basketDigests
        return images.filter { image in
            if case .nameConflict? = basketPresence(image, digests: digests) { return true }
            return false
        }
    }

    var importedThisSession: (count: Int, bytes: Int64) {
        imported.values.reduce((0, Int64(0))) { total, state in
            guard case .done(_, let bytes) = state else { return total }
            return (total.0 + 1, total.1 + bytes)
        }
    }

    var selectedContainer: OrbStackContainer? {
        containerSelection.flatMap { id in containers.first { $0.id == id } }
    }

    func image(for container: OrbStackContainer) -> OrbStackImage? {
        let candidates = images.filter { $0.imageID == container.imageID && !$0.isDangling }
        return candidates.first { $0.basketReference == container.basketImageReference }
            ?? candidates.first { !$0.isUntagged } ?? candidates.first
    }

    // MARK: Checking

    func setChecked(_ id: String, _ on: Bool) {
        if on { checked.insert(id) } else { checked.remove(id) }
    }

    func checkAllImportable() {
        checked.formUnion(imageRows.filter { isImportable($0.image) }.map(\.id))
    }

    // MARK: Import

    func startImport() {
        guard let store, !isImporting else { return }
        let selection = checkedImages
        guard !selection.isEmpty else { return }
        importItems = selection.map { image in
            if image.isDangling { return ImportItem(image: image, state: .skipped("No name to import it under")) }
            if let reason = Self.skipReason(image, presence: basketPresence(image)) {
                return ImportItem(image: image, state: .skipped(reason))
            }
            return ImportItem(image: image, state: .queued)
        }
        isImporting = true
        sheet = .importProgress
        let migrator = self.migrator
        let backend = store.backend
        importTask = Task { [weak self] in
            guard let self else { return }
            for index in importItems.indices where importItems[index].state == .queued {
                if Task.isCancelled { break }
                let image = importItems[index].image
                do {
                    for try await step in migrator.importImage(image, into: backend) {
                        importItems[index].state = Self.state(for: step.phase)
                    }
                    if Task.isCancelled {
                        importItems[index].state = .cancelled
                        break
                    }
                    imported[image.id] = importItems[index].state
                    checked.remove(image.id)
                } catch is CancellationError {
                    importItems[index].state = .cancelled
                } catch MigrationError.alreadyInBasket {
                    importItems[index].state = .skipped("Already in Basket")
                } catch MigrationError.nameConflict(let reference, let reason) {
                    importItems[index].state = .skipped(Self.conflictText(reference, reason))
                } catch {
                    importItems[index].state = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
                }
                await store.refresh([.images])
            }
            for index in importItems.indices where !importItems[index].state.isFinished {
                importItems[index].state = .cancelled
            }
            isImporting = false
            importTask = nil
            await store.refresh([.images, .disk])
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    /// Imports and recreations under way (quitting asks first: their `docker`/`container` children
    /// would outlive Basket).
    var hasRunningWork: Bool { isImporting || activeRecreations > 0 }

    /// Cancels every import and recreation (their child processes are terminated).
    func cancelAll() {
        importTask?.cancel()
        recreateTasks.values.forEach { $0.cancel() }
    }

    /// Why an image that Basket lists under the same reference is skipped; nil when it isn't.
    static func skipReason(_ image: OrbStackImage, presence: BasketPresence?) -> String? {
        let reference = image.basketReference ?? image.reference ?? image.imageID
        switch presence {
        case .absent?: return nil
        case .identical?: return "Already in Basket"
        case .nameConflict(let reason)?: return conflictText(reference, reason)
        case .unverified(let reason)?:
            return "Basket already has an image named \(reference) that couldn't be compared with OrbStack's: \(reason). Not imported."
        case nil:
            return "Basket already has an image named \(reference); still comparing them, so it isn't imported."
        }
    }

    static func conflictText(_ reference: String, _ reason: String) -> String {
        "Name conflict: Basket already has a different \(reference): \(reason). Not imported."
    }

    static func state(for phase: ImportPhase) -> ItemState {
        switch phase {
        case .checking: .checking
        case .exporting(let bytes): .exporting(bytes)
        case .loading(let bytes): .loading(bytes)
        case .done(let references, let bytes): .done(references: references, archiveBytes: bytes)
        }
    }

    var importSummary: String {
        let done = importItems.filter { if case .done = $0.state { true } else { false } }.count
        let failed = importItems.filter { if case .failed = $0.state { true } else { false } }.count
        let total = importItems.count
        if isImporting {
            let finished = importItems.filter(\.state.isFinished).count
            return "\(finished) of \(total) done"
        }
        var parts = ["\(done) imported"]
        if failed > 0 { parts.append("\(failed) failed") }
        let skipped = importItems.filter { if case .skipped = $0.state { true } else { false } }.count
        if skipped > 0 { parts.append("\(skipped) skipped") }
        let cancelled = importItems.filter { $0.state == .cancelled }.count
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        return parts.joined(separator: " · ")
    }

    // MARK: Recreate

    func previewSelectedContainer() {
        guard let container = selectedContainer else { return }
        sheet = .recreate(container.id)
    }

    func plan(for container: OrbStackContainer, name: String) -> RecreationPlan {
        RecreationPlanner.plan(for: container, image: image(for: container), options: RecreationOptions(name: name))
    }

    /// A Basket container name that isn't taken yet, based on the Docker name.
    func suggestedName(for container: OrbStackContainer) -> String {
        let taken = Set(store?.containers.map(\.id) ?? [])
        guard taken.contains(container.name) else { return container.name }
        var index = 2
        while taken.contains("\(container.name)-\(index)") { index += 1 }
        return "\(container.name)-\(index)"
    }

    /// Imports the image if needed, creates volumes and runs the container. Returns the new id.
    func recreate(_ container: OrbStackContainer, plan: RecreationPlan, progress: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let store else { throw CancellationError() }
        let source = image(for: container)
        let migrator = self.migrator
        let backend = store.backend
        let work = Task {
            try await migrator.recreate(plan, sourceImage: source, into: backend) { message in
                Task { @MainActor in progress(message) }
            }
        }
        let token = UUID()
        recreateTasks[token] = work
        activeRecreations += 1
        defer {
            recreateTasks[token] = nil
            activeRecreations -= 1
        }
        let id = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        recreated[container.id] = Recreated(basketID: id, image: plan.image)
        if let source { imported[source.id] = imported[source.id] ?? .done(references: [plan.image], archiveBytes: 0) }
        await store.refresh([.containers, .images, .volumes, .footprints, .disk])
        return id
    }

    // MARK: Status bar

    var statusLine: String {
        switch status {
        case .ready(let version)?:
            let engine = "OrbStack Docker \(version ?? "")".trimmingCharacters(in: .whitespaces)
            switch tab {
            case .images:
                let rows = imageRows
                let total = images.filter(visible).count
                var parts = [rows.count == total ? "\(total) image\(total == 1 ? "" : "s")" : "Showing \(rows.count) of \(total) images"]
                let selection = checkedImages
                if !selection.isEmpty {
                    parts.append("\(selection.count) selected (\(Format.disk(selection.map(\.sizeBytes).reduce(0, +))) in OrbStack)")
                }
                if hiddenUntaggedCount > 0 { parts.append("\(hiddenUntaggedCount) untagged hidden") }
                parts.append(engine)
                return parts.joined(separator: " · ")
            case .containers:
                let running = containers.filter(\.isRunning).count
                return ["\(containers.count) container\(containers.count == 1 ? "" : "s")", "\(running) running in OrbStack", engine]
                    .joined(separator: " · ")
            }
        case .notRunning?: return "OrbStack isn't running"
        case .notInstalled?: return "OrbStack isn't installed"
        case .dockerUnavailable?: return "OrbStack's docker CLI isn't available"
        case nil: return "Reading OrbStack…"
        }
    }
}

// MARK: - Rows

struct MigrationImageRow: Identifiable, Hashable {
    let image: OrbStackImage
    var id: String { image.id }
    var name: String
    var tag: String
    var size: Int64
    var platform: String
    var usedBy: Int
    var created: Double
    var status: MigrationImageStatusKind
    /// Sort key of the "In Basket" column (see `MigrationImageStatusKind.order`).
    var basketOrder: Int { status.order }
}

/// The "In Basket" column: whether Basket has the image, decided by content.
enum MigrationImageStatusKind: Hashable {
    /// Basket doesn't list the reference: importable.
    case notInBasket
    /// Imported this session and verified (or still being compared).
    case imported
    /// Same content in Basket.
    case inBasket
    /// Basket lists the reference; the comparison is running.
    case checking
    /// Basket lists the reference but the two couldn't be compared.
    case unverified(String)
    /// Basket holds a different image under the same reference.
    case nameConflict(String)
    case dangling

    var order: Int {
        switch self {
        case .notInBasket: 0
        case .imported: 1
        case .inBasket: 2
        case .checking: 3
        case .unverified: 4
        case .nameConflict: 5
        case .dangling: 6
        }
    }
}

struct MigrationContainerRow: Identifiable, Hashable {
    let container: OrbStackContainer
    var id: String { container.id }
    var name: String { container.name }
    var image: String
    var stateOrder: Int
    var portsText: String
    var mountsText: String
    var created: Double
}

extension MigrationModel {
    private func matches(_ query: String, _ fields: String?...) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return fields.contains { $0?.localizedCaseInsensitiveContains(q) == true }
    }

    var query: String { store?.search(.migration) ?? "" }

    var imageRows: [MigrationImageRow] {
        let digests = basketDigests
        let query = self.query
        return images
            .filter { visible($0) && matches(query, $0.reference, $0.repository, $0.tag, $0.imageID, $0.platform) }
            .map { image in
                MigrationImageRow(
                    image: image, name: image.repository, tag: image.tag ?? image.reference.map { _ in "<digest>" } ?? "<none>",
                    size: image.sizeBytes, platform: Self.platformLabel(image.platform), usedBy: image.containerCount,
                    created: image.createdAt?.timeIntervalSince1970 ?? 0, status: status(of: image, digests: digests))
            }
            .sorted(using: imageSort)
    }

    func status(of image: OrbStackImage, digests: [String: String]? = nil) -> MigrationImageStatusKind {
        if image.isDangling { return .dangling }
        let presence = basketPresence(image, digests: digests)
        let importedHere = imported[image.id] != nil
        switch presence {
        case .absent?: return .notInBasket
        case .identical?: return importedHere ? .imported : .inBasket
        case nil: return importedHere ? .imported : .checking
        case .unverified(let reason)?: return .unverified(reason)
        case .nameConflict(let reason)?: return .nameConflict(reason)
        }
    }

    var containerRows: [MigrationContainerRow] {
        let query = self.query
        return containers
            .filter { matches(query, $0.name, $0.image, $0.state, $0.status) }
            .map { container in
                MigrationContainerRow(
                    container: container, image: container.image, stateOrder: container.isRunning ? 0 : 1,
                    portsText: Self.portsText(container.ports), mountsText: Self.mountsText(container.mounts),
                    created: container.createdAt?.timeIntervalSince1970 ?? 0)
            }
            .sorted(using: containerSort)
    }

    static func platformLabel(_ platform: String?) -> String {
        guard let platform else { return "—" }
        let parts = platform.split(separator: "/")
        return parts.count > 1 ? String(parts[1]) : platform
    }

    static func portsText(_ ports: [OrbStackPortBinding]) -> String {
        ports.map { port in
            let host = port.hostPort.map(String.init) ?? "random"
            return "\(host)→\(port.containerPort)" + (port.proto == "tcp" ? "" : "/\(port.proto)")
        }
        .joined(separator: ", ")
    }

    /// Short summary ("volume pgdata", "2 binds, tmpfs"); the full list is in `mountsDetail`.
    static func mountsText(_ mounts: [OrbStackMount]) -> String {
        var parts: [String] = mounts.filter { $0.kind == .volume && !$0.isAnonymousVolume }.map { "volume \($0.source)" }
        let anonymous = mounts.filter(\.isAnonymousVolume).count
        if anonymous > 0 { parts.append(anonymous == 1 ? "anonymous volume" : "\(anonymous) anonymous volumes") }
        let binds = mounts.filter { $0.kind == .bind }.count
        if binds > 0 { parts.append(binds == 1 ? "1 bind" : "\(binds) binds") }
        let other = mounts.filter { $0.kind == .tmpfs || $0.kind == .other }.count
        if other > 0 { parts.append(other == 1 ? "tmpfs" : "\(other) tmpfs") }
        return parts.joined(separator: ", ")
    }

    static func mountsDetail(_ mounts: [OrbStackMount]) -> String {
        mounts.map { mount in
            let source = mount.kind == .tmpfs ? "tmpfs" : mount.isAnonymousVolume ? "anonymous volume" : mount.source
            return "\(source) → \(mount.destination)\(mount.readOnly ? " (read-only)" : "")"
        }
        .joined(separator: "\n")
    }
}

extension LaunchOptions {
    /// Fixture sets read OrbStack from `orbstack-*.json`; preview mode has no OrbStack.
    func makeMigrator() -> OrbStackMigrator {
        switch backend {
        case .fixtures(let directory): .fixtures(directory)
        case .preview: OrbStackMigrator(docker: nil, presence: .absent)
        case .cli: .host()
        }
    }
}

extension AppSection {
    /// Placeholder of the toolbar search field.
    var searchPrompt: String { self == .migration ? "Search OrbStack" : "Search \(title)" }
}
