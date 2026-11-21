import SwiftUI
import BasketCore

struct ContainerLogsView: View {
    @Environment(AppStore.self) private var store
    var containerID: String
    @State private var document = LogDocument(maxLines: 5_000)
    @State private var follow = false
    @State private var isLoading = false
    @State private var error: String?
    @State private var reloadToken = 0

    private struct LoadKey: Hashable {
        var id: String
        var follow: Bool
        var token: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("Follow", isOn: $follow)
                    .toggleStyle(.checkbox)
                    .help("Stream new log lines as they are written")
                    .accessibilityIdentifier("containers.detail.logs.follow")
                Button("Reload", systemImage: "arrow.clockwise") { reloadToken += 1 }
                    .disabled(follow)
                    .accessibilityIdentifier("containers.detail.logs.reload")
                Button("Copy", systemImage: "doc.on.doc") { HostActions.copy(document.text) }
                    .disabled(document.lineCount == 0)
                    .accessibilityIdentifier("containers.detail.logs.copy")
                if isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Text(error ?? LogStatus.text(lines: document.lineCount, following: follow))
                    .font(.caption)
                    .foregroundStyle(error == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            Divider()
            LogTextView(document: document, followTail: follow,
                        identifier: "containers.detail.logs", label: String(localized: "Logs for \(containerID)"))
                .overlay {
                    if document.lineCount == 0 && !isLoading && error == nil {
                        Text(follow ? "Waiting for output…" : "No log output")
                            .foregroundStyle(.secondary)
                    }
                }
        }
        .task(id: LoadKey(id: containerID, follow: follow, token: reloadToken)) {
            await load()
        }
    }

    private func load() async {
        error = nil
        isLoading = true
        let backend = store.backend
        let id = containerID
        if !follow {
            do {
                let text = try await backend.logs(id, tail: 1000)
                var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                if lines.last == "" { lines.removeLast() }
                document.replace(with: lines)
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
            return
        }
        document.replace(with: [])
        isLoading = false
        // The backend splits and coalesces lines off the main thread (≤ 10 batches/s, bounded), so a
        // chatty container costs one main-actor hop per batch and an append-only text update.
        do {
            for try await batch in backend.followLogBatches(id) {
                var lines = batch.lines
                if batch.droppedLines > 0 {
                    lines.insert(String(localized: "[Basket skipped \(batch.droppedLines) lines: output was faster than it can be shown]"), at: 0)
                }
                document.append(lines)
            }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
