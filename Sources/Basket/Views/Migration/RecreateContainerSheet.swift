import SwiftUI
import BasketCore

/// Preview of an OrbStack container as a Basket container: the generated `container run` command,
/// everything that doesn't carry over, and "Recreate in Basket".
struct RecreateContainerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let container: OrbStackContainer
    @State private var name = ""
    @State private var phase = Phase.idle
    @State private var task: Task<Void, Never>?

    enum Phase: Equatable { case idle, running(String), done(String), failed(String) }

    var body: some View {
        let model = store.migration
        let plan = model.plan(for: container, name: name)
        SheetScaffold(
            title: "Recreate “\(container.name)” in Basket",
            subtitle: "Basket runs the same image with the settings below in its own lightweight VM. The OrbStack container stays as it is.",
            identifier: "sheet.migration-recreate", width: 640, height: 640
        ) {
            Section {
                TextField("Name in Basket", text: $name)
                    .disabled(phase != .idle)
                    .accessibilityIdentifier("migration.recreate.name")
                LabeledContent("Image") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(plan.image).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Text(imageNote(plan)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let problem = nameProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.warningText)
                }
            }
            Section {
                Text(plan.script)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Command")
                    .accessibilityIdentifier("migration.recreate.command")
            } header: {
                Text("Equivalent command")
            }
            Section {
                if plan.warnings.isEmpty {
                    Label("Everything carries over.", systemImage: "checkmark.circle").foregroundStyle(Color.successText)
                } else {
                    ForEach(plan.warnings) { warning in
                        WarningRow(warning: warning)
                    }
                }
            } header: {
                Text(plan.warnings.isEmpty ? "Notes" : "What doesn't carry over (\(plan.warnings.count))")
            }
            if phase != .idle {
                Section("Progress") {
                    switch phase {
                    case .running(let message):
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(message)
                        }
                    case .done(let id):
                        Label("Running in Basket as \(id)", systemImage: "checkmark.circle.fill").foregroundStyle(Color.successText)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.warningText)
                            .textSelection(.enabled)
                    case .idle:
                        EmptyView()
                    }
                }
                .accessibilityIdentifier("migration.recreate.progress")
            }
        } footer: {
            Button("Copy Command") { HostActions.copy(plan.script) }
                .accessibilityIdentifier("migration.recreate.copy")
            Spacer()
            switch phase {
            case .done(let id):
                Button("Show in Containers") {
                    store.containerSelection = [id]
                    store.selectedSection = .containers
                    dismiss()
                }
                .accessibilityIdentifier("migration.recreate.show")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("migration.recreate.done")
            default:
                Button("Cancel", role: .cancel) {
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("migration.recreate.cancel")
                Button("Recreate in Basket") { recreate(plan) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRecreate)
                    .help(store.availability == .running ? "Run it in Basket now" : "Start Basket's container system first")
                    .accessibilityIdentifier("migration.recreate.run")
            }
        }
        .onAppear { if name.isEmpty { name = model.suggestedName(for: container) } }
        .onDisappear { task?.cancel() }
        .interactiveDismissDisabled(isRunning)
    }

    private var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var nameProblem: String? {
        guard phase == .idle else { return nil }
        if trimmedName.isEmpty { return String(localized: "Enter a name for the container.") }
        if store.containers.contains(where: { $0.id == trimmedName }) {
            return String(localized: "Basket already has a container named “\(trimmedName)”.")
        }
        return nil
    }

    private var canRecreate: Bool {
        (phase == .idle || isFailed) && nameProblem == nil && store.availability == .running
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func imageNote(_ plan: RecreationPlan) -> String {
        let model = store.migration
        if model.basketReferences.contains(plan.image) {
            guard let source = model.image(for: container), source.basketReference == plan.image else {
                return String(localized: "Basket already has an image with this name; it is used as is")
            }
            switch model.basketPresence(source) {
            case .identical?, .absent?: return String(localized: "Already in Basket")
            case .nameConflict(let reason)?: return String(localized: "Name conflict: Basket has a different image with this name: \(reason)")
            case .unverified?: return String(localized: "Basket has an image with this name that couldn't be compared with OrbStack's")
            case nil: return String(localized: "Basket has an image with this name; comparing it with OrbStack's…")
            }
        }
        if let source = model.image(for: container) {
            let size = Format.disk(source.sizeBytes)
            return String(localized: "Imported from OrbStack first (\(source.exportPlatform), up to \(size))")
        }
        return String(localized: "Not in OrbStack; `container run` pulls it")
    }

    private func recreate(_ plan: RecreationPlan) {
        let model = store.migration
        phase = .running(String(localized: "Preparing", comment: "Recreating a container: first progress step"))
        task = Task {
            do {
                let id = try await model.recreate(container, plan: plan) { message in
                    if case .running = phase { phase = .running(message) }
                }
                phase = .done(id)
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
        }
    }
}

private struct WarningRow: View {
    var warning: MigrationWarning

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: warning.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(warning.severity == .warning ? .orange : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(warning.title).fontWeight(.semibold)
                Text(warning.message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(warning.severity == .warning
            ? Text("Warning: \(warning.title). \(warning.message)", comment: "VoiceOver: topic, then the explanation")
            : Text("Note: \(warning.title). \(warning.message)", comment: "VoiceOver: topic, then the explanation"))
    }
}
