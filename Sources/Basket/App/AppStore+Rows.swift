import Foundation
import BasketCore

// Flattened, sortable row models for the tables. Unknown numbers are -1 so they sort first/last.

struct ContainerRow: Identifiable, Hashable {
    let summary: ContainerSummary
    var id: String { summary.id }
    var name: String { summary.id }
    var image: String
    var stateOrder: Int
    var portsText: String
    var cpu: Double
    var memoryUsed: Int64
    var memoryLimit: Int64
    var hostMemory: Int64
    /// Host memory a restart would return (0 unless flagged; see `MemoryInsights`).
    var strandedBytes: Int64 = 0
    /// Set while the container is idle (see `IdleTracker`).
    var idleFor: TimeInterval?
    /// Set on a compose project's header row (its numbers are the project's totals).
    var project: ComposeProject?
}

struct ImageRow: Identifiable, Hashable {
    let summary: ImageSummary
    var id: String { summary.id }
    var name: String
    var tag: String
    var created: Double
    var hostSize: Int64
    var totalSize: Int64
    var variantCount: Int
    var usedBy: [String]

    /// Bytes stored for platforms this Mac can't run natively.
    var extraBytes: Int64 { max(0, totalSize - hostSize) }
    var isBloated: Bool { variantCount > 1 && extraBytes > 0 }
}

struct VolumeRow: Identifiable, Hashable {
    let summary: VolumeSummary
    var id: String { summary.id }
    var name: String { summary.name }
    var allocated: Int64
    var capacity: Int64
    var created: Double
    var usedBy: [String]
    var usedByText: String { usedBy.isEmpty ? "—" : usedBy.joined(separator: ", ") }
}

struct NetworkRow: Identifiable, Hashable {
    let summary: NetworkSummary
    var id: String { summary.id }
    var name: String { summary.name }
    var mode: String { summary.mode }
    var subnet: String { summary.ipv4Subnet ?? "" }
    var gateway: String { summary.ipv4Gateway ?? "" }
    var created: Double
    var attached: Int
}

struct MachineRow: Identifiable, Hashable {
    let summary: MachineSummary
    var id: String { summary.id }
    var name: String { summary.id }
    var image: String { summary.image }
    var stateOrder: Int
    var cpus: Int { summary.cpus }
    var memory: Int64 { summary.memoryBytes }
    var disk: Int64 { summary.diskBytes ?? -1 }
    var created: Double { summary.createdAt?.timeIntervalSince1970 ?? 0 }
    var hostMemory: Int64
}

extension ContainerState {
    /// Running first when sorting ascending.
    var sortOrder: Int {
        switch self {
        case .running: 0
        case .stopping: 1
        case .created: 2
        case .stopped: 3
        case .unknown: 4
        }
    }

    var title: String {
        switch self {
        case .running: "Running"
        case .stopped: "Stopped"
        case .stopping: "Stopping"
        case .created: "Created"
        case .unknown: "Unknown"
        }
    }
}

private func matches(_ query: String, _ fields: String?...) -> Bool {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return true }
    return fields.contains { $0?.localizedCaseInsensitiveContains(q) == true }
}

extension AppStore {
    var containerRows: [ContainerRow] {
        let host = hostMemoryByOwner
        let insights = memoryInsights
        let query = search(.containers)
        return containers
            .filter {
                matches(query, $0.id, $0.imageReference, $0.ipv4Address, Format.ports($0.ports), $0.state.title,
                        $0.labels[ComposeLabels.project], $0.labels[ComposeLabels.service])
            }
            .map { c in
                let stats = latestStats[c.id]
                return ContainerRow(
                    summary: c, image: ImageName(c.imageReference).display, stateOrder: c.state.sortOrder,
                    portsText: Format.ports(c.ports), cpu: cpuPercent[c.id] ?? -1,
                    memoryUsed: stats?.memoryUsageBytes ?? -1,
                    memoryLimit: stats?.memoryLimitBytes ?? c.memoryLimitBytes,
                    hostMemory: host[c.id] ?? -1,
                    strandedBytes: insights[c.id].flatMap { $0.isStranded ? $0.strandedBytes : nil } ?? 0,
                    idleFor: idleDuration(of: c.id)
                )
            }
            .sorted(using: containerSort)
    }

    var imageRows: [ImageRow] {
        let query = search(.images)
        let usage = imageUsage
        return images
            .filter { matches(query, $0.reference, $0.digest) }
            .map { i in
                let name = ImageName(i.reference)
                let users = usage.users(of: i.reference)
                return ImageRow(
                    summary: i, name: name.repository, tag: name.tag,
                    created: i.createdAt?.timeIntervalSince1970 ?? 0, hostSize: i.hostVariantSizeBytes,
                    totalSize: i.totalSizeBytes, variantCount: i.variants.count,
                    usedBy: users.containers + users.machines.map { "machine \($0)" }
                )
            }
            .sorted(using: imageSort)
    }

