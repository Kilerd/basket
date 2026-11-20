import Foundation
import Testing
@testable import BasketCore

@Suite("Update code signature and location")
struct UpdateTrustTests {
    @Test func requirementStringNamesBundleAndTeam() throws {
        #expect(try CodeSignature.requirement(teamID: "ABCDE12345")
                == #"anchor apple generic and identifier "dev.basket.app" and certificate leaf[subject.OU] = "ABCDE12345""#)
    }

    @Test(arguments: ["", "abcde12345", "ABCDE1234", "ABCDE123456", #"ABCDE1234""#, "ABCDE 1234", "ABCDÉ12345"])
    func rejectsMalformedTeams(_ team: String) {
        #expect(throws: UpdateError.self) { try CodeSignature.requirement(teamID: team) }
    }

    @Test func updatesNeedARealTeamSignature() throws {
        #expect(try CodeSignature.Info(identifier: "dev.basket.app", teamID: "ABCDE12345", isAdHoc: false).updateTeam() == "ABCDE12345")
        #expect(throws: UpdateError.self) { try CodeSignature.Info(identifier: "dev.basket.app", teamID: nil, isAdHoc: true).updateTeam() }
        #expect(throws: UpdateError.self) { try CodeSignature.Info(identifier: nil, teamID: nil, isAdHoc: false).updateTeam() }
    }

    @Test func unsignedAndAdHocBundlesFailTheRequirement() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let unsigned = try UpdateFixtures.makeApp(in: dir.url, version: "0.0.2")
        #expect(throws: UpdateError.self) { try CodeSignature.verify(bundle: unsigned, teamID: "ABCDE12345") }

        // A real Mach-O, re-signed ad hoc: valid signature, but no Apple anchor and no team.
        let adHoc = try UpdateFixtures.makeApp(in: dir.url, name: "AdHoc.app", version: "0.0.2")
        let executable = adHoc.appending(path: "Contents/MacOS/Basket")
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        #expect(try await UpdateFixtures.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "dev.basket.app", adHoc.path]).status == 0)
        let info = CodeSignature.info(at: adHoc)
        #expect(info.isAdHoc)
        #expect(info.teamID == nil)
        do {
            try CodeSignature.verify(bundle: adHoc, teamID: "ABCDE12345")
            Issue.record("an ad-hoc bundle passed the requirement")
        } catch let error as UpdateError {
            #expect(error.isSecurityFailure)
        }
    }

    @Test func translocationDetection() throws {
        #expect(AppLocation.pathLooksTranslocated("/private/var/folders/xy/abc/T/AppTranslocation/0A1B2C3D/d/Basket.app"))
        #expect(!AppLocation.pathLooksTranslocated("/Applications/Basket.app"))
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let app = try UpdateFixtures.makeApp(in: dir.url, version: "0.0.1")
        #expect(AppLocation.secTranslocateIsTranslocated(app) == false)
        #expect(!AppLocation.isTranslocated(app))
        #expect(AppLocation.problem(with: app) == nil)
        let fake = try UpdateFixtures.makeApp(in: dir.url.appending(path: "AppTranslocation/0A1B/d"), version: "0.0.1")
        #expect(AppLocation.isTranslocated(fake))
        #expect(AppLocation.problem(with: fake)?.contains("Applications") == true)
        #expect(AppLocation.problem(with: dir.url.appending(path: "basket-debug-binary")) != nil)
    }

    @Test func unwritableLocationsCantBeUpdated() throws {
        let dir = try TemporaryDirectory()
        let folder = dir.url.appending(path: "ReadOnly", directoryHint: .isDirectory)
        let app = try UpdateFixtures.makeApp(in: folder, version: "0.0.1")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            dir.cleanup()
        }
        #expect(AppLocation.isReplaceable(app))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        #expect(!AppLocation.isReplaceable(app))
        #expect(AppLocation.problem(with: app)?.contains("write") == true)
    }
}

@Suite("Update installer")
struct UpdateInstallerTests {
    let current = SemanticVersion(0, 0, 1)

    private func installed(in dir: TemporaryDirectory) throws -> URL {
        try UpdateFixtures.makeApp(in: dir.url.appending(path: "Applications"), version: "0.0.1")
    }

    @Test func stagesAVerifiedUpdateNextToTheApp() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let app = try installed(in: dir)
        let release = try await UpdateFixtures.release(in: dir.url)
        let checked = Checked()
        let installer = UpdateFixtures.installer(release) { checked.add($0) }
        let staging = try UpdateInstaller.makeStagingDirectory(for: app)
        defer { try? FileManager.default.removeItem(at: staging) }
        let archive = staging.appending(path: "download.zip")
        try FileManager.default.copyItem(at: release.zip, to: archive)

