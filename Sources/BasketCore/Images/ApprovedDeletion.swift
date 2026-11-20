import Foundation

/// Exactly what the user approved in a confirmation (containers, images, volumes). The CLI's own
/// prune commands delete whatever *it* considers unused when they run, which can be more than what
/// was shown; Basket deletes these names instead, after `revalidated` drops anything that changed.
public struct ApprovedDeletion: Sendable, Hashable {
    public var containers: [String]
    public var images: [String]
    public var volumes: [String]

    public init(containers: [String] = [], images: [String] = [], volumes: [String] = []) {
        self.containers = containers
        self.images = images
        self.volumes = volumes
    }

    public var isEmpty: Bool { containers.isEmpty && images.isEmpty && volumes.isEmpty }
    public var count: Int { containers.count + images.count + volumes.count }

    /// The approved items that are still safe to delete given the current state: containers that are
    /// still stopped, images no remaining container or machine uses, volumes no remaining container
    /// mounts. Anything that disappeared is dropped too, and every image when it can't be told which
    /// images machines use (`machinesKnown` false or a machine without a known image).
    public func revalidated(
        containers current: [ContainerSummary], machines: [MachineSummary], images currentImages: [ImageSummary],
        volumes currentVolumes: [VolumeSummary], machinesKnown: Bool = true
    ) -> ApprovedDeletion {
        let stopped = Set(current.filter { $0.state == .stopped || $0.state == .created }.map(\.id))
        let keptContainers = containers.filter(stopped.contains)
        let deleting = Set(keptContainers)
        let remaining = current.filter { !deleting.contains($0.id) }

        let usage = ImageUsage(containers: remaining, machines: machines, machinesKnown: machinesKnown)
        let listedImages = Set(currentImages.map { ImageUsage.normalized($0.reference) })
        let keptImages = usage.unknownReason != nil ? []
            : images.filter { listedImages.contains(ImageUsage.normalized($0)) && !usage.isUsed($0) }

        let mounted = Set(remaining.flatMap { container in
            container.mounts.compactMap { mount in
                currentVolumes.first { $0.name == mount.source || (!$0.source.isEmpty && $0.source == mount.source) }?.name
            }
        })
        let listedVolumes = Set(currentVolumes.map(\.name))
        let keptVolumes = volumes.filter { listedVolumes.contains($0) && !mounted.contains($0) }

        return ApprovedDeletion(containers: keptContainers, images: keptImages, volumes: keptVolumes)
    }

    /// Approved items missing from `other` (what revalidation skipped).
    public func subtracting(_ other: ApprovedDeletion) -> ApprovedDeletion {
        ApprovedDeletion(
            containers: containers.filter { !other.containers.contains($0) },
            images: images.filter { !other.images.contains($0) },
            volumes: volumes.filter { !other.volumes.contains($0) })
    }

    /// Deletes containers first (so their images and volumes are free), then images, then volumes.
    public func perform(on backend: any ContainerBackend) async throws {
        if !containers.isEmpty { try await backend.deleteContainers(containers, force: false) }
        if !images.isEmpty { try await backend.deleteImages(images, force: false) }
        if !volumes.isEmpty { try await backend.deleteVolumes(volumes) }
    }
}
