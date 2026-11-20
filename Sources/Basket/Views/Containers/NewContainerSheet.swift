import SwiftUI
import BasketCore

struct NewContainerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RunDraft
    @State private var ports: [ListEntry]
    @State private var environment: [ListEntry]
    @State private var volumes: [ListEntry]
    @State private var isRunning = false
    @State private var error: String?

    init(draft: RunDraft) {
        _draft = State(initialValue: draft)
        _ports = State(initialValue: draft.ports.map { ListEntry(value: $0) })
        _environment = State(initialValue: draft.environment.map { ListEntry(value: $0) })
        _volumes = State(initialValue: draft.volumes.map { ListEntry(value: $0) })
    }

    var body: some View {
        SheetScaffold(
            title: "New Container",
            subtitle: "The container runs in its own lightweight VM. Its memory is returned to macOS when it stops.",
            identifier: "sheet.new-container", height: 640
        ) {
            Section("Image") {
                HStack {
                    TextField("Image", text: $draft.image, prompt: Text("nginx:latest"))
                        .accessibilityIdentifier("new-container.image")
                    if !store.images.isEmpty {
                        Menu {
                            ForEach(store.images) { image in
                                Button(ImageName(image.reference).display) { draft.image = image.reference }
                            }
                        } label: {
                            Image(systemName: "square.stack.3d.up")
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Choose a local image")
                        .accessibilityLabel("Choose a local image")
                    }
                }
                TextField("Name", text: $draft.name, prompt: Text("Optional"))
                    .accessibilityIdentifier("new-container.name")
                TextField("Command", text: $draft.command, prompt: Text("Image default"))
                    .accessibilityIdentifier("new-container.command")
            }
            Section {
                StepperRow(title: "CPUs", value: $draft.cpus, range: 1...max(1, store.system?.hostCPUs ?? 8),
                           identifier: "new-container.cpus")
                Picker("Memory", selection: $draft.memoryMB) {
                    ForEach(Array(Set(memoryChoicesMB + [draft.memoryMB])).sorted(), id: \.self) { mb in
                        Text(memoryChoiceLabel(mb)).tag(mb)
                    }
                }
                .accessibilityIdentifier("new-container.memory")
            } header: {
                Text("Resources")
            } footer: {
                Text("The VM can use up to this much memory; most containers need far less than 1 GB.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ports") {
                StringListEditor(noun: "Port", placeholder: "8080:80", identifier: "new-container.add-port", entries: $ports)
            }
            Section("Volumes") {
                StringListEditor(noun: "Volume", placeholder: "my-volume:/data or /host/path:/path",
                                 identifier: "new-container.add-volume", entries: $volumes)
            }
            Section("Environment") {
                StringListEditor(noun: "Variable", placeholder: "KEY=value", identifier: "new-container.add-env",
                                 entries: $environment)
            }
            Section("Options") {
                Picker("Network", selection: $draft.network) {
                    Text("Default").tag("")
                    ForEach(store.networks.filter { !$0.isBuiltin }) { Text($0.name).tag($0.name) }
                }
                .accessibilityIdentifier("new-container.network")
                Toggle("Remove when stopped", isOn: $draft.removeOnExit)
                    .accessibilityIdentifier("new-container.remove-on-exit")
            }
        } footer: {
            if isRunning {
                ProgressView().controlSize(.small)
                Text("Starting… (the image is pulled first if needed)").foregroundStyle(.secondary).font(.callout)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("new-container.cancel")
            Button("Create & Run") { run() }
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || draft.image.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("new-container.run")
        }
    }

    private func run() {
        draft.ports = ports.map(\.value)
        draft.environment = environment.map(\.value)
        draft.volumes = volumes.map(\.value)
        let spec = draft.spec
        isRunning = true
        error = nil
        Task {
            do {
                _ = try await store.runContainer(spec)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isRunning = false
        }
    }
}
