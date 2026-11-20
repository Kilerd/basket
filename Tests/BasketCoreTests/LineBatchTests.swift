import Darwin
import Foundation
import Testing
@testable import BasketCore

@Suite("CLIRunner stream lifetime and batching")
struct LineBatchTests {
    let shell = CLIRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))

    func waitForExit(_ pid: Int32) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    func waitUntilReleased(_ box: WeakExecution, within limit: Duration = .seconds(5)) async throws -> Bool {
        let deadline = ContinuousClock.now + limit
        while box.isAlive, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return !box.isAlive
    }

    /// An execution is released only after it completed, i.e. after all of its output went into the
    /// stream: a consumer starting then has fallen behind the whole output, on any machine.
    func waitUntilFinished(_ box: WeakExecution) async throws -> Bool {
        try await waitUntilReleased(box, within: .seconds(60))
    }

    /// Reads one line through a bare iterator, then drops it (and the stream with it).
    func firstLineThenDrop(_ stream: AsyncThrowingStream<String, Error>) async throws -> Int32? {
        var iterator = stream.makeAsyncIterator()
        return try await iterator.next().flatMap { Int32($0) }
    }

    @Test func droppingTheIteratorKillsTheProcessAndReleasesIt() async throws {
        let box = WeakExecution()
        let pid = try await ProcessExecution.$launchObserver.withValue({ box.set($0) }) {
            try await firstLineThenDrop(shell.lines(["-c", "echo $$; exec sleep 30"]))
        }
        #expect(try await waitForExit(try #require(pid)))
        #expect(try await waitUntilReleased(box))
    }

    @Test func finishedStreamDoesNotKeepTheExecutionAlive() async throws {
        let box = WeakExecution()
        let stream = ProcessExecution.$launchObserver.withValue({ box.set($0) }) {
            shell.lines(["-c", "echo one; echo two"])
        }
        #expect(try await collect(stream) == ["one", "two"])
        // The stream value is still in scope: nothing may still reference the finished process.
        #expect(try await waitUntilReleased(box))
        withExtendedLifetime(stream) {}
    }

    @Test func linesBufferIsBoundedAndDropsAreCounted() async throws {
        let box = WeakExecution()
        let stream = ProcessExecution.$launchObserver.withValue({ box.set($0) }) { shell.lines(["-c", "seq 0 29999"]) }
        // Read nothing until the process finished: all 30,000 lines had to go through the buffer.
        #expect(try await waitUntilFinished(box))
        let lines = try await collect(stream)
        #expect(lines.count == CLIRunner.lineBufferLimit)
        // The newest lines survive; the notice is the last element and pushed out one more line.
        #expect(Array(lines.dropLast()) == (20_001...29_999).map(String.init))
        // Every line the buffer discarded is counted.
        #expect(lines.last == CLIRunner.droppedLinesNotice(30_000 - CLIRunner.lineBufferLimit))
    }

    @Test func noNoticeWhenNothingWasDropped() async throws {
        #expect(try await collect(shell.lines(["-c", "seq 1 3"])) == ["1", "2", "3"])
    }

    // MARK: Batches

    @Test func batchesCoalesceAChattyProcess() async throws {
        let start = ContinuousClock.now
        var batches: [LogBatch] = []
        for try await batch in shell.lineBatches(["-c", "yes line | head -n 20000; echo done"], capacity: 50_000) {
            batches.append(batch)
        }
        let elapsed = ContinuousClock.now - start
        let lines = batches.flatMap(\.lines)
        #expect(lines.count == 20_001 && lines.last == "done")
        // One wake-up per interval (100 ms), not one per line or per read, however long the run took.
        #expect(batches.count <= Int(elapsed / .milliseconds(100)) + 1, "\(batches.count) batches in \(elapsed)")
        #expect(batches.allSatisfy { $0.droppedLines == 0 })
    }

    @Test func slowConsumerGetsTheNewestLinesAndADropCount() async throws {
        let box = WeakExecution()
        let stream = ProcessExecution.$launchObserver.withValue({ box.set($0) }) {
            shell.lineBatches(["-c", "seq 0 4999"], capacity: 1_000)
        }
        // Read nothing until the process finished: the consumer is behind by all 5,000 lines.
        #expect(try await waitUntilFinished(box))
        var batches: [LogBatch] = []
        for try await batch in stream { batches.append(batch) }
        #expect(batches.count == 1)
        #expect(batches.flatMap(\.lines) == (4_000..<5_000).map(String.init))
        #expect(batches.first?.droppedLines == 4_000)
    }

    @Test func batchesHonourTheInterval() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let go = directory.url.appendingPathComponent("go").path
        // Four lines, then four more only once the test has received a batch (or after ~10 s): at
        // least two batches however slow the machine is.
        let script = """
            i=0; while [ $i -lt 4 ]; do echo $i; sleep 0.05; i=$((i+1)); done
            n=0; while [ ! -e "$1" ] && [ $n -lt 1000 ]; do sleep 0.01; n=$((n+1)); done
            while [ $i -lt 8 ]; do echo $i; sleep 0.05; i=$((i+1)); done
            """
        let interval = Duration.milliseconds(200)
        var iterator = shell.lineBatches(["-c", script, "sh", go], interval: interval).makeAsyncIterator()
        var lines: [String] = []
        var asked: [ContinuousClock.Instant] = []
        var arrived: [ContinuousClock.Instant] = []
        while true {
            asked.append(.now)
            guard let batch = try await iterator.next() else { break }
            arrived.append(.now)
            lines += batch.lines
            if arrived.count == 1 { FileManager.default.createFile(atPath: go, contents: nil) }
        }
        #expect(lines == (0..<8).map(String.init))
        #expect(arrived.count >= 2)
        // A batch is handed over at least `interval` after the previous one was, which happened after
        // the consumer asked for it. (Arrival-to-arrival gaps can be shorter on a loaded machine when
        // the consumer itself resumes late.)
        for index in arrived.indices.dropFirst() {
            #expect(arrived[index] - asked[index - 1] >= interval, "batch \(index)")
        }
        // So at most one batch per interval, however long the run took.
        if let first = asked.first, let last = arrived.last {
            #expect(arrived.count <= Int((last - first) / interval) + 1)
        }
    }

    @Test func droppingTheBatchStreamKillsTheProcess() async throws {
        let box = WeakExecution()
        let pid: Int32? = try await ProcessExecution.$launchObserver.withValue({ box.set($0) }) {
            var iterator = shell.lineBatches(["-c", "echo $$; exec sleep 30"]).makeAsyncIterator()
            return try await iterator.next()?.lines.first.flatMap { Int32($0) }
        }
        #expect(try await waitForExit(try #require(pid)))
        #expect(try await waitUntilReleased(box))
    }

    @Test func cancellingTheBatchConsumerKillsTheProcess() async throws {
        let pids = AsyncStream<Int32>.makeStream()
        let stream = shell.lineBatches(["-c", "echo $$; exec sleep 30"])
        let consumer = Task {
            for try await batch in stream { for line in batch.lines { if let pid = Int32(line) { pids.continuation.yield(pid) } } }
        }
        var iterator = pids.stream.makeAsyncIterator()
        let pid = try #require(await iterator.next())
        consumer.cancel()
        #expect(try await waitForExit(pid))
        _ = await consumer.result
    }

    @Test func batchFailureCarriesStderrAfterTheLines() async throws {
        var lines: [String] = []
        await #expect {
            for try await batch in shell.lineBatches(["-c", "echo progress; echo 'Error: boom' >&2; exit 2"]) {
                lines += batch.lines
            }
        } throws: { error in
            guard case BackendError.commandFailed(_, 2, "boom") = error else { return false }
            return true
        }
        #expect(lines.contains("progress"))
    }

    @Test func defaultFollowLogBatchesWrapsFollowLogs() async throws {
        let backend = FixtureBackend(directory: TestFixtures.set("demo"))
        let expected = try await backend.logs("web", tail: 200).split(separator: "\n").map(String.init)
        var iterator = backend.followLogBatches("web").makeAsyncIterator()
        var lines: [String] = []
        var batches = 0
        while lines.count < expected.count, let batch = try await iterator.next() {
            lines += batch.lines
            batches += 1
        }
        #expect(lines == expected)
        #expect(batches <= 3)
    }
}

final class WeakExecution: @unchecked Sendable {
    private let lock = NSLock()
    private weak var execution: ProcessExecution?
    func set(_ execution: ProcessExecution) { lock.withLock { self.execution = execution } }
    var isAlive: Bool { lock.withLock { execution != nil } }
    var pid: Int32? { lock.withLock { execution?.processIdentifier } }
}
