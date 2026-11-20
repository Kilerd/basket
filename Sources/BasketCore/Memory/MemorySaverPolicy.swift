import Foundation

/// Which containers Memory Saver (automatic or "Stop Idle Containers") may stop.
public enum MemorySaverPolicy {
    /// Why a container may or may not be stopped to save memory.
    public enum Eligibility: Sendable, Hashable {
        case eligible
        /// The user exempted it.
        case exempt
        /// Backs a `container machine`; managed from the Machines section.
        case machine
        /// Started with `--rm`: stopping it would delete it.
        case removedOnStop
        /// Unknown whether stopping deletes it; only stopped when the user opted in for it.
        case removalUnknown
    }

    public static func eligibility(
        of container: ContainerSummary, exemptions: Set<String>, optIns: Set<String>
    ) -> Eligibility {
        if exemptions.contains(container.id) { return .exempt }
        if isMachineBacked(container) { return .machine }
        switch container.removeOnStop {
        case true?: return .removedOnStop
        case nil where !optIns.contains(container.id): return .removalUnknown
        default: return .eligible
        }
    }

    /// Eligible running containers idle right now (any duration), longest idle first.
    public static func idleContainers(
        _ containers: [ContainerSummary], trackers: [String: IdleTracker], exemptions: Set<String>,
        optIns: Set<String> = [], at now: Date
    ) -> [(id: String, idleFor: TimeInterval)] {
        containers.compactMap { container -> (id: String, idleFor: TimeInterval)? in
            guard container.state == .running,
                  eligibility(of: container, exemptions: exemptions, optIns: optIns) == .eligible,
                  let tracker = trackers[container.id], tracker.tracks(container),
                  let idle = tracker.idleDuration(at: now)
            else { return nil }
            return (container.id, idle)
        }
        .sorted { ($0.idleFor, $1.id) > ($1.idleFor, $0.id) }
    }

    /// Containers idle for at least `minimum`: what an automatic pass stops.
    public static func containersToStop(
        _ containers: [ContainerSummary], trackers: [String: IdleTracker], exemptions: Set<String>,
        optIns: Set<String> = [], idleFor minimum: TimeInterval, at now: Date
    ) -> [String] {
        idleContainers(containers, trackers: trackers, exemptions: exemptions, optIns: optIns, at: now)
            .filter { $0.idleFor >= minimum }
            .map(\.id)
    }

    /// Containers that back a `container machine` are managed from the Machines section, never here.
    public static func isMachineBacked(_ container: ContainerSummary) -> Bool {
        container.labels[ResourceLabels.plugin] == "machine"
    }
}
