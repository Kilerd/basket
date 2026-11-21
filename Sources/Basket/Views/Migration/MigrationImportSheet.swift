import SwiftUI
import BasketCore

/// Per-image progress of "Import Selected" (export from OrbStack → load into Basket), with cancel.
struct MigrationImportSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let model = store.migration
        SheetScaffold(
            title: "Import from OrbStack",
            subtitle: "Basket copies only this Mac's platform (\(store.hostPlatform)) when OrbStack has it. Each archive is deleted as soon as it's loaded; OrbStack keeps its copy.",
            identifier: "sheet.migration-import", width: 600, height: 500
        ) {
            Section {
                ForEach(model.importItems) { item in
                    ImportItemRow(item: item)
                }
            }
        } footer: {
            Text(model.importSummary)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("migration.import.summary")
            Spacer()
            if model.isImporting {
                Button("Cancel", role: .cancel) { model.cancelImport() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("migration.import.cancel")
            } else {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("migration.import.done")
            }
        }
        .interactiveDismissDisabled(model.isImporting)
    }
}

private struct ImportItemRow: View {
    var item: MigrationModel.ImportItem

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.image.reference ?? item.image.imageID)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(detailColor)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Text(Format.disk(item.image.sizeBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Disk used in OrbStack")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("migration.import.item.\(item.id)")
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary).accessibilityHidden(true)
        case .checking, .exporting, .loading:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
        case .skipped:
            Image(systemName: "arrow.uturn.right.circle").foregroundStyle(.secondary).accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }

    private var detail: String {
        let platform = item.image.exportPlatform
        switch item.state {
        case .queued: return String(localized: "Waiting", comment: "Import queue: not started yet")
        case .checking: return String(localized: "Checking free disk space…")
        case .exporting(let bytes):
            let size = Format.disk(bytes)
            return bytes > 0 ? String(localized: "Exporting \(platform) from OrbStack… \(size)", comment: "Import progress: platform, bytes so far")
                : String(localized: "Exporting \(platform) from OrbStack…")
        case .loading(let bytes):
            let size = Format.disk(bytes)
            return String(localized: "Loading into Basket… (\(size) archive)")
        case .done(let references, let bytes):
            let copied = Format.disk(bytes)
            return String(localized: "Imported as \(references.localizedList) · \(copied) copied", comment: "Import result: image names, then the size copied")
        case .skipped(let reason): return reason
        case .failed(let message): return message
        case .cancelled: return String(localized: "Cancelled", comment: "Import of one image was cancelled")
        }
    }

    private var detailColor: Color {
        if case .failed = item.state { return .orange }
        return .secondary
    }
}
