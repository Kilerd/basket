import Foundation

/// Result of a finished CLI invocation (non-zero exit codes are returned, not thrown).
public struct CLIResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs the `container` CLI (or any executable) as a child process.
public struct CLIRunner: Sendable {
    public let executableURL: URL
    public let environment: [String: String]

    /// Directories a GUI app needs on PATH (it does not inherit the login shell's PATH).
    public static let standardPathDirectories = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    public init(executableURL: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executableURL = executableURL
        self.environment = Self.childEnvironment(from: environment)
    }

    /// Finds the `container` binary: `explicitPath` if given (exclusively), otherwise
    /// `BASKET_CONTAINER_CLI` → `UserDefaults` `containerCLIPath` → `/opt/homebrew/bin/container`
    /// → `/usr/local/bin/container` → each `$PATH` entry.
    public static func locateContainerCLI(
        explicitPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaultsPath: String? = UserDefaults.standard.string(forKey: "containerCLIPath")
    ) throws -> URL {
        let candidates = explicitPath.map { [$0] }
            ?? containerCLICandidates(environment: environment, userDefaultsPath: userDefaultsPath)
        let fileManager = FileManager.default
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return URL(fileURLWithPath: path)
            }
        }
        throw BackendError.cliNotFound(searched: candidates)
    }

    static func containerCLICandidates(environment: [String: String], userDefaultsPath: String?) -> [String] {
        var candidates: [String] = []
        if let path = environment["BASKET_CONTAINER_CLI"], !path.isEmpty { candidates.append(path) }
        if let path = userDefaultsPath, !path.isEmpty { candidates.append(path) }
        candidates += ["/opt/homebrew/bin/container", "/usr/local/bin/container"]
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            candidates.append("\(directory)/container")
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    static func childEnvironment(from base: [String: String]) -> [String: String] {
        var environment = base
        let existing = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        let merged = standardPathDirectories + existing.filter { !standardPathDirectories.contains($0) }
        environment["PATH"] = merged.joined(separator: ":")
        environment["NO_COLOR"] = "1"
        return environment
    }

    /// Human-readable command line for error messages.
    public func commandLine(_ arguments: [String]) -> String {
        ([executableURL.lastPathComponent] + arguments.map { shellQuoteIfNeeded($0) }).joined(separator: " ")
    }

    /// Runs to completion, collecting stdout and stderr. Throws `BackendError.commandFailed` (exit 124)
    /// on timeout and `BackendError.cliNotFound` if the executable can't be launched; cancelling the
    /// calling task terminates the process.
    public func run(_ arguments: [String], timeout: Duration? = .seconds(30)) async throws -> CLIResult {
        let output = OutputBuffer()
        let box = ContinuationBox<ProcessExecution.Completion>()
        let execution: ProcessExecution
        do {
            execution = try ProcessExecution(
                executableURL: executableURL, arguments: arguments, environment: environment,
                onOutput: { stream, data in output.append(stream, data) },
                onComplete: { completion in box.resume(completion) })
        } catch {
            throw BackendError.cliNotFound(searched: [executableURL.path])
        }

        let timeoutTask = timeout.map { limit in
            Task {
                try await Task.sleep(for: limit)
                output.markTimedOut()
                execution.terminate()
            }
        }
        defer { timeoutTask?.cancel() }

        let completion = await withTaskCancellationHandler {
            await box.value()
        } onCancel: {
            execution.terminate()
        }

        try Task.checkCancellation()
        let (stdout, stderr, timedOut) = output.snapshot()
        if timedOut, completion.wasTerminated {
            let seconds = timeout.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 } ?? 0
            let partial = String(decoding: stderr, as: UTF8.self)
            throw BackendError.commandFailed(
                command: commandLine(arguments), exitCode: 124,
                stderr: "Timed out after \(seconds.formatted()) s. \(partial)")
        }
        return CLIResult(exitCode: completion.exitCode, stdout: stdout, stderr: stderr)
    }

    /// Lines `lines(_:)` buffers for a consumer that falls behind before dropping the oldest.
    static let lineBufferLimit = 10_000

    /// The last line of a `lines(_:)` stream whose consumer fell so far behind that lines were dropped.
    public static func droppedLinesNotice(_ count: Int) -> String {
        "[Basket dropped \(count) earlier line\(count == 1 ? "" : "s"): the reader fell behind]"
    }

    /// Stops every child process Basket started that is still running (when the app quits: children
    /// of a GUI app keep running after it exits). Returns how many were signalled.
    @discardableResult
    public static func terminateAllChildren(grace: TimeInterval = 0.5) -> Int {
        ProcessExecution.terminateAll(grace: grace)
    }

    /// Streams stdout and stderr as lines (split on `\n` and `\r`). Finishes when the process exits;
    /// a non-zero exit finishes with the classified error. The process is terminated when the consuming
    /// task is cancelled or when the stream and its iterator are released (e.g. `break` out of a
    /// `for try await` over the returned stream). A stream kept in a variable after `break` keeps the
    /// process alive until it is released: AsyncStream can't observe an abandoned iterator.
    public func lines(_ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        let command = commandLine(arguments)
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(Self.lineBufferLimit)) { continuation in
            let state = StreamState()
            do {
                let execution = try ProcessExecution(
                    executableURL: executableURL, arguments: arguments, environment: environment,
                    onOutput: { stream, data in
                        for line in state.feed(stream, data) { state.count(continuation.yield(line)) }
                    },
                    onComplete: { completion in
                        for line in state.flush() { state.count(continuation.yield(line)) }
                        // Say so when the consumer lost lines (the oldest are dropped first).
                        let dropped = state.droppedLines
                        if dropped > 0 { continuation.yield(Self.droppedLinesNotice(dropped)) }
                        if completion.exitCode == 0 || completion.wasTerminated {
                            continuation.finish()
                        } else {
                            continuation.finish(
                                throwing: CLIErrorClassifier.error(
                                    command: command, exitCode: completion.exitCode, stderr: state.stderrTail))
                        }
                    })
                // Weak: the execution keeps itself alive until the process is reaped, and a strong
                // reference here would close the cycle stream → execution → continuation → stream.
                continuation.onTermination = { [weak execution] _ in execution?.terminate() }
            } catch {
                continuation.finish(throwing: BackendError.cliNotFound(searched: [executableURL.path]))
            }
        }
    }

    /// Like `lines(_:)`, but coalesced into batches on the reader's queue: the consumer wakes at most
    /// once per `interval` and at most `capacity` lines wait for it (the oldest are dropped and counted
    /// in `LogBatch.droppedLines`). Same lifetime rules as `lines(_:)`.
    public func lineBatches(
        _ arguments: [String], interval: Duration = .milliseconds(100), capacity: Int = 5_000
    ) -> AsyncThrowingStream<LogBatch, Error> {
        let command = commandLine(arguments)
        let batcher = LineBatcher(interval: interval, capacity: capacity)
        let state = StreamState()
        do {
            let execution = try ProcessExecution(
                executableURL: executableURL, arguments: arguments, environment: environment,
                deliveryInterval: .milliseconds(50),
                onOutput: { [weak batcher] stream, data in
                    batcher?.feed(state.feed(stream, data))
                },
                onComplete: { [weak batcher] completion in
                    batcher?.feed(state.flush())
                    if completion.exitCode == 0 || completion.wasTerminated {
                        batcher?.finish()
                    } else {
                        batcher?.finish(
                            throwing: CLIErrorClassifier.error(
                                command: command, exitCode: completion.exitCode, stderr: state.stderrTail))
                    }
                })
            batcher.setOnCancel { [weak execution] in execution?.terminate() }
        } catch {
            batcher.finish(throwing: BackendError.cliNotFound(searched: [executableURL.path]))
        }
        return batcher.stream()
    }
}

