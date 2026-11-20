import Foundation

/// Containers that share a `com.docker.compose.project` label, shown as one collapsible group.
public struct ComposeProject: Identifiable, Sendable, Hashable {
    public enum State: Sendable, Hashable {
        /// Every service is running.
        case running
        /// Some services are running.
        case partial
        case stopped
    }

    public var name: String
    public var id: String { name }
    /// Sorted by service name.
    public var containers: [ContainerSummary]
    /// `com.docker.compose.project.working_dir` of its containers.
    public var workingDirectory: String?
    /// `com.docker.compose.project.config_files` (comma-separated in the label).
    public var configFiles: [String]

    public init(name: String, containers: [ContainerSummary]) {
        self.name = name
        self.containers = containers.sorted {
            (Self.serviceName(of: $0), $0.id) < (Self.serviceName(of: $1), $1.id)
        }
        let labels = containers.map(\.labels)
        workingDirectory = labels.lazy.compactMap { $0[ComposeLabels.workingDir] }.first { !$0.isEmpty }
        configFiles = labels.lazy.compactMap { $0[ComposeLabels.configFiles] }.first { !$0.isEmpty }
            .map { $0.split(separator: ",").map(String.init) } ?? []
    }

    public var runningCount: Int { containers.filter { $0.state == .running }.count }
    public var totalCount: Int { containers.count }

    public var state: State {
        switch runningCount {
        case 0: .stopped
        case totalCount: .running
        default: .partial
        }
    }

    /// Whether Basket created it from a compose file (as opposed to labels set by hand).
    public var isBasketManaged: Bool { containers.contains { $0.labels[ComposeLabels.basket] == "1" } }

    public var services: [String] { containers.map(Self.serviceName(of:)) }

    /// The compose file Basket can reopen (first config file that is an absolute path).
    public var configFile: URL? {
        configFiles.first { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
    }

    public static func projectName(of container: ContainerSummary) -> String? {
        container.labels[ComposeLabels.project].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The service label, else the container id.
    public static func serviceName(of container: ContainerSummary) -> String {
        container.labels[ComposeLabels.service].flatMap { $0.isEmpty ? nil : $0 } ?? container.id
    }

    /// Splits containers into compose projects (sorted by name) and standalone containers (input order).
    public static func group(_ containers: [ContainerSummary]) -> (projects: [ComposeProject], standalone: [ContainerSummary]) {
        var members: [String: [ContainerSummary]] = [:]
        var standalone: [ContainerSummary] = []
        for container in containers {
            if let project = projectName(of: container) {
                members[project, default: []].append(container)
            } else {
                standalone.append(container)
            }
        }
        let projects = members.map { ComposeProject(name: $0.key, containers: $0.value) }.sorted { $0.name < $1.name }
        return (projects, standalone)
    }

    /// Services ordered so dependencies come first (from `com.docker.compose.depends_on`), then by name.
    public var startOrder: [ContainerSummary] {
        let byService = Dictionary(containers.map { (Self.serviceName(of: $0), $0) }, uniquingKeysWith: { a, _ in a })
        var placed: Set<String> = []
        var result: [ContainerSummary] = []
        var remaining = containers
        while !remaining.isEmpty {
            let index = remaining.firstIndex { container in
                Self.dependencies(of: container).allSatisfy { byService[$0] == nil || placed.contains($0) }
            } ?? 0  // a cycle in hand-written labels: just go on in name order
            let next = remaining.remove(at: index)
            placed.insert(Self.serviceName(of: next))
            result.append(next)
        }
        return result
    }

    /// "db:service_started:false,cache:service_healthy:false" → ["db", "cache"]
    public static func dependencies(of container: ContainerSummary) -> [String] {
        (container.labels[ComposeLabels.dependsOn] ?? "").split(separator: ",").compactMap {
            $0.split(separator: ":").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }.filter { !$0.isEmpty }
    }
}
