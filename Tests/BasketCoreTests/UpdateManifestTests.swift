import CryptoKit
import Foundation
import Testing
@testable import BasketCore

@Suite("Update manifest")
struct UpdateManifestTests {
    private func reason(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch UpdateError.invalidManifest(let reason) {
            return reason
        } catch {
            return "unexpected \(error)"
        }
    }

    @Test func decodesThePublishedFormat() throws {
        let manifest = try UpdateManifest.decode(UpdateFixtures.json(UpdateFixtures.manifestObject))
        let offer = try manifest.validated(policy: .production)
        #expect(offer.version == SemanticVersion(0, 0, 2))
        #expect(offer.minimumSystemVersion == SystemVersion(26))
        #expect(offer.url.absoluteString == "https://github.com/Kilerd/basket/releases/download/v0.0.2/Basket-0.0.2-arm64.zip")
        #expect(offer.sha256 == String(repeating: "0f", count: 32))
        #expect(offer.signature.count == 64)
        #expect(offer.notes.hasPrefix("### Added"))
        #expect(offer.date == UpdateManifest.parseDate("2026-11-21T10:00:00Z"))
    }

    @Test func demoFixtureIsAValidManifest() throws {
        let data = try Data(contentsOf: TestFixtures.set("demo").appending(path: "update/latest.json"))
        let offer = try UpdateManifest.decode(data).validated(policy: .production)
        #expect(offer.version == SemanticVersion(0, 0, 2))
        #expect(ReleaseNotes.blocks(offer.notes).first == .heading("Added"))
    }

    @Test func everyFieldIsRequired() throws {
        for key in UpdateFixtures.manifestObject.keys {
            var object = UpdateFixtures.manifestObject
            object[key] = nil
            let data = try UpdateFixtures.json(object)
            let why = reason { _ = try UpdateManifest.decode(data) }
            #expect(why?.contains(key) == true, "missing \(key): \(why ?? "accepted")")
        }
    }

    @Test func rejectsWrongTypesAndGarbage() throws {
        var object = UpdateFixtures.manifestObject
        object["version"] = 2
        #expect(reason { _ = try UpdateManifest.decode(try UpdateFixtures.json(object)) }?.contains("version") == true)
        object = UpdateFixtures.manifestObject
        object["notes"] = NSNull()
        #expect(reason { _ = try UpdateManifest.decode(try UpdateFixtures.json(object)) } != nil)
        #expect(reason { _ = try UpdateManifest.decode(Data("<html>".utf8)) } != nil)
        #expect(reason { _ = try UpdateManifest.decode(Data(repeating: 32, count: UpdatePolicy.maxManifestBytes + 1)) } != nil)
    }

    @Test func ignoresUnknownKeys() throws {
        var object = UpdateFixtures.manifestObject
        object["size"] = 12_345
        object["channel"] = "stable"
        #expect(throws: Never.self) { try UpdateManifest.decode(try UpdateFixtures.json(object)).validated(policy: .production) }
    }

    @Test(arguments: ["0.0", "v0.0.2", "0.0.02", "01.0.0", "1.2.3-beta", "1.2.3+build", "1.2.3.4", "", " 1.2.3", "1..3", "1.2.x", "１.2.3"])
    func rejectsBadVersions(_ version: String) {
        var manifest = UpdateFixtures.manifest()
        manifest.version = version
        #expect(reason { _ = try manifest.validated(policy: .production) }?.contains("version") == true)
    }

    @Test(arguments: [
        "https://evil.example/Kilerd/basket/releases/download/v0.0.2/Basket.zip",
        "https://github.com/someone/basket/releases/download/v0.0.2/Basket.zip",
        "https://github.com/Kilerd/basket-fork/releases/download/v0.0.2/Basket.zip",
        "https://github.com/Kilerd/basket/releases/download.evil.example/Basket.zip",
        "https://github.com.evil.example/Kilerd/basket/releases/download/v0.0.2/Basket.zip",
        "http://github.com/Kilerd/basket/releases/download/v0.0.2/Basket.zip",
        "https://github.com/Kilerd/basket/releases/download/v0.0.2/Basket.zip?x=1",
        "https://github.com/Kilerd/basket/releases/download/v0.0.2/Basket.zip#x",
        "https://github.com/Kilerd/basket/releases/download/../../../other/Basket.zip",
        "https://github.com/Kilerd/basket/releases/download/v0.0.2/%2e%2e/Basket.zip",
        "https://github.com/Kilerd/basket/releases/download//Basket.zip",
        "https://github.com/Kilerd/basket/releases/download/v0.0.2/Basket.dmg",
        "https://github.com/Kilerd/basket/releases/download/",
        "file:///tmp/Basket.zip",
        "Basket.zip",
    ])
    func rejectsDownloadsOutsideTheReleases(_ url: String) {
        let manifest = UpdateFixtures.manifest(url: url)
        #expect(reason { _ = try manifest.validated(policy: .production) }?.contains("url") == true, "\(url)")
    }

