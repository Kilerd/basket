import Darwin
import Foundation
import Testing
@testable import BasketCore

/// Regression tests for the pre-release review: restarts per container, unknown machine images,
/// idle trackers per container instance, and stats counters the CLI didn't report.
@Suite("Restart per container")
struct MemoryReclaimTests {
    /// Fake `container`: state files in `state/`; `stop` deletes `*-temp` (an unknown `--rm` container).
    func fakeCLI(_ directory: TemporaryDirectory, containers: [String: String]) throws -> CLIBackend {
        let state = directory.url.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        for (id, status) in containers { try Data(status.utf8).write(to: state.appendingPathComponent(id)) }
        let log = shellQuote(directory.url.appendingPathComponent("calls.log").path)
        let dir = shellQuote(state.path)
        let script = try directory.script("container", #"""
            echo "$*" >> \#(log)
            case "$1" in
              list)
                printf '['; sep=''
                for f in \#(dir)/*; do
                  [ -e "$f" ] || continue
                  id=$(basename "$f")
                  printf '%s{"id":"%s","configuration":{"id":"%s"},"status":{"state":"%s"}}' "$sep" "$id" "$id" "$(cat "$f")"
                  sep=','
                done
                printf ']\n' ;;
              stop)
                shift
                for id in "$@"; do
                  case "$id" in *-temp) rm -f \#(dir)/"$id" ;; *) printf stopped > \#(dir)/"$id" ;; esac
                done ;;
              start)
                if [ -e \#(dir)/"$2" ]; then printf running > \#(dir)/"$2"; else echo "Error: container $2 not found" >&2; exit 1; fi ;;
              *) echo "Error: unexpected $*" >&2; exit 1 ;;
            esac
            """#)
        return CLIBackend(cliPath: script)
    }

    func calls(_ directory: TemporaryDirectory) -> [String] {
        ((try? String(contentsOf: directory.url.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.hasPrefix("list") }
    }

    /// Regression: all were stopped, then all started; the first failing start left the rest down.
    @Test func oneFailureNeverLeavesTheOthersDown() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let backend = try fakeCLI(directory, containers: [
            "basket-test-u-temp": "running", "basket-test-u-a": "running", "basket-test-u-b": "running",
        ])
        let ids = ["basket-test-u-temp", "basket-test-u-gone", "basket-test-u-a", "basket-test-u-b"]
        let outcome = await MemoryReclaim.restart(ids, using: backend)
        #expect(outcome.restarted == ["basket-test-u-a", "basket-test-u-b"])
        #expect(outcome.failed == [.init(id: "basket-test-u-temp", reason: "stopping deleted it (it was probably started with --rm)")])
        #expect(outcome.skipped == [.init(id: "basket-test-u-gone", reason: "it no longer exists")])
        // Each container is stopped and started before the next one is touched.
        #expect(calls(directory) == [
            "stop basket-test-u-temp", "start basket-test-u-temp",
            "stop basket-test-u-a", "start basket-test-u-a", "stop basket-test-u-b", "start basket-test-u-b",
        ])
        let containers = try await backend.listContainers()
        #expect(containers.filter { $0.state == .running }.map(\.id).sorted() == ["basket-test-u-a", "basket-test-u-b"])
        let report = try #require(outcome.report)
        #expect(report.title == "1 of 4 containers couldn't be restarted")
        #expect(report.detail.contains("basket-test-u-gone was skipped: it no longer exists"))
    }

    @Test func reclaimSkipsStoppedContainersButAPlainRestartStartsThem() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let backend = try fakeCLI(directory, containers: ["basket-test-u-s": "stopped"])
        let reclaim = await MemoryReclaim.restart(["basket-test-u-s"], using: backend, onlyRunning: true)
        #expect(reclaim.skipped == [.init(id: "basket-test-u-s", reason: "it is no longer running")])
        #expect(calls(directory).isEmpty)
        let restart = await MemoryReclaim.restart(["basket-test-u-s"], using: backend, onlyRunning: false)
        #expect(restart.restarted == ["basket-test-u-s"] && calls(directory) == ["start basket-test-u-s"])
        #expect(restart.report == nil)
    }

    /// `--rm` is re-read right before the stop: a container known to be removed on stop is never stopped.
    @Test func removeOnStopContainersAreSkipped() async throws {
        let backend = FixtureBackend(directory: TestFixtures.set("demo"))
        let id = try await backend.run(RunSpec(image: "docker.io/library/alpine:latest", name: "basket-test-u-rm", removeOnExit: true))
        let outcome = await MemoryReclaim.restart([id], using: backend)
        #expect(outcome.skipped == [.init(id: id, reason: "it was started with --rm, so stopping would delete it")])
        #expect(try await backend.listContainers().first { $0.id == id }?.state == .running)
    }
}

@Suite("Image usage when a machine's image is unknown")
struct UnknownMachineImageTests {
    let images = [
        ImageSummary(reference: "docker.io/library/alpine:latest", digest: "sha256:a"),
        ImageSummary(reference: "docker.io/library/ubuntu:24.04", digest: "sha256:u"),
    ]

    /// Regression: a machine whose `machine inspect` failed had no image, so its base image looked unused.
    @Test func noImageIsUnusedWhileAMachineImageIsUnknown() {
        let known = ImageUsage(containers: [], machines: [MachineSummary(id: "dev", image: "docker.io/library/ubuntu:24.04", state: .running)])
        #expect(known.unknownReason == nil)
        #expect(known.unused(images).map(\.reference) == ["docker.io/library/alpine:latest"])

        let unknown = ImageUsage(containers: [], machines: [MachineSummary(id: "dev", image: "", state: .running)])
        #expect(unknown.unknownReason?.contains("“dev”") == true)
        #expect(unknown.unused(images).isEmpty)

        let unlisted = ImageUsage(containers: [], machines: [], machinesKnown: false)
        #expect(unlisted.unknownReason != nil && unlisted.unused(images).isEmpty)
    }

    @Test func approvedImageDeletionsAreDroppedWhileUsageIsUnknown() {
        let approved = ApprovedDeletion(images: ["docker.io/library/alpine:latest"])
        let fine = approved.revalidated(containers: [], machines: [], images: images, volumes: [])
        #expect(fine.images == ["docker.io/library/alpine:latest"])
        let unknownMachine = approved.revalidated(
            containers: [], machines: [MachineSummary(id: "dev", image: "", state: .stopped)], images: images, volumes: [])
        #expect(unknownMachine.images.isEmpty)
        let unlisted = approved.revalidated(containers: [], machines: [], images: images, volumes: [], machinesKnown: false)
        #expect(unlisted.images.isEmpty)
    }

    /// The CLI backend leaves a machine's image empty when `machine inspect` fails or times out.
    @Test func failedMachineInspectLeavesTheImageUnknown() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let list = try TestFixtures.real("machine-list.json")
        let script = try directory.script("container", """
            case "$1 $2" in
              "machine list") echo \(shellQuote(String(decoding: list, as: UTF8.self))) ;;
              "machine inspect") echo "Error: internal error" >&2; exit 1 ;;
              *) echo "Error: unexpected $*" >&2; exit 1 ;;
            esac
            """)
        let machines = try await CLIBackend(cliPath: script).listMachines()
        #expect(machines.count == 1 && machines[0].image.isEmpty)
        #expect(ImageUsage(containers: [], machines: machines).unused(images).isEmpty)
    }
}

@Suite("Idle tracking: instances and unknown counters")
struct IdleTrackingReviewTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func sample(_ seconds: TimeInterval, id: String = "web", cpu: Bool = true, network: Bool = true, reported: Double? = nil) -> ContainerStats {
        ContainerStats(
            id: id, sampledAt: t0.addingTimeInterval(seconds), cpuUsageMicros: 0, memoryUsageBytes: 0, memoryLimitBytes: 0,
            reportedCPUPercent: reported, cpuCounterKnown: cpu, networkCountersKnown: network)
    }

    /// Regression: trackers were keyed on the name only, so a recreated container inherited idle time.
    @Test func aRecreatedContainerStartsFromScratch() {
        var trackers: [String: IdleTracker] = [:]
        let first = ContainerSummary(id: "web", imageReference: "nginx", state: .running, startedAt: t0)
        let firstID = [first.id: IdleTracker.identity(of: first)!]
        for s in stride(from: 0.0, through: 600, by: 60) {
            IdleTracker.record([sample(s)], into: &trackers, identities: firstID)
        }
        #expect((trackers["web"]?.idleDuration(at: t0.addingTimeInterval(600)) ?? 0) >= 540)

        let recreated = ContainerSummary(id: "web", imageReference: "nginx", state: .running, startedAt: t0.addingTimeInterval(610))
        // Before any new sample, the old tracker must not apply to the new instance.
        #expect(trackers["web"]?.tracks(recreated) == false)
        let idle = MemorySaverPolicy.idleContainers(
            [recreated], trackers: trackers, exemptions: [], optIns: ["web"], at: t0.addingTimeInterval(615))
        #expect(idle.isEmpty)

        IdleTracker.record([sample(620)], into: &trackers, identities: [recreated.id: IdleTracker.identity(of: recreated)!])
        #expect(trackers["web"]?.tracks(recreated) == true)
        #expect(trackers["web"]?.idleDuration(at: t0.addingTimeInterval(620)) == nil, "one sample of the new instance")
    }

    /// Regression: missing CPU/network counters defaulted to 0 and looked idle.
    @Test func unknownCountersAreNeverIdle() {
        for (cpu, network, reported) in [(false, true, nil), (true, false, 0.0), (false, false, 0.0)] as [(Bool, Bool, Double?)] {
            var tracker = IdleTracker()
            for s in stride(from: 0.0, through: 600, by: 60) { tracker.record(sample(s, cpu: cpu, network: network, reported: reported)) }
            #expect(tracker.idleDuration(at: t0.addingTimeInterval(600)) == nil, "cpu \(cpu) network \(network)")
        }
        // The CLI's own CPU figure stands in for a missing CPU counter.
        var tracker = IdleTracker()
        for s in stride(from: 0.0, through: 600, by: 60) { tracker.record(sample(s, cpu: false, reported: 0.1)) }
        #expect((tracker.idleDuration(at: t0.addingTimeInterval(600)) ?? 0) >= 540)
    }

    @Test func rawStatsWithoutCountersAreMarkedUnknown() throws {
        let json = #"[{"id":"web","memoryUsageBytes":1048576,"memoryLimitBytes":268435456}]"#
        let raw = try RawJSON.decodeList(RawStats.self, from: Data(json.utf8), command: "stats")
        let stats = try #require(raw.first?.toStats(sampledAt: Date()))
        #expect(!stats.cpuCounterKnown && !stats.networkCountersKnown)
        let full = try #require(try RawJSON.decodeList(RawStats.self, from: TestFixtures.real("stats.json"), command: "stats").first?
            .toStats(sampledAt: Date()))
        #expect(full.cpuCounterKnown && full.networkCountersKnown)
    }
}

@Suite("Children don't outlive Basket")
struct ChildTerminationTests {
    /// Quitting terminates every child still running (here: only the one this test started, so
    /// concurrently running tests keep theirs).
    @Test func terminateAllStopsRunningChildren() async throws {
        let box = WeakExecution()
        let shell = CLIRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
        let stream = ProcessExecution.$launchObserver.withValue({ box.set($0) }) {
            shell.lines(["-c", "echo started; exec sleep 30"])
        }
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == "started")
        let pid = try #require(box.pid)
        #expect(kill(pid, 0) == 0)
        let signalled = ProcessExecution.terminateAll(grace: 2) { $0.processIdentifier == pid }
        #expect(signalled == 1)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        withExtendedLifetime(stream) {}
    }
}

/// Measurement (opt in with `BASKET_MEASURE_WAKEUPS=1`, run alone): following a silent process must
/// not wake Basket ~40 times a second (the old DispatchIO interval timer did, per stream).
@Suite("Idle log follow wakeups", .enabled(if: ProcessInfo.processInfo.environment["BASKET_MEASURE_WAKEUPS"] == "1"))
struct IdleFollowWakeupTests {
    static func wakeups() -> UInt64 {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? info.ri_interrupt_wkups + info.ri_pkg_idle_wkups : 0
    }

    @Test func aSilentFollowedProcessCostsAlmostNoWakeups() async throws {
        let shell = CLIRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
        let stream = shell.lineBatches(["-c", "echo ready; exec sleep 8"])
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        try await Task.sleep(for: .milliseconds(500))
        let before = Self.wakeups()
        try await Task.sleep(for: .seconds(5))
        let perSecond = Double(Self.wakeups() - before) / 5
        print("[wakeups] \(perSecond) per second while following a silent process")
        #expect(perSecond < 20)
        withExtendedLifetime(stream) {}
    }
}
