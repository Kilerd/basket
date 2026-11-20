import Foundation

/// Decides whether one container has been idle — CPU and network quiet *throughout* — and since when.
///
/// Fed with successive `container stats` samples. Each pair of samples covers an interval; the
/// interval is quiet when the average CPU over it (from the cumulative CPU counter, or the CLI's own
/// figure if that is higher) stays under `cpuPercent` and the network traffic (rx + tx) under
/// `networkBytesPerSecond`. The container is idle since the start of the current unbroken run of
/// quiet intervals. Anything Basket couldn't watch breaks the run: a gap longer than `maxSampleGap`
/// (window closed without background sampling, Mac asleep), counters going backwards (the
/// container was restarted), a counter the CLI didn't report (unknown is never "quiet"), or a new
/// container instance under the same name (`identity`).
public struct IdleTracker: Sendable, Hashable {
    public struct Thresholds: Sendable, Hashable {
        /// Percent of one core.
        public var cpuPercent: Double
        public var networkBytesPerSecond: Double
        public var maxSampleGap: TimeInterval

        public init(cpuPercent: Double = 1, networkBytesPerSecond: Double = 1024, maxSampleGap: TimeInterval = 300) {
            self.cpuPercent = cpuPercent
            self.networkBytesPerSecond = networkBytesPerSecond
            self.maxSampleGap = maxSampleGap
        }

        public static let standard = Thresholds()
    }

    /// Average activity over the most recent interval.
    public struct Activity: Sendable, Hashable {
        public var cpuPercent: Double
        public var networkBytesPerSecond: Double
    }

    public var thresholds: Thresholds
    /// The container instance this tracker watches (see `identity(of:)`); nil = not known.
    public private(set) var identity: String?
    public private(set) var lastSample: ContainerStats?
    /// Start of the current run of quiet intervals; nil while active or not yet known.
    public private(set) var idleSince: Date?
    public private(set) var lastActivity: Activity?

    public init(thresholds: Thresholds = .standard, identity: String? = nil) {
        self.thresholds = thresholds
        self.identity = identity
    }

    /// One container instance: its id plus when it started (or was created). A container deleted and
    /// recreated under the same name is a new instance and inherits nothing.
    public static func identity(of container: ContainerSummary) -> String? {
        guard let date = container.startedAt ?? container.createdAt else { return nil }
        return "\(container.id)@\(date.timeIntervalSince1970)"
    }

    /// Whether this tracker may describe `container` (unknown identities don't block).
    public func tracks(_ container: ContainerSummary) -> Bool {
        guard let identity, let current = Self.identity(of: container) else { return true }
        return identity == current
    }

    public mutating func record(_ sample: ContainerStats) {
        guard let previous = lastSample else {
            lastSample = sample
            return
        }
        let elapsed = sample.sampledAt.timeIntervalSince(previous.sampledAt)
        // Duplicate or out-of-order sample: nothing new to learn.
        guard elapsed > 0 else { return }
        lastSample = sample
        let cpuCounters = sample.cpuCounterKnown && previous.cpuCounterKnown
        let networkCounters = sample.networkCountersKnown && previous.networkCountersKnown
        let restarted = (cpuCounters && sample.cpuUsageMicros < previous.cpuUsageMicros)
            || (networkCounters && (sample.networkRxBytes < previous.networkRxBytes || sample.networkTxBytes < previous.networkTxBytes))
        // Missing counters are unknown activity, never quiet: CPU may come from the CLI's own figure,
        // network has no substitute.
        let cpuKnown = cpuCounters || sample.reportedCPUPercent != nil
        guard !restarted, elapsed <= thresholds.maxSampleGap, cpuKnown, networkCounters else {
            idleSince = nil
            lastActivity = nil
            return
        }
        let cpu = max(cpuCounters ? sample.cpuPercent(since: previous) : 0, sample.reportedCPUPercent ?? 0)
        let traffic = (sample.networkRxBytes - previous.networkRxBytes) + (sample.networkTxBytes - previous.networkTxBytes)
        let activity = Activity(cpuPercent: cpu, networkBytesPerSecond: Double(traffic) / elapsed)
        lastActivity = activity
        if activity.cpuPercent < thresholds.cpuPercent && activity.networkBytesPerSecond < thresholds.networkBytesPerSecond {
            if idleSince == nil { idleSince = previous.sampledAt }
        } else {
            idleSince = nil
        }
    }

    /// How long the container has been idle as of the last sample; nil when it is active, unknown,
    /// or the last sample is older than `maxSampleGap` at `now` (nobody is watching any more).
    public func idleDuration(at now: Date) -> TimeInterval? {
        guard let idleSince, let last = lastSample?.sampledAt,
              now.timeIntervalSince(last) <= thresholds.maxSampleGap
        else { return nil }
        return last.timeIntervalSince(idleSince)
    }

    public func isIdle(for duration: TimeInterval, at now: Date) -> Bool {
        guard let idle = idleDuration(at: now) else { return false }
        return idle >= duration
    }

    /// Feeds one `container stats` poll to per-container trackers. Containers missing from the poll
    /// (stopped or deleted) lose their tracker, so a restart starts from scratch; so does a tracker
    /// whose container instance changed (`identities`: id → `identity(of:)`, from the container list).
    public static func record(
        _ samples: [ContainerStats], into trackers: inout [String: IdleTracker], thresholds: Thresholds = .standard,
        identities: [String: String] = [:]
    ) {
        var next: [String: IdleTracker] = [:]
        for sample in samples {
            let identity = identities[sample.id]
            var tracker = next[sample.id] ?? trackers[sample.id] ?? IdleTracker(thresholds: thresholds, identity: identity)
            if let identity, tracker.identity != identity {
                tracker = IdleTracker(thresholds: thresholds, identity: identity)
            }
            tracker.record(sample)
            next[sample.id] = tracker
        }
        trackers = next
    }
}
