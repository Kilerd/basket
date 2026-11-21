import Foundation

extension OrbStackMigrator {
    /// Headroom kept free on top of the image's size while exporting.
    static let diskHeadroomBytes: Int64 = 512 * 1_048_576

    /// Exports `image` from OrbStack (`docker save --platform <host>` when OrbStack has the host
    /// variant, so only that variant is copied) and loads it into Basket. The archive lives in a
    /// fresh temporary directory that is removed when the import ends — also on failure or
    /// cancellation. Cancelling the consumer terminates the running `docker`/`container` process.
    public func importImage(_ image: OrbStackImage, into backend: any ContainerBackend) -> AsyncThrowingStream<ImportProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performImport(image, backend: backend) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Bytes an import needs free: Docker's disk-usage figure (compressed content + unpacked layers)
    /// bounds the archive (compressed content) plus the copy in Basket's content store.
    public static func requiredFreeBytes(for image: OrbStackImage) -> Int64 {
        max(image.sizeBytes, 0) + diskHeadroomBytes
    }

    func performImport(
        _ image: OrbStackImage, backend: any ContainerBackend, progress: @escaping @Sendable (ImportProgress) -> Void
    ) async throws {
        guard let reference = image.reference else {
            throw MigrationError.notImportable("An untagged, unnamed image has no reference to import under.")
        }
        let target = normalizeImageReference(reference)
        progress(ImportProgress(phase: .checking, message: "Checking Basket for \(target)"))
        // Loading repoints a reference Basket already has: never import over an existing name, and
        // only call it "already in Basket" when the content is the same.
        if Self.basketReferences(try await backend.listImages()).contains(target) {
            switch await comparePresent(image, reference: target, backend: backend) {
            case .identical, .absent: throw MigrationError.alreadyInBasket(target)
            case .nameConflict(let reason): throw MigrationError.nameConflict(reference: target, reason: reason)
            case .unverified(let reason): throw MigrationError.nameConflict(reference: target, reason: "the two couldn't be compared: \(reason)")
            }
        }
        try Task.checkCancellation()
        progress(ImportProgress(phase: .checking, message: "Checking free disk space"))
        let directory = try Self.makeImportDirectory(in: temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let needed = Self.requiredFreeBytes(for: image)
        if let available = freeSpace(directory), available < needed {
            throw MigrationError.insufficientDiskSpace(neededBytes: needed, availableBytes: available)
        }

        let archive = directory.appendingPathComponent("image.tar")
        let platform = try await export(reference, platforms: Self.exportCandidates(image), to: archive, directory: directory, progress: progress)
        try Task.checkCancellation()

        let archiveBytes = Self.allocatedSize(of: directory)
        progress(ImportProgress(phase: .loading(bytes: archiveBytes), message: "Loading into Basket"))
        let references = try await load(archive, reference: reference, platform: platform, backend: backend)
        try Task.checkCancellation()
        progress(ImportProgress(
            phase: .done(references: references, archiveBytes: archiveBytes),
            message: "Imported \(references.first ?? normalizeImageReference(reference))"))
    }

    /// Known platform → exactly that (host preferred); unknown → host first, then linux/amd64.
    static func exportCandidates(_ image: OrbStackImage) -> [String] {
        image.platform == nil ? [MigrationPlatform.host, "linux/amd64"] : [image.exportPlatform]
    }

    /// `docker save --platform P -o archive ref`, reporting bytes written; returns the platform used.
    func export(
        _ reference: String, platforms: [String], to archive: URL, directory: URL,
        progress: @escaping @Sendable (ImportProgress) -> Void
    ) async throws -> String {
        var lastError: Error = MigrationError.notImportable("Nothing to export.")
        for platform in platforms {
            progress(ImportProgress(phase: .exporting(bytes: 0), message: "Exporting \(platform) from OrbStack"))
            let arguments = ["save", "--platform", platform, "-o", archive.path, reference]
            let save = Task { try await docker(arguments, timeout: nil) }
            let stalled = StallFlag()
            // Reports bytes written and stops the export when the archive stops growing.
            let monitor = Task { [stallTimeout = exportStallTimeout] in
                let clock = ContinuousClock()
                var lastBytes: Int64 = -1
                var lastGrowth = clock.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    let bytes = Self.allocatedSize(of: directory)
                    if bytes != lastBytes {
                        lastBytes = bytes
                        lastGrowth = clock.now
                        if bytes > 0 {
                            progress(ImportProgress(phase: .exporting(bytes: bytes), message: "Exporting \(platform) from OrbStack"))
                        }
                    } else if clock.now - lastGrowth > stallTimeout {
                        stalled.set()
                        save.cancel()
                        return
                    }
                }
            }
            // The watchdog reports through `progress` too: wait for it to stop before returning, or
            // a late "exporting" update can arrive after "loading" (or even after "done").
            let result: CLIResult
            do {
                result = try await withTaskCancellationHandler { try await save.value } onCancel: { save.cancel() }
                monitor.cancel()
                await monitor.value
            } catch {
                monitor.cancel()
                await monitor.value
                if stalled.isSet, !Task.isCancelled {
                    throw MigrationError.dockerFailed(
                        command: Self.commandLine(arguments),
                        message: "the export made no progress for \(exportStallTimeout.components.seconds) s and was stopped")
                }
                throw error
            }
            if result.exitCode == 0 { return platform }
            lastError = MigrationError.dockerFailed(command: Self.commandLine(arguments), message: Self.message(result))
            // Docker leaves nothing usable behind; start the next attempt from an empty directory.
            for item in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where item.lastPathComponent != Self.importOwnerFile {
                try? FileManager.default.removeItem(at: item)
            }
            guard result.stderrText.contains("does not provide the specified platform") else { break }
        }
        throw lastError
    }

