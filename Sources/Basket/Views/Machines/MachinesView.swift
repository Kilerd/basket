import SwiftUI
import BasketCore

struct MachinesView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let rows = store.machineRows
        ListSectionBody(section: .machines, isEmpty: rows.isEmpty) {
            MachinesTable(rows: rows)
        } empty: {
            SectionEmptyState(
                section: .machines, title: "No Machines", systemImage: "desktopcomputer",
                message: "A machine is a full Linux environment with your home folder mounted — like an OrbStack machine, booted on demand."
            ) {
                Button("New Machine…") { store.activeSheet = .newMachine }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("machines.action.new-empty")
            }
        }
        .navigationTitle("Machines")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
    }

    private var subtitle: String {
        let running = store.machines.filter { $0.state == .running }.count
        return String(localized: "\(running) running of \(store.machines.count)", comment: "Running containers or machines, of all of them")
    }

    private var selected: MachineSummary? {
        guard store.machineSelection.count == 1, let id = store.machineSelection.first else { return nil }
        return store.machines.first { $0.id == id }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let machine = selected
        ToolbarItemGroup {
            ToolbarActionButton(title: "New Machine", systemImage: "plus", identifier: "machines.action.new",
                                help: "New Machine (⌘N)") {
                store.activeSheet = .newMachine
            }
            .disabled(store.availability != .running)
            ToolbarActionButton(title: "Open Shell", systemImage: "apple.terminal", identifier: "machines.action.shell",
                                help: "Open a shell in Terminal (boots the machine if needed)") {
                if let machine { store.openShell(machine: machine.id) }
            }
            .disabled(machine == nil)
            ToolbarActionButton(title: "Start", systemImage: "play.fill", identifier: "machines.action.start") {
                if let machine { Task { await store.startMachine(machine.id) } }
            }
            .disabled(machine == nil || machine?.state == .running)
            ToolbarActionButton(title: "Stop", systemImage: "stop.fill", identifier: "machines.action.stop") {
                if let machine { Task { await store.stopMachine(machine.id) } }
            }
            .disabled(machine?.state != .running)
            ToolbarActionButton(title: "Make Default", systemImage: "star", identifier: "machines.action.set-default",
                                help: "Use this machine when no name is given") {
                if let machine { Task { await store.setDefaultMachine(machine.id) } }
            }
            .disabled(machine == nil || machine?.isDefault == true)
            ToolbarActionButton(title: "Delete", systemImage: "trash", identifier: "machines.action.delete", help: "Delete (⌫)") {
                if let machine { store.confirmDeleteMachine(machine.id) }
            }
            .disabled(machine == nil)
            RefreshButton(section: .machines)
        }
        CommonToolbarItems(section: .machines)
    }
}

private struct MachinesTable: View {
    @Environment(AppStore.self) private var store
    var rows: [MachineRow]

    var body: some View {
        @Bindable var store = store
        Table(rows, selection: $store.machineSelection, sortOrder: $store.machineSort) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    Text(row.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .accessibilityIdentifier("machines.row.\(row.id)")
                    if row.summary.isDefault {
                        Pill(text: "Default", systemImage: "star.fill", tint: Series.blue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 110, ideal: 140)
            TableColumn("Image", value: \.image) { row in
                Text(ImageName(row.image).display).foregroundStyle(.secondary).lineLimit(1).help(row.image)
            }
                .width(min: 90, ideal: 110)
            TableColumn("State", value: \.stateOrder) { row in
                StateBadge(state: row.summary.state, pendingVerb: store.pending[row.id])
            }
            .width(min: 90, ideal: 100)
            TableColumn("CPUs", value: \.cpus) { row in NumericCell("\(row.cpus)") }
                .width(min: 40, ideal: 50)
                .alignment(.numeric)
            TableColumn("Memory", value: \.memory) { row in
                NumericCell(row.memory > 0 ? Format.memory(row.memory) : "—", isPlaceholder: row.memory <= 0)
                    .help("Memory limit of the machine's VM")
            }
            .width(min: 92, ideal: 96)  // "Arbeitsspeicher"
            .alignment(.numeric)
            TableColumn("Host Memory", value: \.hostMemory) { row in
                NumericCell(row.hostMemory < 0 ? "—" : Format.memory(row.hostMemory), isPlaceholder: row.hostMemory < 0)
                    .help("Physical memory macOS pays for this machine's VM")
            }
            .width(min: 80, ideal: 95)
            .alignment(.numeric)
            TableColumn("Disk", value: \.disk) { row in
                NumericCell(row.disk < 0 ? "—" : Format.disk(row.disk), isPlaceholder: row.disk < 0)
                    .help("Space the machine's disk image occupies on your Mac")
            }
            .width(min: 70, ideal: 80)
            .alignment(.numeric)
            TableColumn("Home") { row in Text(homeMountTitle(row.summary.homeMount)).foregroundStyle(.secondary) }
                .width(min: 124, ideal: 128)  // "Lecture et écriture", "Lesen & Schreiben"
            TableColumn("IP Address") { row in
                Text(row.summary.ipv4Address ?? "—").font(.body.monospaced()).foregroundStyle(.secondary)
            }
            .width(min: 112, ideal: 115)  // a full IPv4 address
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first, let m = store.machines.first(where: { $0.id == id }) {
                Button("Open Shell in Terminal", systemImage: "apple.terminal") { store.openShell(machine: m.id) }
                if m.state == .running {
                    Button("Stop", systemImage: "stop.fill") { Task { await store.stopMachine(m.id) } }
                } else {
                    Button("Start", systemImage: "play.fill") { Task { await store.startMachine(m.id) } }
                }
                if !m.isDefault {
                    Button("Make Default", systemImage: "star") { Task { await store.setDefaultMachine(m.id) } }
                }
                if let ip = m.ipv4Address {
                    Button("Copy IP Address (\(ip))", systemImage: "doc.on.doc") { HostActions.copy(ip) }
                }
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive) { store.confirmDeleteMachine(m.id) }
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { store.openShell(machine: id) }
        }
        .onDeleteCommand { if let id = store.machineSelection.first { store.confirmDeleteMachine(id) } }
        .accessibilityIdentifier("machines.list")
    }

    private func homeMountTitle(_ mode: String) -> String {
        switch mode {
        case "rw": String(localized: "Read-write", comment: "How a machine mounts your home folder")
        case "ro": String(localized: "Read-only", comment: "How a machine mounts your home folder")
        case "none": String(localized: "Not mounted", comment: "How a machine mounts your home folder")
        default: mode
        }
    }
}

struct NewMachineSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var preset = Preset.ubuntu
    @State private var customImage = ""
    @State private var name = ""
    @State private var cpus = 2
    @State private var memoryMB = 2048
    @State private var makeDefault = false
    @State private var lines: [String] = []
    @State private var phase = Phase.idle
    @State private var task: Task<Void, Never>?

