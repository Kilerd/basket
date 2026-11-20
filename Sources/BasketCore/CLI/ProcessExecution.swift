import Foundation

/// One child process with stdout and stderr drained concurrently through `DispatchIO`, so a chatty
/// command can never deadlock on a full pipe. All mutable state lives on `queue`.
final class ProcessExecution: @unchecked Sendable {
    enum Stream: Sendable { case stdout, stderr }

    struct Completion: Sendable {
        var exitCode: Int32
        /// True when the process ended because `terminate()` was called (timeout or cancellation).
        var wasTerminated: Bool
    }

    private let process = Process()
    private let queue: DispatchQueue
    private let onOutput: @Sendable (Stream, Data) -> Void
    private var onComplete: (@Sendable (Completion) -> Void)?

    private var channels: [DispatchIO] = []
    private var openStreams = 2
    /// Coalescing (`deliveryInterval`): output waiting per stream, and when each was last handed over.
    private var pendingOutput: [Stream: Data] = [:]
    private var lastDelivery: [Stream: DispatchTime] = [:]
    private var deliveryScheduled: Set<Stream> = []
    private var exitCode: Int32?
    private var terminateRequested = false
    private var completed = false
    /// Keeps the execution alive until it completes, even if the caller drops its reference.
    private var keepAlive: ProcessExecution?

    /// Test hook: sees every execution launched in the current task (lets tests check it is released).
    @TaskLocal static var launchObserver: (@Sendable (ProcessExecution) -> Void)?

    /// Every execution whose process may still run, so quitting Basket can stop them: children of a
    /// GUI app are not terminated when it exits.
    private static let liveLock = NSLock()
    nonisolated(unsafe) private static let live = NSHashTable<ProcessExecution>.weakObjects()

