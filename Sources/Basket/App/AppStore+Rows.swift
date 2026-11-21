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
    var usedByText: String { usedBy.isEmpty ? "—" : usedBy.compactList }
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
        case .running: String(localized: "Running", comment: "State of a container, a machine or the container system")
        case .stopped: String(localized: "Stopped", comment: "State of a container, a machine or the container system")
        case .stopping: String(localized: "Stopping", comment: "State of a container, a machine or the container system")
        case .created: String(localized: "Created (state)", defaultValue: "Created", comment: "Container state: created but never started")
        case .unknown: String(localized: "Unknown", comment: "State of a container, a machine or the container system")
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
                    usedBy: users.containers + users.machines.map {
                        String(localized: "machine \($0)", comment: "A Linux machine named in a list of image users")
                    }
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
    /// Each part is a whole phrase with at most one number, so every number gets its own plural.
    func statusLine(for section: AppSection) -> String {
        /// "12 images", plus "3 shown" while a search hides some.
        func counted(_ totalText: String, visible: Int, total: Int) -> [String] {
            visible == total ? [totalText]
                : [totalText, String(localized: "\(visible) shown", comment: "Status bar: how many items match the search")]
        }
        // OrbStack's side reads fine while Basket's container system is stopped.
        if section == .migration { return migration.statusLine }
        switch availability {
        case .stopped: return String(localized: "Container system stopped")
        case .cliMissing: return String(localized: "container CLI not found")
        default: break
        }
        switch section {
        case .overview:
            return ""
        case .containers:
            let running = runningContainers
            let total = containers.count, visible = containerRows.count
            var parts = counted(String(localized: "\(total) containers", comment: "Status bar"), visible: visible, total: total)
            parts.append(String(localized: "\(running.count) running", comment: "Status bar: number of running containers or machines"))
            let projects = Set(containers.compactMap(ComposeProject.projectName(of:))).count
            if projects > 0 { parts.append(String(localized: "\(projects) compose projects", comment: "Status bar")) }
            if !running.isEmpty {
                let cpu = running.compactMap { cpuPercent[$0.id] }.reduce(0, +)
                let guest = running.compactMap { latestStats[$0.id]?.memoryUsageBytes }.reduce(0, +)
                let host = running.compactMap { hostMemoryByOwner[$0.id] }.reduce(0, +)
                parts.append(String(localized: "CPU \(Format.percent(cpu))", comment: "Status bar: total CPU use"))
                parts.append(String(localized: "\(Format.memory(guest)) used in guests", comment: "Status bar: memory the guests use"))
                if footprintsAvailable {
                    parts.append(String(localized: "\(Format.memory(host)) on this Mac", comment: "Status bar: host memory the VMs cost"))
                }
            }
            return parts.joined(separator: " · ")
        case .images:
            let totalBytes = images.reduce(Int64(0)) { $0 + $1.totalSizeBytes }
            let extra = images.reduce(Int64(0)) { $0 + max(0, $1.totalSizeBytes - $1.hostVariantSizeBytes) }
            let unused = imageUsage.unused(images)
            let total = images.count, visible = imageRows.count
            var parts = counted(String(localized: "\(total) images", comment: "Status bar"), visible: visible, total: total)
            parts.append(String(localized: "\(Format.disk(totalBytes)) on disk", comment: "Status bar: disk space used"))
            if extra > 0 { parts.append(String(localized: "\(Format.disk(extra)) for other platforms", comment: "Status bar: disk space taken by other CPU architectures")) }
            if !unused.isEmpty { parts.append(String(localized: "\(unused.count) unused", comment: "Status bar: number of unused images")) }
            return parts.joined(separator: " · ")
        case .volumes:
            let allocated = volumes.reduce(Int64(0)) { $0 + ($1.allocatedBytes ?? 0) }
            let capacity = volumes.reduce(Int64(0)) { $0 + $1.capacityBytes }
            let total = volumes.count, visible = volumeRows.count
            var parts = counted(String(localized: "\(total) volumes", comment: "Status bar"), visible: visible, total: total)
            parts.append(String(localized: "\(Format.disk(allocated)) on disk", comment: "Status bar: disk space used"))
            if capacity > 0 { parts.append(String(localized: "sparse, up to \(Format.memory(capacity))", comment: "Status bar: volumes are sparse disk images that can grow to this size")) }
            return parts.joined(separator: " · ")
        case .networks:
            let attached = containers.reduce(0) { $0 + $1.networks.count }
            let total = networks.count, visible = networkRows.count
            return (counted(String(localized: "\(total) networks", comment: "Status bar"), visible: visible, total: total)
                + [String(localized: "\(attached) container attachments", comment: "Status bar: how many container–network connections exist")])
                .joined(separator: " · ")
        case .migration:
            return migration.statusLine
        case .machines:
            let running = machines.filter { $0.state == .running }
            let disk = machines.reduce(Int64(0)) { $0 + ($1.diskBytes ?? 0) }
            let host = running.compactMap { hostMemoryByOwner[$0.id] }.reduce(0, +)
            let total = machines.count, visible = machineRows.count
            var parts = counted(String(localized: "\(total) machines", comment: "Status bar"), visible: visible, total: total)
            parts.append(String(localized: "\(running.count) running", comment: "Status bar: number of running containers or machines"))
            if footprintsAvailable, !running.isEmpty {
                parts.append(String(localized: "\(Format.memory(host)) on this Mac", comment: "Status bar: host memory the VMs cost"))
            }
            if disk > 0 { parts.append(String(localized: "\(Format.disk(disk)) on disk", comment: "Status bar: disk space used")) }
            return parts.joined(separator: " · ")
        }
    }
}
