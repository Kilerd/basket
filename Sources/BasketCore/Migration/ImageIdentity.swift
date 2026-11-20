import Foundation

// Deciding whether an OrbStack image is "already in Basket" by content, not by name: an unrelated
// image Basket holds under the same reference must never make the migration skip OrbStack's copy,
// let alone offer it for deletion in OrbStack.

/// The content of one platform variant of an image, as far as two copies can be compared.
public struct ImageContentIdentity: Sendable, Hashable {
    /// "linux/arm64/v8".
    public var platform: String
    /// Digest of the platform manifest, when known (docker reports it only for `--platform` lookups).
    public var manifestDigest: String?
    /// Uncompressed layer digests (`rootfs.diff_ids`), in order.
    public var diffIDs: [String]
    public var config: ImageRuntimeConfig
    /// The config's `created` timestamp as printed.
    public var created: String?

    public init(
        platform: String, manifestDigest: String? = nil, diffIDs: [String], config: ImageRuntimeConfig = ImageRuntimeConfig(),
        created: String? = nil
    ) {
        self.platform = platform
        self.manifestDigest = manifestDigest
        self.diffIDs = diffIDs
        self.config = config
        self.created = created
    }
}

/// The parts of an image config that change how a container runs. Empty and missing are the same.
public struct ImageRuntimeConfig: Sendable, Hashable {
    public var environment: [String]
    public var entrypoint: [String]
    public var command: [String]
    public var workingDirectory: String
    public var user: String
    public var labels: [String: String]
    public var exposedPorts: Set<String>
    public var volumes: Set<String>
    public var stopSignal: String

    public init(
        environment: [String] = [], entrypoint: [String] = [], command: [String] = [], workingDirectory: String = "",
        user: String = "", labels: [String: String] = [:], exposedPorts: Set<String> = [], volumes: Set<String> = [],
        stopSignal: String = ""
    ) {
        self.environment = environment
        self.entrypoint = entrypoint
        self.command = command
        self.workingDirectory = workingDirectory
        self.user = user
        self.labels = labels
        self.exposedPorts = exposedPorts
        self.volumes = volumes
        self.stopSignal = stopSignal
    }

    init(_ raw: RawDockerConfig?) {
        self.init(
            environment: raw?.Env ?? [], entrypoint: raw?.Entrypoint ?? [], command: raw?.Cmd ?? [],
            workingDirectory: raw?.WorkingDir ?? "", user: raw?.User ?? "", labels: raw?.Labels ?? [:],
            exposedPorts: Set((raw?.ExposedPorts ?? [:]).keys), volumes: Set((raw?.Volumes ?? [:]).keys),
            stopSignal: raw?.StopSignal ?? "")
    }
}

/// Whether an OrbStack image is in Basket, decided by content.
public enum BasketPresence: Sendable, Hashable {
    /// Basket has no image under this reference.
    case absent
    /// Basket's image under the same reference has the same content for the platform an import
    /// would copy: the same platform manifest, or the same layers, config and creation time.
    case identical
    /// Basket holds a different image under the same reference (the reason says how it differs).
    case nameConflict(String)
    /// Basket has an image under this reference, but the two couldn't be compared.
    case unverified(String)

    /// Only verified copies count as "in Basket" (skipped by imports, listed for cleanup).
    public var isIdentical: Bool { self == .identical }
    /// Basket has something under the reference: importing would repoint it, so imports skip it.
    public var nameIsTaken: Bool { self != .absent }
}

public enum ImageContentComparison {
    /// Compares OrbStack's variant with Basket's variants of the same reference.
    public static func compare(_ source: ImageContentIdentity, with basket: [ImageContentIdentity]) -> BasketPresence {
        guard let target = basket.first(where: { samePlatform($0.platform, source.platform) }) else {
            let have = basket.map(\.platform)
            return .nameConflict("Basket's copy has no \(source.platform) variant"
                + (have.isEmpty ? "" : "; it has \(have.joined(separator: ", "))"))
        }
        if let digest = source.manifestDigest, digest == target.manifestDigest { return .identical }
        guard !source.diffIDs.isEmpty, !target.diffIDs.isEmpty else {
            return .unverified("their layer lists couldn't be read")
        }
        guard source.diffIDs == target.diffIDs else { return .nameConflict("its layers differ") }
        guard source.config == target.config else { return .nameConflict("same layers, but its configuration differs") }
        guard sameCreated(source.created, target.created) else {
            return .nameConflict("same layers and configuration, but built at a different time")
        }
        return .identical
    }

