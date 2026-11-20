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
                         detail: "\(container.cpus) vCPU\(container.cpus == 1 ? "" : "s")")
                    tile("Memory (guest)", stats.map { Format.memory($0.memoryUsageBytes) } ?? "—",
                         detail: "of \(Format.memory(stats?.memoryLimitBytes ?? container.memoryLimitBytes))")
                    tile("Memory (host)", store.hostMemoryByOwner[container.id].map(Format.memory) ?? "—",
                         detail: "VM footprint")
                    tile("Network", stats.map { "↓ \(Format.disk($0.networkRxBytes))" } ?? "—",
                         detail: stats.map { "↑ \(Format.disk($0.networkTxBytes))" } ?? "")
                    tile("Disk I/O", stats.map { "R \(Format.disk($0.blockReadBytes))" } ?? "—",
                         detail: stats.map { "W \(Format.disk($0.blockWriteBytes))" } ?? "")
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

    private func tile(_ title: String, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            Text(detail.isEmpty ? " " : detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func chart(title: String, points: [StatsPoint], color: Color, value: @escaping (StatsPoint) -> Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Chart(points) { p in
                AreaMark(x: .value("Time", p.date), y: .value(title, value(p)))
                    .foregroundStyle(color.opacity(0.15))
                LineMark(x: .value("Time", p.date), y: .value(title, value(p)))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2))
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
