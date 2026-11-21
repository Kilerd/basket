import AppKit
import BasketCore

/// Form state for "New Container".
struct RunDraft: Hashable {
    var image = ""
    var name = ""
    var command = ""
    var ports: [String] = []
    var environment: [String] = []
    var volumes: [String] = []
    var network = ""
    var cpus: Int
    var memoryMB: Int
    var removeOnExit = false

    static func defaults(image: String = "") -> RunDraft {
        let d = UserDefaults.standard
        return RunDraft(image: image, cpus: max(1, d.integer(forKey: DefaultsKey.defaultCPUs)),
                        memoryMB: max(128, d.integer(forKey: DefaultsKey.defaultMemoryMB)))
    }

    var spec: RunSpec {
        func clean(_ list: [String]) -> [String] {
            list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        return RunSpec(
            image: image.trimmingCharacters(in: .whitespaces),
            name: trimmedName.isEmpty ? nil : trimmedName,
            command: ShellWords.split(command),
            cpus: cpus, memory: MemorySize.cliString(megabytes: memoryMB),
            ports: clean(ports), volumes: clean(volumes), environment: clean(environment),
            network: network.isEmpty ? nil : network, removeOnExit: removeOnExit
        )
    }
}

enum ShellWords {
    /// Splits a command line on whitespace, honouring single/double quotes and backslash escapes.
    static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var inWord = false
        var escaped = false
        for ch in line {
            if escaped { current.append(ch); escaped = false; inWord = true; continue }
            if ch == "\\" && quote != "'" { escaped = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; inWord = true; continue }
            if ch.isWhitespace {
                if inWord { words.append(current); current = ""; inWord = false }
                continue
            }
            current.append(ch)
            inWord = true
        }
        if inWord { words.append(current) }
        return words
    }
}

/// A running operation: the phrase shown in place of a row's state while it runs ("Stopping…")
/// and the banner title if it fails ("Couldn't stop"). Whole phrases, so every language can word
/// both.
struct PendingOperation: Sendable {
    var progress: String
    var failure: String

    static let startSystem = PendingOperation(
        progress: String(localized: "Starting the container system…"),
        failure: String(localized: "Couldn't start the container system"))
    static let stopSystem = PendingOperation(
        progress: String(localized: "Stopping the container system…"),
        failure: String(localized: "Couldn't stop the container system"))
    static let start = PendingOperation(
        progress: String(localized: "Starting…", comment: "Shown in place of a container's or machine's state while it starts"),
        failure: String(localized: "Couldn't start"))
    static let stop = PendingOperation(
        progress: String(localized: "Stopping…", comment: "Shown in place of a container's or machine's state while it stops"),
        failure: String(localized: "Couldn't stop"))
    static let restart = PendingOperation(
        progress: String(localized: "Restarting…", comment: "Shown in place of a container's state while it restarts"),
        failure: String(localized: "Couldn't restart"))
    static let kill = PendingOperation(
        progress: String(localized: "Killing…", comment: "Shown in place of a container's state while it is killed (SIGKILL)"),
        failure: String(localized: "Couldn't kill", comment: "Banner title: killing (SIGKILL) a container failed"))
    static let delete = PendingOperation(
        progress: String(localized: "Deleting…", comment: "Shown in place of an item's state while it is deleted"),
        failure: String(localized: "Couldn't delete"))
    static let removeUnusedImages = PendingOperation(
        progress: String(localized: "Removing unused images…"),
        failure: String(localized: "Couldn't remove unused images"))
    static let removeUnusedVolumes = PendingOperation(
        progress: String(localized: "Removing unused volumes…"),
        failure: String(localized: "Couldn't remove unused volumes"))
    static let reclaimDisk = PendingOperation(
        progress: String(localized: "Reclaiming disk space…"),
        failure: String(localized: "Couldn't reclaim disk space"))
    static let setDefaultMachine = PendingOperation(
        progress: String(localized: "Setting as default…", comment: "Shown in place of a machine's state while it becomes the default machine"),
        failure: String(localized: "Couldn't set the default machine"))
    static let deleteMachine = PendingOperation(
        progress: String(localized: "Deleting…", comment: "Shown in place of an item's state while it is deleted"),
        failure: String(localized: "Couldn't delete the machine"))
    static let composeDown = PendingOperation(
        progress: String(localized: "Removing…", comment: "Shown in place of a Compose service's state while the project is taken down"),
        failure: String(localized: "Couldn't take the project down", comment: "Banner title: `compose down` failed"))
}

