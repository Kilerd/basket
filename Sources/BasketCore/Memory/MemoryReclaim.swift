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
            let title: String
            if total == 1 {
                title = failed.isEmpty
                    ? String(localized: "The container wasn't restarted", bundle: .main)
                    : String(localized: "The container couldn't be restarted", bundle: .main)
            } else {
                // `total` is at least 2 here, so the noun is plural in every language Basket ships.
                title = failed.isEmpty
                    ? String(localized: "Restarted \(restarted.count) of \(total) containers", bundle: .main,
                             comment: "Banner title; the second number is at least 2")
                    : String(localized: "\(failed.count) of \(total) containers couldn't be restarted", bundle: .main,
                             comment: "Banner title; the second number is at least 2")
            }
            let lines = failed.map { String(localized: "\($0.id): \($0.reason)", bundle: .main, comment: "Container name: why it couldn't be restarted") }
                + skipped.map { String(localized: "\($0.id) was skipped: \($0.reason)", bundle: .main) }
            return (title, lines.joined(separator: "\n"))
        }
    }

    /// Restarts each container on its own — stop, then start — so one that fails (or was deleted by
    /// its stop) never leaves the others down. Right before stopping each one its current state is
    /// read again (`container list` re-reads `--rm` from options.json): a container that turned out to
    /// be started with `--rm` or vanished is skipped, and with `onlyRunning` one that is no longer
    /// running is too (a stopped one otherwise just starts). Containers are handled in the order
    /// given (compose projects pass dependency order). Never throws: see `Outcome`; `progress` gets a
    /// line per container.
    public static func restart(
        _ ids: [String], using backend: any ContainerBackend, onlyRunning: Bool = true,
        progress: (String) -> Void = { _ in }
    ) async -> Outcome {
        var outcome = Outcome()
        func skip(_ id: String, _ reason: String) {
            outcome.skipped.append(Outcome.Item(id: id, reason: reason))
            progress(String(localized: "Skipped \(id): \(reason)", bundle: .main))
        }
        func fail(_ id: String, _ reason: String) {
            outcome.failed.append(Outcome.Item(id: id, reason: reason))
            progress(String(localized: "Couldn't restart \(id): \(reason)", bundle: .main))
        }
        for id in ids {
            guard !Task.isCancelled else {
                skip(id, String(localized: "cancelled", bundle: .main, comment: "Why a container wasn't restarted"))
                continue
            }
            let current: ContainerSummary?
            do {
                current = try await backend.listContainers().first { $0.id == id }
            } catch {
                fail(id, String(localized: "couldn't read its state: \(message(error))", bundle: .main))
                continue
            }
            guard let current else {
                skip(id, String(localized: "it no longer exists", bundle: .main))
                continue
            }
            if current.state == .running {
                if current.removeOnStop == true {
                    skip(id, String(localized: "it was started with --rm, so stopping would delete it", bundle: .main))
                    continue
                }
                progress(String(localized: "Restarting \(id)", bundle: .main))
                do {
                    try await backend.stopContainers([id])
                } catch {
                    fail(id, String(localized: "stopping failed: \(message(error))", bundle: .main))
                    continue
                }
            } else if onlyRunning {
                skip(id, String(localized: "it is no longer running", bundle: .main))
                continue
            } else {
                progress(String(localized: "Starting \(id)", bundle: .main))
            }
            do {
                try await backend.startContainer(id)
                outcome.restarted.append(id)
            } catch {
                let gone = (try? await backend.listContainers())?.contains { $0.id == id } == false
                fail(id, gone ? String(localized: "stopping deleted it (it was probably started with --rm)", bundle: .main)
                              : String(localized: "starting failed: \(message(error))", bundle: .main))
            }
        }
        return outcome
    }

    static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