    enum Phase: Equatable { case idle, creating, done, failed(String) }

    enum Preset: String, CaseIterable, Identifiable {
        case ubuntu, debian, fedora, alpine, custom
        var id: String { rawValue }
        var image: String? {
            switch self {
            case .ubuntu: "ubuntu:24.04"
            case .debian: "debian:12"
            case .fedora: "fedora:42"
            case .alpine: "alpine:3.22"
            case .custom: nil
            }
        }
        var title: String {
            switch self {
            case .ubuntu: "Ubuntu 24.04"
            case .debian: "Debian 12"
            case .fedora: "Fedora 42"
            case .alpine: "Alpine 3.22"
            case .custom: String(localized: "Custom image…")
            }
        }
    }

    var body: some View {
        SheetScaffold(
            title: "New Machine",
            subtitle: "A full Linux environment that boots in its own VM and shares your home folder.",
            identifier: "sheet.new-machine", height: 520
        ) {
            Section {
                Picker("Distribution", selection: $preset) {
                    ForEach(Preset.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("new-machine.preset")
                if preset == .custom {
                    TextField("Image", text: $customImage, prompt: Text(verbatim: "archlinux:latest"))
                        .accessibilityIdentifier("new-machine.image")
                }
                TextField("Name", text: $name, prompt: Text(defaultName))
                    .accessibilityIdentifier("new-machine.name")
            }
            Section {
                StepperRow(title: "CPUs", value: $cpus, range: 1...max(1, store.system?.hostCPUs ?? 8),
                           identifier: "new-machine.cpus")
                Picker("Memory", selection: $memoryMB) {
                    // The CLI requires more than 1 GB for a machine.
                    ForEach(memoryChoicesMB.filter { $0 > 1024 }, id: \.self) { Text(memoryChoiceLabel($0)).tag($0) }
                }
                .accessibilityIdentifier("new-machine.memory")
                Toggle("Make this the default machine", isOn: $makeDefault)
                    .accessibilityIdentifier("new-machine.default")
            } header: {
                Text("Resources")
            } footer: {
                Text("Without a limit the CLI would reserve half of your Mac's memory. Machines need more than \(memoryChoiceLabel(1024)); \(memoryChoiceLabel(2048)) is plenty for most shells and builds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if phase != .idle {
                Section("Progress") {
                    switch phase {
                    case .creating: ProgressLog(lines: lines, identifier: "new-machine.progress")
                    case .done: Label("Machine is ready", systemImage: "checkmark.circle.fill").foregroundStyle(Color.successText)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.warningText).textSelection(.enabled)
                    case .idle: EmptyView()
                    }
                }
            }
        } footer: {
            Spacer()
            if phase == .done {
                Button("Open Shell") { store.openShell(machine: resolvedName); dismiss() }
                    .accessibilityIdentifier("new-machine.shell")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("new-machine.done")
            } else {
                Button("Cancel", role: .cancel) { task?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("new-machine.cancel")
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(phase == .creating || image.isEmpty)
                    .accessibilityIdentifier("new-machine.create")
            }
        }
        .onDisappear { task?.cancel() }
    }

    private var image: String {
        (preset.image ?? customImage).trimmingCharacters(in: .whitespaces)
    }

    private var defaultName: String {
        let base = (preset == .custom ? ImageName(customImage).repository : preset.rawValue)
        return base.isEmpty ? "machine" : base.replacingOccurrences(of: "/", with: "-")
    }

    private var resolvedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? defaultName : trimmed
    }

    private func create() {
        let backend = store.backend
        let image = self.image
        let name = resolvedName
        let cpus = self.cpus
        let memory = MemorySize.cliString(megabytes: memoryMB)
        let makeDefault = self.makeDefault
        lines = [String(localized: "Creating \(name) from \(image)…", comment: "Creating a machine: its name, then the image")]
        phase = .creating
        task = Task {
            do {
                for try await line in backend.createMachine(image: image, name: name, cpus: cpus, memory: memory) {
                    lines.append(line)
                    if lines.count > 500 { lines.removeFirst(lines.count - 500) }
                }
                if makeDefault { try await backend.setDefaultMachine(name) }
                phase = .done
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
            await store.refresh([.machines, .footprints, .disk])
            store.machineSelection = [name]
        }
    }
}
