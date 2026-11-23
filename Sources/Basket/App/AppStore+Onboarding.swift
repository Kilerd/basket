import AppKit
import Observation
import UniformTypeIdentifiers
import BasketCore

extension DefaultsKey {
    /// `OnboardingPolicy.currentVersion` once the user finished or closed "Set Up Basket".
    static let onboardingCompletedVersion = "onboardingCompletedVersion"
}

/// Scene id of the "Set Up Basket" window.
enum OnboardingWindow {
    static let id = "onboarding"
    /// Window size including the (hidden) title bar; fixed, the window isn't resizable.
    static let size = CGSize(width: 780, height: 600)
}

enum OnboardingStep: String, CaseIterable, Identifiable, Sendable {
    case welcome, install, system, orbstack, docker, done

    var id: String { rawValue }

    /// Position in the full flow (hidden steps included).
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Title in the step list.
    var listTitle: String {
        switch self {
        case .welcome: String(localized: "Welcome", comment: "Setup step list")
        case .install: String(localized: "Install container", comment: "Setup step list; `container` is the CLI's name")
        case .system: String(localized: "Start container", comment: "Setup step list; `container` is the CLI's name")
        case .orbstack: String(localized: "From OrbStack", comment: "Setup step list")
        case .docker: String(localized: "docker Command", comment: "Setup step list; `docker` is the command's name")
        case .done: String(localized: "Ready", comment: "Setup step list: the last step")
        }
    }
}

/// A long-running step action (brew install, system start, docker command changes).
enum OnboardingPhase: Equatable {
    case idle, running
    case failed(String)

    var isRunning: Bool { self == .running }
    var failure: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// One file the docker command would change and the exact text it adds.
struct PlannedShellChange: Identifiable, Hashable, Sendable {
    var file: String
    var contents: String
    var id: String { file }
}

// MARK: - docker command access

/// `DockerShimInstaller` for the user's home, or a simulation. Fixture and preview runs always get
/// the simulation, so they never read or change the real home directory's shell files; with the
/// real backend, `install()`/`uninstall()` only ever run from a user's click.
protocol DockerShimControl: Sendable {
    /// Home directory the paths below live in (shown as `~`).
    var home: String { get }
    func status() -> DockerShimStatus
    func plannedChanges() -> [PlannedShellChange]
    func install() throws
    func uninstall() throws
}

struct LiveDockerShim: DockerShimControl {
    let installer: DockerShimInstaller

    init() {
        installer = DockerShimInstaller(
            home: FileManager.default.homeDirectoryForCurrentUser,
            shimSource: Bundle.main.bundleURL.appending(path: "Contents/Helpers/basket-docker"))
    }

    var home: String { installer.home.path }
    func status() -> DockerShimStatus { installer.status() }
    func plannedChanges() -> [PlannedShellChange] {
        installer.plannedChanges().map { PlannedShellChange(file: $0.file, contents: $0.contents) }
    }
    func install() throws { try installer.install() }
    func uninstall() throws { try installer.uninstall() }
}

/// Fixture runs: the status comes from `docker-shim.json` in the fixture set (fixture-only file:
/// `{"shell", "currentDocker", "currentDockerIsOrbStack", "isInstalled"}`), the planned text from a
/// `DockerShimInstaller` for `/Users/demo` (only `plannedChanges()` is called on it), and
/// Enable/Disable flip an in-memory flag.
final class SimulatedDockerShim: DockerShimControl, @unchecked Sendable {
    private struct Fixture: Decodable {
        var shell: String?
        var currentDocker: String?
        var currentDockerIsOrbStack: Bool?
        var isInstalled: Bool?
    }

    let home = "/Users/demo"
    private let fixture: Fixture
    private let lock = NSLock()
    private var installed: Bool

    init(fixturesDirectory: URL?) {
        let data = fixturesDirectory.flatMap { try? Data(contentsOf: $0.appending(path: "docker-shim.json")) }
        fixture = data.flatMap { try? JSONDecoder().decode(Fixture.self, from: $0) } ?? Fixture()
        installed = fixture.isInstalled ?? false
    }

    private var planner: DockerShimInstaller { DockerShimInstaller(home: URL(fileURLWithPath: home, isDirectory: true)) }

    func status() -> DockerShimStatus {
        let isInstalled = lock.withLock { installed }
        let shell = fixture.shell ?? "zsh"
        let rcFile = home + (shell == "bash" ? "/.bash_profile" : shell == "fish" ? "/.config/fish/config.fish" : "/.zshrc")
        return DockerShimStatus(
            isInstalled: isInstalled, binPath: home + "/.basket/bin/docker", rcFiles: isInstalled ? [rcFile] : [],
            shell: shell, currentDocker: fixture.currentDocker,
            currentDockerIsOrbStack: fixture.currentDockerIsOrbStack ?? false)
    }

