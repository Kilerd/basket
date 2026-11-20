import SwiftUI
import BasketCore

/// Menu-style status item: service state, memory, quick start/stop.
struct MenuBarContent: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        if store.availability == .running {
            Text("Memory: \(Format.memory(store.totalHostMemory)) across \(vmCount) VM\(vmCount == 1 ? "" : "s")")
            if stranded > 0 {
                Text("Stranded: \(Format.memory(stranded)), returned by a restart")
            }
            if let df = store.diskUsage {
                Text("Disk: \(Format.disk(df.totalBytes)) (\(Format.disk(df.reclaimableBytes)) reclaimable)")
            }
        }
        Divider()
        if store.availability == .running {
            MenuBarMemoryActions()
            Divider()
        }
        if store.availability == .stopped {
            Button("Start Container System") { Task { await store.startSystem() } }
        } else if store.containers.isEmpty {
            Text("No containers")
        } else {
            Section("Containers") {
                ForEach(store.containers.sorted { ($0.state.sortOrder, $0.id) < ($1.state.sortOrder, $1.id) }) { c in
                    Menu {
                        ContainerMenuItems(ids: [c.id])
                    } label: {
                        Label(menuTitle(c), systemImage: c.state.symbol)
                    }
                }
            }
        }
        Divider()
        if !store.memorySaver.activity.isEmpty {
            Section("Recently Returned") {
                ForEach(store.memorySaver.activity.prefix(5)) { entry in
                    Text("\(entry.summary) (\(Format.relative(entry.date)))")
                }
            }
            Divider()
        }
        Button("Open Basket") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("o")
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Basket") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
            .onAppear { store.menuBarOpened() }
    }

    private var stranded: Int64 { store.memoryInsights.totals.strandedBytes }

    private var vmCount: Int {
        store.runningContainers.count + store.machines.filter { $0.state == .running }.count
    }

    private var statusLine: String {
        switch store.availability {
        case .running: "Container system running"
        case .stopped: "Container system stopped"
        case .cliMissing: "container CLI not found"
        case .unknown: "Connecting…"
        }
    }

    private func menuTitle(_ c: ContainerSummary) -> String {
        guard c.state == .running else { return "\(c.id) — \(c.state.title.lowercased())" }
        if let host = store.hostMemoryByOwner[c.id] { return "\(c.id) — \(Format.memory(host))" }
        return c.id
    }
}

/// "Stop Idle Containers" and "Reclaim Stranded Memory…" — one click each from the menu bar.
private struct MenuBarMemoryActions: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let idle = store.idleContainers
        let strandedCount = store.memoryInsights.totals.strandedCount
        Button(idle.isEmpty ? "Stop Idle Containers" : "Stop Idle Containers (\(idle.map(\.id).joined(separator: ", ")))") {
            Task { await store.stopIdleContainers() }
        }
        .disabled(idle.isEmpty)
        Button("Reclaim Stranded Memory…") {
            openWindow(id: "main")
            NSApp.activate()
            store.activeSheet = .reclaimMemory
        }
        .disabled(strandedCount == 0)
        if store.memorySaver.isEnabled {
            Text("Memory Saver stops containers idle for \(Format.duration(TimeInterval(store.memorySaver.idleMinutes * 60)))")
        }
    }
}