    /// `container image load -i archive`; drops the `untagged@…` images the load creates for
    /// attestation manifests docker exports alongside the image. Returns the references loaded.
    func load(_ archive: URL, reference: String, platform: String, backend: any ContainerBackend) async throws -> [String] {
        guard let cli = backend as? CLIBackend else {
            // Fixture/preview backends: their own `image load`, else the pull path adds the image.
            do {
                return try await backend.loadImage(from: archive)
            } catch BackendError.unsupported {
                for try await _ in backend.pullImage(normalizeImageReference(reference), platform: platform) {}
                return [normalizeImageReference(reference)]
            }
        }
        let before = Set((try? await backend.listImages())?.map(\.reference) ?? [])
        let runner = try cli.runner()
        let arguments = ["image", "load", "--input", archive.path]
        let result = try await runner.run(arguments, timeout: nil)
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            let error = CLIErrorClassifier.error(command: runner.commandLine(arguments), exitCode: result.exitCode, stderr: result.stderrText)
            if error == .systemNotRunning { throw error }
            throw MigrationError.loadFailed(CLIErrorClassifier.cleaned(result.stderrText.isEmpty ? result.stdoutText : result.stderrText))
        }
        let loaded = result.stdoutText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" ") }
        let strays = loaded.filter { $0.hasPrefix("untagged@") && !before.contains($0) }
        if !strays.isEmpty { try? await backend.deleteImages(strays, force: false) }
        let kept = loaded.filter { !strays.contains($0) }
        return kept.isEmpty ? [normalizeImageReference(reference)] : kept
    }

    /// Bytes the (visible) files directly inside `directory` occupy.
    static func allocatedSize(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        return items.reduce(Int64(0)) { total, url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return total + Int64(values?.isRegularFile == true ? values?.fileSize ?? 0 : 0)
        }
    }

    // MARK: Containers

    /// Recreates a container in Basket: imports its image from OrbStack first when Basket doesn't
    /// have it (host platform only), creates missing named volumes (empty: data isn't copied), then
    /// runs it detached. Returns the new container's id.
    public func recreate(
        _ plan: RecreationPlan, sourceImage: OrbStackImage?, into backend: any ContainerBackend,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        let present = Self.basketReferences(try await backend.listImages())
        if present.contains(plan.image) {
            // Same name isn't same image: never run the container from an unrelated image.
            if let sourceImage, sourceImage.basketReference == plan.image {
                switch await comparePresent(sourceImage, reference: plan.image, backend: backend) {
                case .nameConflict(let reason):
                    throw MigrationError.nameConflict(reference: plan.image, reason: reason)
                case .unverified(let reason):
                    progress("Using Basket's \(plan.image); it couldn't be compared with OrbStack's (\(reason))")
                case .identical, .absent:
                    break
                }
            }
        } else {
            if let sourceImage, sourceImage.reference != nil {
                for try await step in importImage(sourceImage, into: backend) { progress(step.message) }
            } else {
                progress("The image isn't in OrbStack; `container run` will pull it")
            }
        }
        if !plan.volumes.isEmpty {
            let existing = Set(try await backend.listVolumes().map(\.name))
            for volume in plan.volumes where !existing.contains(volume) {
                progress("Creating volume \(volume)")
                try await backend.createVolume(name: volume, size: nil)
            }
        }
        progress("Starting \(plan.name)")
        guard let cli = backend as? CLIBackend else { return try await backend.run(plan.runSpec) }
        var arguments = plan.runArguments
        if let index = arguments.firstIndex(of: "run") { arguments.insert(contentsOf: ["--progress", "none"], at: index + 1) }
        let output = try await cli.output(arguments, timeout: .seconds(900))
        let id = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).last
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return id.flatMap { $0.isEmpty ? nil : $0 } ?? plan.name
    }
}

/// Set once from the export watchdog, read after the export ends.
private final class StallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
