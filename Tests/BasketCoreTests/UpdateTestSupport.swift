import CryptoKit
import Foundation
@testable import BasketCore

/// Throwaway update artifacts: fake app bundles, zips signed with a key made for the test.
enum UpdateFixtures {
    static let releasePrefix = UpdatePolicy.productionDownloadPrefix

    static func manifest(
        version: String = "0.0.2", url: String? = nil, sha256: String = String(repeating: "ab", count: 32),
        signature: String = Data(repeating: 7, count: 64).base64EncodedString()
    ) -> UpdateManifest {
        UpdateManifest(
            version: version, pubDate: "2026-11-21T10:00:00Z", notes: "### Added\n\n- Signed updates.",
            minimumSystemVersion: "26.0",
            url: url ?? "\(releasePrefix)v\(version)/Basket-\(version)-arm64.zip",
            sha256: sha256, signature: signature)
    }

    static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static var manifestObject: [String: Any] {
        [
            "version": "0.0.2",
            "pub_date": "2026-11-21T10:00:00Z",
            "notes": "### Added\n\n- Signed updates.",
            "minimum_system_version": "26.0",
            "url": "\(releasePrefix)v0.0.2/Basket-0.0.2-arm64.zip",
            "sha256": String(repeating: "0f", count: 32),
            "signature": Data(repeating: 1, count: 64).base64EncodedString(),
        ]
    }

    /// `<dir>/<name>` with Info.plist and a placeholder executable.
    @discardableResult
    static func makeApp(in directory: URL, name: String = "Basket.app", identifier: String = "dev.basket.app",
                        version: String) throws -> URL {
        let app = directory.appending(path: name, directoryHint: .isDirectory)
        let macOS = app.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleVersion": version,
            "CFBundleExecutable": "Basket", "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        let executable = macOS.appending(path: "Basket")
        try "#!/bin/sh\necho \(version)\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return app
    }

    static func version(of app: URL) -> String? {
        let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist"))
        let plist = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        return plist?["CFBundleShortVersionString"] as? String
    }

    /// `ditto -c -k [--keepParent] <source> <zip>`, as the release workflow does.
    static func zip(_ source: URL, to zip: URL, keepParent: Bool = true) async throws {
        let result = try await run("/usr/bin/ditto", ["-c", "-k"] + (keepParent ? ["--keepParent"] : []) + [source.path, zip.path])
        guard result.status == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    struct ProcessResult {
        var pid: Int32
        var status: Int32
        var output: String
    }

    /// Runs a tool without blocking a thread of the (shared) cooperative pool while it runs:
    /// other tests time their own work on it.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String], in directory: URL? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        let output = FileManager.default.temporaryDirectory.appending(path: "basket-tests-output-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        process.standardOutput = handle
        process.standardError = handle
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        try handle.close()
        return ProcessResult(pid: process.processIdentifier, status: status,
                             output: (try? String(contentsOf: output, encoding: .utf8)) ?? "")
    }

    /// A signed release: the zip of a fake app and the offer describing it.
    struct Release {
        var zip: URL
        var offer: UpdateOffer
        var key: Curve25519.Signing.PrivateKey
        var verifier: UpdateVerifier
    }

    static func release(in dir: URL, version: String = "0.0.2", bundleVersion: String? = nil,
                        identifier: String = "dev.basket.app", url: URL? = nil) async throws -> Release {
        let source = dir.appending(path: "source-\(UUID().uuidString)", directoryHint: .isDirectory)
        let app = try makeApp(in: source, identifier: identifier, version: bundleVersion ?? version)
        let archive = dir.appending(path: "Basket-\(version).zip")
        try await zip(app, to: archive)
        try FileManager.default.removeItem(at: source)
        let data = try Data(contentsOf: archive)
        let key = Curve25519.Signing.PrivateKey()
        let offer = UpdateOffer(
            version: SemanticVersion(version)!, date: Date(), notes: "", minimumSystemVersion: SystemVersion(26),
            url: url ?? archive, sha256: UpdateVerifier.sha256Hex(data), signature: try key.signature(for: data))
        let verifier = try UpdateVerifier(publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString())
        return Release(zip: archive, offer: offer, key: key, verifier: verifier)
    }

    static func installer(_ release: Release, policy: UpdatePolicy = .production, system: SystemVersion = SystemVersion(26, 1),
                          verifyCode: @escaping @Sendable (URL) throws -> Void = { _ in }) -> UpdateInstaller {
        UpdateInstaller(policy: policy, verifier: release.verifier, verifyCode: verifyCode, system: system)
    }
}
