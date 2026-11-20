import AppKit
import Observation
import OSLog
import BasketCore

extension DefaultsKey {
    static let updatesAutomaticCheck = "updatesAutomaticCheck"
    static let updatesSkippedVersion = "updatesSkippedVersion"
    static let updatesLastCheck = "updatesLastCheck"
}

/// What the update sheet shows.
enum UpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case available
    case downloading(received: Int64, expected: Int64?)
    case verifying
    /// The swap helper runs; Basket is quitting.
    case relaunching
    case failed(UpdateFailure)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .verifying, .relaunching: true
        default: false
        }
    }
}

struct UpdateFailure: Equatable {
    enum Retry: Equatable { case check, install }

    var title: String
    var message: String
    /// The download isn't what the maintainer published: deleted, never installable.
    var isSecurity = false
    /// nil: no "Try Again" (security failures, a too-old macOS, an unsupported copy).
    var retry: Retry?
}

/// The update source and key: production, or (DEBUG builds only) a local test feed and key.
struct UpdateSetup {
    var policy = UpdatePolicy.production
    var publicKeyBase64 = UpdateVerifier.publicKeyBase64
    /// DEBUG `BASKET_UPDATE_AUTO_INSTALL=1` with a test feed: check at launch and press Install.
    var autoInstall = false

    static func fromProcess(_ env: [String: String] = ProcessInfo.processInfo.environment) -> UpdateSetup {
        var setup = UpdateSetup()
        #if DEBUG
        if let feed = env["BASKET_UPDATE_FEED_URL"].flatMap(URL.init(string:)), feed.scheme == "file" || feed.scheme == "https" {
            setup.policy = .testFeed(feed)
            setup.autoInstall = env["BASKET_UPDATE_AUTO_INSTALL"] == "1"
        }
        if let key = env["BASKET_UPDATE_TEST_PUBLIC_KEY"], !key.isEmpty {
            setup.publicKeyBase64 = key
        }
        #endif
        return setup
    }
}

/// Checks GitHub Releases for a newer Basket and installs it (docs/updates.md): at launch after a
/// minute and then daily when "Automatically check for updates" is on, or from "Check for
/// Updates…". Disabled with an explanation for copies that can't update themselves.
@Observable @MainActor
final class UpdateController {
    let currentVersion: SemanticVersion?
    /// Why this copy can't update itself (ad-hoc signed, translocated, not writable…); nil when it can.
    let unavailableReason: String?
    private(set) var phase: UpdatePhase = .idle
    /// The newer release found by the last check (cleared when skipped or found to be unsafe).
    private(set) var offer: UpdateOffer?
    private(set) var offerSize: Int64?
    private(set) var lastChecked: Date?
    private(set) var skippedVersion: String?
    var automaticallyChecks: Bool {
        didSet {
            defaults?.set(automaticallyChecks, forKey: DefaultsKey.updatesAutomaticCheck)
            start()
        }
    }

    @ObservationIgnored weak var store: AppStore?
    @ObservationIgnored private let installer: UpdateInstaller?
    @ObservationIgnored private let setup: UpdateSetup
    @ObservationIgnored private let isUITest: Bool
    /// nil in UI-test runs: nothing is read from or written to the user's defaults.
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    /// The sheet waits for another sheet to close.
    @ObservationIgnored private var presentWhenFree = false
    @ObservationIgnored private let logger = Logger(subsystem: UpdatePolicy.bundleIdentifier, category: "updates")

    static let launchDelay: Duration = .seconds(60)
    static let checkInterval: TimeInterval = 24 * 3600