        let staged = try await installer.stage(archive: archive, offer: release.offer, replacing: app,
                                               currentVersion: current, staging: staging)
        #expect(staged.version == SemanticVersion(0, 0, 2))
        #expect(staged.destination == app)
        #expect(UpdateFixtures.version(of: staged.newApp) == "0.0.2")
        #expect(staged.newApp.path.hasPrefix(staging.path))
        #expect(checked.urls == [staged.newApp])
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        let volume = { (url: URL) in try url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject }
        #expect(try volume(staging) == volume(app.deletingLastPathComponent()))
    }

    @Test func refusesTamperedOrForeignArchives() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let app = try installed(in: dir)
        let release = try await UpdateFixtures.release(in: dir.url)

        func attempt(_ offer: UpdateOffer, installer: UpdateInstaller? = nil, archive: URL? = nil) async -> UpdateError? {
            let staging = dir.url.appending(path: "staging-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let copy = staging.appending(path: "download.zip")
            try? FileManager.default.copyItem(at: archive ?? release.zip, to: copy)
            do {
                _ = try await (installer ?? UpdateFixtures.installer(release)).stage(
                    archive: copy, offer: offer, replacing: app, currentVersion: current, staging: staging)
                return nil
            } catch {
                return error as? UpdateError
            }
        }

        let offer = release.offer
        let wrongSHA = UpdateOffer(version: offer.version, date: offer.date, notes: "", minimumSystemVersion: offer.minimumSystemVersion,
                                   url: offer.url, sha256: String(repeating: "0", count: 64), signature: offer.signature)
        #expect(await attempt(wrongSHA) == .checksumMismatch)

        let otherKey = try await UpdateFixtures.release(in: dir.url.appending(path: "other"), version: "0.0.2")
        #expect(await attempt(release.offer, installer: UpdateFixtures.installer(otherKey)) == .badSignature)

        let codeFails = UpdateFixtures.installer(release) { _ in throw UpdateError.codeSignature("not from this team") }
        #expect(await attempt(release.offer, installer: codeFails) == .codeSignature("not from this team"))
        let codeThrowsOther = UpdateFixtures.installer(release) { _ in throw CocoaError(.fileReadUnknown) }
        #expect(await attempt(release.offer, installer: codeThrowsOther).map(kind) == .codeSignature(""))
    }

    @Test func refusesBundlesThatArentTheAnnouncedVersion() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let app = try installed(in: dir)
        for (bundleVersion, identifier) in [("0.0.3", "dev.basket.app"), ("0.0.1", "dev.basket.app"), ("0.0.2", "dev.example.other")] {
            let sub = dir.url.appending(path: UUID().uuidString)
            let release = try await UpdateFixtures.release(in: sub, version: "0.0.2", bundleVersion: bundleVersion, identifier: identifier)
            let staging = sub.appending(path: "staging")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            await #expect(throws: UpdateError.self) {
                do {
                    _ = try await UpdateFixtures.installer(release).stage(archive: release.zip, offer: release.offer, replacing: app,
                                                                         currentVersion: current, staging: staging)
                } catch let error as UpdateError {
                    #expect(kind(error) == .bundleMismatch(""), "\(bundleVersion) \(identifier): \(error)")
                    throw error
                }
            }
        }
    }

    @Test func refusesArchivesWithoutExactlyOneApp() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let app = try installed(in: dir)
        let content = dir.url.appending(path: "two", directoryHint: .isDirectory)
        try UpdateFixtures.makeApp(in: content, version: "0.0.2")
        try UpdateFixtures.makeApp(in: content, name: "Other.app", version: "0.0.2")
        let zip = dir.url.appending(path: "two.zip")
        try await UpdateFixtures.zip(content, to: zip, keepParent: false)
        let data = try Data(contentsOf: zip)
        let release = try await UpdateFixtures.release(in: dir.url.appending(path: "r"))
        let offer = UpdateOffer(version: SemanticVersion(0, 0, 2), date: Date(), notes: "", minimumSystemVersion: SystemVersion(26),
                                url: zip, sha256: UpdateVerifier.sha256Hex(data), signature: try release.key.signature(for: data))
        let staging = dir.url.appending(path: "staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        await #expect(throws: UpdateError.invalidArchive("it should contain only Basket.app")) {
            _ = try await UpdateFixtures.installer(release).stage(archive: zip, offer: offer, replacing: app,
                                                                 currentVersion: current, staging: staging)
        }
    }

    @Test func refusesDowngradesReinstallsAndNewerSystems() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let app = try installed(in: dir)
        let release = try await UpdateFixtures.release(in: dir.url, version: "0.0.2")
        let installer = UpdateFixtures.installer(release)
        for running in [SemanticVersion(0, 0, 2), SemanticVersion(0, 0, 3), SemanticVersion(1, 0, 0)] {
            await #expect(throws: UpdateError.notNewer(current: running.description, offered: "0.0.2")) {
                _ = try await installer.prepare(release.offer, replacing: app, currentVersion: running) { _ in }
            }
        }
        let needs27 = UpdateOffer(version: release.offer.version, date: Date(), notes: "", minimumSystemVersion: SystemVersion(27),
                                  url: release.offer.url, sha256: release.offer.sha256, signature: release.offer.signature)
        await #expect(throws: UpdateError.requiresNewerSystem("27.0")) {
            _ = try await installer.prepare(needs27, replacing: app, currentVersion: current) { _ in }
        }
    }

    @Test func fetchesDownloadsAndStagesFromAFileFeed() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let app = try installed(in: dir)
        let feedDir = dir.url.appending(path: "feed", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: feedDir, withIntermediateDirectories: true)
        let release = try await UpdateFixtures.release(in: feedDir)
        let manifest = UpdateManifest(
            version: "0.0.2", pubDate: "2026-11-21T10:00:00Z", notes: "- Test", minimumSystemVersion: "26.0",
            url: release.zip.absoluteString, sha256: release.offer.sha256, signature: release.offer.signature.base64EncodedString())
        let feed = feedDir.appending(path: "latest.json")
        try JSONEncoder().encode(manifest).write(to: feed)

        let installer = UpdateFixtures.installer(release, policy: .testFeed(feed))
        let offer = try await installer.fetchOffer()
        #expect(offer.version == SemanticVersion(0, 0, 2))
        #expect(await installer.archiveSize(offer) == Int64(try Data(contentsOf: release.zip).count))

        let events = Checked()
        let staged = try await installer.prepare(offer, replacing: app, currentVersion: current) { event in
            if case .verifying = event { events.add(URL(fileURLWithPath: "/verifying")) }
        }
        defer { try? FileManager.default.removeItem(at: staged.stagingDirectory) }
        #expect(UpdateFixtures.version(of: staged.newApp) == "0.0.2")
        #expect(events.urls.count == 1)

        // The production policy never accepts this feed's file:// archive.
        await #expect(throws: UpdateError.self) {
            _ = try await UpdateFixtures.installer(release, policy: UpdatePolicy(feedURL: feed, downloadPrefixes: [UpdatePolicy.productionDownloadPrefix])).fetchOffer()
        }
    }

    @Test func capsTheDownloadSizeAndHonoursCancellation() async throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        let app = try installed(in: dir)
        let release = try await UpdateFixtures.release(in: dir.url)
        var policy = UpdatePolicy.testFeed(dir.url.appending(path: "latest.json"))
        policy.maxArchiveBytes = 100
        await #expect(throws: UpdateError.self) {
            do {
                _ = try await UpdateFixtures.installer(release, policy: policy).prepare(release.offer, replacing: app, currentVersion: current) { _ in }
            } catch let error as UpdateError {
                #expect(kind(error) == .tooLarge(0))
                throw error
            }
        }
        let task = Task {
            try await UpdateFixtures.installer(release).prepare(release.offer, replacing: app, currentVersion: current) { _ in }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}

