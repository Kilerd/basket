import AppKit
import Observation
import BasketCore

enum Availability: Equatable {
    case unknown, running, stopped
    case cliMissing(String)
}

enum DataKind: String, CaseIterable, Sendable {
    case system, containers, stats, footprints, images, volumes, networks, machines, disk, orbstack

    var title: String {
        switch self {
        case .system: "system status"
        case .stats: "container statistics"
        case .footprints: "host memory"
        case .disk: "disk usage"
        case .orbstack: "OrbStack status"
        default: rawValue
        }
    }
}

struct BannerMessage: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var detail: String
    /// Set when raised by background polling; the next successful load of that kind clears it.
    var pollKind: DataKind?
}

struct Confirmation: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    /// nil makes it informational (single OK button).
    var confirmLabel: String?
    var isDestructive = true
    /// Return cancels: for actions that need a deliberate click ("Delete Anyway").
    var cancelIsDefault = false
    var action: @MainActor () -> Void
}

enum ActiveSheet: Identifiable {
    case newContainer(RunDraft)
    case pullImage(String)
    case newVolume
    case newNetwork
    case newMachine
    case reclaim
    case reclaimMemory
    /// "Compose Up…": the plan for a compose file, then `up` (see `ComposePlanSheet`).
    case composePlan(URL)

    var id: String {
        switch self {
        case .newContainer: "newContainer"
        case .pullImage: "pullImage"
        case .newVolume: "newVolume"
        case .newNetwork: "newNetwork"
        case .newMachine: "newMachine"
        case .reclaim: "reclaim"
        case .reclaimMemory: "reclaimMemory"
        case .composePlan: "composePlan"
        }
    }
}

enum ContainerDetailTab: String, CaseIterable, Identifiable {
    case info = "Info", logs = "Logs", inspect = "Inspect", stats = "Stats"
    var id: String { rawValue }
}

struct StatsPoint: Identifiable, Hashable {
    var date: Date
    var cpuPercent: Double
    var memoryBytes: Int64
    var id: Date { date }
}

@Observable @MainActor
final class AppStore {
    let options: LaunchOptions
    private(set) var backend: any ContainerBackend
    @ObservationIgnored private var orbInspector: OrbStackInspector
    @ObservationIgnored private var backendCLIPath: String
    /// "Migrate from OrbStack" (see `MigrationModel`).
    let migration: MigrationModel

    // MARK: UI state
    var selectedSection: AppSection
    var activeSheet: ActiveSheet?
    var confirmation: Confirmation?
    var banner: BannerMessage?
    var searchText: [AppSection: String] = [:]
    var containerSelection: Set<String> = []
    var containerDetailTab = ContainerDetailTab.info
    var imageSelection: Set<String> = []
    var volumeSelection: Set<String> = []
    var networkSelection: Set<String> = []
    var machineSelection: Set<String> = []
    var containerSort = [KeyPathComparator(\ContainerRow.name)]
    /// Compose project whose header row is selected in the containers table (see AppStore+Compose).
    var selectedComposeProject: String?
    var collapsedComposeProjects: Set<String> = []
    var composeDetailTab = ComposeDetailTab.overview
    var imageSort = [KeyPathComparator(\ImageRow.name)]
    var volumeSort = [KeyPathComparator(\VolumeRow.name)]
    var networkSort = [KeyPathComparator(\NetworkRow.name)]
    var machineSort = [KeyPathComparator(\MachineRow.name)]

    // MARK: Data
    var availability: Availability = .unknown
    var system: SystemStatus?
    var containers: [ContainerSummary] = []
    var latestStats: [String: ContainerStats] = [:]
    var cpuPercent: [String: Double] = [:]
    var statsHistory: [String: [StatsPoint]] = [:]
    var footprints: [HostMemoryFootprint] = []
    var footprintsAvailable = true
    var images: [ImageSummary] = []
    var volumes: [VolumeSummary] = []
    var networks: [NetworkSummary] = []
    var machines: [MachineSummary] = []
    /// The last machine list loaded. Until then (or after it failed) no image counts as unused: any
    /// of them could be a machine's base image.
    var machinesKnown = false
    var diskUsage: DiskUsage?
    var orbStack: OrbStackSnapshot?
    var loaded: Set<DataKind> = []
    /// Resource id → in-flight verb ("Stopping"), shown next to the row.
    var pending: [String: String] = [:]
    /// Image reference → its running "Keep only linux/arm64" (quitting asks while any runs).
    @ObservationIgnored var slimTasks: [String: Task<Void, Never>] = [:]
    /// Archives an interrupted or failed slim kept (offered for restore in Images).
    var recoveryArchives: [RecoveryArchive] = []
    var isRefreshing = false
    /// Incremented every time a stats sample is ingested (the self-test waits for two).
    private(set) var statsSamples = 0
    /// Idle tracking, exemptions and activity log (see AppStore+Memory).
    let memorySaver: MemorySaverState