    /// Volume name → ids of containers that mount it.
    var volumeUsers: [String: [String]] {
        var users: [String: [String]] = [:]
        for c in containers {
            for m in c.mounts {
                // A volume mount's source is the volume name or its backing image path.
                if let v = volumes.first(where: { $0.name == m.source || $0.source == m.source }) {
                    users[v.name, default: []].append(c.id)
                }
            }
        }
        return users
    }

    var volumeRows: [VolumeRow] {
        let query = search(.volumes)
        let users = volumeUsers
        return volumes
            .filter { matches(query, $0.name, $0.source, $0.format) }
            .map { v in
                VolumeRow(summary: v, allocated: v.allocatedBytes ?? -1, capacity: v.capacityBytes,
                          created: v.createdAt?.timeIntervalSince1970 ?? 0, usedBy: users[v.name] ?? [])
            }
            .sorted(using: volumeSort)
    }

    var networkRows: [NetworkRow] {
        let query = search(.networks)
        var attached: [String: Int] = [:]
        for c in containers { for n in c.networks { attached[n, default: 0] += 1 } }
        return networks
            .filter { matches(query, $0.name, $0.mode, $0.ipv4Subnet, $0.ipv4Gateway) }
            .map { NetworkRow(summary: $0, created: $0.createdAt?.timeIntervalSince1970 ?? 0, attached: attached[$0.name] ?? 0) }
            .sorted(using: networkSort)
    }

    var machineRows: [MachineRow] {
        let host = hostMemoryByOwner
        let query = search(.machines)
        return machines
            .filter { matches(query, $0.id, $0.image, $0.ipv4Address, $0.state.title) }
            .map { MachineRow(summary: $0, stateOrder: $0.state.sortOrder, hostMemory: host[$0.id] ?? -1) }
            .sorted(using: machineSort)
    }

    /// The status bar line under each list: counts plus what the section costs in memory or disk.
    func statusLine(for section: AppSection) -> String {
        func shown(_ visible: Int, _ total: Int, _ noun: String) -> String {
            let plural = total == 1 ? noun : noun + "s"
            return visible == total ? "\(total) \(plural)" : "Showing \(visible) of \(total) \(plural)"
        }
        // OrbStack's side reads fine while Basket's container system is stopped.
        if section == .migration { return migration.statusLine }
        switch availability {
        case .stopped: return "Container system stopped"
        case .cliMissing: return "container CLI not found"
        default: break
        }
        switch section {
        case .overview:
            return ""
        case .containers:
            let running = runningContainers
            var parts = [shown(containerRows.count, containers.count, "container"), "\(running.count) running"]
            let projects = Set(containers.compactMap(ComposeProject.projectName(of:))).count
            if projects > 0 { parts.append("\(projects) compose project\(projects == 1 ? "" : "s")") }
            if !running.isEmpty {
                let cpu = running.compactMap { cpuPercent[$0.id] }.reduce(0, +)
                let guest = running.compactMap { latestStats[$0.id]?.memoryUsageBytes }.reduce(0, +)
                let host = running.compactMap { hostMemoryByOwner[$0.id] }.reduce(0, +)
                parts.append("CPU \(Format.percent(cpu))")
                parts.append("\(Format.memory(guest)) used in guests")
                if footprintsAvailable { parts.append("\(Format.memory(host)) on this Mac") }
            }
            return parts.joined(separator: " · ")
        case .images:
            let total = images.reduce(Int64(0)) { $0 + $1.totalSizeBytes }
            let extra = images.reduce(Int64(0)) { $0 + max(0, $1.totalSizeBytes - $1.hostVariantSizeBytes) }
            let unused = imageUsage.unused(images)
            var parts = [shown(imageRows.count, images.count, "image"), "\(Format.disk(total)) on disk"]
            if extra > 0 { parts.append("\(Format.disk(extra)) for other platforms") }
            if !unused.isEmpty { parts.append("\(unused.count) unused") }
            return parts.joined(separator: " · ")
        case .volumes:
            let allocated = volumes.reduce(Int64(0)) { $0 + ($1.allocatedBytes ?? 0) }
            let capacity = volumes.reduce(Int64(0)) { $0 + $1.capacityBytes }
            var parts = [shown(volumeRows.count, volumes.count, "volume"), "\(Format.disk(allocated)) on disk"]
            if capacity > 0 { parts.append("sparse, up to \(Format.memory(capacity))") }
            return parts.joined(separator: " · ")
        case .networks:
            let attached = containers.reduce(0) { $0 + $1.networks.count }
            return [shown(networkRows.count, networks.count, "network"), "\(attached) container attachment\(attached == 1 ? "" : "s")"]
                .joined(separator: " · ")
        case .migration:
            return migration.statusLine
        case .machines:
            let running = machines.filter { $0.state == .running }
            let disk = machines.reduce(Int64(0)) { $0 + ($1.diskBytes ?? 0) }
            let host = running.compactMap { hostMemoryByOwner[$0.id] }.reduce(0, +)
            var parts = [shown(machineRows.count, machines.count, "machine"), "\(running.count) running"]
            if footprintsAvailable, !running.isEmpty { parts.append("\(Format.memory(host)) on this Mac") }
            if disk > 0 { parts.append("\(Format.disk(disk)) on disk") }
            return parts.joined(separator: " · ")
        }
    }
}