    /// SIGTERM to every child still running (synchronously: the app may exit right after), then
    /// SIGKILL to those still alive after `grace`. Returns how many were signalled.
    @discardableResult
    static func terminateAll(grace: TimeInterval = 0.5, where include: (ProcessExecution) -> Bool = { _ in true }) -> Int {
        let executions = liveLock.withLock { live.allObjects }.filter(include)
        let pids = executions.map(\.processIdentifier).filter { $0 > 0 && kill($0, 0) == 0 }
        for pid in pids { kill(pid, SIGTERM) }
        guard !pids.isEmpty else { return 0 }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) { usleep(20_000) }
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        return pids.count
    }

    /// Launches immediately; `onOutput` and `onComplete` are called on a private serial queue.
    /// `deliveryInterval`: hand output over at most this often (or once 64 KB are waiting) instead of
    /// after every read — for chatty streams whose consumer batches anyway.
    init(
        executableURL: URL, arguments: [String], environment: [String: String],
        deliveryInterval: DispatchTimeInterval? = nil,
        onOutput: @escaping @Sendable (Stream, Data) -> Void,
        onComplete: @escaping @Sendable (Completion) -> Void
    ) throws {
        queue = DispatchQueue(label: "basket.process.\(executableURL.lastPathComponent)")
        self.onOutput = onOutput
        self.onComplete = onComplete

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let queue = self.queue
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            queue.async { [weak self] in self?.processExited(status) }
        }

        try process.run()

        queue.sync {
            keepAlive = self
            channels = [
                makeChannel(stdoutPipe.fileHandleForReading, stream: .stdout, interval: deliveryInterval),
                makeChannel(stderrPipe.fileHandleForReading, stream: .stderr, interval: deliveryInterval),
            ]
        }
        Self.liveLock.withLock { Self.live.add(self) }
        Self.launchObserver?(self)
    }

    var processIdentifier: Int32 { process.processIdentifier }

    /// SIGTERM now, SIGKILL if the process is still alive after `grace`.
    func terminate(grace: TimeInterval = 2) {
        queue.async { [self] in
            guard exitCode == nil else { return }
            terminateRequested = true
            if process.isRunning { process.terminate() }
            let pid = process.processIdentifier
            queue.asyncAfter(deadline: .now() + grace) { [self] in
                if exitCode == nil, process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    private func makeChannel(_ handle: FileHandle, stream: Stream, interval: DispatchTimeInterval?) -> DispatchIO {
        // The cleanup handler keeps the FileHandle (which owns the fd) alive until the channel closes.
        let channel = DispatchIO(type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue) { _ in
            _ = handle
        }
        channel.setLimit(lowWater: 1)
        // Without a high-water mark every read allocates a multi-megabyte buffer, which dominates the
        // cost of a chatty stream (one read per line written by `logs --follow`).
        channel.setLimit(highWater: 64 * 1024)
        // Reads stay event-driven (no channel interval: its timer fires ~20×/s per stream even while a
        // followed log is silent); with `interval` the output is coalesced and handed over at most
        // that often, via a one-shot timer that only exists while output is waiting.
        channel.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, _ in
            guard let self else { return }
            if let data, !data.isEmpty {
                if let interval { coalesce(Data(data), stream: stream, interval: interval) } else { onOutput(stream, Data(data)) }
            }
            if done {
                deliverPending(stream)
                channel.close()
                streamClosed()
            }
        }
        return channel
    }

    private func coalesce(_ data: Data, stream: Stream, interval: DispatchTimeInterval) {
        pendingOutput[stream, default: Data()].append(data)
        let now = DispatchTime.now()
        let due = lastDelivery[stream].map { $0 + interval } ?? now
        if (pendingOutput[stream]?.count ?? 0) >= 64 * 1024 || due <= now {
            deliverPending(stream)
        } else if !deliveryScheduled.contains(stream) {
            deliveryScheduled.insert(stream)
            queue.asyncAfter(deadline: due) { [weak self] in
                self?.deliveryScheduled.remove(stream)
                self?.deliverPending(stream)
            }
        }
    }

    private func deliverPending(_ stream: Stream) {
        guard let data = pendingOutput.removeValue(forKey: stream), !data.isEmpty else { return }
        lastDelivery[stream] = .now()
        onOutput(stream, data)
    }

    private func streamClosed() {
        openStreams -= 1
        finishIfDone()
    }

    private func processExited(_ status: Int32) {
        exitCode = status
        finishIfDone()
        // A grandchild may inherit the pipes and keep them open; don't wait for it forever.
        queue.asyncAfter(deadline: .now() + 1) { [self] in
            guard !completed else { return }
            channels.forEach { $0.close(flags: .stop) }
            deliverPending(.stdout)
            deliverPending(.stderr)
            openStreams = 0
            finishIfDone()
        }
    }

    private func finishIfDone() {
        guard !completed, openStreams <= 0, let exitCode else { return }
        completed = true
        let callback = onComplete
        onComplete = nil
        callback?(Completion(exitCode: exitCode, wasTerminated: terminateRequested))
        Self.liveLock.withLock { Self.live.remove(self) }
        keepAlive = nil
    }
}

/// Splits a byte stream into lines on `\n` and `\r` (progress bars redraw with `\r`), skipping empties.
/// Each byte is scanned once (a huge line costs linear time, not a rescan per chunk), and a line longer
/// than `maxLineBytes` is cut into pieces at UTF-8 boundaries, each piece but the last ending in
/// `splitMarker`, so memory stays bounded.
struct LineSplitter: Sendable {
    static let defaultMaxLineBytes = 1 << 20
    static let splitMarker = " […line longer than 1 MiB, continued on the next line]"

    let maxLineBytes: Int
    private var buffer: [UInt8] = []
    /// Start of the line in progress; bytes before it were handed out (compacted lazily).
    private var head = 0
    /// Bytes from `head` up to here hold no separator.
    private var scanned = 0

    init(maxLineBytes: Int = LineSplitter.defaultMaxLineBytes) {
        self.maxLineBytes = max(16, maxLineBytes)
    }

    mutating func feed(_ data: Data) -> [String] {
        buffer.append(contentsOf: data)
        var lines: [String] = []
        var start = head
        let limit = maxLineBytes
        let marker = Self.splitMarker
        let scannedFrom = scanned
        buffer.withUnsafeBufferPointer { bytes in
            let count = bytes.count
            guard let base = bytes.baseAddress else { return }
            func next(_ byte: UInt8, from index: Int) -> Int {
                guard index < count, let found = memchr(base + index, Int32(byte), count - index) else { return count }
                return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
            }
            func text(_ range: Range<Int>) -> String {
                String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self)
            }
            var newline = next(0x0A, from: scannedFrom)
            var carriage = next(0x0D, from: scannedFrom)
            while true {
                let separator = min(newline, carriage)
                while separator - start > limit {
                    var cut = start + limit
                    // Don't split a UTF-8 sequence: back off over continuation bytes (10xxxxxx).
                    var backoff = 0
                    while backoff < 3, cut > start + 1, bytes[cut] & 0xC0 == 0x80 { cut -= 1; backoff += 1 }
                    lines.append(text(start..<cut) + marker)
                    start = cut
                }
                guard separator < count else { break }
                if separator > start { lines.append(text(start..<separator)) }
                start = separator + 1
                if newline == separator { newline = next(0x0A, from: start) }
                if carriage == separator { carriage = next(0x0D, from: start) }
            }
        }
        head = start
        scanned = buffer.count
        if head > 64 * 1024, head * 2 > buffer.count {
            buffer.removeFirst(head)
            scanned -= head
            head = 0
        }
        return lines
    }

    mutating func flush() -> [String] {
        defer {
            buffer = []
            head = 0
            scanned = 0
        }
        guard head < buffer.count else { return [] }
        return [String(decoding: buffer[head...], as: UTF8.self)]
    }
}