    init(isUITest: Bool, setup: UpdateSetup = .fromProcess(), bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.isUITest = isUITest
        self.setup = setup
        self.defaults = isUITest ? nil : defaults
        defaults.register(defaults: [DefaultsKey.updatesAutomaticCheck: true])
        automaticallyChecks = isUITest ? true : defaults.bool(forKey: DefaultsKey.updatesAutomaticCheck)
        skippedVersion = self.defaults?.string(forKey: DefaultsKey.updatesSkippedVersion)
        lastChecked = self.defaults?.object(forKey: DefaultsKey.updatesLastCheck) as? Date

        let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init)
        currentVersion = version
        var reason: String?
        var team: String?
        if bundle.bundleURL.pathExtension != "app" || bundle.bundleIdentifier != UpdatePolicy.bundleIdentifier || version == nil {
            reason = AppLocation.problem(with: bundle.bundleURL)
                ?? "This build of Basket has no release version, so it can't update itself."
        } else {
            do {
                team = try CodeSignature.runningApp().updateTeam()
                reason = AppLocation.problem(with: bundle.bundleURL)
            } catch {
                reason = error.localizedDescription
            }
        }
        var installer: UpdateInstaller?
        if reason == nil, let team {
            do {
                let verifier = try UpdateVerifier(publicKeyBase64: setup.publicKeyBase64)
                installer = UpdateInstaller(policy: setup.policy, verifier: verifier) { app in
                    try CodeSignature.verify(bundle: app, teamID: team)
                }
            } catch {
                reason = error.localizedDescription
            }
        }
        self.installer = installer
        unavailableReason = reason
    }

    var isBusy: Bool { phase.isBusy }
    var isAvailable: Bool { unavailableReason == nil }
    var currentVersionText: String { currentVersion?.description ?? "development build" }

    // MARK: Scheduling

    /// (Re)starts the launch + daily schedule; never in UI-test runs.
    func start() {
        schedule?.cancel()
        schedule = nil
        #if DEBUG
        if setup.autoInstall, installer != nil {
            schedule = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.autoInstallForTesting()
            }
            return
        }
        #endif
        guard !isUITest, installer != nil, automaticallyChecks else { return }
        schedule = Task { [weak self] in
            try? await Task.sleep(for: Self.launchDelay)
            var first = true
            while !Task.isCancelled {
                await self?.automaticCheck(force: first)
                first = false
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private func automaticCheck(force: Bool) async {
        guard automaticallyChecks, work == nil, !phase.isBusy else { return }
        if !force, let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkInterval { return }
        await check(userInitiated: false)
    }

    #if DEBUG
    private func autoInstallForTesting() async {
        logger.notice("BASKET_UPDATE_AUTO_INSTALL: checking \(self.setup.policy.feedURL.absoluteString, privacy: .public)")
        phase = .checking
        present()
        await check(userInitiated: true)
        guard phase == .available else {
            logger.error("BASKET_UPDATE_AUTO_INSTALL: no installable update (\(String(describing: self.phase), privacy: .public))")
            return
        }
        try? await Task.sleep(for: .seconds(2))
        install()
    }
    #endif

    // MARK: Actions

    /// "Check for Updates…": shows the sheet right away (checking → result).
    func checkForUpdates() {
        guard !phase.isBusy else { return present() }
        guard isAvailable else {
            phase = .idle
            return present()
        }
        phase = .checking
        present()
        work = Task { [weak self] in
            await self?.check(userInitiated: true)
            self?.work = nil
        }
    }

    private func check(userInitiated: Bool) async {
        guard let installer, let currentVersion else { return }
        do {
            let offer = try await installer.fetchOffer()
            lastChecked = Date()
            defaults?.set(lastChecked, forKey: DefaultsKey.updatesLastCheck)
            switch offer.eligibility(current: currentVersion, system: .current) {
            case .upToDate:
                self.offer = nil
                phase = userInitiated ? .upToDate : .idle
            case .requiresNewerSystem(let system):
                self.offer = nil
                phase = userInitiated
                    ? .failed(UpdateFailure(title: "Basket \(offer.version) needs macOS \(system)",
                                            message: "This Mac runs macOS \(SystemVersion.current). Basket \(currentVersion) stays installed."))
                    : .idle
            case .available:
                if !userInitiated, skippedVersion == offer.version.description {
                    phase = .idle
                    return
                }
                self.offer = offer
                offerSize = nil
                phase = .available
                Task { [weak self] in
                    let size = await installer.archiveSize(offer)
                    if self?.offer == offer { self?.offerSize = size }
                }
                if !userInitiated { presentIfConvenient() }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("update check failed: \(error.localizedDescription, privacy: .public)")
            // A failed automatic check stays quiet and keeps what is already known.
            if userInitiated { phase = .failed(failure(error, retry: .check)) }
        }
    }

    /// "Install and Relaunch": download → verify → stage → helper → quit.
    func install() {
        guard let offer, let installer, let currentVersion, work == nil else { return }
        if let busy = busyWork() { return phase = .failed(busy) }
        phase = .downloading(received: 0, expected: offerSize)
        let destination = Bundle.main.bundleURL
        work = Task { [weak self] in
            do {
                let staged = try await installer.prepare(offer, replacing: destination, currentVersion: currentVersion) { progress in
                    Task { @MainActor in self?.apply(progress) }
                }
                guard let self else { return }
                if let busy = self.busyWork() {
                    try? FileManager.default.removeItem(at: staged.stagingDirectory)
                    self.phase = .failed(busy)
                    self.work = nil
                    return
                }
                self.phase = .relaunching
                do {
                    try UpdateSwap.launchDetached(UpdateSwap.plan(for: staged), log: Self.logFile())
                } catch {
                    try? FileManager.default.removeItem(at: staged.stagingDirectory)
                    throw error
                }
                self.logger.notice("installing Basket \(offer.version.description, privacy: .public); quitting")
                // Let the sheet show "Relaunching…" for a moment.
                try? await Task.sleep(for: .milliseconds(300))
                NSApp.terminate(nil)
            } catch is CancellationError {
                self?.phase = .available
                self?.work = nil
            } catch {
                guard let self else { return }
                self.logger.error("update install failed: \(error.localizedDescription, privacy: .public)")
                if (error as? UpdateError)?.isSecurityFailure == true { self.offer = nil }
                self.phase = .failed(self.failure(error, retry: .install))
                self.work = nil
            }
        }
    }

    /// Menu bar ▸ "Update to Basket X…": the known offer, without checking again.
    func showAvailableUpdate() {
        if offer != nil, !phase.isBusy { phase = .available }
        present()
    }

    func cancel() {
        work?.cancel()
        if phase == .checking {
            work = nil
            phase = .idle
            store?.activeSheet = nil
        }
    }

    /// "Later" / "OK" / "Close": the offer stays (menu bar, Settings) until the next check.
    func dismiss() {
        if phase.isBusy { work?.cancel() }
        work = nil
        phase = offer == nil ? .idle : .available
        if case .update? = store?.activeSheet { store?.activeSheet = nil }
    }

    func skipThisVersion() {
        guard let offer else { return dismiss() }
        skippedVersion = offer.version.description
        defaults?.set(skippedVersion, forKey: DefaultsKey.updatesSkippedVersion)
        self.offer = nil
        dismiss()
    }

    func retry(_ retry: UpdateFailure.Retry) {
        switch retry {
        case .check: checkForUpdates()
        case .install:
            phase = .available
            install()
        }
    }

    // MARK: Presentation

    /// Shows the sheet on the main window (callers open it first), or once another sheet closes.
    func present() {
        guard let store else { return }
        if case .update? = store.activeSheet { return }
        if store.activeSheet == nil {
            store.activeSheet = .update
        } else {
            presentWhenFree = true
        }
    }

    /// Automatic checks only interrupt when the window is up and no other sheet is open; otherwise
    /// the menu bar extra and Settings show the update.
    private func presentIfConvenient() {
        guard let store, store.activeSheet == nil, store.confirmation == nil,
              store.mainWindow?.isVisible == true else { return }
        store.activeSheet = .update
    }

    /// Called when the store's sheet closes.
    func sheetClosed() {
        guard presentWhenFree else { return }
        presentWhenFree = false
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.present()
        }
    }

    // MARK: Helpers

    private func apply(_ progress: UpdateInstaller.Progress) {
        switch (progress, phase) {
        case (.downloading(let received, let expected), .downloading):
            phase = .downloading(received: received, expected: expected ?? offerSize)
        case (.verifying, .downloading):
            phase = .verifying
        default:
            break
        }
    }

    private func busyWork() -> UpdateFailure? {
        let work = store?.longRunningWork ?? []
        guard !work.isEmpty else { return nil }
        return UpdateFailure(
            title: "Basket is still working",
            message: work.joined(separator: "\n") + "\n\nInstalling quits Basket, which would stop this. Finish or cancel it, then install the update.",
            retry: .install)
    }

    func failure(_ error: Error, retry: UpdateFailure.Retry) -> UpdateFailure {
        let updateError = error as? UpdateError
        if let updateError, updateError.isSecurityFailure {
            return UpdateFailure(
                title: "The update failed a security check",
                message: updateError.localizedDescription + " Basket was not changed. Please report this (see SECURITY.md in the Basket repository).",
                isSecurity: true)
        }
        let title = retry == .check ? "Couldn't check for updates" : "Couldn't install the update"
        switch updateError {
        case .requiresNewerSystem?, .notNewer?, .unavailable?, .invalidPublicKey?:
            return UpdateFailure(title: title, message: error.localizedDescription)
        default:
            return UpdateFailure(title: title, message: error.localizedDescription, retry: retry)
        }
    }

    /// `~/Library/Logs/Basket/update.log`: the swap helper's output (it runs after Basket quit).
    static func logFile() -> URL? {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let directory = library.appending(path: "Logs/Basket", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "update.log")
    }

    /// Self-test extras: puts the sheet into a given state without any network access.
    func showForSelfTest(_ phase: UpdatePhase, offer: UpdateOffer?, size: Int64?) {
        work?.cancel()
        work = nil
        self.offer = offer
        offerSize = size
        self.phase = phase
    }
}