    func plannedChanges() -> [PlannedShellChange] {
        planner.plannedChanges().map { PlannedShellChange(file: $0.file, contents: $0.contents) }
    }

    func install() throws { lock.withLock { installed = true } }
    func uninstall() throws { lock.withLock { installed = false } }
}

// MARK: - Model

/// State and actions of "Set Up Basket" (see `OnboardingView`). One per app, reached through
/// `AppStore.onboarding`.
@Observable @MainActor
final class OnboardingModel {
    @ObservationIgnored private(set) weak var store: AppStore?
    @ObservationIgnored let docker: any DockerShimControl
    let requirements: SetupRequirements
    /// Decided once at launch (see `OnboardingPolicy`): the onboarding window opens instead of the main one.
    let showsAtLaunch: Bool

    var step = OnboardingStep.welcome
    var cli: ContainerCLIInfo?
    var isCheckingCLI = false
    var brewPath: URL?
    var installPhase = OnboardingPhase.idle
    var installLog: [String] = []
    var systemStatus: SystemStatus?
    var isCheckingSystem = false
    var startPhase = OnboardingPhase.idle
    var startLog: [String] = []
    var orbStack: OrbStackSnapshot?
    var dockerStatus: DockerShimStatus?
    var dockerPlan: [PlannedShellChange] = []
    var dockerPhase = OnboardingPhase.idle

    @ObservationIgnored weak var window: NSWindow?
    /// "Open Basket" as wired by the window (it owns `openWindow`); the self-test calls it.
    @ObservationIgnored var finishAction: (() -> Void)?
    @ObservationIgnored var selfTestStarted = false
    /// `OnboardingLaunchPresenter` ran (once per process).
    @ObservationIgnored var launchPresentationChecked = false
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?

    /// The model of the running app (the store is a singleton too).
    static var current: OnboardingModel?

    static let releasesURL = URL(string: "https://github.com/apple/container/releases/latest")!
    static let dockerDocsURL = URL(string: "https://github.com/Kilerd/basket/blob/main/docs/docker-shim.md")!

    init(store: AppStore, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.store = store
        let options = store.options
        // Fixture and preview runs simulate the docker command; a real-backend run reads the real
        // state (status and planned text only — install/uninstall need a user's click).
        let simulated = options.backend != .cli
        docker = simulated ? SimulatedDockerShim(fixturesDirectory: options.fixturesDirectory) : LiveDockerShim()
        requirements = .current()
        let forced = environment["BASKET_ONBOARDING"] == "1"
        showsAtLaunch = OnboardingPolicy.shouldShowAtLaunch(
            completedVersion: UserDefaults.standard.integer(forKey: DefaultsKey.onboardingCompletedVersion),
            cliInstalled: Self.cliInstalledAtLaunch(options), isUITest: options.isUITest, forced: forced)
        if simulated || options.isUITest {
            // UI tests are host-independent: Homebrew "exists" only when asked for.
            brewPath = environment["BASKET_FAKE_BREW"] == "1" ? URL(fileURLWithPath: HomebrewLocator.candidates[0]) : nil
        } else {
            brewPath = HomebrewLocator.locate()
        }
        if !simulated, !options.isUITest { refreshInstalledShim() }
    }

    private var options: LaunchOptions? { store?.options }
    /// Fixture or preview backend: installs, starts and the docker command are simulated. The
    /// self-test only presses those buttons in such runs.
    var isSimulated: Bool { options?.backend != .cli }

    /// Cheap synchronous check (a few `stat`s) used to decide whether to open onboarding at launch.
    private static func cliInstalledAtLaunch(_ options: LaunchOptions) -> Bool {
        switch options.backend {
        case .fixtures(let directory):
            !FileManager.default.fileExists(atPath: directory.appending(path: FixtureBackend.cliMissingMarker).path)
        case .preview:
            true
        case .cli:
            (try? CLIRunner.locateContainerCLI(
                explicitPath: options.explicitCLIPath,
                userDefaultsPath: UserDefaults.standard.string(forKey: DefaultsKey.containerCLIPath))) != nil
        }
    }

    /// An app update ships a new shim: keep an enabled docker command current. Live runs only.
    private func refreshInstalledShim() {
        let docker = self.docker
        Task.detached(priority: .utility) {
            guard docker.status().isInstalled else { return }
            try? (docker as? LiveDockerShim)?.installer.refreshShimIfNeeded()
        }
    }

    // MARK: Steps

    /// OrbStack is installed, as the sidebar sees it: known at launch, then updated by every
    /// OrbStack read (the sidebar's and this window's own).
    var orbStackInstalled: Bool { store?.orbStackInstalled ?? false }

