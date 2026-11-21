import SwiftUI
import Charts
import BasketCore

struct ContainerStatsView: View {
    @Environment(AppStore.self) private var store
    var container: ContainerSummary

    var body: some View {
        if container.state != .running {
            ContentUnavailableView("Not Running", systemImage: "chart.xyaxis.line",
                                   description: Text("Start the container to see live CPU and memory usage."))
        } else {
            let stats = store.latestStats[container.id]
            let points = store.statsHistory[container.id] ?? []
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    tile("CPU", store.cpuPercent[container.id].map(Format.percent) ?? "—",
                         detail: String(localized: "\(container.cpus) vCPUs"))
                    tile("Memory (guest)", stats.map { Format.memory($0.memoryUsageBytes) } ?? "—",
                         detail: String(localized: "of \(Format.memory(stats?.memoryLimitBytes ?? container.memoryLimitBytes))", comment: "Under a memory figure: out of this memory limit"))
                    tile("Memory (host)", store.hostMemoryByOwner[container.id].map(Format.memory) ?? "—",
                         detail: String(localized: "VM footprint"))
                    tile("Network", stats.map { "↓ \(Format.disk($0.networkRxBytes))" } ?? "—",
                         detail: stats.map { "↑ \(Format.disk($0.networkTxBytes))" } ?? "")
                    tile("Disk I/O", stats.map { String(localized: "R \(Format.disk($0.blockReadBytes))", comment: "Disk I/O: bytes read (R = read)") } ?? "—",
                         detail: stats.map { String(localized: "W \(Format.disk($0.blockWriteBytes))", comment: "Disk I/O: bytes written (W = written)") } ?? "")
                    tile("Processes", stats.map { "\($0.processCount)" } ?? "—", detail: "")
                }
                HStack(spacing: 14) {
                    chart(title: "CPU %", points: points, color: Series.blue) { $0.cpuPercent }
                    chart(title: "Memory (MiB)", points: points, color: Series.aqua) { Double($0.memoryBytes) / 1_048_576 }
                }
            }
            .padding(14)
        }
    }

    private func tile(_ title: LocalizedStringKey, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            Text(detail.isEmpty ? " " : detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func chart(title: LocalizedStringKey, points: [StatsPoint], color: Color, value: @escaping (StatsPoint) -> Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Chart(points) { p in
                AreaMark(x: .value("Time", p.date), y: .value(title, value(p)))
                    .foregroundStyle(color.opacity(0.15))
                    .accessibilityHidden(true)  // the line carries the same values
                LineMark(x: .value("Time", p.date), y: .value(title, value(p)))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    // A sample's time and value, short in every language (the default is a
                    // full date range).
                    .accessibilityLabel(Text(verbatim: p.date.formatted(date: .omitted, time: .standard)))
                    .accessibilityValue(Text(verbatim: value(p).formatted(.number.precision(.fractionLength(0...1)))))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Series.track)
                    AxisValueLabel(format: .dateTime.hour().minute().second())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Series.track)
                    AxisValueLabel()
                }
            }
            .overlay {
                if points.count < 2 {
                    Text("Collecting samples…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
