import Foundation

/// The image-store calls `ImageSlimmer` needs. Every `ContainerBackend` provides them through
/// `BackendImageStore`; tests substitute their own.
public protocol ImageStore: Sendable {
    func listImages() async throws -> [ImageSummary]
    func saveImage(_ reference: String, platform: String?, to archive: URL) async throws
    func loadImage(from archive: URL) async throws -> [String]
    func tagImage(_ source: String, as target: String) async throws
    func deleteImages(_ references: [String], force: Bool) async throws
}

public struct BackendImageStore: ImageStore {
    public let backend: any ContainerBackend

    public init(_ backend: any ContainerBackend) { self.backend = backend }

    public func listImages() async throws -> [ImageSummary] { try await backend.listImages() }
    public func saveImage(_ reference: String, platform: String?, to archive: URL) async throws {
        try await backend.saveImage(reference, platform: platform, to: archive)
    }
    public func loadImage(from archive: URL) async throws -> [String] { try await backend.loadImage(from: archive) }
    public func tagImage(_ source: String, as target: String) async throws { try await backend.tagImage(source, as: target) }
    public func deleteImages(_ references: [String], force: Bool) async throws {
        try await backend.deleteImages(references, force: force)
    }
}

/// Drops every platform variant of an image except the host's, locally — nothing is pulled, so it
/// works for images that were built, loaded or retagged here and can't come back from a registry:
///
/// 1. `image save --platform linux/arm64` into an archive (nothing changes yet),
/// 2. check the archive: an OCI layout naming this reference, only host manifests, plausible size,
/// 3. `image load` it — this repoints the existing reference to the slim index in one step, so the
///    image never disappears (verified with container 1.7.1),
/// 4. check the reference is listed with the host variant, then delete the archive,
/// 5. reclaim the now-unreferenced variants: the CLI garbage-collects content only on `image delete`,
///    so the image is tagged under a throwaway name and that name is deleted.
///
/// If loading fails and the original is no longer listed unchanged, the archive is kept and the
/// error says where it is and how to load it by hand.
public struct ImageSlimmer: Sendable {
    public enum Step: String, Sendable, CaseIterable {
        case saving, verifying, loading, checking, reclaiming

        public var title: String {
            switch self {
            case .saving: "Saving the \(ImageSlimmer.hostPlatform) variant"
            case .verifying: "Checking the archive"
            case .loading: "Loading it back"
            case .checking: "Checking the image"
            case .reclaiming: "Reclaiming disk space"
            }
        }
    }

    public struct Outcome: Sendable, Hashable {
        public var before: ImageSummary
        public var after: ImageSummary
        /// False when the throwaway-tag cleanup failed; the space comes back on the next image delete.
        public var reclaimed: Bool
    }

    public static let hostPlatform = HostPlatform.pullPlatform

    let store: any ImageStore
    let platform: String
    let workDirectory: URL
    let availableBytes: @Sendable (URL) -> Int64?

    public init(
        store: any ImageStore, workDirectory: URL, platform: String = ImageSlimmer.hostPlatform,
        availableBytes: @escaping @Sendable (URL) -> Int64? = ImageSlimmer.availableCapacity
    ) {
        self.store = store
        self.workDirectory = workDirectory
        self.platform = platform
        self.availableBytes = availableBytes
    }

    /// Whether `image` has a host variant and at least one other to remove.
    public static func canSlim(_ image: ImageSummary, platform: String = hostPlatform) -> Bool {
        image.hostVariantSizeBytes > 0
            && image.variants.contains { matches($0.platform, platform) }
            && image.variants.contains { !matches($0.platform, platform) }
    }

    /// Disk space the archive (and the CLI's copy of it while loading) needs.
    public static func requiredFreeBytes(for image: ImageSummary) -> Int64 {
        image.hostVariantSizeBytes * 2 + 256 * 1_048_576
    }

    public func slim(_ reference: String, progress: @Sendable (Step) -> Void = { _ in }) async throws -> Outcome {
        let before = try await image(reference)
        guard before.hostVariantSizeBytes > 0, before.variants.contains(where: { Self.matches($0.platform, platform) }) else {
            throw SlimError.noHostVariant(reference: reference, platform: platform)
        }
        guard before.variants.contains(where: { !Self.matches($0.platform, platform) }) else {
            throw SlimError.nothingToRemove(reference)
        }
        let needed = Self.requiredFreeBytes(for: before)
        if let available = availableBytes(workDirectory), available < needed {
            throw SlimError.notEnoughSpace(needed: needed, available: available)
        }
        let archive = try makeArchiveURL(for: reference)

        progress(.saving)
        do {
            try await store.saveImage(reference, platform: platform, to: archive)
            progress(.verifying)
            try verify(archive, reference: reference, before: before)
            try Task.checkCancellation()
        } catch {
            remove(archive)
            if error is CancellationError { throw error }
            throw SlimError.saveFailed(Self.message(error))
        }

        progress(.loading)
        do {
            _ = try await store.loadImage(from: archive)
        } catch {
            // A failed load may still have touched the reference: only drop the archive when the
            // original is listed exactly as before.
            if let current = try? await image(reference), current.digest == before.digest {
                remove(archive)
                throw SlimError.loadFailed(Self.message(error))
            }
            throw SlimError.needsRecovery(reason: "Loading failed: \(Self.message(error))", archive: archive)
        }

        progress(.checking)
        guard let after = try? await image(reference) else {
            throw SlimError.needsRecovery(reason: "The image isn't listed after loading.", archive: archive)
        }
        guard after.variants.contains(where: { Self.matches($0.platform, platform) }) else {
            throw SlimError.needsRecovery(
                reason: "After loading, the image has no \(platform) variant.", archive: archive)
        }
        remove(archive)
        if after.variants.contains(where: { !Self.matches($0.platform, platform) }) {
            throw SlimError.notSlimmed(reference)
        }

        progress(.reclaiming)
        let reclaimed = await reclaimOrphanedContent(reference)
        return Outcome(before: before, after: after, reclaimed: reclaimed)
    }