    /// OrbStack's step only exists when OrbStack is installed; the list is numbered from these.
    var visibleSteps: [OnboardingStep] {
        OnboardingStep.allCases.filter { $0 != .orbstack || orbStackInstalled }
    }

    func isSatisfied(_ step: OnboardingStep) -> Bool {
        switch step {
        case .welcome: requirements.isSatisfied
        case .install: cli != nil
        case .system: systemStatus?.isRunning == true
        case .orbstack, .done: true
        case .docker: dockerStatus?.isInstalled == true
        }
    }

    /// Called when the window opens (also when re-run from the menu or Settings).
    func begin() {
        step = .welcome
        installLog = []
        startLog = []
        installPhase = .idle
        startPhase = .idle
        dockerPhase = .idle
        Task {
            async let cli: Void = checkCLI()
            async let orb: Void = loadOrbStack()
            async let docker: Void = loadDocker()
            _ = await (cli, orb, docker)
            await checkSystem()
        }
    }

    /// The next visible step, also from a step that has just been hidden (OrbStack removed).
    func next() {
        guard let target = visibleSteps.first(where: { $0.order > step.order }) else { return }
        go(to: target)
    }

    func back() {
        guard let target = visibleSteps.last(where: { $0.order < step.order }) else { return }
        go(to: target)
    }

    func go(to target: OnboardingStep) {
        step = target
        switch target {
        case .install: if cli == nil { Task { await checkCLI() } }
        case .system: Task { await checkSystem() }
        case .docker: Task { await loadDocker() }
        default: break
        }
    }

    // MARK: Install container

    func checkCLI() async {
        guard let store else { return }
        isCheckingCLI = true
        defer { isCheckingCLI = false }
        let found: ContainerCLIInfo?
        switch store.options.backend {
        case .fixtures:
            if let fixture = store.backend as? FixtureBackend, await fixture.isCLIInstalled {
                let version = (try? await fixture.systemStatus())?.cliVersion
                found = ContainerCLIInfo(path: "/opt/homebrew/bin/container", version: version)
            } else {
                found = nil
            }
        case .preview:
            found = ContainerCLIInfo(path: "/opt/homebrew/bin/container", version: "1.7.1")
        case .cli:
            found = await ContainerCLIProbe.detect(
                explicitPath: store.options.explicitCLIPath,
                userDefaultsPath: UserDefaults.standard.string(forKey: DefaultsKey.containerCLIPath))
        }
        let appeared = cli == nil && found != nil
        cli = found
        if appeared { await store.refreshAll() }
    }

