import Foundation

/// An update downloaded, verified and extracted next to the installed app, ready for
/// `UpdateSwap` once Basket quits.
public struct StagedUpdate: Equatable, Sendable {
    public let version: SemanticVersion
    public let previousVersion: SemanticVersion
    /// Private directory on the destination's volume; removed after a successful swap.
    public let stagingDirectory: URL
    /// The verified new app inside `stagingDirectory`.
    public let newApp: URL
    /// The installed app it replaces.
    public let destination: URL

    /// Where the swap parks the old app (same volume) before it goes to the Trash.
    public var backup: URL {
        stagingDirectory.appending(path: "previous", directoryHint: .isDirectory)
            .appending(path: destination.lastPathComponent, directoryHint: .isDirectory)
    }
}

/// Fetches `latest.json`, then downloads → verifies (SHA-256 + Ed25519) → extracts → checks the
/// bundle id, version and code signature → stages (docs/updates.md, "What the app checks").
public struct UpdateInstaller: Sendable {
    public enum Progress: Equatable, Sendable {
        case downloading(received: Int64, expected: Int64?)
        case verifying
    }

    public var policy: UpdatePolicy
    public var verifier: UpdateVerifier
    /// Checks the extracted app's code signature; production uses `CodeSignature.verify` with the
    /// running app's team. Tests inject their own.
    public var verifyCode: @Sendable (URL) throws -> Void
    public var system: SystemVersion
    public var session: URLSession

