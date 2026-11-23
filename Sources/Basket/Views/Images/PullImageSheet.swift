import SwiftUI
import BasketCore

struct PullImageSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var reference: String
    @State private var platformChoice = PlatformChoice.host
    @State private var customPlatform = ""
    @State private var lines: [String] = []
    @State private var phase = Phase.idle
    @State private var task: Task<Void, Never>?

    enum PlatformChoice: Hashable { case host, amd64, custom }
    enum Phase: Equatable { case idle, pulling, done, failed(String) }

    init(reference: String) {
        _reference = State(initialValue: reference)
    }

    var body: some View {
        SheetScaffold(
            title: "Pull Image",
            subtitle: "Basket pulls only the platform this Mac runs. A multi-platform pull of alpine stores about ten variants.",
            identifier: "sheet.pull-image", height: 480
        ) {
            Section {
                TextField("Image", text: $reference, prompt: Text("alpine:latest or ghcr.io/org/app:1.0"))
                    .disabled(phase == .pulling)
                    .onSubmit { if canPull { pull() } }
                    .accessibilityIdentifier("pull-image.reference")
                Picker("Platform", selection: $platformChoice) {
                    Text("This Mac (\(store.hostPlatform)) — recommended").tag(PlatformChoice.host)
                    Text("Intel (linux/amd64, runs with Rosetta)").tag(PlatformChoice.amd64)
                    Text("Other…").tag(PlatformChoice.custom)
                }
                .disabled(phase == .pulling)
                .accessibilityIdentifier("pull-image.platform")
                if platformChoice == .custom {
                    TextField("Custom platform", text: $customPlatform, prompt: Text(verbatim: "linux/arm/v7"))
                        .accessibilityIdentifier("pull-image.custom-platform")
                }
            }
            if phase != .idle {
                Section("Progress") {
                    switch phase {
                    case .pulling:
                        ProgressLog(lines: lines, identifier: "pull-image.progress")
                    case .done:
                        Label("Pulled \(ImageName(reference).display)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.successText)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.warningText)
                            .textSelection(.enabled)
                    case .idle:
                        EmptyView()
                    }
                }
            }
        } footer: {
            Spacer()
            switch phase {
            case .done:
                Button("Run…") { store.runImage(resolvedReference) }
                    .accessibilityIdentifier("pull-image.run")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("pull-image.done")
            default:
                Button("Cancel", role: .cancel) {
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("pull-image.cancel")
                Button("Pull") { pull() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canPull)
                    .accessibilityIdentifier("pull-image.pull")
            }
        }
        .onDisappear { task?.cancel() }
    }

    private var canPull: Bool {
        phase != .pulling && !reference.trimmingCharacters(in: .whitespaces).isEmpty
            && (platformChoice != .custom || !customPlatform.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var platform: String? {
        switch platformChoice {
        case .host: nil
        case .amd64: "linux/amd64"
        case .custom: customPlatform.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Images are listed by their fully-qualified reference.
    private var resolvedReference: String {
        let ref = reference.trimmingCharacters(in: .whitespaces)
        return store.images.first { $0.reference == ref || ImageName($0.reference).display == ImageName(ref).display }?.reference ?? ref
    }

    private func pull() {
        let ref = reference.trimmingCharacters(in: .whitespaces)
        let backend = store.backend
        let platform = self.platform
        lines = [String(localized: "Pulling \(ref)…")]
        phase = .pulling
        task = Task {
            do {
                for try await line in backend.pullImage(ref, platform: platform) {
                    lines.append(line)
                    if lines.count > 500 { lines.removeFirst(lines.count - 500) }
                }
                phase = .done
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
            await store.refresh([.images, .disk])
        }
    }
}