    /// "linux/arm64" matches "linux/arm64/v8"; a variant only counts when both sides name one
    /// (arm64's "v8" is its default).
    static func samePlatform(_ a: String, _ b: String) -> Bool {
        func parts(_ platform: String) -> (String, String, String) {
            let items = platform.split(separator: "/").map(String.init)
            let arch = items.count > 1 ? items[1] : ""
            var variant = items.count > 2 ? items[2] : ""
            if arch == "arm64" && variant == "v8" { variant = "" }
            return (items.first ?? "", arch, variant)
        }
        let (osA, archA, variantA) = parts(a)
        let (osB, archB, variantB) = parts(b)
        guard osA == osB, archA == archB, !archA.isEmpty else { return false }
        return variantA.isEmpty || variantB.isEmpty || variantA == variantB
    }

    static func sameCreated(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        if a == b { return true }
        guard let dateA = RawJSON.parseDate(a), let dateB = RawJSON.parseDate(b) else { return false }
        return abs(dateA.timeIntervalSince(dateB)) < 0.001
    }
}

// MARK: - Reading both sides

/// One element of `container image inspect` with what content comparison needs.
struct RawBasketImageInspect: Decodable, Sendable {
    var variants: [Variant]?

    struct Variant: Decodable, Sendable {
        var digest: String?
        var platform: RawPlatform?
        var config: Config?
    }

    struct Config: Decodable, Sendable {
        var created: String?
        var rootfs: RootFS?
        var config: RawDockerConfig?
    }

    struct RootFS: Decodable, Sendable {
        var diff_ids: [String]?
    }

    /// Platform variants (attestation manifests left out).
    var identities: [ImageContentIdentity] {
        (variants ?? []).compactMap { variant in
            guard let platform = variant.platform, !platform.isAttestation else { return nil }
            return ImageContentIdentity(
                platform: platform.fullString, manifestDigest: variant.digest, diffIDs: variant.config?.rootfs?.diff_ids ?? [],
                config: ImageRuntimeConfig(variant.config?.config), created: variant.config?.created)
        }
    }
}

extension RawDockerImage {
    /// The variant docker resolved for this inspect element; nil when docker had no content for it.
    var contentIdentity: ImageContentIdentity? {
        guard let platform = DockerFormat.platform(of: self) else { return nil }
        let manifest = Descriptor.flatMap { descriptor in
            descriptor.mediaType.map(DockerFormat.manifestMediaTypes.contains) == true ? descriptor.digest : nil
        }
        return ImageContentIdentity(
            platform: platform, manifestDigest: manifest, diffIDs: RootFS?.Layers ?? [],
            config: ImageRuntimeConfig(Config), created: Created)
    }
}

extension OrbStackMigrator {
    /// Whether each image is in Basket, by content (see `BasketPresence`), keyed by `OrbStackImage.id`.
    /// Only images whose reference Basket lists are inspected (one docker and one container call each).
    public func basketPresence(
        of images: [OrbStackImage], basket: [ImageSummary], backend: any ContainerBackend
    ) async -> [String: BasketPresence] {
        let listed = Self.basketReferences(basket)
        var result: [String: BasketPresence] = [:]
        for image in images {
            guard let reference = image.basketReference, listed.contains(reference) else {
                result[image.id] = .absent
                continue
            }
            if Task.isCancelled { break }
            result[image.id] = await comparePresent(image, reference: reference, backend: backend)
        }
        return result
    }

    /// Compares `image` with what Basket holds under `reference` (which Basket lists).
    func comparePresent(_ image: OrbStackImage, reference: String, backend: any ContainerBackend) async -> BasketPresence {
        let source: ImageContentIdentity
        do {
            guard let identity = try await orbStackIdentity(image) else {
                return .unverified("OrbStack has no content for it on this Mac's platform or linux/amd64")
            }
            source = identity
        } catch {
            return .unverified("couldn't read OrbStack's copy: \(error.localizedDescription)")
        }
        let basket: [ImageContentIdentity]
        do {
            let text = try await backend.inspectImage(reference)
            let decoded = try JSONDecoder().decode([Lossy<RawBasketImageInspect>].self, from: Data(text.utf8))
            basket = decoded.compactMap(\.value).first?.identities ?? []
        } catch {
            return .unverified("couldn't inspect Basket's copy: \(error.localizedDescription)")
        }
        return ImageContentComparison.compare(source, with: basket)
    }

    /// `docker image inspect --platform P` for the platform an import would export (host first when
    /// the platform is unknown, then linux/amd64): that element names the platform manifest.
    func orbStackIdentity(_ image: OrbStackImage) async throws -> ImageContentIdentity? {
        for platform in Self.exportCandidates(image) {
            let result = try await docker(["image", "inspect", "--platform", platform, image.imageID])
            guard result.exitCode == 0 else { continue }
            let inspected = try DockerFormat.decodeArray(RawDockerImage.self, from: result.stdout, command: "docker image inspect")
            if let identity = inspected.first?.contentIdentity, !identity.diffIDs.isEmpty || identity.manifestDigest != nil {
                return identity
            }
        }
        return nil
    }
}
