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

extension AppStore {
    /// Runs a backend operation, tracks it as pending on `ids`, refreshes `kinds` afterwards and
    /// reports failures in the banner. Returns whether it succeeded.
    @discardableResult
    func perform(
        _ verb: String, ids: [String] = [], refresh kinds: [DataKind],
        _ operation: @escaping @Sendable (any ContainerBackend) async throws -> Void
    ) async -> Bool {
        for id in ids { pending[id] = verb }
        defer { for id in ids { pending[id] = nil } }
        let backend = self.backend
        do {
            try await operation(backend)
            await refresh(kinds)
            return true
        } catch {
            showError("\(verb) failed", error)
            await refresh(kinds)
            return false
        }
    }

    // MARK: Section-level commands (menus, keyboard shortcuts)

    var newItemTitle: String {
        switch selectedSection {
        case .overview, .containers: "New Container…"
        case .images: "Pull Image…"
        case .volumes: "New Volume…"
        case .networks: "New Network…"
        case .machines: "New Machine…"
        case .migration: "New Container…"
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
        await perform("Starting the container system", refresh: DataKind.allCases) { try await $0.startSystem() }
    }

    func confirmStopSystem() {
        let running = runningContainers.count
        confirmation = Confirmation(
            title: "Stop the container system?",
            message: running > 0
                ? "\(running) running container\(running == 1 ? "" : "s") will be stopped and their memory returned to macOS."
                : "Basket will stop the container API server. You can start it again at any time.",
            confirmLabel: "Stop System"
        ) { [weak self] in
            Task { await self?.perform("Stopping the container system", refresh: DataKind.allCases) { try await $0.stopSystem() } }
        }
    }

    // MARK: Containers

    func startContainers(_ ids: [String]) async {
        await perform("Starting", ids: ids, refresh: [.containers, .stats, .footprints]) { backend in
            for id in ids { try await backend.startContainer(id) }
        }
        await refreshComposeHosts(after: ids)
    }

    func stopContainers(_ ids: [String]) async {
        await perform("Stopping", ids: ids, refresh: [.containers, .stats, .footprints]) { try await $0.stopContainers(ids) }
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
        for id in ids { pending[id] = "Restarting" }
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
            showError("Restarting failed", error)
            return MemoryReclaim.Outcome()
        }
    }

    func killContainers(_ ids: [String]) async {
        await perform("Killing", ids: ids, refresh: [.containers, .stats, .footprints]) { try await $0.killContainers(ids) }
    }

    func confirmDeleteContainers(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let sorted = ids.sorted()
        let anyRunning = containers.contains { ids.contains($0.id) && $0.state == .running }
        let names = sorted.count == 1 ? "“\(sorted[0])”" : "\(sorted.count) containers"
        confirmation = Confirmation(
            title: "Delete \(names)?",
            message: (anyRunning ? "Running containers are stopped first. " : "")
                + "Their writable layers are removed; images and volumes are kept.",
            confirmLabel: "Delete"
        ) { [weak self] in
            Task { await self?.deleteContainers(sorted, force: anyRunning) }
        }
    }

