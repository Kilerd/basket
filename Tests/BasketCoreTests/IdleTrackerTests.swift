import Foundation
import Testing
@testable import BasketCore

/// Dates don't round-trip intervals exactly; a millisecond is plenty for these checks.
private func approx(_ value: TimeInterval?, _ expected: TimeInterval) -> Bool {
    guard let value else { return false }
    return abs(value - expected) < 0.001
}

@Suite struct IdleTrackerTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A sample `seconds` after t0 with cumulative counters.
    private func sample(
        _ seconds: TimeInterval, cpuMicros: Int64 = 0, rx: Int64 = 0, tx: Int64 = 0, reported: Double? = nil, id: String = "c"
    ) -> ContainerStats {
        ContainerStats(
            id: id, sampledAt: t0.addingTimeInterval(seconds), cpuUsageMicros: cpuMicros, memoryUsageBytes: 0,
            memoryLimitBytes: 0, networkRxBytes: rx, networkTxBytes: tx, reportedCPUPercent: reported)
    }

    /// Quiet samples every `step` seconds from `start` to `end`.
    private func quiet(_ tracker: inout IdleTracker, from start: TimeInterval, to end: TimeInterval, step: TimeInterval,
                       cpuMicros: Int64 = 0, rx: Int64 = 0) {
        var s = start
        while s <= end {
            tracker.record(sample(s, cpuMicros: cpuMicros, rx: rx))
            s += step
        }
    }

    @Test func oneSampleIsNotEnough() {
        var tracker = IdleTracker()
        tracker.record(sample(0, reported: 0))
        #expect(tracker.idleDuration(at: t0) == nil)
        #expect(!tracker.isIdle(for: 0, at: t0))
    }

    @Test func quietSamplesAccumulateIdleTime() {
        var tracker = IdleTracker()
        quiet(&tracker, from: 0, to: 30 * 60, step: 60)
        #expect(tracker.idleSince == t0)
        #expect(approx(tracker.idleDuration(at: t0.addingTimeInterval(30 * 60 + 5)), 30 * 60))
        #expect(tracker.isIdle(for: 30 * 60, at: t0.addingTimeInterval(30 * 60)))
        #expect(!tracker.isIdle(for: 31 * 60, at: t0.addingTimeInterval(30 * 60)))
    }

    @Test func belowThresholdActivityStillCountsAsIdle() {
        var tracker = IdleTracker()
        // 0.5 % of a core (0.3 s CPU per minute) and 600 B/s of network.
        for minute in 0...20 {
            let m = Int64(minute)
            tracker.record(sample(Double(minute) * 60, cpuMicros: m * 300_000, rx: m * 30_000, tx: m * 6_000))
        }
        #expect(approx(tracker.idleDuration(at: t0.addingTimeInterval(20 * 60)), 20 * 60))
        #expect(tracker.lastActivity.map { abs($0.cpuPercent - 0.5) < 1e-9 } == true)
        #expect(tracker.lastActivity?.networkBytesPerSecond == 600)
    }

    @Test func cpuBurstResetsIdleTime() {
        var tracker = IdleTracker()
        quiet(&tracker, from: 0, to: 600, step: 60)
        // 3 s of CPU in one minute = 5 %.
        tracker.record(sample(660, cpuMicros: 3_000_000))
        #expect(tracker.idleDuration(at: t0.addingTimeInterval(660)) == nil)
        quiet(&tracker, from: 720, to: 900, step: 60, cpuMicros: 3_000_000)
        #expect(tracker.idleSince == t0.addingTimeInterval(660))
        #expect(approx(tracker.idleDuration(at: t0.addingTimeInterval(900)), 240))
    }

    @Test func networkTrafficResetsIdleTime() {
        var tracker = IdleTracker()
        quiet(&tracker, from: 0, to: 300, step: 60)
        // 120 KB in a minute = 2 KB/s.
        tracker.record(sample(360, rx: 60_000, tx: 60_000))
        #expect(tracker.idleSince == nil)
        #expect(tracker.lastActivity?.networkBytesPerSecond == 2_000)
    }

    @Test func reportedCPUAboveThresholdCountsAsActive() {
        var tracker = IdleTracker()
        tracker.record(sample(0, reported: 0))
        // Counter unchanged, but the CLI's own 2 s window saw 4 %.
        tracker.record(sample(3, reported: 4))
        #expect(tracker.idleSince == nil)
        tracker.record(sample(6, reported: 0.2))
        #expect(tracker.idleSince == t0.addingTimeInterval(3))
    }

    @Test func longGapBreaksTheRun() {
        var tracker = IdleTracker()
        quiet(&tracker, from: 0, to: 600, step: 60)
        // Mac asleep for an hour: counters didn't move, but nobody watched.
        tracker.record(sample(4200))
        #expect(tracker.idleSince == nil)
        tracker.record(sample(4260))
        #expect(tracker.idleSince == t0.addingTimeInterval(4200))
        #expect(approx(tracker.idleDuration(at: t0.addingTimeInterval(4260)), 60))
    }

    @Test func staleTrackerReportsNothing() {
        var tracker = IdleTracker()
        quiet(&tracker, from: 0, to: 600, step: 60)
        #expect(approx(tracker.idleDuration(at: t0.addingTimeInterval(600 + 299)), 600))
        #expect(tracker.idleDuration(at: t0.addingTimeInterval(600 + 301)) == nil)
    }

    @Test func countersGoingBackwardsMeanARestart() {
        var tracker = IdleTracker()
        quiet(&tracker, from: 0, to: 600, step: 60, cpuMicros: 5_000_000, rx: 90_000)
        tracker.record(sample(660, cpuMicros: 100, rx: 10))
        #expect(tracker.idleSince == nil)
    }

    @Test func duplicateSamplesAreIgnored() {
        var tracker = IdleTracker()
        quiet(&tracker, from: 0, to: 120, step: 60)
        tracker.record(sample(120, cpuMicros: 99_000_000))
        tracker.record(sample(60, cpuMicros: 99_000_000))
        #expect(approx(tracker.idleDuration(at: t0.addingTimeInterval(120)), 120))
    }

    @Test func customThresholds() {
        var tracker = IdleTracker(thresholds: .init(cpuPercent: 10, networkBytesPerSecond: 10_000, maxSampleGap: 30))
        tracker.record(sample(0))
        tracker.record(sample(20, cpuMicros: 1_000_000, rx: 100_000))  // 5 %, 5 KB/s
        #expect(tracker.idleSince == t0)
        tracker.record(sample(60, cpuMicros: 1_000_000, rx: 100_000))  // 40 s gap > 30 s
        #expect(tracker.idleSince == nil)
    }

    @Test func recordPollKeepsOnlyLiveContainers() {
        var trackers: [String: IdleTracker] = [:]
        IdleTracker.record([sample(0, id: "a"), sample(0, id: "b")], into: &trackers)
        IdleTracker.record([sample(3, id: "a"), sample(3, id: "b")], into: &trackers)
        #expect(trackers["a"]?.idleSince == t0)
        // b stopped: its tracker goes; when it comes back it starts from scratch.
        IdleTracker.record([sample(6, id: "a")], into: &trackers)
        #expect(trackers["b"] == nil)
        IdleTracker.record([sample(9, id: "a"), sample(9, id: "b")], into: &trackers)
        #expect(approx(trackers["a"]?.idleDuration(at: t0.addingTimeInterval(9)), 9))
        #expect(trackers["b"]?.idleDuration(at: t0.addingTimeInterval(9)) == nil)
    }
}

