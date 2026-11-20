import SwiftUI
import BasketCore

/// Detail Info strip (full width): where the VM's host memory goes — guest / overhead / stranded
/// as a legend and one stacked bar — plus a restart action when memory is stranded.
struct ContainerMemorySection: View {
    @Environment(AppStore.self) private var store
    var container: ContainerSummary

    private static let overheadColor = Color.secondary.opacity(0.5)

    var body: some View {
        let breakdown = store.memoryInsights[container.id]
        InfoSection(title: "Host Memory") {
            if let b = breakdown {
                GridRow {
                    HStack(spacing: 20) {
                        metric("On this Mac", Format.memory(b.hostFootprintBytes), nil,
                               help: "Physical memory macOS pays for this container's VM.")
                        metric("Guest in use", Format.memory(b.guestInUseBytes), Series.aqua,
                               help: "Memory the Linux guest reports as used.")
                        metric("VM overhead", "about \(Format.memory(b.overheadBytes))", Self.overheadColor,
                               help: "Estimated fixed cost of the VM itself (kernel, page tables, devices); grows slowly with the memory limit.")
                        metric("Stranded", b.strandedBytes > 0 ? Format.memory(b.strandedBytes) : "None", Series.orange,
                               help: b.isStranded ? StrandedMark.help(b.strandedBytes)
                                  : "Memory the VM holds beyond what the guest and the VM itself need.")
                        Spacer(minLength: 0)
                        if b.isStranded {
                            Button("Restart to Reclaim…", systemImage: "arrow.counterclockwise") {
                                store.confirmRestartContainers([container.id], reclaim: true)
                            }
                            .controlSize(.small)
                            .disabled(store.pending[container.id] != nil)
                            .help("Restart the container to return about \(Format.memory(b.strandedBytes)) to macOS. In-memory state is lost; published ports come back.")
                            .accessibilityLabel("Reclaim Memory (Restart)")
                            .accessibilityIdentifier("containers.action.reclaim-memory")
                        }
                    }
                }
                GridRow {
                    StackedBar(segments: [
                        .init(label: "Guest", value: b.guestInUseBytes, color: Series.aqua),
                        .init(label: "Overhead", value: b.overheadBytes, color: Self.overheadColor),
                        .init(label: "Stranded", value: b.strandedBytes, color: Series.orange),
                    ])
                    .frame(height: 8)
                }
            } else {
                GridRow {
                    HStack(spacing: 20) {
                        metric("On this Mac", store.hostMemoryByOwner[container.id].map(Format.memory) ?? "—", nil,
                               help: "Physical memory macOS pays for this container's VM.")
                        metric("Guest in use", store.latestStats[container.id].map { Format.memory($0.memoryUsageBytes) } ?? "—", nil,
                               help: "Memory the Linux guest reports as used.")
                        Text(container.state == .running ? "Measuring…" : "Stopped: no VM running.")
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                }
            }
        }
    }

    /// Legend entry: swatch (when `color` is set), label and value at their natural width.
    private func metric(_ label: String, _ value: String, _ color: Color?, help: String) -> some View {
        HStack(spacing: 6) {
            if let color {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            }
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.callout)
        .fixedSize()
        .help(help)
    }
}

/// Resources rows for activity and the Memory Saver exemption.
struct ContainerActivityRows: View {
    @Environment(AppStore.self) private var store
    var container: ContainerSummary

    var body: some View {
        InfoRow(label: "Activity", value: activity)
        if !MemorySaverPolicy.isMachineBacked(container) {
            GridRow {
                Text("Memory Saver").foregroundStyle(.secondary).lineLimit(1)
                saverControl
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
        }
    }

    @ViewBuilder private var saverControl: some View {
        switch container.removeOnStop {
        case true?:
            Text("Skipped (--rm)")
                .help("Stopping a container started with --rm deletes it, so Memory Saver never stops it.")
        case false?:
            Toggle("Exempt", isOn: Binding(
                get: { store.memorySaver.isExempt(container.id) },
                set: { store.memorySaver.setExempt(container.id, $0) }))
                .toggleStyle(.checkbox)
                .help("Exempt containers are never stopped automatically or by “Stop Idle Containers”.")
                .accessibilityLabel("Exempt from Memory Saver")
                .accessibilityIdentifier("containers.detail.memory-saver")
        case nil:
            Toggle("Allow stopping", isOn: Binding(
                get: { store.memorySaver.isOptedIn(container.id) },
                set: { store.memorySaver.setOptedIn(container.id, $0) }))
                .toggleStyle(.checkbox)
                .help("Basket can't tell whether this container was started with --rm (stopping would delete it), so Memory Saver leaves it alone unless you allow it.")
                .accessibilityLabel("Allow Memory Saver to stop")
                .accessibilityIdentifier("containers.detail.memory-saver")
        }
    }

    private var activity: String {
        guard container.state == .running else { return "—" }
        if let idle = store.idleDuration(of: container.id) { return "Idle for \(Format.duration(idle))" }
        return store.memorySaver.trackers[container.id]?.lastActivity == nil ? "Watching…" : "Active"
    }
}