    func deleteContainers(_ ids: [String], force: Bool) async {
        await perform("Deleting", ids: ids, refresh: [.containers, .stats, .footprints, .disk]) {
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
        let names = sorted.count == 1 ? "“\(ImageName(sorted[0]).display)”" : "\(sorted.count) images"
        let delete: @MainActor () -> Void = { [weak self] in
            Task {
                await self?.perform("Deleting image", ids: sorted, refresh: [.images, .disk]) {
                    try await $0.deleteImages(sorted, force: false)
                }
            }
        }
        guard !inUse.isEmpty else {
            confirmation = Confirmation(
                title: "Delete \(names)?",
                message: "Frees up to \(Format.disk(bytes)). Images built or loaded on this Mac can't be pulled again.",
                confirmLabel: "Delete", action: delete)
            return
        }
        let users = inUse.map { ref in
            let who = usage.users(of: ref).description
            return sorted.count == 1 ? "Used by \(who)." : "\(ImageName(ref).display) is used by \(who)."
        }
        confirmation = Confirmation(
            title: inUse.count == 1 ? "“\(ImageName(inUse[0]).display)” is in use" : "\(inUse.count) images are in use",
            message: users.joined(separator: "\n")
                + "\n\nContainers keep their own copy of the files and keep working, but nothing new can be created "
                + "from \(sorted.count == 1 ? "it" : "them") until pulled again — and an image built or loaded on this Mac "
                + "can't be pulled. Delete what uses \(sorted.count == 1 ? "it" : "them") first to be safe.",
            confirmLabel: "Delete Anyway", cancelIsDefault: true, action: delete)
    }

    /// Lists exactly what will be deleted, and deletes exactly that (re-checked when confirmed) —
    /// never `image prune --all`, which removes whatever the CLI thinks is unused at that moment,
    /// machine base images included.
    func confirmPruneImages() {
        if let reason = imageUsage.unknownReason {
            confirmation = Confirmation(
                title: "Can't tell which images are unused",
                message: reason + " Nothing is removed until Basket can read every machine; try again in a moment, or delete images one by one.",
                confirmLabel: nil) {}
            return
        }
        let unused = imageUsage.unused(images)
        let bytes = unused.reduce(0) { $0 + $1.totalSizeBytes }
        confirmation = Confirmation(
            title: unused.isEmpty ? "No unused images" : "Remove \(unused.count) unused image\(unused.count == 1 ? "" : "s")?",
            message: unused.isEmpty
                ? "Every image is used by a container or machine."
                : unused.map { ImageName($0.reference).display }.joined(separator: ", ")
                    + "\n\nFrees about \(Format.disk(bytes)). Pulled images can be pulled again; images built or loaded on this Mac are gone for good.",
            confirmLabel: unused.isEmpty ? nil : "Remove"
        ) { [weak self] in
            guard !unused.isEmpty else { return }
            Task { await self?.deleteApproved(ApprovedDeletion(images: unused.map(\.reference)), verb: "Removing unused images") }
        }
    }

    /// Keeps only the host variant, locally (see `ImageSlimmer`): nothing is pulled, so it also works
    /// for images built, loaded or retagged here, and the reference never disappears.
    func confirmSlimImage(_ ref: String) {
        guard let image = images.first(where: { $0.reference == ref }), ImageSlimmer.canSlim(image) else { return }
        let others = image.variants.filter { !$0.platform.hasPrefix(hostPlatform) }.count
        let saving = max(0, image.totalSizeBytes - image.hostVariantSizeBytes)
        var message = "Removes the \(others) other platform variant\(others == 1 ? "" : "s") (about \(Format.disk(saving))). "
            + "Basket saves the \(hostPlatform) variant to an archive on this Mac and loads it back under the same "
            + "name; nothing is downloaded."
        let users = imageUsage.users(of: ref)
        if !users.isEmpty {
            message += "\n\nUsed by \(users.description); they keep working."
            let foreign = containers.filter { users.containers.contains($0.id) && !$0.platform.isEmpty && !$0.platform.hasPrefix(hostPlatform) }
            if !foreign.isEmpty {
                message += " \(foreign.map(\.id).joined(separator: ", ")) run\(foreign.count == 1 ? "s" : "") another platform's variant: "
                    + "recreating \(foreign.count == 1 ? "it" : "them") will need a pull."
            }
        }
        confirmation = Confirmation(
            title: "Keep only the \(hostPlatform) variant of “\(ImageName(ref).display)”?",
            message: message, confirmLabel: "Keep Only \(hostPlatform)"
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
        pending[ref] = "Slimming"
        let report: @Sendable (ImageSlimmer.Step) -> Void = { step in
            Task { @MainActor [weak self] in
                if self?.pending[ref] != nil { self?.pending[ref] = step.title }
            }
        }
        do {
            let outcome = try await slimmer.slim(ref, progress: report)
            if !outcome.reclaimed {
                banner = BannerMessage(
                    title: "Kept only \(hostPlatform)",
                    detail: "The old variants' space is released the next time an image is deleted.")
            }
        } catch {
            showError("Keeping only \(hostPlatform) failed", error)
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
        confirmation = Confirmation(
            title: sorted.count == 1 ? "Delete volume “\(sorted[0])”?" : "Delete \(sorted.count) volumes?",
            message: "All data in \(sorted.count == 1 ? "it" : "them") is lost. Frees \(Format.disk(bytes)) on disk.",
            confirmLabel: "Delete"
        ) { [weak self] in
            Task { await self?.perform("Deleting volume", refresh: [.volumes, .disk]) { try await $0.deleteVolumes(sorted) } }
        }
    }

    func confirmPruneVolumes() {
        let users = volumeUsers
        let unused = volumes.filter { users[$0.name] == nil }
        let bytes = unused.reduce(0) { $0 + ($1.allocatedBytes ?? 0) }
        confirmation = Confirmation(
            title: unused.isEmpty ? "No unused volumes" : "Remove \(unused.count) unused volume\(unused.count == 1 ? "" : "s")?",
            message: unused.isEmpty
                ? "Every volume is mounted by a container."
                : unused.map(\.name).joined(separator: ", ") + "\n\nTheir data is lost. Frees \(Format.disk(bytes)).",
            confirmLabel: unused.isEmpty ? nil : "Remove"
        ) { [weak self] in
            guard !unused.isEmpty else { return }
            Task { await self?.deleteApproved(ApprovedDeletion(volumes: unused.map(\.name)), verb: "Removing unused volumes") }
        }
    }

    // MARK: Networks

    func confirmDeleteNetworks(_ names: [String]) {
        let deletable = networks.filter { names.contains($0.name) && !$0.isBuiltin }.map(\.name).sorted()
        guard !deletable.isEmpty else { return }
        confirmation = Confirmation(
            title: deletable.count == 1 ? "Delete network “\(deletable[0])”?" : "Delete \(deletable.count) networks?",
            message: "Containers attached to it lose that connection.",
            confirmLabel: "Delete"
        ) { [weak self] in
            Task { await self?.perform("Deleting network", refresh: [.networks]) { try await $0.deleteNetworks(deletable) } }
        }
    }

    // MARK: Machines

    func startMachine(_ id: String) async {
        await perform("Starting", ids: [id], refresh: [.machines, .footprints]) { try await $0.startMachine(id) }
    }

    func stopMachine(_ id: String) async {
        await perform("Stopping", ids: [id], refresh: [.machines, .footprints]) { try await $0.stopMachine(id) }
    }

    func setDefaultMachine(_ id: String) async {
        await perform("Setting default", ids: [id], refresh: [.machines]) { try await $0.setDefaultMachine(id) }
    }

    func confirmDeleteMachine(_ id: String) {
        confirmation = Confirmation(
            title: "Delete machine “\(id)”?",
            message: "The machine's disk and everything installed in it are removed. Your home folder is not affected.",
            confirmLabel: "Delete"
        ) { [weak self] in
            Task { await self?.perform("Deleting machine", ids: [id], refresh: [.machines, .footprints, .disk]) { try await $0.deleteMachine(id) } }
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
    func deleteApproved(_ approved: ApprovedDeletion, verb: String) async {
        await refresh([.containers, .machines, .images, .volumes])
        let safe = approved.revalidated(
            containers: containers, machines: machines, images: images, volumes: volumes, machinesKnown: machinesKnown)
        let usageUnknown = imageUsage.unknownReason
        let skipped = approved.subtracting(safe)
        let ids = safe.containers + safe.images + safe.volumes
        let ok = await perform(verb, ids: ids, refresh: [.containers, .stats, .footprints, .images, .volumes, .disk]) {
            try await safe.perform(on: $0)
        }
        if ok, !skipped.isEmpty {
            let names = skipped.containers + skipped.images.map { ImageName($0).display } + skipped.volumes
            var detail = names.joined(separator: ", ") + " started, gained a user or disappeared, so \(skipped.count == 1 ? "it was" : "they were") not deleted."
            if let usageUnknown, !skipped.images.isEmpty { detail += " Images were kept: \(usageUnknown)" }
            banner = BannerMessage(
                title: "Kept \(skipped.count) item\(skipped.count == 1 ? "" : "s") that changed since you confirmed",
                detail: detail)
        }
    }
}