// MARK: - Errors

enum CLIErrorClassifier {
    /// Markers the CLI prints when the apiserver (or its plugins) can't be reached. Sources:
    /// apple/container `Application.swift` ("XPC connection error … Ensure container system service has
    /// been started with `container system start`."), `DefaultCommand.swift` ("Plugins are unavailable"),
    /// `SystemStatus.swift` ("apiserver is not running").
    static let notRunningMarkers = [
        "XPC connection error",
        "Ensure container system service has been started",
        "Plugins are unavailable",
        "apiserver is not running",
    ]

    static func isSystemNotRunning(_ stderr: String) -> Bool {
        notRunningMarkers.contains { stderr.localizedCaseInsensitiveContains($0) }
    }

    static func error(command: String, exitCode: Int32, stderr: String) -> BackendError {
        if isSystemNotRunning(stderr) { return .systemNotRunning }
        return .commandFailed(command: command, exitCode: exitCode, stderr: cleaned(stderr))
    }

    /// Keeps the message from the first "Error: " line on (dropping progress lines before it) without
    /// that prefix.
    static func cleaned(_ stderr: String) -> String {
        let lines = stderr.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("Error: ") }) else {
            return stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let text = lines[start...].joined(separator: "\n").dropFirst("Error: ".count)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Shell quoting

/// Single-quotes `value` for a POSIX shell.
public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

/// Returns `value` bare when it only contains shell-safe characters, quoted otherwise.
public func shellQuoteIfNeeded(_ value: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:@%+=,")
    if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
    return shellQuote(value)
}

// MARK: - Plumbing

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var timedOut = false

    func append(_ stream: ProcessExecution.Stream, _ data: Data) {
        lock.withLock {
            switch stream {
            case .stdout: stdout.append(data)
            case .stderr: stderr.append(data)
            }
        }
    }

    func markTimedOut() { lock.withLock { timedOut = true } }

    func snapshot() -> (Data, Data, Bool) { lock.withLock { (stdout, stderr, timedOut) } }
}

private final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = LineSplitter()
    private var stderr = LineSplitter()
    private var tail: [String] = []
    private var dropped = 0

    /// Lines the bounded stream buffer discarded so far.
    var droppedLines: Int { lock.withLock { dropped } }

    func count(_ result: AsyncThrowingStream<String, Error>.Continuation.YieldResult) {
        if case .dropped = result { lock.withLock { dropped += 1 } }
    }

    func feed(_ stream: ProcessExecution.Stream, _ data: Data) -> [String] {
        lock.withLock {
            switch stream {
            case .stdout:
                return stdout.feed(data)
            case .stderr:
                let lines = stderr.feed(data)
                remember(lines)
                return lines
            }
        }
    }

    func flush() -> [String] {
        lock.withLock {
            let errLines = stderr.flush()
            remember(errLines)
            return stdout.flush() + errLines
        }
    }

    var stderrTail: String { lock.withLock { tail.joined(separator: "\n") } }

    private func remember(_ lines: [String]) {
        tail.append(contentsOf: lines)
        if tail.count > 40 { tail.removeFirst(tail.count - 40) }
    }
}

/// A one-shot value that can be awaited once; resuming before awaiting is fine.
final class ContinuationBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Value?
    private var continuation: CheckedContinuation<Value, Never>?

    func resume(_ value: Value) {
        let waiter: CheckedContinuation<Value, Never>? = lock.withLock {
            guard result == nil else { return nil }
            result = value
            defer { continuation = nil }
            return continuation
        }
        waiter?.resume(returning: value)
    }

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            let ready: Value? = lock.withLock {
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