    func installWithHomebrew() {
        guard let brew = brewPath, !installPhase.isRunning else { return }
        installPhase = .running
        installLog = ["$ brew install container"]
        installTask = Task {
            do {
                for try await line in homebrewLines(brew) {
                    installLog.append(line)
                    if installLog.count > 2_000 { installLog.removeFirst(installLog.count - 2_000) }
                }
                if Task.isCancelled {
                    installLog.append(String(localized: "Cancelled.", comment: "Last line of an install or start log"))
                    installPhase = .idle
                    return
                }
                await checkCLI()
                installPhase = cli == nil
                    ? .failed(String(localized: "Homebrew finished, but Basket still can't find container. Click Check Again, or choose where it is."))
                    : .idle
            } catch {
                installPhase = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    func cancelInstall() {
        installTask?.cancel()
        installTask = nil
    }

    private func homebrewLines(_ brew: URL) -> AsyncThrowingStream<String, Error> {
        guard isSimulated else {
            let runner = CLIRunner(executableURL: brew, environment: HomebrewLocator.environment())
            return runner.lines(HomebrewLocator.installArguments)
        }
        // Fixture runs: a synthetic transcript in Homebrew's shape, then the fixture's CLI "appears".
        let fixture = store?.backend as? FixtureBackend
        let lines = [
            "==> Fetching downloads for: container",
            "==> Downloading https://ghcr.io/v2/homebrew/core/container/manifests/1.7.1",
            "==> Pouring container--1.7.1.arm64_tahoe.bottle.tar.gz",
            "==> Caveats",
            "When starting container with `brew services`, no kernel is installed automatically.",
            "==> Summary",
            "/opt/homebrew/Cellar/container/1.7.1: 37 files, 61.2MB",
        ]
        return AsyncThrowingStream { continuation in
            let task = Task {
                for line in lines {
                    try? await Task.sleep(for: .milliseconds(60))
                    if Task.isCancelled { break }
                    continuation.yield(line)
                }
                if !Task.isCancelled { await fixture?.simulateCLIInstall() }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(Self.releasesURL)
    }

    /// "I Installed It Elsewhere…": the chosen binary becomes Settings' `containerCLIPath`.
    func chooseCLI() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        panel.message = String(localized: "Choose the container executable")
        panel.prompt = String(localized: "Use This", comment: "Open panel button: use the chosen container executable")
        panel.allowedContentTypes = [.unixExecutable]
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            UserDefaults.standard.set(url.path, forKey: DefaultsKey.containerCLIPath)
            self.store?.reloadBackend()
            Task { await self.checkCLI() }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    // MARK: Start the system

    func checkSystem() async {
        guard let store, cli != nil else {
            systemStatus = nil
            return
        }
        isCheckingSystem = true
        defer { isCheckingSystem = false }
        systemStatus = try? await store.backend.systemStatus()
    }

    func startSystem() {
        guard let store, !startPhase.isRunning, cli != nil else { return }
        startPhase = .running
        startLog = ["$ container system start --enable-kernel-install"]
        let backend = store.backend
        let cliPath = cli?.path
        startTask = Task {
            do {
                if case .cli = store.options.backend, let cliPath {
                    let runner = CLIRunner(executableURL: URL(fileURLWithPath: cliPath))
                    for try await line in runner.lines(["system", "start", "--enable-kernel-install"]) {
                        startLog.append(line)
                        if startLog.count > 2_000 { startLog.removeFirst(startLog.count - 2_000) }
                    }
                } else {
                    try await backend.startSystem()
                    startLog.append("Verifying apiserver is running...")
                }
                if Task.isCancelled {
                    startLog.append(String(localized: "Cancelled.", comment: "Last line of an install or start log"))
                    startPhase = .idle
                    return
                }
                await checkSystem()
                startPhase = systemStatus?.isRunning == true
                    ? .idle : .failed(String(localized: "The container system didn't report itself as running."))
                await store.refreshAll()
            } catch {
                startPhase = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    func cancelStart() {
        startTask?.cancel()
        startTask = nil
    }

    // MARK: OrbStack

    func loadOrbStack() async {
        guard let store else { return }
        let snapshot = await store.options.makeOrbStackInspector().snapshot()
        orbStack = snapshot
        store.orbStackDetected(snapshot.isInstalled)
    }

    /// Basket's side of the comparison: what its container VMs cost right now.
    var basketMemoryBytes: Int64 { store?.totalHostMemory ?? 0 }
    var basketDiskBytes: Int64 { store?.diskUsage?.totalBytes ?? 0 }

    // MARK: docker command

    func loadDocker() async {
        let docker = self.docker
        let (status, plan) = await Task.detached { (docker.status(), docker.plannedChanges()) }.value
        dockerStatus = status
        dockerPlan = plan
    }

    func setDockerCommand(enabled: Bool) {
        guard !dockerPhase.isRunning else { return }
        dockerPhase = .running
        let docker = self.docker
        Task {
            let result = await Task.detached { () -> Result<Void, Error> in
                Result { enabled ? try docker.install() : try docker.uninstall() }
            }.value
            await loadDocker()
            switch result {
            case .success: dockerPhase = .idle
            case .failure(let error):
                let reason = error.localizedDescription
                dockerPhase = .failed(enabled
                    ? String(localized: "Couldn't add the docker command: \(reason)")
                    : String(localized: "Couldn't remove the docker command: \(reason)"))
            }
        }
    }

    /// `/Users/demo/.zshrc` → `~/.zshrc`.
    func displayPath(_ path: String) -> String {
        let home = docker.home
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: Finishing

    /// Remembers that this version of the flow was seen (not in UI-test runs).
    func markCompleted() {
        guard options?.isUITest == false else { return }
        UserDefaults.standard.set(OnboardingPolicy.currentVersion, forKey: DefaultsKey.onboardingCompletedVersion)
    }

    /// The window is going away (Open Basket, Migrate…, or its close button).
    func windowClosed() {
        cancelInstall()
        cancelStart()
        markCompleted()
    }
}

extension AppStore {
    /// "Set Up Basket" state; created on first use.
    var onboarding: OnboardingModel {
        if let model = OnboardingModel.current, model.store === self { return model }
        let model = OnboardingModel(store: self)
        OnboardingModel.current = model
        return model
    }

    /// The onboarding window appeared: identify it for the AX contract and, in an onboarding
    /// self-test (`BASKET_SELFTEST_DIR` + `BASKET_ONBOARDING=1`), start capturing its steps.
    func attachOnboarding(window: NSWindow) {
        let model = onboarding
        guard model.window !== window else { return }
        model.window = window
        window.setAccessibilityIdentifier("onboarding.window")
        if options.isUITest { window.animationBehavior = .none }
        if let directory = options.selfTestDirectory, !model.selfTestStarted,
           ProcessInfo.processInfo.environment["BASKET_ONBOARDING"] == "1" {
            model.selfTestStarted = true
            Task { await SelfTestRunner(store: self, directory: directory).runOnboarding() }
        }
    }
}
