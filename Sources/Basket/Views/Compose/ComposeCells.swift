import SwiftUI
import BasketCore

extension ComposeProject.State {
    var symbol: String {
        switch self {
        case .running: "play.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .stopped: "stop.circle"
        }
    }

    var color: Color {
        switch self {
        case .running: .green
        case .partial: .orange
        case .stopped: .secondary
        }
    }
}

extension ComposeProject {
    /// "3/4 running"
    var runningSummary: String { "\(runningCount)/\(totalCount) running" }
}

/// Name cell of the containers table. With compose projects present every row gets the same two
/// leading slots — disclosure button (project rows) and an icon: the project's stack, a tree line
/// for its services, a box for standalone containers — so names start at one x in every row.
struct ContainerNameCell: View {
    @Environment(AppStore.self) private var store
    var row: ContainerRow
    /// The table shows compose projects (otherwise rows look exactly as before: just the name).
    var grouped: Bool
    /// Last service of its project: the tree line ends here.
    var isLastService = false

    static let disclosureWidth: CGFloat = 20
    static let iconWidth: CGFloat = 16

    var body: some View {
        HStack(spacing: 6) {
            if grouped {
                disclosure
                icon.frame(width: Self.iconWidth).accessibilityHidden(true)
            }
            if let project = row.project {
                Text(project.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Compose project \(project.name)" + (project.workingDirectory.map { " in \($0)" } ?? ""))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHint("Compose project with \(project.totalCount) service\(project.totalCount == 1 ? "" : "s"), \(project.runningSummary)")
                    .accessibilityIdentifier("containers.group.\(project.name)")
            } else if row.summary.labels[ComposeLabels.project] != nil {
                let service = ComposeProject.serviceName(of: row.summary)
                HStack(spacing: 6) {
                    Text(service)
                        .fontWeight(.medium)
                        .layoutPriority(1)
                    Text(row.summary.id)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
                .help("Service \(service) of \(row.summary.labels[ComposeLabels.project] ?? ""), container \(row.summary.id)")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("containers.row.\(row.id)")
            } else {
                Text(row.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.name)
                    .accessibilityIdentifier("containers.row.\(row.id)")
            }
            Spacer(minLength: 0)
        }
    }

    /// The button's 20 pt hit target overhangs a text-height slot, so project rows keep the table's
    /// row height.
    @ViewBuilder private var disclosure: some View {
        Color.clear
            .frame(width: Self.disclosureWidth, height: 16)
            .overlay { disclosureButton }
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var disclosureButton: some View {
        if let project = row.project {
            let expanded = !store.collapsedComposeProjects.contains(project.name)
            Button {
                if expanded {
                    store.collapsedComposeProjects.insert(project.name)
                } else {
                    store.collapsedComposeProjects.remove(project.name)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.disclosureWidth, height: Self.disclosureWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the services of \(project.name)" : "Show the services of \(project.name)")
            .accessibilityLabel(expanded ? "Collapse \(project.name)" : "Expand \(project.name)")
            .accessibilityIdentifier("containers.group.\(project.name).toggle")
        }
    }

    @ViewBuilder private var icon: some View {
        if let project = row.project {
            Image(systemName: "square.3.layers.3d")
                .foregroundStyle(project.state == .stopped ? Color.secondary : Series.blue)
        } else if row.summary.labels[ComposeLabels.project] != nil {
            TreeLine(isLast: isLastService)
                .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                .frame(height: 16)
        } else {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
        }
    }
}

/// "├" / "└" connecting a service to its project above.
struct TreeLine: Shape {
    var isLast: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.midX.rounded() + 0.5
        // Rows are ~24 pt apart and the slot is text-high: reach into the gaps to join the rows.
        path.move(to: CGPoint(x: x, y: rect.minY - 6))
        path.addLine(to: CGPoint(x: x, y: isLast ? rect.midY : rect.maxY + 6))
        path.move(to: CGPoint(x: x, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// "▶ 3/4 running" — same geometry as `StateBadge`, so the column lines up with container rows.
struct ComposeStateBadge: View {
    var project: ComposeProject
    var pendingVerb: String?

    var body: some View {
        HStack(spacing: 5) {
            if let pendingVerb {
                ProgressView().controlSize(.mini)
                Text(pendingVerb + "…").foregroundStyle(.secondary)
            } else {
                Image(systemName: project.state.symbol).foregroundStyle(project.state.color).accessibilityHidden(true)
                Text(project.runningSummary)
            }
        }
        .lineLimit(1)
    }
}

extension ComposeLabels {
    /// Labels Compose/Basket manage; the container's Info tab shows them as the Compose section.
    static func isManaged(_ key: String) -> Bool {
        key.hasPrefix("com.docker.compose.") || key == basket || key.hasPrefix(basket + ".")
    }
}

/// Info-tab row for a container that belongs to a compose project ("shop · service api").
struct ComposeServiceRow: View {
    var container: ContainerSummary

    var body: some View {
        if let project = ComposeProject.projectName(of: container) {
            let dependencies = ComposeProject.dependencies(of: container)
            InfoRow(
                label: "Compose",
                value: "\(project) · service \(ComposeProject.serviceName(of: container))"
                    + (dependencies.isEmpty ? "" : " · after \(dependencies.joined(separator: ", "))"))
        }
    }
}
