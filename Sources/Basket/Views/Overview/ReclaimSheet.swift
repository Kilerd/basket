import SwiftUI
import BasketCore

/// Lists exactly what will be deleted, then deletes exactly that (re-checked against fresh state);
/// the CLI's prune commands are never used. The plan is a snapshot taken when the sheet opens:
/// containers stopped while it is open (by the user or Memory Saver) are never added to it.
struct ReclaimSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: AppStore.ReclaimSnapshot?
    /// Off by default: a stopped container may only be paused for now, and its writable layer is gone for good.
    @State private var pruneContainers = false
    @State private var pruneImages = true
    @State private var pruneVolumes = false
    @State private var isWorking = false

    struct Item: Identifiable {
        var id: String
        var name: String
        var detail: String?
        var bytes: Int64?
    }

    var body: some View {
        let snapshot = self.snapshot ?? store.reclaimSnapshot()
        let plan = snapshot.plan(includingStoppedContainers: pruneContainers)
        let approved = plan.approved(containers: pruneContainers, images: pruneImages, volumes: pruneVolumes)
        let df = snapshot.diskUsage
        SheetScaffold(
            title: "Reclaim Disk Space",
            subtitle: "Exactly the items listed are deleted: this list was taken when the sheet opened. Running containers, machines and everything they use are kept.",
            identifier: "sheet.reclaim", width: 560, height: 620
        ) {
            category(
                "Stopped containers", isOn: $pruneContainers, identifier: "reclaim.containers",
                total: df?.containers.reclaimableBytes,
                note: "Their writable layers are deleted for good. Images and volumes only they use are added below.",
                items: plan.stoppedContainers.map { Item(id: $0.id, name: $0.id, detail: ImageName($0.imageReference).display) })
            category(
                "Unused images", isOn: $pruneImages, identifier: "reclaim.images", total: imageBytes(plan, snapshot),
                note: "Pulled images can be pulled again; ones built or loaded on this Mac are gone for good.",
                items: plan.unusedImages.map { Item(id: $0.reference, name: ImageName($0.reference).display, bytes: $0.totalSizeBytes) },
                unavailable: plan.imageUsageUnknown.map { "No image is offered. \($0)" })
            category(
                "Unused volumes", isOn: $pruneVolumes, identifier: "reclaim.volumes",
                total: plan.unusedVolumes.reduce(Int64(0)) { $0 + ($1.allocatedBytes ?? 0) },
                note: "Data stored in them is permanently lost.", warning: true,
                items: plan.unusedVolumes.map { Item(id: $0.name, name: $0.name, bytes: $0.allocatedBytes) })
        } footer: {
            if isWorking {
                ProgressView().controlSize(.small)
                Text("Deleting…").foregroundStyle(.secondary)
            } else {
                Text(summary(approved)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("reclaim.action.cancel")
            // Deliberately no default-button shortcut: Return must never delete.
            Button(approved.isEmpty ? "Delete" : "Delete \(approved.count) Item\(approved.count == 1 ? "" : "s")", role: .destructive) {
                isWorking = true
                Task {
                    await store.deleteApproved(approved, verb: "Reclaiming disk space")
                    isWorking = false
                    dismiss()
                }
            }
            .disabled(isWorking || approved.isEmpty)
            .accessibilityIdentifier("reclaim.action.confirm")
        }
        .onAppear { if self.snapshot == nil { self.snapshot = store.reclaimSnapshot() } }
    }

    private func summary(_ approved: ApprovedDeletion) -> String {
        guard !approved.isEmpty else { return "Nothing selected" }
        var parts: [String] = []
        if !approved.containers.isEmpty { parts.append("\(approved.containers.count) container\(approved.containers.count == 1 ? "" : "s")") }
        if !approved.images.isEmpty { parts.append("\(approved.images.count) image\(approved.images.count == 1 ? "" : "s")") }
        if !approved.volumes.isEmpty { parts.append("\(approved.volumes.count) volume\(approved.volumes.count == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    /// The CLI's reclaimable figure (it includes unpacked snapshots, so it matches the Overview card)
    /// when the plan is the CLI's own notion of unused; otherwise the sum of what is listed.
    private func imageBytes(_ plan: AppStore.ReclaimPlan, _ snapshot: AppStore.ReclaimSnapshot) -> Int64 {
        let planned = Set(plan.unusedImages.map(\.reference))
        let cliUnused = Set(ImageUsage(containers: snapshot.containers, machines: []).unused(snapshot.images).map(\.reference))
        if let df = snapshot.diskUsage, !planned.isEmpty, planned == cliUnused { return df.images.reclaimableBytes }
        return plan.unusedImages.reduce(0) { $0 + $1.totalSizeBytes }
    }

    @ViewBuilder
    private func category(
        _ title: String, isOn: Binding<Bool>, identifier: String, total: Int64?, note: String, warning: Bool = false,
        items: [Item], unavailable: String? = nil
    ) -> some View {
        Section {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(title) (\(items.count))")
                        Spacer(minLength: 8)
                        if let total, total > 0, !items.isEmpty {
                            Text(Format.disk(total)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Text(unavailable ?? note)
                        .font(.caption)
                        .foregroundStyle(warning || unavailable != nil ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(items.isEmpty)
            .accessibilityIdentifier(identifier)
            // Every item, so nothing is deleted that wasn't shown.
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.id)
                    if let detail = item.detail {
                        Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if items.contains(where: { $0.bytes != nil }) {
                        Text(item.bytes.map(Format.disk) ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 76, alignment: .trailing)
                    }
                }
                .font(.callout)
                .opacity(isOn.wrappedValue ? 1 : 0.55)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("\(identifier).item.\(item.id)")
            }
        }
    }
}