    public init(policy: UpdatePolicy, verifier: UpdateVerifier, verifyCode: @escaping @Sendable (URL) throws -> Void,
                system: SystemVersion = .current, session: URLSession? = nil) {
        self.policy = policy
        self.verifier = verifier
        self.verifyCode = verifyCode
        self.system = system
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    // MARK: Manifest

    public func fetchOffer() async throws -> UpdateOffer {
        var request = URLRequest(url: policy.feedURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var data = Data()
        try await stream(request, limit: Int64(UpdatePolicy.maxManifestBytes), tooLarge: { _ in
            UpdateError.invalidManifest(String(localized: "it is too large", bundle: .main))
        }) { chunk, _, _ in data.append(chunk) }
        return try UpdateManifest.decode(data).validated(policy: policy)
    }

    /// The archive's size for the sheet (HEAD request); nil when the server doesn't say.
    public func archiveSize(_ offer: UpdateOffer) async -> Int64? {
        if offer.url.isFileURL {
            return (try? offer.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        }
        var request = URLRequest(url: offer.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength > 0
        else { return nil }
        return response.expectedContentLength
    }

    // MARK: Install

    /// Everything up to the swap. On any failure (or cancellation) the staging directory is gone.
    public func prepare(_ offer: UpdateOffer, replacing installedApp: URL, currentVersion: SemanticVersion,
                        progress: @escaping @Sendable (Progress) -> Void) async throws -> StagedUpdate {
        try checkEligible(offer, currentVersion: currentVersion)
        let staging = try Self.makeStagingDirectory(for: installedApp)
        do {
            let archive = staging.appending(path: "download.zip")
            try await download(offer, to: archive, progress: progress)
            progress(.verifying)
            return try await stage(archive: archive, offer: offer, replacing: installedApp,
                                   currentVersion: currentVersion, staging: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Streams the archive to `file`, enforcing `policy.maxArchiveBytes`. Cancellable.
    public func download(_ offer: UpdateOffer, to file: URL, progress: @escaping @Sendable (Progress) -> Void) async throws {
        let request = URLRequest(url: offer.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw UpdateError.installFailed(String(localized: "can't write \(file.lastPathComponent)", bundle: .main))
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var lastReport: Int64 = -1
        progress(.downloading(received: 0, expected: nil))
        try await stream(request, limit: policy.maxArchiveBytes, tooLarge: { UpdateError.tooLarge($0) }) { chunk, received, expected in
            try handle.write(contentsOf: chunk)
            if received - lastReport >= 256 << 10 || received == expected {
                lastReport = received
                progress(.downloading(received: received, expected: expected))
            }
        }
    }

    /// Verifies the archive, extracts it into `staging/new` and checks the app inside.
    public func stage(archive: URL, offer: UpdateOffer, replacing installedApp: URL, currentVersion: SemanticVersion,
                      staging: URL) async throws -> StagedUpdate {
        try checkEligible(offer, currentVersion: currentVersion)
        try verifier.verify(archive: archive, sha256: offer.sha256, signature: offer.signature)
        let extracted = staging.appending(path: "new", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try await Self.extract(archive, into: extracted)
        try? FileManager.default.removeItem(at: archive)
        let app = try Self.singleApp(in: extracted)
        try Self.checkBundle(app, offer: offer, currentVersion: currentVersion, identifier: policy.appBundleIdentifier)
        do {
            try verifyCode(app)
        } catch let error as UpdateError {
            throw error.isSecurityFailure ? error : UpdateError.codeSignature(error.localizedDescription)
        } catch {
            throw UpdateError.codeSignature(error.localizedDescription)
        }
        return StagedUpdate(version: offer.version, previousVersion: currentVersion, stagingDirectory: staging,
                            newApp: app, destination: installedApp)
    }

    func checkEligible(_ offer: UpdateOffer, currentVersion: SemanticVersion) throws {
        guard offer.version > currentVersion else {
            throw UpdateError.notNewer(current: currentVersion.description, offered: offer.version.description)
        }
        guard system >= offer.minimumSystemVersion else {
            throw UpdateError.requiresNewerSystem(offer.minimumSystemVersion.description)
        }
    }

    // MARK: Steps

    /// A fresh private directory on the same volume as `app`, so the swap is a rename.
    public static func makeStagingDirectory(for app: URL) throws -> URL {
        let fm = FileManager.default
        let directory: URL
        do {
            directory = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        } catch {
            throw UpdateError.installFailed(String(localized: "no temporary folder on the volume of \(app.path) (\(error.localizedDescription))", bundle: .main))
        }
        let parentVolume = try? app.deletingLastPathComponent().resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let stagingVolume = try? directory.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        if let parentVolume, let stagingVolume, !parentVolume.isEqual(stagingVolume) {
            try? fm.removeItem(at: directory)
            throw UpdateError.installFailed(String(localized: "the temporary folder isn't on the same volume as \(app.path)", bundle: .main))
        }
        return directory
    }

    /// `ditto -x -k`: the counterpart of the release's `ditto -c -k --keepParent`.
    static func extract(_ archive: URL, into directory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: UpdateError.invalidArchive(String(localized: "ditto couldn't run (\(error.localizedDescription))", bundle: .main)))
            }
        }
        guard status == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.invalidArchive(message.isEmpty
                ? String(localized: "unzipping failed", bundle: .main)
                : String(localized: "unzipping failed: \(String(message.prefix(200)))", bundle: .main))
        }
    }

    /// The archive must hold exactly one item: a real (non-symlink) `.app` directory.
    static func singleApp(in directory: URL) throws -> URL {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])) ?? []
        guard items.count == 1, let item = items.first, item.pathExtension == "app" else {
            throw UpdateError.invalidArchive(String(localized: "it should contain only Basket.app", bundle: .main))
        }
        // Keep `directory`'s spelling of the path (the listing resolves /var → /private/var).
        let app = directory.appending(path: item.lastPathComponent, directoryHint: .isDirectory)
        let values = try? app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values?.isSymbolicLink == false, values?.isDirectory == true else {
            throw UpdateError.invalidArchive(String(localized: "Basket.app isn't a folder", bundle: .main))
        }
        return app
    }

    /// Bundle id `identifier` (the policy's: `dev.basket.app` in release builds), version equal to
    /// the manifest's and newer than the running one.
    static func checkBundle(_ app: URL, offer: UpdateOffer, currentVersion: SemanticVersion,
                            identifier expected: String = UpdatePolicy.bundleIdentifier) throws {
        let plistURL = app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw UpdateError.bundleMismatch(String(localized: "it has no readable Info.plist", bundle: .main)) }
        let identifier = info["CFBundleIdentifier"] as? String
        guard identifier == expected else {
            throw UpdateError.bundleMismatch(identifier.map { String(localized: "its bundle identifier is “\($0)”", bundle: .main) }
                ?? String(localized: "it has no bundle identifier", bundle: .main))
        }
        let versionString = info["CFBundleShortVersionString"] as? String
        guard let versionString, let version = SemanticVersion(versionString), version == offer.version else {
            let announced = offer.version.description
            throw UpdateError.bundleMismatch(versionString.map {
                String(localized: "it is version \($0), the update information says \(announced)", bundle: .main)
            } ?? String(localized: "it has no version number, the update information says \(announced)", bundle: .main))
        }
        guard version > currentVersion else {
            throw UpdateError.bundleMismatch(String(localized: "version \(version.description) isn't newer than the installed \(currentVersion.description)", bundle: .main))
        }
    }

    /// Reads `request` in chunks; `sink(chunk, receivedSoFar, expected)`. Non-200 HTTP is an error.
    private func stream(_ request: URLRequest, limit: Int64, tooLarge: (Int64) -> UpdateError,
                        sink: (Data, Int64, Int64?) throws -> Void) async throws {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw Self.networkError(error)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.network(String(localized: "the server answered HTTP \(http.statusCode)", bundle: .main))
        }
        let expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        if let expected, expected > limit { throw tooLarge(expected) }
        var buffer = Data()
        buffer.reserveCapacity(64 << 10)
        var received: Int64 = 0
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count == 64 << 10 {
                    received += Int64(buffer.count)
                    if received > limit { throw tooLarge(received) }
                    try sink(buffer, received, expected)
                    buffer.removeAll(keepingCapacity: true)
                    try Task.checkCancellation()
                }
            }
        } catch let error as UpdateError {
            throw error
        } catch {
            throw Self.networkError(error)
        }
        try Task.checkCancellation()
        if !buffer.isEmpty {
            received += Int64(buffer.count)
            if received > limit { throw tooLarge(received) }
            try sink(buffer, received, expected)
        }
        if let expected, received != expected {
            let got = received.formatted(.byteCount(style: .file)), total = expected.formatted(.byteCount(style: .file))
            throw UpdateError.network(String(localized: "the download ended after \(got) of \(total)", bundle: .main))
        }
    }

    private static func networkError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            return UpdateError.network(urlError.localizedDescription)
        }
        return UpdateError.network(error.localizedDescription)
    }
}
