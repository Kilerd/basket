import SwiftUI
import BasketCore

/// The hero card: what the VMs really cost, how much of it is stranded, who is idle, and what
/// Basket recently gave back.
struct MemoryCard: View {
    @Environment(AppStore.self) private var store

    private struct Consumer: Identifiable {
        var id: String
        var isMachine: Bool
        var bytes: Int64
        var strandedBytes: Int64
    }

    var body: some View {
        let insights = store.memoryInsights
        let vmCount = store.runningContainers.count + store.machines.filter { $0.state == .running }.count
        Card("Memory", systemImage: "memorychip", identifier: "overview.card.memory") {
            Button {
                store.activeSheet = .reclaimMemory
            } label: {
                Label("Reclaim…", systemImage: "arrow.counterclockwise")
            }
            .disabled(insights.totals.strandedCount == 0)
            .help(insights.totals.strandedCount == 0
                  ? "No VM holds memory its guest has freed"
                  : "Restart VMs that hold memory their guests have freed")
            .accessibilityLabel("Reclaim Memory…")
            .accessibilityIdentifier("overview.action.reclaim-memory")
        } content: {
            HeroNumber(
                value: store.footprintsAvailable ? Format.memory(store.totalHostMemory) : "—",
                caption: vmCount == 0
                    ? "Nothing running — container VMs use no memory"
                    : "real memory macOS pays for \(vmCount) VMs"
            )
            comparison(insights)
            idleRow
            Divider()
            consumersList(insights)
            activityList
        }
    }

    private func comparison(_ insights: MemoryInsights) -> some View {
        let host = store.footprintsAvailable ? store.totalHostMemory : 0
        let guest = store.totalGuestMemory
        let limits = store.totalMemoryLimits
        let stranded = insights.totals.strandedBytes
        let scale = Double(max(host, guest, limits, 1))
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            comparisonRow("Host (real)", host, scale, Series.blue,
                          help: "Physical footprint of the VM processes — what Activity Monitor charges to Basket.")
            comparisonRow("Guest in use", guest, scale, Series.aqua,
                          help: "Memory the Linux guests report as used.")
            if store.footprintsAvailable {
                comparisonRow("Stranded", stranded, scale, Series.orange,
                              help: "Memory VMs still hold after their guests freed it. A VM only gives it back when it restarts.")
            }
            comparisonRow("Limits", limits, scale, Color.secondary.opacity(0.55),
                          help: "Sum of the memory limits of running VMs; a VM never takes more than its limit.")
        }
    }

    private func comparisonRow(_ label: LocalizedStringKey, _ bytes: Int64, _ scale: Double, _ color: Color, help: LocalizedStringKey) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            MeterBar(fraction: Double(bytes) / scale, color: color, height: 8)
                .frame(minWidth: 80)
            Text(Format.memory(bytes)).cardSlot(CardSlot.memory).gridColumnAlignment(.trailing)
        }
        .font(.callout)
        .help(help)
    }

    /// "web has been idle for 4 min  [Stop Idle]" — only while something is idle.
    @ViewBuilder private var idleRow: some View {
        let idle = store.idleContainers
        if let first = idle.first {
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(idle.count == 1
                     ? "\(first.id) has been idle for \(Format.duration(first.idleFor))"
                     : "\(idle.count) containers are idle: \(idle.map(\.id).localizedList)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(IdleMark.help(first.idleFor))
                Spacer(minLength: 8)
                Button(idle.count == 1 ? "Stop" : "Stop All") {
                    Task { await store.stopIdleContainers() }
                }
                .help("Stop idle containers and return their memory to macOS")
                .accessibilityLabel(idle.count == 1 ? "Stop idle container" : "Stop idle containers")
                .accessibilityIdentifier("overview.action.stop-idle")
            }
            .font(.callout)
        }
    }

    private func consumers(_ insights: MemoryInsights) -> [Consumer] {
        let host = store.hostMemoryByOwner
        var list = store.runningContainers.map { c in
            let breakdown = insights[c.id]
            return Consumer(id: c.id, isMachine: false, bytes: host[c.id] ?? store.latestStats[c.id]?.memoryUsageBytes ?? 0,
                            strandedBytes: breakdown?.isStranded == true ? breakdown?.strandedBytes ?? 0 : 0)
        }
        list += store.machines.filter { $0.state == .running }.map {
            Consumer(id: $0.id, isMachine: true, bytes: host[$0.id] ?? 0, strandedBytes: 0)
        }
        return Array(list.sorted { $0.bytes > $1.bytes }.prefix(5))
    }

    @ViewBuilder private func consumersList(_ insights: MemoryInsights) -> some View {
        let top = consumers(insights)
        Text("Top consumers").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        if top.isEmpty {
            Text("Each container runs in its own lightweight VM. Stopping it returns the memory to macOS immediately.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let maxBytes = Double(max(top.first?.bytes ?? 1, 1))
            // Fixed name/mark/value widths: bars start and end at the same x in every row and the
            // values' right edges line up. The value slot is the one the comparison above uses.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(top) { c in
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            // Fixed icon width keeps names aligned across symbol shapes.
                            Image(systemName: c.isMachine ? "desktopcomputer" : "shippingbox")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                                .accessibilityHidden(true)
                            Text(c.id).lineLimit(1).truncationMode(.middle)
                        }
                        .frame(width: 150, alignment: .leading)
                        StrandedMeterBar(fraction: Double(c.bytes) / maxBytes, strandedFraction: Double(c.strandedBytes) / maxBytes)
                            .frame(maxWidth: .infinity)
                        // Mark slot left of the value, as in the Containers table.
                        Group {
                            if c.strandedBytes > 0 {
                                StrandedMark(bytes: c.strandedBytes)
                            } else {
                                Color.clear.accessibilityHidden(true)
                            }
                        }
                        .frame(width: 14)
                        Text(Format.memory(c.bytes)).cardSlot(CardSlot.memory)
                    }
                    .font(.callout)
                }
            }
        }
    }

    /// What Memory Saver and reclaims did lately.
    @ViewBuilder private var activityList: some View {
        let recent = store.memorySaver.activity.prefix(3)
        if !recent.isEmpty {
            Text("Recently returned").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(recent) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: entry.kind == .reclaim ? "arrow.counterclockwise" : "moon.zzz")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        Text(entry.summary).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(Format.relative(entry.date)).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