    // MARK: Steps

    private func image(_ reference: String) async throws -> ImageSummary {
        let wanted = ImageUsage.normalized(reference)
        guard let image = try await store.listImages().first(where: { ImageUsage.normalized($0.reference) == wanted }) else {
            throw SlimError.imageNotFound(reference)
        }
        return image
    }

    private func verify(_ archive: URL, reference: String, before: ImageSummary) throws {
        let inspected = try ImageArchive.inspect(archive)
        let wanted = ImageUsage.normalized(reference)
        guard inspected.references.contains(where: { ImageUsage.normalized($0) == wanted }) else {
            throw ImageArchive.Invalid(
                reason: "it is labelled \(inspected.references.joined(separator: ", ")) instead of \(reference)")
        }
        let platforms = inspected.manifests.map(\.platform)
        guard !platforms.isEmpty, platforms.allSatisfy({ Self.matches($0, platform) }) else {
            throw ImageArchive.Invalid(
                reason: "it holds \(platforms.isEmpty ? "no platform" : platforms.joined(separator: ", ")) instead of only \(platform)")
        }
        guard inspected.fileSize >= before.hostVariantSizeBytes else {
            throw ImageArchive.Invalid(
                reason: "it is \(inspected.fileSize) bytes, smaller than the \(before.hostVariantSizeBytes)-byte \(platform) variant")
        }
    }

    /// Tags the image under a throwaway name and deletes that name: `image delete` is what makes the
    /// CLI drop content no reference uses any more (the old index and the other variants' layers).
    private func reclaimOrphanedContent(_ reference: String) async -> Bool {
        let temporary = Self.temporaryReference(for: reference)
        do { try await store.tagImage(reference, as: temporary) } catch { return false }
        do {
            try await store.deleteImages([temporary], force: false)
            return true
        } catch {
            try? await store.deleteImages([temporary], force: true)
            return false
        }
    }

    // MARK: Helpers

    /// "linux/arm64/v8" matches "linux/arm64" (os and architecture compared).
    static func matches(_ variant: String, _ platform: String) -> Bool {
        let a = variant.split(separator: "/")
        let b = platform.split(separator: "/")
        return a.count >= 2 && b.count >= 2 && a[0] == b[0] && a[1] == b[1]
    }

    /// "docker.io/library/alpine:latest" → "docker.io/library/alpine:basket-reclaim-1a2b3c4d".
    static func temporaryReference(for reference: String) -> String {
        "\(repository(of: reference)):basket-reclaim-\(UUID().uuidString.prefix(8).lowercased())"
    }

    static func repository(of reference: String) -> String {
        var repository = reference.split(separator: "@", maxSplits: 1).first.map(String.init) ?? reference
        if let colon = repository.lastIndex(of: ":"), !repository[colon...].contains("/") {
            repository = String(repository[..<colon])
        }
        return repository
    }

    private func makeArchiveURL(for reference: String) throws -> URL {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let name = String(String(reference.split(separator: "/").last ?? "image").map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "-" })
        return workDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8).lowercased()).tar")
    }

    private func remove(_ archive: URL) {
        try? FileManager.default.removeItem(at: archive)
    }

    static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    public static let availableCapacity: @Sendable (URL) -> Int64? = { url in
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

public enum SlimError: Error, LocalizedError, Sendable, Equatable {
    case imageNotFound(String)
    case noHostVariant(reference: String, platform: String)
    case nothingToRemove(String)
    case notEnoughSpace(needed: Int64, available: Int64)
    /// Saving failed or the archive was unusable; nothing was changed.
    case saveFailed(String)
    /// Loading failed and the original is listed unchanged; nothing was changed.
    case loadFailed(String)
    /// The CLI loaded the image with its other variants; nothing was removed.
    case notSlimmed(String)
    /// The image may have changed: the archive is kept so it can be loaded by hand.
    case needsRecovery(reason: String, archive: URL)

    public var errorDescription: String? {
        switch self {
        case .imageNotFound(let reference):
            "\(reference) is no longer listed."
        case .noHostVariant(let reference, let platform):
            "\(reference) has no \(platform) variant to keep."
        case .nothingToRemove(let reference):
            "\(reference) already holds only this Mac's platform."
        case .notEnoughSpace(let needed, let available):
            "Not enough free disk space: needs \(Self.size(needed)), \(Self.size(available)) available. Nothing was changed."
        case .saveFailed(let message):
            "\(message) Nothing was changed."
        case .loadFailed(let message):
            "\(message) The original image is unchanged."
        case .notSlimmed(let reference):
            "The container CLI kept the other platform variants of \(reference); nothing was removed."
        case .needsRecovery(let reason, let archive):
            "\(reason) A copy of the image is kept at \(archive.path) — load it with: container image load --input \(shellQuoteIfNeeded(archive.path))"
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