    // MARK: Window & polling
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored weak var searchField: NSSearchField?
    /// SwiftUI's `openSettings`, captured by the main window (the self-test opens Settings).
    @ObservationIgnored var openSettings: (() -> Void)?
    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var pollTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var windowVisible = false
    @ObservationIgnored private var lastServiceCheck = Date.distantPast
    @ObservationIgnored private var selfTestStarted = false
    @ObservationIgnored private var statsInFlight = false
    @ObservationIgnored var backgroundWatch: Task<Void, Never>?
    @ObservationIgnored private var pollingSlowdown: Double = 1

    init(options: LaunchOptions) {
        UserDefaults.standard.register(defaults: [
            DefaultsKey.refreshInterval: 2.0,
            DefaultsKey.defaultCPUs: 1,
            DefaultsKey.defaultMemoryMB: 512,
        ])
        self.options = options
        let cliPath = UserDefaults.standard.string(forKey: DefaultsKey.containerCLIPath) ?? ""
        self.backendCLIPath = cliPath
        self.backend = options.makeBackend(settingsCLIPath: cliPath)
        self.orbInspector = OrbStackInspector(fixturesDirectory: options.fixturesDirectory)
        self.migration = MigrationModel(migrator: options.makeMigrator())
        self.selectedSection = options.initialSection ?? .overview
        self.memorySaver = MemorySaverState(persistent: !options.isUITest)
        migration.store = self
        BasketAppDelegate.store = self
        cleanUpAfterPreviousRun()
        // Starts background sampling even if the window never opens (launched at login, closed).
        Task { [weak self] in self?.updatePolling() }
    }

    static func makeDefault() -> AppStore { AppStore(options: .fromProcess()) }

    /// Rebuilds the backend after the CLI path changed in Settings.
    func reloadBackend() {
        let path = UserDefaults.standard.string(forKey: DefaultsKey.containerCLIPath) ?? ""
        guard path != backendCLIPath else { return }
        backendCLIPath = path
        backend = options.makeBackend(settingsCLIPath: path)
        availability = .unknown
        banner = nil
        Task { await refreshAll() }
    }

    // MARK: Window tracking

