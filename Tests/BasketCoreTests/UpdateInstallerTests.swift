import Foundation
import Security
import Testing
@testable import BasketCore

@Suite("Update code signature and location")
struct UpdateTrustTests {
    static let developerID = #"anchor apple generic and identifier "dev.basket.app" and certificate leaf[subject.OU] = "ABCDE12345""#
        + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    @Test func requirementNeedsANotarizedDeveloperIDAppOfTheTeam() throws {
        #expect(try CodeSignature.requirement(teamID: "ABCDE12345") == Self.developerID + " and notarized")
        #expect(try CodeSignature.requirementAllowingUnnotarized(teamID: "ABCDE12345") == Self.developerID)
    }

    @Test func requirementsCompile() throws {
        for text in [try CodeSignature.requirement(teamID: "ABCDE12345"),
                     try CodeSignature.requirementAllowingUnnotarized(teamID: "ABCDE12345")] {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, "\(text)")
            #expect(requirement != nil)
        }
    }

    @Test(arguments: ["", "abcde12345", "ABCDE1234", "ABCDE123456", #"ABCDE1234""#, "ABCDE 1234", "ABCDÉ12345"])
    func rejectsMalformedTeams(_ team: String) {
        #expect(throws: UpdateError.self) { try CodeSignature.requirement(teamID: team) }
    }

    @Test(arguments: ["", #"dev.basket.app" or anchor apple"#, "dev basket"])
    func rejectsMalformedIdentifiers(_ identifier: String) {
        #expect(throws: UpdateError.self) { try CodeSignature.requirement(teamID: "ABCDE12345", identifier: identifier) }
    }

    /// Opt-in, against real apps on this Mac (their team and bundle id stand in for Basket's):
    /// `BASKET_TEST_NOTARIZED_APP=<a notarized Developer ID .app>` must pass,
    /// `BASKET_TEST_UNNOTARIZED_APP=<a Developer ID .app that was never notarized>` (e.g.
    /// `scripts/build-app.sh release` with a Developer ID identity) must fail, and pass without
    /// `notarized`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BASKET_TEST_NOTARIZED_APP"] != nil))
    func notarizedDeveloperIDAppsPass() throws {
        let app = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BASKET_TEST_NOTARIZED_APP"]!)
        let info = CodeSignature.info(at: app)
        let team = try #require(info.teamID)
        let identifier = try #require(info.identifier)
        try CodeSignature.verify(bundle: app, requirement: CodeSignature.requirement(teamID: team, identifier: identifier))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BASKET_TEST_UNNOTARIZED_APP"] != nil))
    func unnotarizedDeveloperIDAppsFail() throws {
        let app = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BASKET_TEST_UNNOTARIZED_APP"]!)
        let info = CodeSignature.info(at: app)
        let team = try #require(info.teamID)
        let identifier = try #require(info.identifier)
        do {
            try CodeSignature.verify(bundle: app, requirement: CodeSignature.requirement(teamID: team, identifier: identifier))
            Issue.record("a Developer ID app that isn't notarized passed the update requirement")
        } catch let error as UpdateError {
            #expect(error.isSecurityFailure)
        }
        try CodeSignature.verify(bundle: app, requirement: CodeSignature.requirementAllowingUnnotarized(teamID: team, identifier: identifier))
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
        /// Stands in for /usr/bin/codesign (the fake apps aren't signed): records every call in
        /// `codesign-calls`, fails for a bundle containing `Contents/REJECT`, and plays the swap
        /// race for one containing `Contents/CHANGE-AFTER-CHECK` (passes, then marks it REJECT).
        let codesign: String
        static let requirement = (try? CodeSignature.requirement(teamID: "ABCDE12345")) ?? ""

        init(name: String = "Basket.app", parent: String = "Applications") throws {
            dir = try TemporaryDirectory()
            destination = try UpdateFixtures.makeApp(in: dir.url.appending(path: parent), name: name, version: "0.0.1")
            staging = dir.url.appending(path: "staging", directoryHint: .isDirectory)
            newApp = try UpdateFixtures.makeApp(in: staging.appending(path: "new"), version: "0.0.2")
            trash = dir.url.appending(path: "Trash", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            codesign = try dir.script("fake-codesign", #"""
                calls="$(/usr/bin/dirname "$0")/codesign-calls"
                for arg in "$@"; do printf '%s\n' "$arg"; done >> "$calls"
                printf '%s\n' '@@end-of-call@@' >> "$calls"
                for app; do :; done
                if [ -e "$app/Contents/REJECT" ]; then echo "$app: invalid signature (fake)" >&2; exit 1; fi
                if [ -e "$app/Contents/CHANGE-AFTER-CHECK" ]; then : > "$app/Contents/REJECT"; fi
                exit 0
                """#)
        }

        var staged: StagedUpdate {
            StagedUpdate(version: SemanticVersion(0, 0, 2), previousVersion: SemanticVersion(0, 0, 1),
                         stagingDirectory: staging, newApp: newApp, destination: destination)
        }

        func plan(pid: Int32) -> UpdateSwap.Plan {
            var plan = UpdateSwap.plan(for: staged, requirement: Self.requirement, pid: pid, relaunch: false)
            plan.trashDirectory = trash
            plan.codesign = codesign
            return plan
        }

        func trashItems() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).sorted()
        }

        /// The fake codesign's calls, one argument list each.
        func codesignCalls() -> [[String]] {
            let text = (try? String(contentsOf: dir.url.appending(path: "codesign-calls"), encoding: .utf8)) ?? ""
            return text.split(separator: "@@end-of-call@@\n", omittingEmptySubsequences: true)
                .map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty } }
        }

        func expectedCall(_ app: URL) -> [String] {
            ["--verify", "--deep", "--strict", "-R", "=" + Self.requirement, app.path]
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
        // The code signature is checked again right before the swap and once more in place.
        #expect(layout.codesignCalls() == [layout.expectedCall(layout.newApp), layout.expectedCall(layout.destination)])
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
        #expect(layout.codesignCalls() == [layout.expectedCall(layout.newApp), layout.expectedCall(layout.destination)])
    }

    @Test func refusesAStagedAppThatFailsTheCodeSignatureCheck() async throws {
        let layout = try Layout()
        defer { layout.dir.cleanup() }
        FileManager.default.createFile(atPath: layout.newApp.appending(path: "Contents/REJECT").path, contents: nil)
        let (status, output) = try await swap(layout.plan(pid: try await exitedPID()))
        #expect(status == 1)
        #expect(output.contains("failed the code-signature check; Basket was not changed"), "\(output)")
        #expect(output.contains("invalid signature (fake)"), "codesign's own message goes to the log")
        #expect(UpdateFixtures.version(of: layout.destination) == "0.0.1")
        #expect(layout.trashItems().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: layout.staging.path))
        #expect(layout.codesignCalls() == [layout.expectedCall(layout.newApp)])
    }

    @Test func rollsBackWhenTheAppChangesDuringTheSwap() async throws {
        let layout = try Layout()
        defer { layout.dir.cleanup() }
        // Passes the check before the swap, fails it in place: the old app goes back.
        FileManager.default.createFile(atPath: layout.newApp.appending(path: "Contents/CHANGE-AFTER-CHECK").path, contents: nil)
        let (status, output) = try await swap(layout.plan(pid: try await exitedPID()))
        #expect(status == 1)
        #expect(output.contains("failed the code-signature check in place; restoring the previous version"), "\(output)")
        #expect(UpdateFixtures.version(of: layout.destination) == "0.0.1")
        #expect(!FileManager.default.fileExists(atPath: layout.destination.appending(path: "Contents/REJECT").path))
        #expect(layout.trashItems().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: layout.staging.path))
        #expect(layout.codesignCalls() == [layout.expectedCall(layout.newApp), layout.expectedCall(layout.destination)])
    }

    @Test func refusesToSwapWithoutARequirement() async throws {
        let layout = try Layout()
        defer { layout.dir.cleanup() }
        var plan = layout.plan(pid: try await exitedPID())
        plan.requirement = ""
        #expect(throws: UpdateError.self) { try UpdateSwap.launchDetached(plan, log: nil) }
        let (status, output) = try await swap(plan)
        #expect(status == 1)
        #expect(output.contains("no code requirement"))
        #expect(UpdateFixtures.version(of: layout.destination) == "0.0.1")
        #expect(layout.codesignCalls().isEmpty)
    }

    /// Quitting to install must not stop the helper: it runs in its own session and process group
    /// (no signal to Basket's group or terminal reaches it), and it isn't a `CLIRunner` child, so
    /// the quit cleanup (`CLIRunner.terminateAllChildren`) never signals it.
    @Test func theLaunchedHelperRunsInItsOwnSessionAndOutlivesTheApp() async throws {
        let layout = try Layout()
        defer { layout.dir.cleanup() }
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["30"]
        try app.run()
        defer { if app.isRunning { app.terminate() } }
        let log = layout.dir.url.appending(path: "update.log")
        let helper = try UpdateSwap.launchDetached(layout.plan(pid: app.processIdentifier), log: log)
        #expect(getsid(helper) == helper)
        #expect(getpgid(helper) == helper)
        #expect(getsid(helper) != getsid(0))
        // "Basket" quits; the helper notices, swaps and exits on its own.
        app.terminate()
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(30)
        while waitpid(helper, &status, WNOHANG) == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(UpdateFixtures.version(of: layout.destination) == "0.0.2", "\(output)")
        #expect(output.contains("installed \(layout.destination.path)"), "\(output)")
    }

    @Test func plansRunTheRealCodesign() {
        #expect(UpdateSwap.codesignTool == "/usr/bin/codesign")
        let plan = UpdateSwap.Plan(pid: 1, destination: URL(fileURLWithPath: "/Applications/Basket.app"),
                                   newApp: URL(fileURLWithPath: "/tmp/s/new/Basket.app"), backup: URL(fileURLWithPath: "/tmp/s/previous/Basket.app"),
                                   trashDirectory: nil, trashName: "Basket 0.0.1", stagingDirectory: URL(fileURLWithPath: "/tmp/s"),
                                   relaunch: true, requirement: Layout.requirement)
        #expect(UpdateSwap.arguments(plan).suffix(2) == [Layout.requirement, "/usr/bin/codesign"])
    }

    /// The helper with the real /usr/bin/codesign: an ad-hoc signed bundle satisfies
    /// `identifier "dev.basket.app"` but not the update requirement (no Apple anchor, no team).
    @Test func realCodesignEnforcesTheRequirement() async throws {
        func signedLayout() async throws -> Layout {
            let layout = try Layout()
            let executable = layout.newApp.appending(path: "Contents/MacOS/Basket")
            try FileManager.default.removeItem(at: executable)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
            let signed = try await UpdateFixtures.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "dev.basket.app", layout.newApp.path])
            #expect(signed.status == 0, "\(signed.output)")
            return layout
        }
        let accepted = try await signedLayout()
        defer { accepted.dir.cleanup() }
        var plan = accepted.plan(pid: try await exitedPID())
        plan.codesign = UpdateSwap.codesignTool
        plan.requirement = #"identifier "dev.basket.app""#
        var (status, output) = try await swap(plan)
        #expect(status == 0, "\(output)")
        #expect(UpdateFixtures.version(of: accepted.destination) == "0.0.2")

        let refused = try await signedLayout()
        defer { refused.dir.cleanup() }
        plan = refused.plan(pid: try await exitedPID())
        plan.codesign = UpdateSwap.codesignTool
        (status, output) = try await swap(plan)
        #expect(status == 1)
        #expect(output.contains("failed the code-signature check; Basket was not changed"), "\(output)")
        #expect(UpdateFixtures.version(of: refused.destination) == "0.0.1")
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
