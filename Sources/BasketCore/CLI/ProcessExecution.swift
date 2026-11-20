import Foundation

/// One child process with stdout and stderr drained concurrently (a read source per pipe), so a chatty
/// command can never deadlock on a full pipe. All mutable state lives on `queue`.
///
/// Completion is reported only after both pipes were drained, normally at EOF. A grandchild that
/// inherited the pipes (a background job) can keep them open after the child exited; then, after
/// `Timing.grandchildGrace`, the pipes are read up to what they hold at that moment — all of the
/// child's own output is in there once it has exited — and closed. A reader that runs late (a loaded
/// machine) delays completion; it never loses output.
final class ProcessExecution: @unchecked Sendable {
    enum Stream: Sendable { case stdout, stderr }

    struct Completion: Sendable {
        var exitCode: Int32
        /// True when the process ended because `terminate()` was called (timeout or cancellation).
        var wasTerminated: Bool
    }

    struct Timing: Sendable {
        /// How long the pipes may stay open after the child exited; only a grandchild can hold them.
        var grandchildGrace: DispatchTimeInterval = .seconds(1)
        /// Test hook: start reading this late, as a reader starved on a loaded machine would.
        var readerStartDelay: DispatchTimeInterval?
    }

    /// The read end of one pipe; `source` exists once reading started.
    private struct Reader {
        /// Owns the descriptor; closed when the stream is.
        let handle: FileHandle
        let descriptor: Int32
        var source: DispatchSourceRead?

        init(_ handle: FileHandle) {
            self.handle = handle
            descriptor = handle.fileDescriptor
            // An empty pipe answers EAGAIN instead of blocking the queue.
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
    }

    /// At most this much is read per wake-up, so with a fast writer the other pipe and timers get turns.
    private static let readLimitPerEvent = 1 << 20
    /// `FIONREAD` (`_IOR('f', 127, int)`), a macro Swift can't import: bytes waiting in a pipe.
    private static let fionread =
        UInt(IOC_OUT) | UInt(MemoryLayout<Int32>.size & Int(IOCPARM_MASK)) << 16 | UInt(UInt8(ascii: "f")) << 8 | 127

    private let process = Process()
    private let queue: DispatchQueue
    private let timing: Timing
    private let deliveryInterval: DispatchTimeInterval?
    private let onOutput: @Sendable (Stream, Data) -> Void
    private var onComplete: (@Sendable (Completion) -> Void)?

    private var readers: [Stream: Reader] = [:]
    /// Counted rather than `readers.count`: the child can exit before the readers exist.
    private var openStreams = 2
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)
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
    /// Read when an execution starts; tests shorten the grace or starve the readers.
    @TaskLocal static var timing = Timing()

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
        timing = Self.timing
        self.deliveryInterval = deliveryInterval
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
            readers = [.stdout: Reader(stdoutPipe.fileHandleForReading), .stderr: Reader(stderrPipe.fileHandleForReading)]
            if let delay = timing.readerStartDelay {
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.startReading() }
            } else {
                startReading()
            }
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

    // MARK: Reading

    /// Watches the pipes still open. Event-driven: a silent pipe costs no wake-ups.
    private func startReading() {
        for (stream, reader) in readers where reader.source == nil {
            let source = DispatchSource.makeReadSource(fileDescriptor: reader.descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.read(stream, upTo: Self.readLimitPerEvent) }
            // The descriptor is closed only once the source stopped watching it.
            let handle = reader.handle
            source.setCancelHandler { try? handle.close() }
            readers[stream]?.source = source
            source.activate()
        }
    }

    /// Reads up to `limit` bytes of what `stream`'s pipe holds now and hands them over; at EOF (every
    /// copy of the write end is closed) the stream is closed.
    private func read(_ stream: Stream, upTo limit: Int) {
        guard let descriptor = readers[stream]?.descriptor else { return }
        var remaining = limit
        while remaining > 0 {
            let count = readBuffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, min($0.count, remaining)) }
            if count > 0 {
                remaining -= count
                deliver(Data(readBuffer[..<count]), from: stream)
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN {
                return  // empty for now; the source fires again when more arrives
            } else {
                closeStream(stream)  // EOF, or a read error: nothing more will come
                return
            }
        }
    }

    private func closeStream(_ stream: Stream) {
        guard let reader = readers.removeValue(forKey: stream) else { return }
        if let source = reader.source { source.cancel() } else { try? reader.handle.close() }
        deliverPending(stream)
        openStreams -= 1
        finishIfDone()
    }

    private func processExited(_ status: Int32) {
        exitCode = status
        finishIfDone()
        guard !completed else { return }
        // Everything the child wrote is in the pipes now and EOF follows once it has been read, unless a
        // grandchild inherited the pipes and keeps them open. Don't wait for that forever.
        queue.asyncAfter(deadline: .now() + timing.grandchildGrace) { [weak self] in self?.stopWaitingForGrandchildren() }
    }

    /// Reads what the pipes hold right now (all of the child's own output, however late the readers
    /// ran) and closes them, leaving behind a grandchild that still holds them open.
    private func stopWaitingForGrandchildren() {
        for stream in [Stream.stdout, .stderr] {
            guard let reader = readers[stream] else { continue }
            var waiting: Int32 = 0
            let readable = ioctl(reader.descriptor, Self.fionread, &waiting) == 0 ? Int(waiting) : Self.readLimitPerEvent
            if readable > 0 { read(stream, upTo: readable) }
            closeStream(stream)  // no-op if the read reached EOF
        }
    }

    // MARK: Delivery

    private func deliver(_ data: Data, from stream: Stream) {
        if let deliveryInterval { coalesce(data, stream: stream, interval: deliveryInterval) } else { onOutput(stream, data) }
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