extension AppStore {
    /// Runs a backend operation, tracks it as pending on `ids`, refreshes `kinds` afterwards and
    /// reports failures in the banner. Returns whether it succeeded.
    @discardableResult
    func perform(
        _ operationName: PendingOperation, ids: [String] = [], refresh kinds: [DataKind],
        _ operation: @escaping @Sendable (any ContainerBackend) async throws -> Void
    ) async -> Bool {
        for id in ids { pending[id] = operationName.progress }
        defer { for id in ids { pending[id] = nil } }
        let backend = self.backend
        do {
            try await operation(backend)
            await refresh(kinds)
            return true
        } catch {
            showError(operationName.failure, error)
            await refresh(kinds)
            return false
        }
    }

    // MARK: Section-level commands (menus, keyboard shortcuts)

    var newItemTitle: String {
        switch selectedSection {
        case .overview, .containers: String(localized: "New Container…")
        case .images: String(localized: "Pull Image…")
        case .volumes: String(localized: "New Volume…")
        case .networks: String(localized: "New Network…")
        case .machines: String(localized: "New Machine…")
        case .migration: String(localized: "New Container…")
        }
    }

    func newItem() {
        switch selectedSection {
        case .overview, .containers: activeSheet = .newContainer(.defaults())
        case .images: activeSheet = .pullImage("")
        case .volumes: activeSheet = .newVolume
        case .networks: activeSheet = .newNetwork
        case .machines: activeSheet = .newMachine
        case .migration: activeSheet = .newContainer(.defaults())
        }
    }

    var canDeleteSelection: Bool {
        switch selectedSection {
        case .overview: false
        case .containers: !containerSelection.isEmpty
        case .images: !imageSelection.isEmpty
        case .volumes: !volumeSelection.isEmpty
        case .networks: networks.contains { networkSelection.contains($0.id) && !$0.isBuiltin }
        case .machines: machineSelection.count == 1
        case .migration: false
        }
    }

    func deleteSelection() {
        switch selectedSection {
        case .overview: break
        case .containers: confirmDeleteContainers(Array(containerSelection))
        case .images: confirmDeleteImages(Array(imageSelection))
        case .volumes: confirmDeleteVolumes(Array(volumeSelection))
        case .networks: confirmDeleteNetworks(Array(networkSelection))
        case .machines: if let id = machineSelection.first { confirmDeleteMachine(id) }
        case .migration: break
        }
    }

    // MARK: System

    func startSystem() async {
        availability = .unknown
        await perform(.startSystem, refresh: DataKind.allCases) { try await $0.startSystem() }
    }

    func confirmStopSystem() {
        let running = runningContainers.count
        confirmation = Confirmation(
            title: String(localized: "Stop the container system?"),
            message: running > 0
                ? String(localized: "\(running) running containers will be stopped and their memory returned to macOS.")
                : String(localized: "Basket will stop the container API server. You can start it again at any time."),
            confirmLabel: String(localized: "Stop System")
        ) { [weak self] in
            Task { await self?.perform(.stopSystem, refresh: DataKind.allCases) { try await $0.stopSystem() } }
        }
    }

    // MARK: Containers

    func startContainers(_ ids: [String]) async {
        await perform(.start, ids: ids, refresh: [.containers, .stats, .footprints]) { backend in
            for id in ids { try await backend.startContainer(id) }
        }
        await refreshComposeHosts(after: ids)
    }

