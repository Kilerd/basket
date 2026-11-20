import Foundation
import BasketCore

/// Memory insights (stranded memory, idle containers), Memory Saver and restart-to-reclaim.
extension AppStore {
    /// Per-container host-memory breakdown of running containers.
    var memoryInsights: MemoryInsights {
        MemoryInsights(containers: containers, stats: latestStats, footprints: footprints)
    }

    /// Containers Memory Saver may stop that are idle right now (no minimum), longest first.
    /// Exempt, machine-backed and `--rm` containers (or unknown ones not opted in) are left out.
    var idleContainers: [(id: String, idleFor: TimeInterval)] {
        guard availability == .running else { return [] }
        return MemorySaverPolicy.idleContainers(
            containers, trackers: memorySaver.trackers, exemptions: memorySaver.exemptions,
            optIns: memorySaver.optIns, at: Date())
    }

    /// Idle time of one running container, regardless of eligibility; nil when active or unknown.
    func idleDuration(of id: String) -> TimeInterval? {
        guard let container = containers.first(where: { $0.id == id && $0.state == .running }),
              memorySaver.trackers[id]?.tracks(container) != false
        else { return nil }
        return memorySaver.idleDuration(of: id)
    }

    // MARK: Background sampling

    /// With Memory Saver on and the window hidden, sample activity once a minute (stats only while
    /// something runs). Otherwise Basket polls only while its window is visible.
    func updateBackgroundWatch(foreground: Bool) {
        if foreground {
            backgroundWatch?.cancel()
            backgroundWatch = nil
        } else if backgroundWatch == nil {
            backgroundWatch = Task { [weak self] in
                while !Task.isCancelled {
                    if let self, self.memorySaver.isEnabled {
                        await self.refresh([.system, .containers, .footprints])
                        if !self.runningContainers.isEmpty { await self.refresh([.stats]) }
                    }
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }

    // MARK: Memory Saver

    /// Called after every stats sample: feeds the idle trackers and stops containers idle for
    /// longer than the Settings threshold (when Memory Saver is on).
    func memorySaverDidIngest(_ samples: [ContainerStats]) {
        memorySaver.record(samples, containers: containers)
        guard memorySaver.isEnabled, availability == .running else { return }
        let now = Date()
        let minimum = TimeInterval(memorySaver.idleMinutes * 60)
        let due = idleContainers.filter {
            $0.idleFor >= minimum && pending[$0.id] == nil && memorySaver.mayAttempt($0.id, at: now)
        }
        guard !due.isEmpty else { return }
        memorySaver.noteAttempt(due.map(\.id), at: now)
        Task { await stop(due, kind: .autoStop) }
    }

    /// "Stop Idle Containers": every eligible container idle right now. Never needs a confirmation:
    /// `--rm` containers (deleted by a stop) are never eligible.
    func stopIdleContainers() async {
        await stop(idleContainers, kind: .stopIdle)
    }

    /// The candidates were picked from cached data: re-read the containers (and their `--rm` status)
    /// first and stop only those still eligible — running, not `--rm`, the same instance and still idle.
    private func stop(_ idle: [(id: String, idleFor: TimeInterval)], kind: MemoryActivity.Kind) async {
        let candidates = idle.map(\.id)
        guard !candidates.isEmpty else { return }
        memorySaver.inFlight.formUnion(candidates)
        defer { memorySaver.inFlight.subtract(candidates) }
        await refresh([.containers])
        let minimum = kind == .autoStop ? TimeInterval(memorySaver.idleMinutes * 60) : 0
        let current = Dictionary(idleContainers.map { ($0.id, $0.idleFor) }, uniquingKeysWith: { first, _ in first })
        let confirmed = idle.compactMap { item -> (id: String, idleFor: TimeInterval)? in
            guard let idleFor = current[item.id], idleFor >= minimum else { return nil }
            return (item.id, idleFor)
        }
        let ids = confirmed.map(\.id)
        guard !ids.isEmpty else { return }
        let before = hostMemoryByOwner
        let ok = await perform("Stopping", ids: ids, refresh: [.containers, .stats, .footprints]) { backend in
            try await backend.stopContainers(ids)
        }
        guard ok else { return }
        let now = Date()
        memorySaver.log(confirmed.map {
            MemoryActivity(date: now, kind: kind, containerID: $0.id, idleSeconds: $0.idleFor, freedBytes: before[$0.id])
        })
    }

    // MARK: Restart (plain, or to reclaim stranded memory)

    /// Restarts the containers so their VMs start over with a fresh footprint, and logs what came back.
    func reclaimMemory(_ ids: [String]) async {
        guard !ids.isEmpty else { return }
        let before = hostMemoryByOwner
        let restarted = await restart(ids, onlyRunning: true).restarted
        guard !restarted.isEmpty else { return }
        await refreshComposeHosts(after: restarted)
        let after = hostMemoryByOwner
        let now = Date()
        memorySaver.log(restarted.map { id in
            MemoryActivity(date: now, kind: .reclaim, containerID: id,
                           freedBytes: before[id].map { max(0, $0 - (after[id] ?? 0)) })
        })
    }

    /// Asks before a restart. Containers started with `--rm` are refused (stopping deletes them);
    /// when Basket can't tell, the message says so. `reclaim` logs the memory returned.
    func confirmRestartContainers(_ ids: [String], reclaim: Bool = false) {
        let items = containers.filter { ids.contains($0.id) }.sorted { $0.id < $1.id }
        guard !items.isEmpty else { return }
        // Only stopping a running container can delete it; a stopped one just starts.
        let deleted = items.filter { $0.state == .running && $0.removeOnStop == true }.map(\.id)
        let unknown = items.filter { $0.state == .running && $0.removeOnStop == nil }.map(\.id)
        let restartable = items.map(\.id).filter { !deleted.contains($0) }
        func names(_ list: [String]) -> String { list.map { "“\($0)”" }.joined(separator: ", ") }

        guard !restartable.isEmpty else {
            confirmation = Confirmation(
                title: deleted.count == 1 ? "Can't restart \(names(deleted))" : "Can't restart these containers",
                message: "\(deleted.count == 1 ? "It was" : "They were") started with --rm, so stopping deletes \(deleted.count == 1 ? "it" : "them") and \(deleted.count == 1 ? "it" : "they") can't come back. Stop \(deleted.count == 1 ? "it" : "them") yourself if no longer needed.",
                confirmLabel: nil) {}
            return
        }

        var message: [String] = []
        if reclaim, restartable.count == 1, let stranded = memoryInsights[restartable[0]]?.strandedBytes, stranded > 0 {
            message.append("Its VM holds about \(Format.memory(stranded)) the guest no longer uses; a restart returns it to macOS.")
        }
        message.append("A brief interruption: published ports come back once \(restartable.count == 1 ? "it is" : "they are") running again, but anything kept only in memory is lost.")
        if !deleted.isEmpty {
            message.append("Skipped \(names(deleted)): started with --rm, so stopping would delete \(deleted.count == 1 ? "it" : "them").")
        }
        if !unknown.isEmpty {
            message.append("Basket can't tell whether \(names(unknown)) \(unknown.count == 1 ? "was" : "were") started with --rm. If so, stopping deletes \(unknown.count == 1 ? "it" : "them") for good.")
        }
        let subject = restartable.count == 1 ? names(restartable) : "\(restartable.count) containers"
        confirmation = Confirmation(
            title: reclaim ? "Restart \(subject) to reclaim memory?" : "Restart \(subject)?",
            message: message.joined(separator: "\n\n"),
            confirmLabel: unknown.isEmpty ? "Restart" : "Restart Anyway",
            isDestructive: !unknown.isEmpty
        ) { [weak self] in
            Task {
                if reclaim { await self?.reclaimMemory(restartable) } else { await self?.restartContainers(restartable) }
            }
        }
    }
}

extension Format {
    /// "45 s", "12 min", "2 h 5 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s) s" }
        let minutes = s / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

extension MemoryActivity {
    var summary: String {
        let freed = freedBytes.flatMap { $0 > 0 ? " · freed \(Format.memory($0))" : nil } ?? ""
        switch kind {
        case .autoStop:
            return "Stopped \(containerID) after \(Format.duration(idleSeconds ?? 0)) idle\(freed)"
        case .stopIdle:
            return "Stopped idle \(containerID)\(freed)"
        case .reclaim:
            return "Restarted \(containerID)\(freed)"
        }
    }
}