@Suite struct MemorySaverPolicyTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func trackers(idleMinutes: [String: Int], now: TimeInterval) -> [String: IdleTracker] {
        var result: [String: IdleTracker] = [:]
        for (id, minutes) in idleMinutes {
            var tracker = IdleTracker()
            let start = now - Double(minutes) * 60
            tracker.record(ContainerStats(id: id, sampledAt: t0.addingTimeInterval(start), cpuUsageMicros: 0,
                                          memoryUsageBytes: 0, memoryLimitBytes: 0))
            tracker.record(ContainerStats(id: id, sampledAt: t0.addingTimeInterval(now), cpuUsageMicros: 0,
                                          memoryUsageBytes: 0, memoryLimitBytes: 0))
            result[id] = tracker
        }
        return result
    }

    @Test func picksIdleRunningContainersOnly() {
        let now: TimeInterval = 7200
        func running(_ id: String, removeOnStop: Bool? = false, labels: [String: String] = [:]) -> ContainerSummary {
            ContainerSummary(id: id, imageReference: "alpine", state: .running, labels: labels, removeOnStop: removeOnStop)
        }
        let containers = [
            running("web"),
            running("db"),
            running("exempt"),
            ContainerSummary(id: "gone", imageReference: "redis", state: .stopped, removeOnStop: false),
            running("dev-box-32cb51", labels: ["com.apple.container.plugin": "machine"]),
            running("new"),
            running("scratch", removeOnStop: true),
            running("unknown", removeOnStop: nil),
            running("opted", removeOnStop: nil),
        ]
        // Short gaps only: each tracker gets two samples `minutes` apart, which must fit `maxSampleGap`.
        var all = trackers(idleMinutes: [
            "web": 4, "db": 2, "exempt": 4, "gone": 4, "dev-box-32cb51": 4, "scratch": 4, "unknown": 4, "opted": 3,
        ], now: now)
        all["new"] = IdleTracker()
        let at = t0.addingTimeInterval(now)
        let idle = MemorySaverPolicy.idleContainers(containers, trackers: all, exemptions: ["exempt"], optIns: ["opted"], at: at)
        #expect(idle.map(\.id) == ["web", "opted", "db"])
        #expect(approx(idle.first?.idleFor, 240))
        let stop = MemorySaverPolicy.containersToStop(
            containers, trackers: all, exemptions: ["exempt"], optIns: ["opted"], idleFor: 180, at: at)
        #expect(stop == ["web", "opted"])
    }

    @Test func eligibilityExplainsWhy() {
        func c(_ id: String, _ removeOnStop: Bool?, labels: [String: String] = [:]) -> ContainerSummary {
            ContainerSummary(id: id, imageReference: "alpine", state: .running, labels: labels, removeOnStop: removeOnStop)
        }
        let policy = { (container: ContainerSummary) in
            MemorySaverPolicy.eligibility(of: container, exemptions: ["x"], optIns: ["u2"])
        }
        #expect(policy(c("a", false)) == .eligible)
        #expect(policy(c("x", false)) == .exempt)
        #expect(policy(c("rm", true)) == .removedOnStop)
        // Opting in never overrides a known --rm.
        #expect(MemorySaverPolicy.eligibility(of: c("rm", true), exemptions: [], optIns: ["rm"]) == .removedOnStop)
        #expect(policy(c("u", nil)) == .removalUnknown)
        #expect(policy(c("u2", nil)) == .eligible)
        #expect(policy(c("m", false, labels: ["com.apple.container.plugin": "machine"])) == .machine)
    }

    @Test func demoFixtureHasOneIdleContainer() async throws {
        let backend = FixtureBackend(directory: TestFixtures.set("demo"))
        var trackers: [String: IdleTracker] = [:]
        IdleTracker.record(try await backend.containerStats(), into: &trackers)
        try await Task.sleep(for: .milliseconds(20))
        IdleTracker.record(try await backend.containerStats(), into: &trackers)
        let idle = MemorySaverPolicy.idleContainers(
            try await backend.listContainers(), trackers: trackers, exemptions: [], at: Date())
        #expect(idle.map(\.id) == ["web"])
    }
}
