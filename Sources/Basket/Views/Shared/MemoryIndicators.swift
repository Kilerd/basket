import SwiftUI
import BasketCore

/// Orange "attention" mark for a VM holding memory its guest has freed. Same symbol everywhere
/// (table, Overview, details) so it reads as one signal.
struct StrandedMark: View {
    var bytes: Int64

    var body: some View {
        Image(systemName: "exclamationmark.circle")
            .foregroundStyle(.orange)
            .help(Self.help(bytes))
            .accessibilityLabel("\(Format.memory(bytes)) stranded")
    }

    static func help(_ bytes: Int64) -> String {
        "About \(Format.memory(bytes)) stranded: the VM still holds memory its guest has freed. Restart the container to return it to macOS."
    }
}

/// Moon mark for a container that has been idle (CPU and network quiet) since `idleFor` ago.
struct IdleMark: View {
    var idleFor: TimeInterval

    var body: some View {
        Image(systemName: "moon.zzz")
            .foregroundStyle(.secondary)
            .help(Self.help(idleFor))
            .accessibilityLabel("idle for \(Format.duration(idleFor))")
    }

    static func help(_ idleFor: TimeInterval) -> String {
        "Idle for \(Format.duration(idleFor)): under 1% CPU and under 1 KB/s of network traffic the whole time."
    }
}

/// Table cell: host footprint right-aligned, with a fixed slot for the stranded mark (an image
/// labelled "… stranded" for VoiceOver) to its left.
struct HostMemoryCell: View {
    var bytes: Int64
    var strandedBytes: Int64

    var body: some View {
        NumericCell(text: bytes < 0 ? "—" : Format.memory(bytes), isPlaceholder: bytes < 0, valueWidth: 66, markWidth: 14) {
            if strandedBytes > 0 { StrandedMark(bytes: strandedBytes).font(.caption) }
        }
        .help(strandedBytes > 0 ? StrandedMark.help(strandedBytes) : "Physical memory macOS pays for this container's VM")
    }
}

/// Table cell: CPU percent right-aligned, with a fixed slot for the idle mark to its left.
struct CPUCell: View {
    var percent: Double
    var idleFor: TimeInterval?

    var body: some View {
        NumericCell(text: percent < 0 ? "—" : Format.percent(percent), isPlaceholder: percent < 0, valueWidth: 46, markWidth: 14) {
            if let idleFor { IdleMark(idleFor: idleFor).font(.caption) }
        }
    }
}

/// Meter whose right end shows the stranded part of the value in orange.
struct StrandedMeterBar: View {
    var fraction: Double
    var strandedFraction: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * min(1, max(0, fraction))
            let stranded = proxy.size.width * min(1, max(0, strandedFraction))
            ZStack(alignment: .leading) {
                Capsule().fill(Series.track)
                Capsule().fill(Series.orange).frame(width: max(fraction > 0 ? height : 0, width))
                Capsule().fill(Series.blue).frame(width: max(fraction > 0 ? height : 0, width - stranded))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Per-container memory actions for the table's context menu and the menu bar extra.
struct MemoryMenuItems: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    var container: ContainerSummary

    var body: some View {
        if container.state == .running, store.memoryInsights[container.id]?.isStranded == true {
            Button("Reclaim Memory (Restart)…", systemImage: "memorychip") {
                openWindow.mainWindowThen { store.confirmRestartContainers([container.id], reclaim: true) }
            }
        }
        switch container.removeOnStop {
        case false?:
            Toggle("Exempt from Memory Saver", isOn: Binding(
                get: { store.memorySaver.isExempt(container.id) },
                set: { store.memorySaver.setExempt(container.id, $0) }))
        case nil where !MemorySaverPolicy.isMachineBacked(container):
            // Stopping might delete it (`--rm` unknown): Memory Saver leaves it alone unless allowed.
            Toggle("Allow Memory Saver to Stop", isOn: Binding(
                get: { store.memorySaver.isOptedIn(container.id) },
                set: { store.memorySaver.setOptedIn(container.id, $0) }))
        default:
            EmptyView()
        }
    }
}

extension OpenWindowAction {
    /// Confirmations are alerts on the main window, which may be closed when the action comes from
    /// the menu bar: bring the window up first, then ask.
    @MainActor func mainWindowThen(_ action: () -> Void) {
        self(id: "main")
        NSApp.activate()
        action()
    }
}