    func stopContainers(_ ids: [String]) async {
        await perform(.stop, ids: ids, refresh: [.containers, .stats, .footprints]) { try await $0.stopContainers(ids) }
    }

    /// Each container is stopped and started on its own, so one that fails to come back never leaves
    /// the others down; one that turned out to be started with `--rm` since the confirmation is skipped.
    func restartContainers(_ ids: [String]) async {
        let outcome = await restart(ids, onlyRunning: false)
        await refreshComposeHosts(after: outcome.restarted)
    }

    /// Per-container stop → start (see `MemoryReclaim.restart`), tracked as pending, with skipped and
    /// failed containers reported in the banner.
    func restart(_ ids: [String], onlyRunning: Bool) async -> MemoryReclaim.Outcome {
        await restart(ids) { await MemoryReclaim.restart(ids, using: $0, onlyRunning: onlyRunning) }
    }

    /// Tracks `ids` as restarting while `operation` runs, then refreshes and puts skipped and failed
    /// containers in the banner (or the error, when the run couldn't begin).
    @discardableResult
    func restart(
        _ ids: [String], _ operation: @escaping @Sendable (any ContainerBackend) async throws -> MemoryReclaim.Outcome
    ) async -> MemoryReclaim.Outcome {
        guard !ids.isEmpty else { return MemoryReclaim.Outcome() }
        for id in ids { pending[id] = PendingOperation.restart.progress }
        let result: Result<MemoryReclaim.Outcome, any Error>
        do { result = .success(try await operation(backend)) } catch { result = .failure(error) }
        for id in ids { pending[id] = nil }
        await refresh([.containers, .stats, .footprints])
        switch result {
        case .success(let outcome):
            if let report = outcome.report {
                banner = BannerMessage(title: report.title, detail: report.detail)
            }
            return outcome
        case .failure(let error):
            showError(PendingOperation.restart.failure, error)
            return MemoryReclaim.Outcome()
        }
    }

    func killContainers(_ ids: [String]) async {
        await perform(.kill, ids: ids, refresh: [.containers, .stats, .footprints]) { try await $0.killContainers(ids) }
    }

    func confirmDeleteContainers(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let sorted = ids.sorted()
        let anyRunning = containers.contains { ids.contains($0.id) && $0.state == .running }
        let message: String = switch (sorted.count == 1, anyRunning) {
        case (true, true): String(localized: "It's stopped first. Its writable layer is removed; images and volumes are kept.")
        case (true, false): String(localized: "Its writable layer is removed; images and volumes are kept.")
        case (false, true):
            String(localized: "Running containers are stopped first. Their writable layers are removed; images and volumes are kept.")
        case (false, false): String(localized: "Their writable layers are removed; images and volumes are kept.")
        }
        confirmation = Confirmation(
            title: sorted.count == 1
                ? String(localized: "Delete “\(sorted[0])”?")
                : String(localized: "Delete \(sorted.count) containers?"),
            message: message,
            confirmLabel: String(localized: "Delete")
        ) { [weak self] in
            Task { await self?.deleteContainers(sorted, force: anyRunning) }
        }
    }

    func deleteContainers(_ ids: [String], force: Bool) async {
        await perform(.delete, ids: ids, refresh: [.containers, .stats, .footprints, .disk]) {
            try await $0.deleteContainers(ids, force: force)
        }
    }

    func runContainer(_ spec: RunSpec) async throws -> String {
        let id = try await backend.run(spec)
        await refresh([.containers, .stats, .footprints, .images, .disk])
        containerSelection = [id]
        selectedSection = .containers
        return id
    }

    func openShell(container id: String) {
        HostActions.openInTerminal(backend.shellCommandLine(forContainer: id), title: id, onError: showError)
    }

    func openShell(machine id: String) {
        HostActions.openInTerminal(backend.shellCommandLine(forMachine: id), title: id, onError: showError)
    }

    // MARK: Images

    /// Containers (running or not) and machines per image; `container list` doesn't include machines.
    /// While the machine list (or a machine's image) is unknown, no image counts as unused.
    var imageUsage: ImageUsage { ImageUsage(containers: containers, machines: machines, machinesKnown: machinesKnown) }

