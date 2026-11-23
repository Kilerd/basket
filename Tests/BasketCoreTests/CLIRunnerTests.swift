import Darwin
import Foundation
import Testing
@testable import BasketCore

@Suite("CLIRunner")
struct CLIRunnerTests {
    let shell = CLIRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))

    @Test func collectsStdoutStderrAndExitCode() async throws {
        let result = try await shell.run(["-c", "echo out; echo err >&2; exit 3"])
        #expect(result.exitCode == 3)
        #expect(result.stdoutText == "out\n")
        #expect(result.stderrText == "err\n")
    }

    @Test func largeOutputOnBothPipesDoesNotDeadlock() async throws {
        // Interleaved 4 MB on stdout and stderr: a sequential reader would block once either pipe fills.
        let script = "i=0; while [ $i -lt 8 ]; do head -c 262144 /dev/zero; head -c 262144 /dev/zero >&2; i=$((i+1)); done"
        let result = try await shell.run(["-c", script], timeout: .seconds(20))
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 8 * 262_144)
        #expect(result.stderr.count == 8 * 262_144)
    }

    @Test func childGetsSanePath() async throws {
        let runner = CLIRunner(executableURL: URL(fileURLWithPath: "/bin/sh"), environment: ["PATH": "/nonexistent"])
        let result = try await runner.run(["-c", "echo $PATH"])
        let path = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(path.hasPrefix("/opt/homebrew/bin:"))
        #expect(path.contains("/usr/bin"))
        #expect(path.hasSuffix(":/nonexistent"))
    }

    // These two prove the child is stopped, not how fast a busy machine does it: the child would
    // run 60 s, so finishing well under that is the signal (a CI runner took 5.7 s once).
    @Test func timeoutTerminatesTheProcess() async throws {
        let start = ContinuousClock.now
        await #expect {
            _ = try await shell.run(["-c", "sleep 60"], timeout: .milliseconds(300))
        } throws: { error in
            guard case BackendError.commandFailed(_, let code, let stderr) = error else { return false }
            return code == 124 && stderr.contains("Timed out")
        }
        #expect(ContinuousClock.now - start < .seconds(30))
    }

    @Test func taskCancellationTerminatesRun() async throws {
        let start = ContinuousClock.now
        let task = Task { try await shell.run(["-c", "sleep 60"], timeout: nil) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(ContinuousClock.now - start < .seconds(30))
    }

    @Test func streamSplitsOnNewlineAndCarriageReturn() async throws {
        let lines = try await collect(shell.lines(["-c", #"printf 'one\ntwo\rthree\r\n\nfour'; printf 'err\r' >&2"#]))
        #expect(lines.filter { $0 != "err" } == ["one", "two", "three", "four"])
        #expect(lines.contains("err"))
    }

    @Test func streamFailureCarriesStderr() async throws {
        await #expect {
            _ = try await collect(shell.lines(["-c", "echo progress; echo 'Error: boom' >&2; exit 2"]))
        } throws: { error in
            error as? BackendError == .commandFailed(command: "sh -c 'echo progress; echo '\\''Error: boom'\\'' >&2; exit 2'", exitCode: 2, stderr: "boom")
        }
    }

    func waitForExit(_ pid: Int32) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    @Test func breakingOutOfTheLoopKillsTheProcess() async throws {
        let first = try await collect(shell.lines(["-c", "echo $$; exec sleep 30"]), limit: 1)
        let line = try #require(first.first)
        let pid = try #require(Int32(line))
        #expect(try await waitForExit(pid))
    }

    @Test func cancellingTheConsumingTaskKillsTheProcess() async throws {
        let pids = AsyncStream<Int32>.makeStream()
        let stream = shell.lines(["-c", "echo $$; exec sleep 30"])
        let consumer = Task {
            for try await line in stream { if let pid = Int32(line) { pids.continuation.yield(pid) } }
        }
        var iterator = pids.stream.makeAsyncIterator()
        let pid = try #require(await iterator.next())
        consumer.cancel()
        #expect(try await waitForExit(pid))
        _ = await consumer.result
    }

    @Test func missingExecutableIsCLINotFound() async throws {
        let runner = CLIRunner(executableURL: URL(fileURLWithPath: "/nonexistent/container"))
        await #expect(throws: BackendError.cliNotFound(searched: ["/nonexistent/container"])) {
            _ = try await runner.run(["list"])
        }
        await #expect(throws: BackendError.cliNotFound(searched: ["/nonexistent/container"])) {
            _ = try await collect(runner.lines(["list"]))
        }
    }

    // MARK: Locating the binary

    @Test func explicitPathIsExclusive() throws {
        #expect(throws: BackendError.cliNotFound(searched: ["/nope/container"])) {
            try CLIRunner.locateContainerCLI(explicitPath: "/nope/container", environment: [:], userDefaultsPath: nil)
        }
        #expect(try CLIRunner.locateContainerCLI(explicitPath: "/bin/sh").path == "/bin/sh")
    }

    @Test func searchOrder() throws {
        let candidates = CLIRunner.containerCLICandidates(
            environment: ["BASKET_CONTAINER_CLI": "/env/container", "PATH": "/a:/opt/homebrew/bin:/b"],
            userDefaultsPath: "/defaults/container")
        #expect(candidates == [
            "/env/container", "/defaults/container", "/opt/homebrew/bin/container", "/usr/local/bin/container",
            "/a/container", "/b/container",
        ])
        // The env override wins when it exists; a bad one falls through to the next candidate.
        #expect(try CLIRunner.locateContainerCLI(environment: ["BASKET_CONTAINER_CLI": "/bin/sh"], userDefaultsPath: nil).path == "/bin/sh")
        #expect(try CLIRunner.locateContainerCLI(
            environment: ["BASKET_CONTAINER_CLI": "/nope", "PATH": ""], userDefaultsPath: "/bin/sh").path == "/bin/sh")
    }

    // MARK: Helpers

    @Test func lineSplitterKeepsPartialLines() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("ab".utf8)) == [])
        #expect(splitter.feed(Data("c\rd".utf8)) == ["abc"])
        #expect(splitter.feed(Data([0xE2, 0x82])) == [])  // split UTF-8 sequence
        #expect(splitter.feed(Data([0xAC, 0x0A])) == ["d€"])
        #expect(splitter.flush() == [])
        _ = splitter.feed(Data("tail".utf8))
        #expect(splitter.flush() == ["tail"])
    }

    /// Regression: the partial line used to be rescanned on every chunk (a 16 MB line took ~12 s).
    @Test func hugeLinesAreSplitInLinearTime() {
        var splitter = LineSplitter()
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 64 * 1024)
        let clock = ContinuousClock()
        var lines: [String] = []
        let elapsed = clock.measure {
            for _ in 0..<256 { lines += splitter.feed(chunk) }  // 16 MiB without a newline
            lines += splitter.feed(Data("\nnext\n".utf8))
        }
        #expect(elapsed < .seconds(2), "took \(elapsed)")
        #expect(lines.count == 17 && lines.last == "next")
        let pieces = lines.dropLast()
        #expect(pieces.dropLast().allSatisfy { $0.hasSuffix(LineSplitter.splitMarker) && $0.utf8.count == (1 << 20) + LineSplitter.splitMarker.utf8.count })
        #expect(pieces.reduce(0) { $0 + $1.replacingOccurrences(of: LineSplitter.splitMarker, with: "").utf8.count } == 16 << 20)
        #expect(splitter.flush().isEmpty)
    }

    @Test func splitPiecesKeepUTF8Intact() {
        var splitter = LineSplitter(maxLineBytes: 16)
        // 15 ASCII bytes, then "€" (3 bytes) would straddle the 16-byte cut.
        let lines = splitter.feed(Data(("a" + String(repeating: "b", count: 14) + "€€\n").utf8))
        #expect(lines.count == 2)
        #expect(lines[0] == "a" + String(repeating: "b", count: 14) + LineSplitter.splitMarker)
        #expect(lines[1] == "€€")
        #expect(!lines.joined().contains("\u{FFFD}"))
    }

    @Test func manyCarriageReturnsWithoutNewlines() {
        var splitter = LineSplitter()
        let progress = Data((0..<20_000).map { "\r\($0)%" }.joined().utf8)
        let clock = ContinuousClock()
        var lines: [String] = []
        let elapsed = clock.measure { lines = splitter.feed(progress) + splitter.flush() }
        #expect(elapsed < .seconds(2), "took \(elapsed)")
        #expect(lines.count == 20_000 && lines.last == "19999%")
    }

    @Test func shellQuoting() {
        #expect(shellQuote("it's") == #"'it'\''s'"#)
        #expect(shellQuoteIfNeeded("probe-alpine") == "probe-alpine")
        #expect(shellQuoteIfNeeded("my box") == "'my box'")
        #expect(shellQuoteIfNeeded("") == "''")
    }
}
