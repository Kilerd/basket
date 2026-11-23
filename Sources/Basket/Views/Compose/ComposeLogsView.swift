import SwiftUI
import BasketCore

/// Logs of every service of a project in one view, each line prefixed with its service name (like
/// `docker compose logs`). Followed logs interleave in arrival order.
struct ComposeLogsView: View {
    @Environment(AppStore.self) private var store
    var project: ComposeProject
    @State private var document = LogDocument(maxLines: 10_000)
    @State private var follow = false
    @State private var isLoading = false
    @State private var error: String?
    @State private var reloadToken = 0

    private struct LoadKey: Hashable {
        var ids: [String]
        var follow: Bool
        var token: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("Follow", isOn: $follow)
                    .toggleStyle(.checkbox)
                    .help("Stream new log lines from every service as they are written")
                    .accessibilityIdentifier("containers.detail.compose-logs.follow")
                Button("Reload", systemImage: "arrow.clockwise") { reloadToken += 1 }
                    .disabled(follow)
                    .accessibilityIdentifier("containers.detail.compose-logs.reload")
                Button("Copy", systemImage: "doc.on.doc") { HostActions.copy(document.text) }
                    .disabled(document.lineCount == 0)
                    .accessibilityIdentifier("containers.detail.compose-logs.copy")
                if isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Text(error ?? LogStatus.text(lines: document.lineCount, services: project.totalCount, following: follow))
                    .font(.caption)
                    .foregroundStyle(error == nil ? Color.secondary : Color.warningText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            Divider()
            LogTextView(document: document, followTail: follow,
                        identifier: "containers.detail.compose-logs", label: String(localized: "Logs for compose project \(project.name)"))
                .overlay {
                    if document.lineCount == 0 && !isLoading && error == nil {
                        Text(follow ? "Waiting for output…" : "No log output").foregroundStyle(.secondary)
                    }
                }
        }
        .task(id: LoadKey(ids: project.containers.map(\.id), follow: follow, token: reloadToken)) {
            await load()
        }
    }

    private var prefixes: [String: String] {
        let width = project.services.map(\.count).max() ?? 0
        return Dictionary(uniqueKeysWithValues: project.containers.map { container in
            let service = ComposeProject.serviceName(of: container)
            return (container.id, service.padding(toLength: width, withPad: " ", startingAt: 0) + " | ")
        })
    }

    private func load() async {
        error = nil
        isLoading = true
        let backend = store.backend
        let prefixes = self.prefixes
        let containers = project.startOrder
        if !follow {
            var lines: [String] = []
            var failures: [String] = []
            for container in containers {
                do {
                    let text = try await backend.logs(container.id, tail: 300)
                    lines += text.split(separator: "\n").map { prefixes[container.id, default: ""] + $0 }
                } catch {
                    failures.append(ComposeProject.serviceName(of: container))
                }
            }
            document.replace(with: lines)
            if !failures.isEmpty { error = String(localized: "Couldn't read the logs of \(failures.localizedList)") }
            isLoading = false
            return
        }
        document.replace(with: [])
        isLoading = false
        // One producer per service feeds a single stream; the main actor only appends batches.
        let (merged, continuation) = AsyncStream<[String]>.makeStream()
        let producers = containers.map { container in
            let prefix = prefixes[container.id, default: ""]
            let id = container.id
            return Task.detached {
                do {
                    for try await batch in backend.followLogBatches(id) {
                        var lines = batch.lines.map { prefix + $0 }
                        if batch.droppedLines > 0 {
                            lines.insert(prefix + String(localized: "[Basket skipped \(batch.droppedLines) lines: output was faster than it can be shown]"), at: 0)
                        }
                        continuation.yield(lines)
                    }
                } catch {}
            }
        }
        await withTaskCancellationHandler {
            for await lines in merged { document.append(lines) }
        } onCancel: {
            producers.forEach { $0.cancel() }
            continuation.finish()
        }
    }
}