@Suite("Update swap")
struct UpdateSwapTests {
    struct Layout {
        let dir: TemporaryDirectory
        let destination: URL
        let staging: URL
        let newApp: URL
        let trash: URL

        init(name: String = "Basket.app", parent: String = "Applications") throws {
            dir = try TemporaryDirectory()
            destination = try UpdateFixtures.makeApp(in: dir.url.appending(path: parent), name: name, version: "0.0.1")
            staging = dir.url.appending(path: "staging", directoryHint: .isDirectory)
            newApp = try UpdateFixtures.makeApp(in: staging.appending(path: "new"), version: "0.0.2")
            trash = dir.url.appending(path: "Trash", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        }

        var staged: StagedUpdate {
            StagedUpdate(version: SemanticVersion(0, 0, 2), previousVersion: SemanticVersion(0, 0, 1),
                         stagingDirectory: staging, newApp: newApp, destination: destination)
        }

        func plan(pid: Int32) -> UpdateSwap.Plan {
            var plan = UpdateSwap.plan(for: staged, pid: pid, relaunch: false)
            plan.trashDirectory = trash
            return plan
        }

        func trashItems() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).sorted()
        }
    }

    /// Runs the helper to completion; returns its exit status and output.
    private func swap(_ plan: UpdateSwap.Plan, in directory: URL? = nil) async throws -> (Int32, String) {
        let arguments = UpdateSwap.arguments(plan)
        let result = try await UpdateFixtures.run(arguments[0], Array(arguments.dropFirst()), in: directory)
        return (result.status, result.output)
    }

    private func exitedPID() async throws -> Int32 {
        try await UpdateFixtures.run("/usr/bin/true", []).pid
    }

    @Test func replacesTheAppAndTrashesTheOldOne() async throws {
        let layout = try Layout()
        defer { layout.dir.cleanup() }
        let (status, output) = try await swap(layout.plan(pid: try await exitedPID()))
        #expect(status == 0, "\(output)")
        #expect(UpdateFixtures.version(of: layout.destination) == "0.0.2")
        #expect(layout.trashItems() == ["Basket 0.0.1.app"])
        #expect(UpdateFixtures.version(of: layout.trash.appending(path: "Basket 0.0.1.app")) == "0.0.1")
        #expect(!FileManager.default.fileExists(atPath: layout.staging.path))
    }

    @Test func waitsForTheAppToQuit() async throws {
        let layout = try Layout()
        defer { layout.dir.cleanup() }
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["1"]
        try sleeper.run()
        let start = Date()
        let (status, output) = try await swap(layout.plan(pid: sleeper.processIdentifier))
        #expect(status == 0, "\(output)")
        #expect(Date().timeIntervalSince(start) > 0.7)
        #expect(UpdateFixtures.version(of: layout.destination) == "0.0.2")
    }

    @Test func rollsBackWhenTheNewAppCantMoveIntoPlace() async throws {
        let layout = try Layout()
        let locked = layout.staging.appending(path: "new")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            layout.dir.cleanup()
        }
        // The new app can't leave its read-only folder, so the second rename fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let (status, output) = try await swap(layout.plan(pid: try await exitedPID()))
        #expect(status == 1)
        #expect(output.contains("restoring the previous version"))
        #expect(UpdateFixtures.version(of: layout.destination) == "0.0.1")
        #expect(!FileManager.default.fileExists(atPath: layout.staged.backup.path))
        #expect(layout.trashItems().isEmpty)
    }

    @Test func leavesTheAppAloneWhenItCantBeMovedAside() async throws {
        let layout = try Layout()
        let parent = layout.destination.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
            layout.dir.cleanup()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        let (status, output) = try await swap(layout.plan(pid: try await exitedPID()))
        #expect(status == 1)
        #expect(output.contains("Basket was not changed"))
        #expect(UpdateFixtures.version(of: layout.destination) == "0.0.1")
        #expect(!FileManager.default.fileExists(atPath: layout.staging.path))
    }

    @Test func keepsEarlierTrashItemsAndClearsQuarantine() async throws {
        let layout = try Layout()
        defer { layout.dir.cleanup() }
        try UpdateFixtures.makeApp(in: layout.trash, name: "Basket 0.0.1.app", version: "0.0.1")
        #expect(try await UpdateFixtures.run("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0081;00000000;Test;", layout.newApp.path]).status == 0)
        let (status, output) = try await swap(layout.plan(pid: try await exitedPID()))
        #expect(status == 0, "\(output)")
        #expect(layout.trashItems() == ["Basket 0.0.1 (2).app", "Basket 0.0.1.app"])
        #expect(try await UpdateFixtures.run("/usr/bin/xattr", ["-p", "com.apple.quarantine", layout.destination.path]).status != 0)
    }

    @Test func pathsWithShellMetacharactersStayLiteral() async throws {
        let layout = try Layout(name: #"Bas"ket $(touch pwned) `touch pwned`.app"#, parent: "Apps; touch pwned; 'q' \\")
        defer { layout.dir.cleanup() }
        let (status, output) = try await swap(layout.plan(pid: try await exitedPID()), in: layout.dir.url)
        #expect(status == 0, "\(output)")
        #expect(UpdateFixtures.version(of: layout.destination) == "0.0.2")
        #expect(layout.trashItems() == [#"Bas"ket $(touch pwned) `touch pwned` 0.0.1.app"#])
        #expect(!FileManager.default.fileExists(atPath: layout.dir.url.appending(path: "pwned").path))
    }
}

/// Collects URLs from a @Sendable callback.
final class Checked: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [URL] = []
    func add(_ url: URL) { lock.withLock { collected.append(url) } }
    var urls: [URL] { lock.withLock { collected } }
}

/// The error's case with payloads blanked, for "which kind of failure" checks.
func kind(_ error: UpdateError) -> UpdateError {
    switch error {
    case .invalidManifest: .invalidManifest("")
    case .network: .network("")
    case .tooLarge: .tooLarge(0)
    case .invalidArchive: .invalidArchive("")
    case .bundleMismatch: .bundleMismatch("")
    case .codeSignature: .codeSignature("")
    case .notNewer: .notNewer(current: "", offered: "")
    case .requiresNewerSystem: .requiresNewerSystem("")
    case .unavailable: .unavailable("")
    case .installFailed: .installFailed("")
    default: error
    }
}
