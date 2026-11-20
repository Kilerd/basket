import Foundation

/// Returning stranded memory = giving the container a fresh VM: stop it, start it again.
public enum MemoryReclaim {
    /// What a restart run did, per container.
    public struct Outcome: Sendable, Hashable {
        public struct Item: Sendable, Hashable {
            public var id: String
            public var reason: String

            public init(id: String, reason: String) {
                self.id = id
                self.reason = reason
            }
        }

        public var restarted: [String] = []
        /// Left alone: started with `--rm`, gone, or (for reclaim) no longer running.
        public var skipped: [Item] = []
        /// Stop or start failed (the others went ahead regardless).
        public var failed: [Item] = []

        public init(restarted: [String] = [], skipped: [Item] = [], failed: [Item] = []) {
            self.restarted = restarted
            self.skipped = skipped
            self.failed = failed
        }

        /// Banner text when something was skipped or failed; nil when every container restarted.
        public var report: (title: String, detail: String)? {
            guard !skipped.isEmpty || !failed.isEmpty else { return nil }
            let total = restarted.count + skipped.count + failed.count
            let title = failed.isEmpty
                ? "Restarted \(restarted.count) of \(total) container\(total == 1 ? "" : "s")"
                : "\(failed.count) of \(total) container\(total == 1 ? "" : "s") couldn't be restarted"
            let lines = failed.map { "\($0.id): \($0.reason)" } + skipped.map { "\($0.id) was skipped: \($0.reason)" }
            return (title, lines.joined(separator: "\n"))
        }
    }

    /// Restarts each container on its own — stop, then start — so one that fails (or was deleted by
    /// its stop) never leaves the others down. Right before stopping each one its current state is
    /// read again (`container list` re-reads `--rm` from options.json): a container that turned out to
    /// be started with `--rm` or vanished is skipped, and with `onlyRunning` one that is no longer
    /// running is too (a stopped one otherwise just starts). Never throws: see `Outcome`.
    public static func restart(_ ids: [String], using backend: any ContainerBackend, onlyRunning: Bool = true) async -> Outcome {
        var outcome = Outcome()
        for id in ids {
            guard !Task.isCancelled else {
                outcome.skipped.append(Outcome.Item(id: id, reason: "cancelled"))
                continue
            }
            let current: ContainerSummary?
            do {
                current = try await backend.listContainers().first { $0.id == id }
            } catch {
                outcome.failed.append(Outcome.Item(id: id, reason: "couldn't read its state: \(message(error))"))
                continue
            }
            guard let current else {
                outcome.skipped.append(Outcome.Item(id: id, reason: "it no longer exists"))
                continue
            }
            if current.state == .running {
                if current.removeOnStop == true {
                    outcome.skipped.append(Outcome.Item(id: id, reason: "it was started with --rm, so stopping would delete it"))
                    continue
                }
                do {
                    try await backend.stopContainers([id])
                } catch {
                    outcome.failed.append(Outcome.Item(id: id, reason: "stopping failed: \(message(error))"))
                    continue
                }
            } else if onlyRunning {
                outcome.skipped.append(Outcome.Item(id: id, reason: "it is no longer running"))
                continue
            }
            do {
                try await backend.startContainer(id)
                outcome.restarted.append(id)
            } catch {
                let gone = (try? await backend.listContainers())?.contains { $0.id == id } == false
                outcome.failed.append(Outcome.Item(
                    id: id,
                    reason: gone ? "stopping deleted it (it was probably started with --rm)" : "starting failed: \(message(error))"))
            }
        }
        return outcome
    }

    static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
