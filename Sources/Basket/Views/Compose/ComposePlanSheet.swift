import SwiftUI
import BasketCore

/// "Compose Up…": what Basket will create for a compose file (services, memory, the equivalent
/// `container` commands, what doesn't carry over), then `up` with streamed progress.
struct ComposePlanSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var loaded: Result<ComposePlan, Error>?
    @State private var phase = Phase.idle
    @State private var lines: [String] = []
    @State private var task: Task<Void, Never>?

    enum Phase: Equatable { case idle, running, done, failed(String) }

    var body: some View {
        SheetScaffold(
            title: "\(title)",
            subtitle: "Basket runs each service in its own lightweight VM, with the memory shown below.",
            identifier: "sheet.compose-plan", width: 820, height: 720
        ) {
            switch loaded {
            case .success(let plan)?:
                PlanSections(plan: plan, existing: existingProblem(plan), phase: phase, lines: lines)
            case .failure(let error)?:
                Section {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("compose-plan.error")
                } header: {
                    Text("Basket can't read \(url.lastPathComponent)")
                }
            case nil:
                Section { ProgressView("Reading \(url.lastPathComponent)…") }
            }
        } footer: {
            footer
        }
        .onAppear(perform: load)
        .onDisappear { task?.cancel() }
        .interactiveDismissDisabled(phase == .running)
    }

    private var title: String {
        if case .success(let plan)? = loaded { return "Compose Up “\(plan.project)”" }
        return "Compose Up"
    }

    private var plan: ComposePlan? {
        if case .success(let plan)? = loaded { return plan }
        return nil
    }

    @ViewBuilder private var footer: some View {
        Button("Copy Commands") { if let plan { HostActions.copy(plan.commandLines().joined(separator: "\n")) } }
            .disabled(plan == nil)
            .accessibilityIdentifier("compose-plan.copy")
        Spacer()
        switch phase {
        case .done:
            Button("Show in Containers") {
                if let plan {
                    store.containerSelection = []
                    store.selectedComposeProject = plan.project
                    store.composeDetailTab = .overview
                    store.selectedSection = .containers
                }
                dismiss()
            }
            .accessibilityIdentifier("compose-plan.show")
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("compose-plan.done")
        default:
            Button(phase == .running ? "Stop Waiting" : "Cancel", role: .cancel) {
                task?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("compose-plan.cancel")
            Button(isFailed ? "Try Again" : "Up") { up() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canUp)
                .help(store.availability == .running ? "Create the networks and volumes, then start every service" : "Start the container system first")
                .accessibilityIdentifier("compose-plan.up")
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var canUp: Bool {
        guard let plan, phase == .idle || isFailed, store.availability == .running else { return false }
        return existingProblem(plan)?.blocking != true
    }

    /// Name clashes block `up`; an existing project of the same name is reused.
    private func existingProblem(_ plan: ComposePlan) -> (message: String, blocking: Bool)? {
        let names = Set(plan.services.map(\.containerName))
        if let clash = store.containers.first(where: { names.contains($0.id) && ComposeProject.projectName(of: $0) != plan.project }) {
            return ("A container named “\(clash.id)” already exists outside this project. Rename or delete it first.", true)
        }
        if phase == .idle, store.containers.contains(where: { ComposeProject.projectName(of: $0) == plan.project }) {
            return ("Project “\(plan.project)” already exists: Up starts its stopped services and leaves running ones as they are. Take it down first to apply changes to the file.", false)
        }
        return nil
    }

    private func load() {
        guard loaded == nil else { return }
        loaded = Result {
            try ComposePlanner.plan(try ComposeLoader.load(fileAt: url), options: store.composePlanOptions)
        }
    }

    private func up() {
        guard let plan else { return }
        phase = .running
        lines = []
        let backend = store.backend
        task = Task {
            let (stream, continuation) = AsyncStream<String>.makeStream()
            let consumer = Task { @MainActor in
                for await line in stream { lines.append(line) }
            }
            do {
                try await ComposeOperations(backend: backend).up(plan) { continuation.yield($0) }
                continuation.finish()
                await consumer.value
                phase = .done
            } catch {
                continuation.finish()
                await consumer.value
                phase = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
            await store.refresh([.containers, .stats, .footprints, .networks, .volumes, .disk])
        }
    }
}

// MARK: - Sections

private struct PlanSections: View {
    var plan: ComposePlan
    var existing: (message: String, blocking: Bool)?
    var phase: ComposePlanSheet.Phase
    var lines: [String]

    var body: some View {
        Section {
            let file = plan.configFiles.first ?? plan.workingDirectory
            LabeledContent("Compose file") {
                Text((file as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file)
                    .accessibilityIdentifier("compose-plan.file")
            }
            ResourceSummary(plan: plan)
            if let discovery {
                Label(discovery.message, systemImage: "network")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("compose-plan.service-names")
            }
            if let existing {
                Label(existing.message, systemImage: existing.blocking ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(existing.blocking ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("compose-plan.existing")
            }
        } header: {
            Text("Project “\(plan.project)”")
        }

        Section {
            ServicesGrid(plan: plan)
        } header: {
            Text("Services, in start order")
        }

        if phase != .idle {
            Section {
                ProgressLines(lines: lines, phase: phase)
            } header: {
                Text("Progress")
            }
        }

        Section {
            ForEach(Array(sortedWarnings.enumerated()), id: \.element.id) { index, warning in
                ComposeWarningRow(warning: warning)
                    .accessibilityIdentifier("compose-plan.warning.\(index)")
            }
        } header: {
            Text("Notes and what doesn't carry over (\(sortedWarnings.count))")
        }

        Section {
            Text(plan.commandLines().joined(separator: "\n\n"))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Equivalent commands")
                .accessibilityIdentifier("compose-plan.commands")
        } header: {
            Text("Equivalent commands")
        }
    }

    /// How services find each other (shown in the summary, not in the list).
    private var discovery: ComposeWarning? {
        plan.warnings.first { $0.service == nil && $0.topic == "Service names" }
    }

    /// Warnings before notes; otherwise the planner's order.
    private var sortedWarnings: [ComposeWarning] {
        let rest = plan.warnings.filter { $0 != discovery }
        return rest.filter { $0.severity == .warning } + rest.filter { $0.severity == .info }
    }
}

/// What the project costs: memory limits plus the estimated per-VM overhead, and CPUs.
private struct ResourceSummary: View {
    var plan: ComposePlan

    var body: some View {
        let r = plan.resources
        LabeledContent("Memory") {
            Text("\(Format.memory(r.memoryLimitBytes)) limits + ≈ \(Format.memory(r.overheadBytes)) VM overhead = up to \(Format.memory(r.memoryLimitBytes + r.overheadBytes)) on this Mac")
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("compose-plan.memory")
        }
        .help("Each service is its own VM: the guest may use its limit, and the VM costs about 240–290 MB on top")
        LabeledContent("CPUs") {
            Text(r.defaultCPUServices > 0 ? "\(r.cpus) + system default" : "\(r.cpus)")
                .monospacedDigit()
                .accessibilityIdentifier("compose-plan.cpus")
        }
    }
}

/// Service | Image | Memory | CPUs | Ports in fixed-width columns; numbers right-aligned.
private struct ServicesGrid: View {
    var plan: ComposePlan

    static let serviceWidth: CGFloat = 150
    static let imageWidth: CGFloat = 190
    static let memoryWidth: CGFloat = 70
    static let defaultWidth: CGFloat = 50
    static let cpuWidth: CGFloat = 40

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Service").frame(width: Self.serviceWidth, alignment: .leading)
                Text("Image").frame(width: Self.imageWidth, alignment: .leading)
                Text("Memory").frame(width: Self.memoryWidth, alignment: .trailing)
                Color.clear.frame(width: Self.defaultWidth, height: 1)
                Text("CPUs").frame(width: Self.cpuWidth, alignment: .trailing)
                Text("Ports").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            ForEach(plan.services) { service in
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(service.name).fontWeight(.medium)
                        Text(service.containerName).font(.caption).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: Self.serviceWidth, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("compose-plan.service.\(service.name)")
                    Text(service.spec.image)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.imageWidth, alignment: .leading)
                        .help(service.spec.image)
                    Text(Format.memory(service.memoryBytes))
                        .monospacedDigit()
                        .frame(width: Self.memoryWidth, alignment: .trailing)
                        .help(service.memoryIsDefault ? "No limit in the file: the default from Settings" : "From the file")
                    Text(service.memoryIsDefault ? "default" : "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.defaultWidth, alignment: .leading)
                    Text(service.spec.cpus.map(String.init) ?? "—")
                        .monospacedDigit()
                        .frame(width: Self.cpuWidth, alignment: .trailing)
                    Text(service.portsSummary.isEmpty ? "—" : service.portsSummary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(service.portsSummary.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(service.portsSummary)
                }
            }
            if plan.services.contains(where: \.memoryIsDefault) {
                GridRow {
                    Text("“default”: no memory limit in the file. Each container is its own VM, so it gets the default from Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridCellColumns(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Services")
        .accessibilityIdentifier("compose-plan.services")
    }
}

private struct ProgressLines: View {
    var lines: [String]
    var phase: ComposePlanSheet.Phase

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            switch phase {
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working…").foregroundStyle(.secondary)
                }
            case .done:
                Label("Up and running", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compose-plan.progress")
    }
}

struct ComposeWarningRow: View {
    var warning: ComposeWarning

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: warning.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(warning.severity == .warning ? .orange : .secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(topic).fontWeight(.semibold)
                Text(warning.message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(warning.severity == .warning ? "Warning" : "Note"): \(topic). \(warning.message)")
    }

    private var topic: String {
        warning.service.map { "\($0) · \(warning.topic)" } ?? warning.topic
    }
}