    /// Deleting an image the CLI happily deletes even when containers or machines use it, so in-use
    /// images get a blocking dialog whose only action is an explicit "Delete Anyway".
    func confirmDeleteImages(_ refs: [String]) {
        guard !refs.isEmpty else { return }
        let sorted = refs.sorted()
        let usage = imageUsage
        let inUse = sorted.filter(usage.isUsed)
        let bytes = images.filter { refs.contains($0.reference) }.reduce(0) { $0 + $1.totalSizeBytes }
        let delete: @MainActor () -> Void = { [weak self] in
            Task {
                await self?.perform(.delete, ids: sorted, refresh: [.images, .disk]) {
                    try await $0.deleteImages(sorted, force: false)
                }
            }
        }
        guard !inUse.isEmpty else {
            confirmation = Confirmation(
                title: sorted.count == 1
                    ? String(localized: "Delete “\(ImageName(sorted[0]).display)”?")
                    : String(localized: "Delete \(sorted.count) images?"),
                message: String(localized: "Frees up to \(Format.disk(bytes)). Images built or loaded on this Mac can't be pulled again."),
                confirmLabel: String(localized: "Delete"), action: delete)
            return
        }
        let users = inUse.map { ref in
            let who = usage.users(of: ref).description
            return sorted.count == 1
                ? String(localized: "Used by \(who).")
                : String(localized: "\(ImageName(ref).display) is used by \(who).")
        }
        let consequence = sorted.count == 1
            ? String(localized: "Containers keep their own copy of the files and keep working, but nothing new can be created from it until pulled again — and an image built or loaded on this Mac can't be pulled. Delete what uses it first to be safe.")
            : String(localized: "Containers keep their own copy of the files and keep working, but nothing new can be created from them until pulled again — and an image built or loaded on this Mac can't be pulled. Delete what uses them first to be safe.")
        confirmation = Confirmation(
            title: inUse.count == 1
                ? String(localized: "“\(ImageName(inUse[0]).display)” is in use")
                : String(localized: "\(inUse.count) images are in use"),
            message: users.joined(separator: "\n") + "\n\n" + consequence,
            confirmLabel: String(localized: "Delete Anyway"), cancelIsDefault: true, action: delete)
    }

    /// Lists exactly what will be deleted, and deletes exactly that (re-checked when confirmed) —
    /// never `image prune --all`, which removes whatever the CLI thinks is unused at that moment,
    /// machine base images included.
    func confirmPruneImages() {
        if let reason = imageUsage.unknownReason {
            confirmation = Confirmation(
                title: String(localized: "Can't tell which images are unused"),
                message: String(localized: "\(reason) Nothing is removed until Basket can read every machine; try again in a moment, or delete images one by one.",
                                comment: "%@ is a sentence explaining why (for example, a machine couldn't be inspected)"),
                confirmLabel: nil) {}
            return
        }
        let unused = imageUsage.unused(images)
        let bytes = unused.reduce(0) { $0 + $1.totalSizeBytes }
        confirmation = Confirmation(
            title: unused.isEmpty
                ? String(localized: "No unused images")
                : String(localized: "Remove \(unused.count) unused images?"),
            message: unused.isEmpty
                ? String(localized: "Every image is used by a container or machine.")
                : unused.map { ImageName($0.reference).display }.localizedList + "\n\n"
                    + String(localized: "Frees about \(Format.disk(bytes)). Pulled images can be pulled again; images built or loaded on this Mac are gone for good."),
            confirmLabel: unused.isEmpty ? nil : String(localized: "Remove")
        ) { [weak self] in
            guard !unused.isEmpty else { return }
            Task { await self?.deleteApproved(ApprovedDeletion(images: unused.map(\.reference)), operation: .removeUnusedImages) }
        }
    }