    @Test func fileURLsOnlyThroughATestFeedAndOnlyNextToIt() throws {
        let feed = URL(fileURLWithPath: "/tmp/basket-feed/latest.json")
        let policy = UpdatePolicy.testFeed(feed)
        let ok = UpdateFixtures.manifest(url: "file:///tmp/basket-feed/Basket-0.0.2.zip")
        #expect(try ok.validated(policy: policy).url.path == "/tmp/basket-feed/Basket-0.0.2.zip")
        #expect(reason { _ = try ok.validated(policy: .production) } != nil)
        for url in ["file:///tmp/other/Basket-0.0.2.zip", "file:///tmp/basket-feed/../x/Basket.zip", "https://github.com/Kilerd/basket/releases/download/v0.0.2/B.zip"] {
            #expect(reason { _ = try UpdateFixtures.manifest(url: url).validated(policy: policy) } != nil, "\(url)")
        }
    }

    @Test func checksAndSignatureFormats() throws {
        #expect(throws: Never.self) { try UpdateFixtures.manifest(sha256: String(repeating: "AB", count: 32)).validated(policy: .production) }
        #expect(try UpdateFixtures.manifest(sha256: String(repeating: "AB", count: 32)).validated(policy: .production).sha256
                == String(repeating: "ab", count: 32))
        for sha in [String(repeating: "a", count: 63), String(repeating: "g", count: 64), String(repeating: "a", count: 65), ""] {
            #expect(reason { _ = try UpdateFixtures.manifest(sha256: sha).validated(policy: .production) }?.contains("sha256") == true)
        }
        for signature in ["not base64!", Data(repeating: 1, count: 63).base64EncodedString(), ""] {
            #expect(reason { _ = try UpdateFixtures.manifest(signature: signature).validated(policy: .production) }?.contains("signature") == true)
        }
    }

    @Test func datesAndSystemVersions() throws {
        var manifest = UpdateFixtures.manifest()
        manifest.pubDate = "2026-11-21T10:00:00.250Z"
        #expect(throws: Never.self) { try manifest.validated(policy: .production) }
        manifest.pubDate = "yesterday"
        #expect(reason { _ = try manifest.validated(policy: .production) }?.contains("pub_date") == true)
        manifest = UpdateFixtures.manifest()
        manifest.minimumSystemVersion = "26"
        #expect(try manifest.validated(policy: .production).minimumSystemVersion == SystemVersion(26, 0, 0))
        manifest.minimumSystemVersion = "macOS 26"
        #expect(reason { _ = try manifest.validated(policy: .production) }?.contains("minimum_system_version") == true)
    }
}

@Suite("Update versions")
struct UpdateVersionTests {
    @Test func semanticVersionsOrderNumerically() {
        let ordered = ["0.0.1", "0.0.2", "0.0.9", "0.0.10", "0.1.0", "0.10.0", "1.0.0", "10.0.0"].map { SemanticVersion($0)! }
        #expect(ordered.shuffled().sorted() == ordered)
        #expect(SemanticVersion("0.0.10")! > SemanticVersion("0.0.9")!)
        #expect(SemanticVersion("1.2.3") == SemanticVersion(1, 2, 3))
        #expect(SemanticVersion("1.2.3")?.description == "1.2.3")
        #expect(SemanticVersion("9999999999.0.0") == nil)
    }

    @Test func systemVersions() {
        #expect(SystemVersion("26") == SystemVersion("26.0.0"))
        #expect(SystemVersion("26.3")! > SystemVersion("26.0")!)
        #expect(SystemVersion("27.0")! > SystemVersion(OperatingSystemVersion(majorVersion: 26, minorVersion: 9, patchVersion: 1)))
        #expect(SystemVersion("26.0.1.2") == nil)
        #expect(SystemVersion(26, 0).description == "26.0")
    }

