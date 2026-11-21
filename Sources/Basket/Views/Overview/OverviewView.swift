import SwiftUI
import BasketCore

struct OverviewView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    MemoryCard()
                    DiskCard()
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 16) {
                    SystemCard()
                    if store.orbStack?.isInstalled == true {
                        OrbStackCard()
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .navigationTitle("Overview")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                ToolbarActionButton(title: "New Container", systemImage: "plus", identifier: "overview.action.new",
                                    help: "New Container (⌘N)") {
                    store.activeSheet = .newContainer(.defaults())
                }
            }
            ToolbarItem {
                RefreshButton(section: .overview)
            }
        }
    }

    private var subtitle: String {
        switch store.availability {
        case .running:
            let running = store.runningContainers.count
            return String(localized: "\(running) running · \(Format.memory(store.totalHostMemory)) memory", comment: "Overview window subtitle: running containers and the host memory they cost")
        case .stopped: return String(localized: "Container system stopped")
        case .cliMissing: return String(localized: "container CLI not found")
        case .unknown: return String(localized: "Connecting…")
        }
    }
}

// MARK: - Memory: see MemoryCard.swift

// MARK: - Disk

private struct DiskCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let df = store.diskUsage
        Card("Disk", systemImage: "internaldrive", identifier: "overview.card.disk") {
            Button {
                store.activeSheet = .reclaim
            } label: {
                Label("Reclaim…", systemImage: "arrow.3.trianglepath")
            }
            .disabled((df?.reclaimableBytes ?? 0) == 0 && store.reclaimPlan(includingStoppedContainers: true).stoppedContainers.isEmpty)
            .help("Remove stopped containers, unused images and volumes")
            .accessibilityIdentifier("overview.action.reclaim")
        } content: {
            HeroNumber(
                value: df.map { Format.disk($0.totalBytes) } ?? "—",
                caption: df.map { "\(Format.disk($0.reclaimableBytes)) reclaimable" }
                    ?? (store.availability == .stopped ? "Start the container system to measure disk usage" : "Measuring…")
            )
            if let df {
                StackedBar(segments: [
                    .init(label: "Containers", value: df.containers.sizeBytes, color: Series.blue),
                    .init(label: "Images", value: df.images.sizeBytes, color: Series.orange),
                    .init(label: "Volumes", value: df.volumes.sizeBytes, color: Series.aqua),
                ])
                .frame(height: 10)
                breakdown(df)
                let bloat = store.images.reduce(Int64(0)) { $0 + max(0, $1.totalSizeBytes - $1.hostVariantSizeBytes) }
                if bloat > 0 {
                    Label("\(Format.disk(bloat)) of images is for other CPU architectures", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("Multi-platform pulls store every variant. Slim them down from the Images section.")
                }
            }
        }
    }

    /// Spans the card like the bar above it: the category takes the leading, flexible column; the
    /// numbers sit in fixed right-aligned slots that end at the card's trailing edge, where the
    /// bar and the Memory card's values end.
    private func breakdown(_ df: DiskUsage) -> some View {
        let count = CardSlot.count, size = CardSlot.disk
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Text("In use").cardSlot(count).gridColumnAlignment(.trailing)
                Text("Size").cardSlot(size).gridColumnAlignment(.trailing)
                Text("Reclaimable").cardSlot(size).gridColumnAlignment(.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            categoryRow("Containers", df.containers, Series.blue, slots: (count, size))
            categoryRow("Images", df.images, Series.orange, slots: (count, size))
            categoryRow("Volumes", df.volumes, Series.aqua, slots: (count, size))
        }
    }

    private func categoryRow(_ name: LocalizedStringKey, _ c: DiskUsageCategory, _ color: Color,
                             slots: (count: CGFloat, size: CGFloat)) -> some View {
        GridRow {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                Text(name).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(c.active) of \(c.total)").cardSlot(slots.count).foregroundStyle(.secondary)
            Text(Format.disk(c.sizeBytes)).cardSlot(slots.size)
            Text(c.reclaimableBytes > 0 ? Format.disk(c.reclaimableBytes) : "—").cardSlot(slots.size)
                .foregroundStyle(c.reclaimableBytes > 0 ? .primary : .secondary)
        }
        .font(.callout)
    }
}

/// Horizontal stacked bar with 2 pt gaps between segments.
struct StackedBar: View {
    struct Segment: Identifiable {
        var label: String
        var value: Int64
        var color: Color
        var id: String { label }
    }

    var segments: [Segment]

    var body: some View {
        GeometryReader { proxy in
            let visible = segments.filter { $0.value > 0 }
            let total = Double(visible.reduce(0) { $0 + $1.value })
            let gaps = CGFloat(max(0, visible.count - 1)) * 2
            HStack(spacing: 2) {
                if visible.isEmpty {
                    Capsule().fill(Series.track)
                } else {
                    ForEach(visible) { s in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(s.color)
                            .frame(width: max(3, (proxy.size.width - gaps) * Double(s.value) / total))
                    }
                }
            }
        }
        // Decorative: the category rows below carry the same numbers as text.
        .accessibilityHidden(true)
    }
}

// MARK: - System