    /// Keeps only the host variant, locally (see `ImageSlimmer`): nothing is pulled, so it also works
    /// for images built, loaded or retagged here, and the reference never disappears.
    func confirmSlimImage(_ ref: String) {
        guard let image = images.first(where: { $0.reference == ref }), ImageSlimmer.canSlim(image) else { return }
        let others = image.variants.filter { !$0.platform.hasPrefix(hostPlatform) }.count
        let saving = max(0, image.totalSizeBytes - image.hostVariantSizeBytes)
        var message = String(localized: "Removes the \(others) other platform variants (about \(Format.disk(saving))). Basket saves the \(hostPlatform) variant to an archive on this Mac and loads it back under the same name; nothing is downloaded.")
        let users = imageUsage.users(of: ref)
        if !users.isEmpty {
            var usedBy = String(localized: "Used by \(users.description); they keep working.")
            let foreign = containers.filter { users.containers.contains($0.id) && !$0.platform.isEmpty && !$0.platform.hasPrefix(hostPlatform) }
            if !foreign.isEmpty {
                let names = foreign.map(\.id).localizedList
                usedBy = foreign.count == 1
                    ? String(localized: "\(usedBy) \(names) runs another platform's variant: recreating it will need a pull.",
                             comment: "The first %@ is the previous sentence (“Used by …; they keep working.”)")
                    : String(localized: "\(usedBy) \(names) run another platform's variant: recreating them will need a pull.",
                             comment: "The first %@ is the previous sentence (“Used by …; they keep working.”)")
            }
            message += "\n\n" + usedBy
        }
        confirmation = Confirmation(
            title: String(localized: "Keep only the \(hostPlatform) variant of “\(ImageName(ref).display)”?"),
            message: message, confirmLabel: String(localized: "Keep Only \(hostPlatform)")
        ) { [weak self] in
            self?.startSlim(ref)
        }
    }

    /// Runs `slimImage` as a task quitting can cancel (see `BasketAppDelegate`).
    func startSlim(_ ref: String) {
        guard slimTasks[ref] == nil else { return }
        slimTasks[ref] = Task { [weak self] in
            await self?.slimImage(ref)
            self?.slimTasks[ref] = nil
            self?.scanRecoveryArchives()
        }
    }

    func slimImage(_ ref: String) async {
        let slimmer = ImageSlimmer(store: BackendImageStore(backend), workDirectory: imageArchiveDirectory)
        pending[ref] = String(localized: "Slimming…", comment: "Shown next to an image while Basket keeps only this Mac's platform variant")
        let report: @Sendable (ImageSlimmer.Step) -> Void = { step in
            Task { @MainActor [weak self] in
                if self?.pending[ref] != nil {
                    self?.pending[ref] = String(localized: "\(step.title)…", comment: "A step in progress, e.g. “Checking the archive…”")
                }
            }
        }
        do {
            let outcome = try await slimmer.slim(ref, progress: report)
            if !outcome.reclaimed {
                banner = BannerMessage(
                    title: String(localized: "Kept only \(hostPlatform)"),
                    detail: String(localized: "The old variants' space is released the next time an image is deleted."))
            }
        } catch {
            showError(String(localized: "Couldn't keep only \(hostPlatform)"), error)
        }
        pending[ref] = nil
        await refresh([.images, .disk])
    }

