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

    func waitUntilReleased(_ box: WeakExecution) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while box.isAlive, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        return !box.isAlive
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
        let stream = shell.lines(["-c", "seq 0 29999"])
        try await Task.sleep(for: .seconds(1))  // let the producer run far ahead of us
        let lines = try await collect(stream)
        #expect(lines.count <= CLIRunner.lineBufferLimit)
        // The notice is the last element; the newest output line is right before it.
        let notice = try #require(lines.last)
        #expect(lines.dropLast().last == "29999")
        let received = lines.count - 1
        // Every line the buffer discarded is counted (the notice itself may push out one more).
        let reported = Int(notice.split(separator: " ")[2]) ?? -1
        #expect(notice == CLIRunner.droppedLinesNotice(reported))
        #expect(reported >= 30_000 - received - 1 && reported <= 30_000 - received + 1, "\(reported) vs \(30_000 - received)")
    }

    @Test func noNoticeWhenNothingWasDropped() async throws {
        #expect(try await collect(shell.lines(["-c", "seq 1 3"])) == ["1", "2", "3"])
    }

    // MARK: Batches

    @Test func batchesCoalesceAChattyProcess() async throws {
        var batches: [LogBatch] = []
        for try await batch in shell.lineBatches(["-c", "yes line | head -n 20000; echo done"], capacity: 50_000) {
            batches.append(batch)
        }
        let lines = batches.flatMap(\.lines)
        #expect(lines.count == 20_001 && lines.last == "done")
        #expect(batches.count < 50)  // one wake-up per interval, not one per line
        #expect(batches.allSatisfy { $0.droppedLines == 0 })
    }

    @Test func slowConsumerGetsTheNewestLinesAndADropCount() async throws {
        let stream = shell.lineBatches(["-c", "seq 0 4999"], capacity: 1_000)
        try await Task.sleep(for: .seconds(1.5))
        var batches: [LogBatch] = []
        for try await batch in stream { batches.append(batch) }
        let lines = batches.flatMap(\.lines)
        #expect(batches.allSatisfy { $0.lines.count <= 1_000 })
        #expect(lines.count + batches.reduce(0) { $0 + $1.droppedLines } == 5_000)
        #expect(lines.last == "4999")
        #expect(batches.first?.droppedLines == 4_000)
    }

    @Test func batchesHonourTheInterval() async throws {
        let start = ContinuousClock.now
        var arrivals: [Duration] = []
        for try await _ in shell.lineBatches(["-c", "i=0; while [ $i -lt 8 ]; do echo $i; sleep 0.05; i=$((i+1)); done"],
                                             interval: .milliseconds(200)) {
            arrivals.append(ContinuousClock.now - start)
        }
        #expect(arrivals.count >= 2 && arrivals.count <= 4)
        for (previous, next) in zip(arrivals, arrivals.dropFirst()) { #expect(next - previous >= .milliseconds(190)) }
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