private struct SystemCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Card("Container System", systemImage: "server.rack", identifier: "overview.card.system") {
            switch store.availability {
            case .running:
                Button("Stop", systemImage: "stop.fill") { store.confirmStopSystem() }
                    .help("Stop the container system and all running containers")
                    .accessibilityIdentifier("overview.action.stop-system")
            case .stopped, .unknown:
                Button("Start", systemImage: "play.fill") { Task { await store.startSystem() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.availability == .unknown)
                    .help("Start the container system")
                    .accessibilityIdentifier("overview.action.start-system")
            case .cliMissing:
                SettingsLink { Text("Settings…") }
                    .accessibilityIdentifier("overview.action.settings")
            }
        } content: {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol).foregroundStyle(statusColor).font(.title2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle).font(.title3.weight(.semibold))
                    Text(statusDetail).font(.callout).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("CLI", store.system?.cliVersion.map { "container \($0)" })
                row("API server", store.system?.serverVersion)
                row("Host", hostLine)
                row("Containers", store.system.map { String(localized: "\($0.containersRunning) running of \($0.containersTotal)", comment: "Running containers or machines, of all of them") })
                row("Images", store.system.map { Format.count($0.imagesTotal) })
                row("Data", store.system?.appRoot.map { ($0 as NSString).abbreviatingWithTildeInPath })
            }
            .font(.callout)
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value ?? "—")
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value ?? "")
        }
    }

    private var hostLine: String? {
        guard let s = store.system else { return nil }
        let cpus = s.hostCPUs.map { String(localized: "\($0) CPUs") }
        let os = s.hostOS.map { $0.replacingOccurrences(of: "Version ", with: "macOS ") }
        let parts = [cpus, os].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var statusTitle: String {
        switch store.availability {
        case .running: String(localized: "Running", comment: "State of a container, a machine or the container system")
        case .stopped: String(localized: "Stopped", comment: "State of a container, a machine or the container system")
        case .cliMissing: String(localized: "CLI not found", comment: "Sidebar footer: the container CLI is missing")
        case .unknown: String(localized: "Checking…")
        }
    }

    private var statusDetail: String {
        switch store.availability {
        case .running: String(localized: "Each container gets its own VM; nothing runs when idle.")
        case .stopped: String(localized: "No VMs are running. Start the system to run containers.")
        case .cliMissing(let message): message
        case .unknown: String(localized: "Contacting the container API server")
        }
    }

    private var statusSymbol: String {
        switch store.availability {
        case .running: "checkmark.circle.fill"
        case .stopped: "pause.circle.fill"
        case .cliMissing: "exclamationmark.triangle.fill"
        case .unknown: "circle.dotted"
        }
    }

    private var statusColor: Color {
        switch store.availability {
        case .running: .green
        case .cliMissing: .orange
        default: .secondary
        }
    }
}

// MARK: - OrbStack comparison

private struct OrbStackCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let orb = store.orbStack
        Card("OrbStack vs Basket", systemImage: "arrow.left.arrow.right", identifier: "overview.card.orbstack") {
            Pill(text: orb?.isRunning == true ? "OrbStack running" : "OrbStack not running",
                 systemImage: orb?.isRunning == true ? "circle.fill" : "circle",
                 tint: orb?.isRunning == true ? .orange : .secondary)
        } content: {
            if let orb {
                // One grid for both comparisons, so their bars and values share columns; the values
                // end at the card's trailing edge like the other cards'.
                let slot = max(CardSlot.memory, CardSlot.disk)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    comparison(title: "Memory", orbStack: orb.memoryFootprintBytes, basket: store.totalHostMemory,
                               format: Format.memory, slot: slot)
                    comparison(title: "Disk", orbStack: orb.dataAllocatedBytes ?? 0, basket: store.diskUsage?.totalBytes ?? 0,
                               format: Format.disk, slot: slot, spaceAbove: 8)
                }
                Text(summary(orb))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A title spanning the grid, then OrbStack's and Basket's rows.
    @ViewBuilder
    private func comparison(title: LocalizedStringKey, orbStack: Int64, basket: Int64, format: (Int64) -> String,
                            slot: CGFloat, spaceAbove: CGFloat = 0) -> some View {
        let scale = Double(max(orbStack, basket, 1))
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.top, spaceAbove)
        bar("OrbStack", orbStack, scale, Series.orange, format, slot: slot)
        bar("Basket", basket, scale, Series.blue, format, slot: slot)
    }

    private func bar(_ label: String, _ bytes: Int64, _ scale: Double, _ color: Color, _ format: (Int64) -> String,
                     slot: CGFloat) -> some View {
        GridRow {
            Text(label).lineLimit(1).fixedSize()
            MeterBar(fraction: Double(bytes) / scale, color: color, height: 8).frame(minWidth: 80)
            Text(format(bytes)).cardSlot(slot).gridColumnAlignment(.trailing)
        }
        .font(.callout)
    }

    private func summary(_ orb: OrbStackSnapshot) -> String {
        var parts: [String] = []
        if orb.isRunning, orb.memoryFootprintBytes > store.totalHostMemory {
            parts.append(String(localized: "Quitting OrbStack would return \(Format.memory(orb.memoryFootprintBytes)) to macOS."))
        }
        if let data = orb.dataAllocatedBytes, data > 0 {
            parts.append(String(localized: "Its data image holds \(Format.disk(data)) and never shrinks on its own.",
                                comment: "OrbStack's data image (a disk image file), not a container image"))
        }
        if let n = orb.dockerImageCount {
            parts.append(String(localized: "\(n) Docker images stored there.", comment: "Container images stored in OrbStack's data image"))
        }
        return parts.isEmpty ? String(localized: "OrbStack is installed.") : Format.sentences(parts)
    }
}
