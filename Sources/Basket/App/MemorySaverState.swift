import Foundation
import Observation
import BasketCore

extension DefaultsKey {
    static let memorySaverEnabled = "memorySaverEnabled"
    static let memorySaverIdleMinutes = "memorySaverIdleMinutes"
    static let memorySaverExemptions = "memorySaverExemptions"
    static let memorySaverOptIns = "memorySaverOptIns"
    static let memoryActivity = "memoryActivity"
}

/// Choices offered for "Stop containers idle for".
let memorySaverIdleChoices = [15, 30, 60, 120]

/// One thing Basket did to give memory back, shown in the Overview and the menu bar.
struct MemoryActivity: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        /// Memory Saver stopped an idle container on its own.
        case autoStop
        /// The user chose "Stop Idle Containers".
        case stopIdle
        /// The user restarted a container to reclaim stranded memory.
        case reclaim
    }

    var id = UUID()
    var date: Date
    var kind: Kind
    var containerID: String
    var idleSeconds: Double?
    /// Host memory returned to macOS, when it could be measured.
    var freedBytes: Int64?
}

/// Idle tracking, exemptions and the activity log behind Memory Saver.
@Observable @MainActor
final class MemorySaverState {
    private(set) var trackers: [String: IdleTracker] = [:]
    private(set) var exemptions: Set<String>
    /// Containers whose `--rm` status is unknown that the user still allows Memory Saver to stop.
    private(set) var optIns: Set<String>
    /// Newest first.
    private(set) var activity: [MemoryActivity]

    /// Containers an automatic stop is under way for.
    @ObservationIgnored var inFlight: Set<String> = []
    /// Last automatic attempt per container, so a failing stop isn't retried on every sample.
    @ObservationIgnored private var lastAttempt: [String: Date] = [:]
    /// nil in UI-test runs: nothing is read from or written to the user's defaults.
    @ObservationIgnored private let defaults: UserDefaults?

    static let activityLimit = 20
    static let retryInterval: TimeInterval = 600

    init(persistent: Bool, defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            DefaultsKey.memorySaverEnabled: false,
            DefaultsKey.memorySaverIdleMinutes: 30,
        ])
        self.defaults = persistent ? defaults : nil
        func storedSet(_ key: String) -> Set<String> {
            persistent ? Set(defaults.stringArray(forKey: key) ?? []) : []
        }
        exemptions = storedSet(DefaultsKey.memorySaverExemptions)
        optIns = storedSet(DefaultsKey.memorySaverOptIns)
        activity = persistent
            ? defaults.data(forKey: DefaultsKey.memoryActivity)
                .flatMap { try? JSONDecoder().decode([MemoryActivity].self, from: $0) } ?? []
            : []
    }

    // MARK: Settings (read live so Settings changes apply on the next sample)

    /// Always off in UI-test runs.
    var isEnabled: Bool { defaults?.bool(forKey: DefaultsKey.memorySaverEnabled) ?? false }

    var idleMinutes: Int {
        let value = UserDefaults.standard.integer(forKey: DefaultsKey.memorySaverIdleMinutes)
        return value > 0 ? value : 30
    }

    // MARK: Tracking

    /// `containers` tie each tracker to one container instance (id + start time), so a container
    /// deleted and recreated under the same name starts from scratch.
    func record(_ samples: [ContainerStats], containers: [ContainerSummary]) {
        let identities = Dictionary(
            containers.compactMap { container in IdleTracker.identity(of: container).map { (container.id, $0) } },
            uniquingKeysWith: { first, _ in first })
        IdleTracker.record(samples, into: &trackers, identities: identities)
    }

    func idleDuration(of id: String, at now: Date = Date()) -> TimeInterval? {
        trackers[id]?.idleDuration(at: now)
    }

    func mayAttempt(_ id: String, at now: Date) -> Bool {
        guard !inFlight.contains(id) else { return false }
        guard let last = lastAttempt[id] else { return true }
        return now.timeIntervalSince(last) >= Self.retryInterval
    }

    func noteAttempt(_ ids: [String], at now: Date) {
        for id in ids { lastAttempt[id] = now }
    }

    // MARK: Exemptions

    func isExempt(_ id: String) -> Bool { exemptions.contains(id) }

    func setExempt(_ id: String, _ exempt: Bool) {
        if exempt { exemptions.insert(id) } else { exemptions.remove(id) }
        defaults?.set(exemptions.sorted(), forKey: DefaultsKey.memorySaverExemptions)
    }

    func isOptedIn(_ id: String) -> Bool { optIns.contains(id) }

    func setOptedIn(_ id: String, _ optedIn: Bool) {
        if optedIn { optIns.insert(id) } else { optIns.remove(id) }
        defaults?.set(optIns.sorted(), forKey: DefaultsKey.memorySaverOptIns)
    }

    func eligibility(of container: ContainerSummary) -> MemorySaverPolicy.Eligibility {
        MemorySaverPolicy.eligibility(of: container, exemptions: exemptions, optIns: optIns)
    }

    // MARK: Activity

    func log(_ entries: [MemoryActivity]) {
        guard !entries.isEmpty else { return }
        activity = Array((entries.sorted { $0.date > $1.date } + activity).prefix(Self.activityLimit))
        if let defaults, let data = try? JSONEncoder().encode(activity) {
            defaults.set(data, forKey: DefaultsKey.memoryActivity)
        }
    }

    func clearActivity() {
        activity = []
        defaults?.removeObject(forKey: DefaultsKey.memoryActivity)
    }
}