    /// Where slimming writes its temporary archive (kept there only if something went wrong). UI-test
    /// runs use their own scratch directory, never the user's archives.
    var imageArchiveDirectory: URL {
        if options.isUITest {
            return FileManager.default.temporaryDirectory
                .appending(path: "basket-uitest-image-archives-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        }
        return URL.applicationSupportDirectory.appending(path: "Basket/Image Archives", directoryHint: .isDirectory)
    }

    var hostPlatform: String { ImageSlimmer.hostPlatform }

    func runImage(_ ref: String) {
        activeSheet = .newContainer(.defaults(image: ref))
    }

    // MARK: Volumes

    func confirmDeleteVolumes(_ names: [String]) {
        guard !names.isEmpty else { return }
        let sorted = names.sorted()
        let bytes = volumes.filter { names.contains($0.name) }.reduce(0) { $0 + ($1.allocatedBytes ?? 0) }
        let one = sorted.count == 1
        confirmation = Confirmation(
            title: one ? String(localized: "Delete volume “\(sorted[0])”?") : String(localized: "Delete \(sorted.count) volumes?"),
            message: one
                ? String(localized: "All data in it is lost. Frees \(Format.disk(bytes)) on disk.")
                : String(localized: "All data in them is lost. Frees \(Format.disk(bytes)) on disk."),
            confirmLabel: String(localized: "Delete")
        ) { [weak self] in
            let operation = PendingOperation(
                progress: PendingOperation.delete.progress,
                failure: one ? String(localized: "Couldn't delete the volume") : String(localized: "Couldn't delete the volumes"))
            Task { await self?.perform(operation, refresh: [.volumes, .disk]) { try await $0.deleteVolumes(sorted) } }
        }
    }

    func confirmPruneVolumes() {
        let users = volumeUsers
        let unused = volumes.filter { users[$0.name] == nil }
        let bytes = unused.reduce(0) { $0 + ($1.allocatedBytes ?? 0) }
        confirmation = Confirmation(
            title: unused.isEmpty
                ? String(localized: "No unused volumes")
                : String(localized: "Remove \(unused.count) unused volumes?"),
            message: unused.isEmpty
                ? String(localized: "Every volume is mounted by a container.")
                : unused.map(\.name).localizedList + "\n\n" + String(localized: "Their data is lost. Frees \(Format.disk(bytes))."),
            confirmLabel: unused.isEmpty ? nil : String(localized: "Remove")
        ) { [weak self] in
            guard !unused.isEmpty else { return }
            Task { await self?.deleteApproved(ApprovedDeletion(volumes: unused.map(\.name)), operation: .removeUnusedVolumes) }
        }
    }

    // MARK: Networks

    func confirmDeleteNetworks(_ names: [String]) {
        let deletable = networks.filter { names.contains($0.name) && !$0.isBuiltin }.map(\.name).sorted()
        guard !deletable.isEmpty else { return }
        let one = deletable.count == 1
        confirmation = Confirmation(
            title: one
                ? String(localized: "Delete network “\(deletable[0])”?")
                : String(localized: "Delete \(deletable.count) networks?"),
            message: one
                ? String(localized: "Containers attached to it lose that connection.")
                : String(localized: "Containers attached to them lose that connection."),
            confirmLabel: String(localized: "Delete")
        ) { [weak self] in
            let operation = PendingOperation(
                progress: PendingOperation.delete.progress,
                failure: one ? String(localized: "Couldn't delete the network") : String(localized: "Couldn't delete the networks"))
            Task { await self?.perform(operation, refresh: [.networks]) { try await $0.deleteNetworks(deletable) } }
        }
    }

    // MARK: Machines

    func startMachine(_ id: String) async {
        await perform(.start, ids: [id], refresh: [.machines, .footprints]) { try await $0.startMachine(id) }
    }

    func stopMachine(_ id: String) async {
        await perform(.stop, ids: [id], refresh: [.machines, .footprints]) { try await $0.stopMachine(id) }
    }

    func setDefaultMachine(_ id: String) async {
        await perform(.setDefaultMachine, ids: [id], refresh: [.machines]) { try await $0.setDefaultMachine(id) }
    }

    func confirmDeleteMachine(_ id: String) {
        confirmation = Confirmation(
            title: String(localized: "Delete machine “\(id)”?"),
            message: String(localized: "The machine's disk and everything installed in it are removed. Your home folder is not affected."),
            confirmLabel: String(localized: "Delete")
        ) { [weak self] in
            Task { await self?.perform(.deleteMachine, ids: [id], refresh: [.machines, .footprints, .disk]) { try await $0.deleteMachine(id) } }
        }
    }

    // MARK: Reclaim

    struct ReclaimPlan {
        var stoppedContainers: [ContainerSummary]
        var unusedImages: [ImageSummary]
        var unusedVolumes: [VolumeSummary]
        /// Why no image is offered: Basket can't tell which images machines use.
        var imageUsageUnknown: String?

        func approved(containers: Bool, images: Bool, volumes: Bool) -> ApprovedDeletion {
            ApprovedDeletion(
                containers: containers ? stoppedContainers.map(\.id) : [],
                images: images ? unusedImages.map(\.reference) : [],
                volumes: volumes ? unusedVolumes.map(\.name) : [])
        }
    }

    /// The state Reclaim plans from, taken once when its sheet opens: polling while the sheet is open
    /// (containers stopped meanwhile, by the user or Memory Saver) never adds to what gets deleted.
    struct ReclaimSnapshot {
        var containers: [ContainerSummary]
        var images: [ImageSummary]
        var volumes: [VolumeSummary]
        var machines: [MachineSummary]
        var machinesKnown: Bool
        var volumeUsers: [String: [String]]
        var diskUsage: DiskUsage?

        /// What Reclaim would delete. When stopped containers go first, their images and volumes
        /// become unused too; images that machines boot from are never unused, and no image is while
        /// a machine's image is unknown.
        func plan(includingStoppedContainers: Bool) -> ReclaimPlan {
            let stopped = containers.filter { $0.state == .stopped || $0.state == .created }
            let stoppedIDs = Set(stopped.map(\.id))
            let remaining = includingStoppedContainers ? containers.filter { !stoppedIDs.contains($0.id) } : containers
            let remainingIDs = Set(remaining.map(\.id))
            let usage = ImageUsage(containers: remaining, machines: machines, machinesKnown: machinesKnown)
            return ReclaimPlan(
                stoppedContainers: stopped,
                unusedImages: usage.unused(images),
                unusedVolumes: volumes.filter { (volumeUsers[$0.name] ?? []).allSatisfy { !remainingIDs.contains($0) } },
                imageUsageUnknown: usage.unknownReason)
        }
    }

    func reclaimSnapshot() -> ReclaimSnapshot {
        ReclaimSnapshot(
            containers: containers, images: images, volumes: volumes, machines: machines, machinesKnown: machinesKnown,
            volumeUsers: volumeUsers, diskUsage: diskUsage)
    }

    /// What Reclaim would delete right now (the sheet itself works from a snapshot).
    func reclaimPlan(includingStoppedContainers: Bool) -> ReclaimPlan {
        reclaimSnapshot().plan(includingStoppedContainers: includingStoppedContainers)
    }

    /// Deletes exactly what the user approved, after re-checking it against fresh state: whatever was
    /// started, got a new user or vanished since the confirmation is skipped (and reported).
    func deleteApproved(_ approved: ApprovedDeletion, operation: PendingOperation) async {
        await refresh([.containers, .machines, .images, .volumes])
        let safe = approved.revalidated(
            containers: containers, machines: machines, images: images, volumes: volumes, machinesKnown: machinesKnown)
        let usageUnknown = imageUsage.unknownReason
        let skipped = approved.subtracting(safe)
        let ids = safe.containers + safe.images + safe.volumes
        let ok = await perform(operation, ids: ids, refresh: [.containers, .stats, .footprints, .images, .volumes, .disk]) {
            try await safe.perform(on: $0)
        }
        if ok, !skipped.isEmpty {
            let names = (skipped.containers + skipped.images.map { ImageName($0).display } + skipped.volumes).localizedList
            var detail = skipped.count == 1
                ? String(localized: "\(names) started, gained a user or disappeared, so it wasn't deleted.")
                : String(localized: "\(names) started, gained a user or disappeared, so they weren't deleted.")
            if let usageUnknown, !skipped.images.isEmpty {
                detail = String(localized: "\(detail) Images were kept: \(usageUnknown)",
                                comment: "The first %@ is the previous sentence; the second explains why images were kept")
            }
            banner = BannerMessage(
                title: String(localized: "Kept \(skipped.count) items that changed since you confirmed"),
                detail: detail)
        }
    }
}
