import SwiftUI
import BasketCore

/// Restart VMs that hold memory their guests have freed (apple/container VMs never give it back).
struct ReclaimMemorySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Taken when the sheet opens so rows don't move while the user decides or restarts run.
    @State private var candidates: [MemoryInsights.Breakdown]?
    @State private var selected: Set<String> = []
    @State private var isWorking = false

    var body: some View {
        let list = candidates ?? store.memoryInsights.stranded
        // A row that turned out to be `--rm` (or vanished) since the sheet opened can't stay chosen.
        let chosen = list.filter { selected.contains($0.id) && isSelectable($0.id) }
        let freed = chosen.reduce(Int64(0)) { $0 + $1.strandedBytes }
        SheetScaffold(
            title: "Reclaim Stranded Memory",
            subtitle: "These VMs still hold memory their guests have freed. A VM only returns it to macOS when it restarts.",
            identifier: "sheet.reclaim-memory", height: 500
        ) {
            Section("Restart") {
                if list.isEmpty {
                    Text("Nothing to reclaim: every VM uses about what its guest needs.")
                        .foregroundStyle(.secondary)
                }
                ForEach(list) { item in
                    let removal = removeOnStop(item.id)
                    Toggle(isOn: binding(for: item.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(item.id).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text("about \(Format.memory(item.strandedBytes))")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(Format.memory(item.hostFootprintBytes)) on this Mac · \(Format.memory(item.guestInUseBytes)) used by the guest")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            switch removal {
                            case true?:
                                Text("Started with --rm: stopping deletes it, so it can't be restarted.")
                                    .font(.caption).foregroundStyle(.orange)
                            case nil:
                                Text("Basket can't tell whether it was started with --rm. If so, restarting deletes it.")
                                    .font(.caption).foregroundStyle(.orange)
                            default:
                                EmptyView()
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!isSelectable(item.id))
                    .accessibilityIdentifier("reclaim-memory.container.\(item.id)")
                }
            }
            Section("What restarting means") {
                consequence("arrow.counterclockwise", "A brief interruption: each container stops and starts again, usually within seconds.")
                consequence("network", "Published ports come back as soon as it is running again.")
                consequence("exclamationmark.triangle", "Anything kept only in memory (caches, sessions, unsaved work) is lost. Files and volumes are kept.",
                            tint: .orange)
            }
        } footer: {
            if isWorking {
                ProgressView().controlSize(.small)
                Text("Restarting…").foregroundStyle(.secondary)
            } else if freed > 0 {
                Text("Frees about \(Format.memory(freed))").foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("reclaim-memory.action.cancel")
            Button(chosen.count == 1 ? "Restart 1 Container" : "Restart \(chosen.count) Containers") {
                restart(chosen.map(\.id))
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isWorking || chosen.isEmpty)
            .accessibilityIdentifier("reclaim-memory.action.confirm")
        }
        .onChange(of: store.containers) {
            selected = selected.filter(isSelectable)
        }
        .onAppear {
            guard candidates == nil else { return }
            let stranded = store.memoryInsights.stranded
            candidates = stranded
            // Only containers known to survive a stop start checked.
            selected = Set(stranded.map(\.id).filter { removeOnStop($0) == false })
        }
    }

    private func removeOnStop(_ id: String) -> Bool? {
        store.containers.first { $0.id == id }?.removeOnStop
    }

    /// Still there, running and not started with `--rm` (restarting re-checks this per container too).
    private func isSelectable(_ id: String) -> Bool {
        guard let container = store.containers.first(where: { $0.id == id }) else { return false }
        return container.state == .running && container.removeOnStop != true
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { selected.contains(id) }, set: { if $0 { selected.insert(id) } else { selected.remove(id) } })
    }

    private func consequence(_ symbol: String, _ text: String, tint: Color = .secondary) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }

    private func restart(_ ids: [String]) {
        isWorking = true
        Task {
            await store.reclaimMemory(ids)
            isWorking = false
            dismiss()
        }
    }
}