    @Test func eligibilityNeverOffersDowngradesOrReinstalls() throws {
        let offer = try UpdateFixtures.manifest(version: "0.0.5").validated(policy: .production)
        let system = SystemVersion(26, 1)
        #expect(offer.eligibility(current: SemanticVersion(0, 0, 4), system: system) == .available)
        #expect(offer.eligibility(current: SemanticVersion(0, 0, 5), system: system) == .upToDate)
        #expect(offer.eligibility(current: SemanticVersion(0, 1, 0), system: system) == .upToDate)
        var newer = UpdateFixtures.manifest(version: "0.0.5")
        newer.minimumSystemVersion = "27.0"
        #expect(try newer.validated(policy: .production).eligibility(current: SemanticVersion(0, 0, 4), system: system)
                == .requiresNewerSystem(SystemVersion(27)))
    }
}

@Suite("Update signature")
struct UpdateVerifierTests {
    let key = Curve25519.Signing.PrivateKey()
    let data = Data("Basket.app zip bytes".utf8)

    var verifier: UpdateVerifier {
        get throws { try UpdateVerifier(publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()) }
    }

    @Test func productionKeyIsAValidEd25519Key() throws {
        let verifier = try UpdateVerifier()
        #expect(verifier.publicKey.count == 32)
        #expect(verifier.publicKey.base64EncodedString() == UpdateVerifier.publicKeyBase64)
    }

    @Test func rejectsInvalidKeys() {
        #expect(throws: UpdateError.invalidPublicKey) { try UpdateVerifier(publicKeyBase64: "not a key") }
        #expect(throws: UpdateError.invalidPublicKey) { try UpdateVerifier(publicKeyBase64: Data(repeating: 1, count: 31).base64EncodedString()) }
    }

    @Test func acceptsAGoodSignature() throws {
        let signature = try key.signature(for: data)
        try verifier.verify(data: data, sha256: UpdateVerifier.sha256Hex(data), signature: signature)
        try verifier.verify(data: data, sha256: UpdateVerifier.sha256Hex(data).uppercased(), signature: signature)
    }

    @Test func checksumMismatch() throws {
        let signature = try key.signature(for: data)
        var tampered = data
        tampered[0] ^= 1
        #expect(throws: UpdateError.checksumMismatch) {
            try verifier.verify(data: tampered, sha256: UpdateVerifier.sha256Hex(data), signature: signature)
        }
    }

    @Test func badSignatures() throws {
        let sha = UpdateVerifier.sha256Hex(data)
        // Signed with another key.
        let other = try Curve25519.Signing.PrivateKey().signature(for: data)
        #expect(throws: UpdateError.badSignature) { try verifier.verify(data: data, sha256: sha, signature: other) }
        // Signature over other bytes (a checksum that matches doesn't help).
        let elsewhere = try key.signature(for: Data("other".utf8))
        #expect(throws: UpdateError.badSignature) { try verifier.verify(data: data, sha256: sha, signature: elsewhere) }
        var flipped = try key.signature(for: data)
        flipped[10] ^= 0x80
        #expect(throws: UpdateError.badSignature) { try verifier.verify(data: data, sha256: sha, signature: flipped) }
        // The production key doesn't accept a throwaway key's signature.
        #expect(throws: UpdateError.badSignature) {
            try UpdateVerifier().verify(data: data, sha256: sha, signature: try key.signature(for: data))
        }
    }

    @Test func securityFailuresAreFlagged() {
        #expect(UpdateError.badSignature.isSecurityFailure)
        #expect(UpdateError.checksumMismatch.isSecurityFailure)
        #expect(UpdateError.codeSignature("x").isSecurityFailure)
        #expect(UpdateError.bundleMismatch("x").isSecurityFailure)
        #expect(!UpdateError.network("offline").isSecurityFailure)
        #expect(!UpdateError.notNewer(current: "1.0.0", offered: "1.0.0").isSecurityFailure)
    }
}

@Suite("Release notes")
struct ReleaseNotesTests {
    @Test func changelogSection() {
        let notes = """
        ### Added

        - Signed updates: Basket checks GitHub Releases daily and
          installs only verified builds.
        - Settings ▸ Updates.

        ### Fixed
        Something **important**
        across two lines.
        """
        #expect(ReleaseNotes.blocks(notes) == [
            .heading("Added"),
            .bullet("Signed updates: Basket checks GitHub Releases daily and installs only verified builds."),
            .bullet("Settings ▸ Updates."),
            .heading("Fixed"),
            .paragraph("Something **important** across two lines."),
        ])
        #expect(ReleaseNotes.blocks("") == [])
    }
}