    func attach(window: NSWindow) {
        guard mainWindow !== window else { return }
        for o in windowObservers { NotificationCenter.default.removeObserver(o) }
        mainWindow = window
        window.setAccessibilityIdentifier("basket.main")
        if options.isUITest {
            window.animationBehavior = .none
            var frame = window.frame
            frame.origin.y += frame.height - 820
            frame.size = NSSize(width: 1280, height: 820)
            window.setFrame(frame, display: true)
        }
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.updateWindowVisibility() }
        }
        windowObservers = [
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main, using: update),
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setWindowVisible(false) }
            },
            center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main, using: update),
            center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main, using: update),
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.activationChanged() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.activationChanged() }
            },
        ]
        updateWindowVisibility()
        if let dir = options.selfTestDirectory, !selfTestStarted {
            selfTestStarted = true
            Task { await SelfTestRunner(store: self, directory: dir).run() }
        }
    }

    private func updateWindowVisibility() {
        guard let window = mainWindow else { return setWindowVisible(false) }
        setWindowVisible(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
    }

    private func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        updatePolling()
    }

    /// The menu bar extra was opened: show fresh numbers even when the window is closed.
    func menuBarOpened() {
        guard pollTasks.isEmpty else { return }
        Task { await refresh([.system, .containers, .stats, .footprints]) }
    }

    // MARK: Polling

    var refreshInterval: Double {
        max(1, UserDefaults.standard.double(forKey: DefaultsKey.refreshInterval))
    }

    private func updatePolling() {
        // UI-test runs poll even when another window covers ours, so captures are never empty.
        let shouldPoll = windowVisible || options.isUITest
        if shouldPoll, pollTasks.isEmpty {
            startPolling()
        } else if !shouldPoll, !pollTasks.isEmpty {
            stopPolling()
        }
        updateBackgroundWatch(foreground: shouldPoll)
    }

    func restartPolling() {
        guard !pollTasks.isEmpty else { return }
        stopPolling()
        startPolling()
    }

    private func startPolling() {
        // While another app is active (window still visible) everything polls 3× slower.
        // Self-test runs keep full speed: they wait for samples and may never be the active app.
        let slow: Double = NSApp.isActive || options.selfTestDirectory != nil ? 1 : 3
        pollingSlowdown = slow
        // Separate loops so a slow call (stats sample ~3 s, a hung `system status` up to 10 s)
        // never delays the others.
        pollTasks = [
            poll(every: refreshInterval * slow, [.containers, .footprints]),
            poll(every: max(3, refreshInterval) * slow, [.stats]),
            poll(every: 10 * slow, [.system]),
            poll(every: 10 * slow, [.images, .volumes, .networks, .machines]),
            poll(every: 15 * slow, [.disk]),
            poll(every: 30 * slow, [.orbstack]),
        ]
    }

    /// Re-paces polling when Basket becomes or stops being the active app.
    private func activationChanged() {
        let slow: Double = NSApp.isActive || options.selfTestDirectory != nil ? 1 : 3
        if slow != pollingSlowdown { restartPolling() }
    }

    private func stopPolling() {
        pollTasks.forEach { $0.cancel() }
        pollTasks = []
    }

    private func poll(every seconds: Double, _ kinds: [DataKind]) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(kinds)
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func refreshAll() async {
        isRefreshing = true
        await refresh(DataKind.allCases)
        isRefreshing = false
    }

    /// Loads `kinds` concurrently. A stats sample takes seconds, so unless stats are the only
    /// thing asked for, it runs in the background instead of holding up the caller.
    func refresh(_ kinds: [DataKind]) async {
        var awaited = kinds
        if kinds.count > 1, let i = awaited.firstIndex(of: .stats) {
            awaited.remove(at: i)
            Task { await self.load(.stats) }
        }
        await withDiscardingTaskGroup { group in
            for kind in awaited {
                group.addTask { await self.load(kind) }
            }
        }
    }

    private func load(_ kind: DataKind) async {
        if kind == .stats {
            guard !statsInFlight else { return }
            statsInFlight = true
        }
        defer { if kind == .stats { statsInFlight = false } }
        let backend = self.backend
        do {
            // Polls mostly return what is already shown: only assign changed values, so SwiftUI
            // doesn't re-render every view that reads them on every tick.
            switch kind {
            case .system:
                let status = try await backend.systemStatus()
                setIfChanged(\.system, status)
                if status.isRunning {
                    setIfChanged(\.availability, .running)
                } else {
                    markServiceStopped()
                }
            case .containers:
                setIfChanged(\.containers, try await backend.listContainers())
                keepSelection(\.containerSelection, within: containers.map(\.id))
            case .stats:
                ingest(try await backend.containerStats())
            case .footprints:
                do {
                    let sampled = try await backend.hostMemoryFootprints()
                    if !Self.footprintsMatch(footprints, sampled) { footprints = sampled }
                    setIfChanged(\.footprintsAvailable, true)
                } catch BackendError.unsupported {
                    setIfChanged(\.footprints, [])
                    setIfChanged(\.footprintsAvailable, false)
                }
            case .images:
                setIfChanged(\.images, try await backend.listImages())
                keepSelection(\.imageSelection, within: images.map(\.id))
            case .volumes:
                setIfChanged(\.volumes, try await backend.listVolumes())
                keepSelection(\.volumeSelection, within: volumes.map(\.id))
            case .networks:
                setIfChanged(\.networks, try await backend.listNetworks())
                keepSelection(\.networkSelection, within: networks.map(\.id))
            case .machines:
                setIfChanged(\.machines, try await backend.listMachines())
                setIfChanged(\.machinesKnown, true)
                keepSelection(\.machineSelection, within: machines.map(\.id))
            case .disk:
                setIfChanged(\.diskUsage, try await backend.diskUsage())
            case .orbstack:
                setIfChanged(\.orbStack, await orbInspector.snapshot())
            }
            if !loaded.contains(kind) { loaded.insert(kind) }
            // A successful list call proves the API server answers; host-side numbers (footprints,
            // OrbStack) don't. A stopped state only clears through `system status`.
            if availability == .unknown, [.containers, .images, .volumes, .networks, .machines].contains(kind) {
                availability = .running
            }
            if banner?.pollKind == kind { banner = nil }
        } catch {
            if !loaded.contains(kind) { loaded.insert(kind) }
            // A backend without machines has none; any other failure leaves their images unknown.
            if kind == .machines { setIfChanged(\.machinesKnown, Self.isUnsupported(error)) }
            await handleLoadError(error, kind: kind)
        }
    }

    private static func isUnsupported(_ error: Error) -> Bool {
        if case .unsupported? = error as? BackendError { return true }
        return false
    }

    /// Assigns only when the value differs (an `@Observable` setter notifies even for equal values).
    private func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppStore, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func keepSelection(_ keyPath: ReferenceWritableKeyPath<AppStore, Set<String>>, within ids: [String]) {
        let current = self[keyPath: keyPath]
        guard !current.isEmpty else { return }
        let kept = current.intersection(ids)
        if kept != current { self[keyPath: keyPath] = kept }
    }

    /// Same VMs with footprints within 1 MiB: not worth a re-render (phys_footprint jitters by pages).
    private static func footprintsMatch(_ a: [HostMemoryFootprint], _ b: [HostMemoryFootprint]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.pid == $1.pid && $0.ownerID == $1.ownerID && abs($0.footprintBytes - $1.footprintBytes) < 1 << 20
        }
    }

    private func handleLoadError(_ error: Error, kind: DataKind) async {
        if error is CancellationError { return }
        switch error as? BackendError {
        case .systemNotRunning?:
            markServiceStopped()
            return
        case .cliNotFound?:
            availability = .cliMissing(error.localizedDescription)
            return
        case .unsupported?:
            return
        default:
            break
        }
        if availability == .stopped { return }
        // An unexpected failure is most often the service going away; check before alarming the user.
        if kind != .system, Date().timeIntervalSince(lastServiceCheck) > 5 {
            lastServiceCheck = Date()
            if let status = try? await backend.systemStatus(), !status.isRunning {
                markServiceStopped()
                return
            }
        }
        let title = "Couldn't load \(kind.title)", detail = error.localizedDescription
        if banner == nil || (banner?.pollKind != nil && (banner?.title != title || banner?.detail != detail)) {
            banner = BannerMessage(title: title, detail: detail, pollKind: kind)
        }
    }

    private func markServiceStopped() {
        setIfChanged(\.availability, .stopped)
        // Stopping the service stops every VM; don't keep showing them as running.
        setIfChanged(\.containers, [])
        setIfChanged(\.machines, [])
        setIfChanged(\.machinesKnown, false)
        setIfChanged(\.containerSelection, [])
        setIfChanged(\.machineSelection, [])
        setIfChanged(\.latestStats, [:])
        setIfChanged(\.cpuPercent, [:])
        setIfChanged(\.statsHistory, [:])
        setIfChanged(\.footprints, [])
        if banner?.pollKind != nil { banner = nil }
    }

    private func ingest(_ samples: [ContainerStats]) {
        var cpu: [String: Double] = [:]
        var history = statsHistory
        for sample in samples {
            // Prefer the CLI's own figure (available from the first sample); else diff two samples.
            if let reported = sample.reportedCPUPercent {
                cpu[sample.id] = reported
            } else if let previous = latestStats[sample.id], sample.sampledAt > previous.sampledAt,
                      sample.cpuCounterKnown, previous.cpuCounterKnown {
                cpu[sample.id] = sample.cpuPercent(since: previous)
            } else if let last = cpuPercent[sample.id] {
                cpu[sample.id] = last
            }
            var points = history[sample.id] ?? []
            points.append(StatsPoint(date: sample.sampledAt, cpuPercent: cpu[sample.id] ?? 0, memoryBytes: sample.memoryUsageBytes))
            if points.count > 150 { points.removeFirst(points.count - 150) }
            history[sample.id] = points
        }
        let live = Set(samples.map(\.id))
        statsHistory = history.filter { live.contains($0.key) }
        latestStats = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cpuPercent = cpu
        statsSamples += 1
        memorySaverDidIngest(samples)
    }

    // MARK: Derived numbers

    /// phys_footprint per container/machine id.
    var hostMemoryByOwner: [String: Int64] {
        var result: [String: Int64] = [:]
        for f in footprints {
            guard let owner = f.ownerID else { continue }
            result[owner, default: 0] += f.footprintBytes
        }
        return result
    }

    var totalHostMemory: Int64 { footprints.reduce(0) { $0 + $1.footprintBytes } }
    var totalGuestMemory: Int64 { latestStats.values.reduce(0) { $0 + $1.memoryUsageBytes } }
    var totalMemoryLimits: Int64 {
        containers.filter { $0.state == .running }.reduce(0) { $0 + $1.memoryLimitBytes }
            + machines.filter { $0.state == .running }.reduce(0) { $0 + $1.memoryBytes }
    }

    var runningContainers: [ContainerSummary] { containers.filter { $0.state == .running } }

    func isLoaded(_ section: AppSection) -> Bool {
        switch section {
        case .overview: true
        case .containers: loaded.contains(.containers)
        case .images: loaded.contains(.images)
        case .volumes: loaded.contains(.volumes)
        case .networks: loaded.contains(.networks)
        case .machines: loaded.contains(.machines)
        case .migration: migration.loaded
        }
    }

    func search(_ section: AppSection) -> String { searchText[section] ?? "" }

    // MARK: Errors

    func showError(_ title: String, _ error: Error) {
        banner = BannerMessage(title: title, detail: error.localizedDescription, pollKind: nil)
    }

    func focusSearch() {
        guard let field = searchField, let window = field.window else { return }
        window.makeFirstResponder(field)
    }
}
