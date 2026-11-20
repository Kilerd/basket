import Foundation

/// Coalesces lines from a fast producer (any thread) into `LogBatch`es for a slower consumer: the
/// consumer is woken at most once per `interval`, and at most `capacity` lines wait for it (the oldest
/// are dropped and counted). It is the pull side of an `AsyncThrowingStream(unfolding:)`, so it lives
/// exactly as long as that stream and its iterators; releasing it (or cancelling the consuming task)
/// calls `onCancel`, which stops the producer.
final class LineBatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: Duration
    private let capacity: Int
    private var pending: [String] = []
    private var dropped = 0
    private var completion: (any Error)??
    private var cancelled = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var lastDelivery: ContinuousClock.Instant?
    private var onCancel: (@Sendable () -> Void)?

    init(interval: Duration = .milliseconds(100), capacity: Int = 5_000) {
        self.interval = interval
        self.capacity = max(1, capacity)
    }

    deinit { cancel() }

    /// What stops the producer; runs once, on cancellation or when the batcher is released.
    func setOnCancel(_ handler: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            if cancelled { return true }
            onCancel = handler
            return false
        }
        if runNow { handler() }
    }

    /// The stream consumers iterate.
    func stream() -> AsyncThrowingStream<LogBatch, Error> {
        AsyncThrowingStream(unfolding: { [self] in try await next() })
    }

    // MARK: Producer side

    func feed(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let resume: CheckedContinuation<Void, Never>? = lock.withLock {
            guard completion == nil, !cancelled else { return nil }
            pending.append(contentsOf: lines)
            if pending.count > capacity {
                let excess = pending.count - capacity
                pending.removeFirst(excess)
                dropped += excess
            }
            defer { waiter = nil }
            return waiter
        }
        resume?.resume()
    }

    /// The producer is done; the consumer still gets every pending line first, then the error if any.
    func finish(throwing error: (any Error)? = nil) {
        let resume: CheckedContinuation<Void, Never>? = lock.withLock {
            guard completion == nil else { return nil }
            completion = .some(error)
            defer { waiter = nil }
            return waiter
        }
        resume?.resume()
    }

    // MARK: Consumer side

    /// The next batch, nil once the producer finished (or the consumer was cancelled).
    func next() async throws -> LogBatch? {
        if let last = lock.withLock({ lastDelivery }) {
            let remaining = last + interval - .now
            if remaining > .zero {
                do { try await Task.sleep(for: remaining) } catch {
                    cancel()
                    return nil
                }
            }
        }
        while true {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let ready = lock.withLock {
                        if !pending.isEmpty || completion != nil || cancelled { return true }
                        waiter = continuation
                        return false
                    }
                    if ready { continuation.resume() }
                }
            } onCancel: {
                cancel()
            }
            switch take() {
            case .batch(let batch): return batch
            case .end: return nil
            case .failure(let error): throw error
            case .nothing: continue
            }
        }
    }

    private enum Outcome {
        case batch(LogBatch), end, failure(any Error), nothing
    }

    private func take() -> Outcome {
        lock.withLock {
            if cancelled { return .end }
            if !pending.isEmpty {
                defer {
                    pending.removeAll(keepingCapacity: true)
                    dropped = 0
                    lastDelivery = .now
                }
                return .batch(LogBatch(lines: pending, droppedLines: dropped))
            }
            switch completion {
            case .none: return .nothing
            case .some(.none): return .end
            case .some(.some(let error)): return .failure(error)
            }
        }
    }

    /// Stops the producer and ends the stream.
    func cancel() {
        let (handler, resume): ((@Sendable () -> Void)?, CheckedContinuation<Void, Never>?) = lock.withLock {
            guard !cancelled else { return (nil, nil) }
            cancelled = true
            pending.removeAll()
            defer {
                onCancel = nil
                waiter = nil
            }
            return (onCancel, waiter)
        }
        resume?.resume()
        handler?()
    }

    /// Batches an existing line stream: a background task drains `source` (so the consumer's actor is
    /// not woken per line) and is cancelled when the batched stream goes away.
    static func batches(
        of source: AsyncThrowingStream<String, Error>, interval: Duration = .milliseconds(100), capacity: Int = 5_000
    ) -> AsyncThrowingStream<LogBatch, Error> {
        let batcher = LineBatcher(interval: interval, capacity: capacity)
        let pump = Task.detached { [weak batcher] in
            do {
                for try await line in source {
                    guard let batcher else { return }
                    batcher.feed([line])
                }
                batcher?.finish()
            } catch {
                batcher?.finish(throwing: error)
            }
        }
        batcher.setOnCancel { pump.cancel() }
        return batcher.stream()
    }
}
