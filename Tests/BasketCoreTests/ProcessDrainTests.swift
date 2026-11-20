import Darwin
import Foundation
import Testing
@testable import BasketCore

/// Issue #2: a child's stdout and stderr are complete when its completion is reported, however late
/// the readers get to run, and a grandchild holding the pipes open delays completion only by the
/// grace period, without costing any output that was already in the pipes.
@Suite("Process output is drained before completion")
struct ProcessDrainTests {
    let shell = CLIRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))

    /// The readers start only after the child exited and the grandchild grace ran out: on a loaded
    /// machine a reader can be scheduled that late (the CI failure of issue #2).
    static let starvedReaders = ProcessExecution.Timing(
        grandchildGrace: .milliseconds(100), readerStartDelay: .milliseconds(800))

    static func isBoom(_ error: any Error) -> Bool {
        guard case BackendError.commandFailed(_, 2, "boom") = error else { return false }
        return true
    }

    @Test func runKeepsTheOutputOfAChildThatExitedBeforeTheReadersRan() async throws {
        let result = try await ProcessExecution.$timing.withValue(Self.starvedReaders) {
            try await shell.run(["-c", "seq 1 5000; echo 'Error: boom' >&2; exit 3"])
        }
        #expect(result.exitCode == 3)
        #expect(result.stdoutText == (1...5000).map { "\($0)\n" }.joined())
        #expect(result.stderrText == "Error: boom\n")
    }

    @Test func linesKeepTheOutputOfAChildThatExitedBeforeTheReadersRan() async throws {
        let stream = ProcessExecution.$timing.withValue(Self.starvedReaders) {
            shell.lines(["-c", "seq 1 3; echo 'Error: boom' >&2; exit 2"])
        }
        var lines: [String] = []
        await #expect {
            for try await line in stream { lines.append(line) }
        } throws: { Self.isBoom($0) }
        #expect(lines.filter { $0 != "Error: boom" } == ["1", "2", "3"])
        #expect(lines.contains("Error: boom"))
    }

    @Test func batchesKeepTheOutputOfAChildThatExitedBeforeTheReadersRan() async throws {
        let stream = ProcessExecution.$timing.withValue(Self.starvedReaders) {
            shell.lineBatches(["-c", "seq 0 4999; echo 'Error: boom' >&2; exit 2"], capacity: 10_000)
        }
        var lines: [String] = []
        await #expect {
            for try await batch in stream { lines += batch.lines }
        } throws: { Self.isBoom($0) }
        #expect(lines.filter { $0 != "Error: boom" } == (0..<5000).map(String.init))
        #expect(lines.contains("Error: boom"))
    }

    /// A background job inherits the pipes and keeps them open after the child exits, so EOF never
    /// comes: completion waits only the grace period, and everything the child wrote arrives, also
    /// when the readers had not run yet when the grace ran out.
    @Test(arguments: [ProcessExecution.Timing(grandchildGrace: .milliseconds(300)), ProcessDrainTests.starvedReaders])
    func grandchildHoldingThePipesOpenDelaysCompletionOnlyByTheGrace(timing: ProcessExecution.Timing) async throws {
        let start = ContinuousClock.now
        let stream = ProcessExecution.$timing.withValue(timing) {
            shell.lines(["-c", "sleep 60 & echo $!; seq 1 2000; echo 'Error: boom' >&2; exit 2"])
        }
        var lines: [String] = []
        await #expect {
            for try await line in stream { lines.append(line) }
        } throws: { Self.isBoom($0) }
        let elapsed = ContinuousClock.now - start
        // stdout in order; where the stderr line lands relative to it is up to the scheduler.
        let stdout = lines.filter { $0 != "Error: boom" }
        let grandchild = try #require(stdout.first.flatMap { Int32($0) })
        // Completion did not wait for the grandchild, which still holds the pipes.
        #expect(kill(grandchild, 0) == 0)
        kill(grandchild, SIGKILL)
        #expect(elapsed < .seconds(30))
        #expect(Array(stdout.dropFirst()) == (1...2000).map(String.init))
        #expect(lines.contains("Error: boom"))
    }
}
