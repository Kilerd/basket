import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import BasketCore

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage(DefaultsKey.containerCLIPath) private var cliPath = ""
    @AppStorage(DefaultsKey.refreshInterval) private var refreshInterval = 2.0
    @AppStorage(DefaultsKey.defaultCPUs) private var defaultCPUs = 1
    @AppStorage(DefaultsKey.defaultMemoryMB) private var defaultMemoryMB = 512
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("container CLI") {
                HStack {
                    TextField("Path", text: $cliPath, prompt: Text("Automatic (/opt/homebrew/bin/container)"))
                        .onSubmit { store.reloadBackend() }
                        .accessibilityIdentifier("settings.cli-path")
                    Button("Choose…") { chooseCLI() }
                        .accessibilityIdentifier("settings.cli-choose")
                }
                Text(cliStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.options.explicitCLIPath != nil {
                    Text("Overridden by BASKET_CONTAINER_CLI for this launch.").font(.caption).foregroundStyle(.orange)
                }
            }
            SetupSettingsSection()
            Section("Refresh") {
                Picker("Update containers every", selection: $refreshInterval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                }
                .onChange(of: refreshInterval) { store.restartPolling() }
                .accessibilityIdentifier("settings.refresh-interval")
                Text("Basket only polls while its window is visible, and 3× slower while you use another app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            MemorySaverSettingsSection()
            Section("New containers") {
                StepperRow(title: "Default CPUs", value: $defaultCPUs, range: 1...16, identifier: "settings.default-cpus")
                Picker("Default memory", selection: $defaultMemoryMB) {
                    ForEach(memoryChoicesMB, id: \.self) { Text(memoryChoiceLabel($0)).tag($0) }
                }
                .accessibilityIdentifier("settings.default-memory")
            }
            Section("General") {
                LanguageSettingsRows()
                Toggle("Launch Basket at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                    .accessibilityIdentifier("settings.launch-at-login")
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.orange)
                }
            }
            UpdateSettingsSection()
        }
        .formStyle(.grouped)
        // Wide enough for German and French labels next to their controls.
        .frame(width: 580)
        // As tall as the content up to a height that fits a 13-inch display; the form scrolls.
        .frame(maxHeight: 760)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { store.reloadBackend() }
    }

    private var cliStatus: String {
        let path = cliPath.trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return String(localized: "Searches /opt/homebrew/bin, /usr/local/bin and your PATH.") }
        return FileManager.default.isExecutableFile(atPath: path)
            ? String(localized: "Found an executable at this path.") : String(localized: "No executable at this path.")
    }

    private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.message = String(localized: "Choose the container executable")
        panel.allowedContentTypes = [.unixExecutable]
        if panel.runModal() == .OK, let url = panel.url {
            cliPath = url.path
            store.reloadBackend()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = String(localized: "Couldn't update the login item: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Off by default: stopping a container is the user's call unless they opt in.
private struct MemorySaverSettingsSection: View {
    @Environment(AppStore.self) private var store
    @AppStorage(DefaultsKey.memorySaverEnabled) private var enabled = false
    @AppStorage(DefaultsKey.memorySaverIdleMinutes) private var idleMinutes = 30

    var body: some View {
        Section("Memory Saver") {
            Toggle("Stop idle containers automatically", isOn: $enabled)
                .accessibilityIdentifier("settings.memory-saver")
            Picker("Stop containers idle for", selection: $idleMinutes) {
                ForEach(memorySaverIdleChoices, id: \.self) { Text(Format.duration(TimeInterval($0 * 60))).tag($0) }
            }
            .disabled(!enabled)
            .accessibilityIdentifier("settings.memory-saver-idle")
            Text("Idle means under 1% CPU and under 1 KB/s of network traffic the whole time. A stopped container returns all its memory to macOS. With the window closed, Basket checks activity once a minute.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(exemptionsText)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var exemptionsText: String {
        let exempt = store.memorySaver.exemptions.sorted()
        guard !exempt.isEmpty else {
            return String(localized: "Never stopped: containers started with --rm (stopping deletes them) and ones you exempt in their context menu or details.")
        }
        return String(localized: "Never stopped: containers started with --rm (stopping deletes them) and ones you exempt in their context menu or details. Exempt now: \(exempt.localizedList).")
    }
}

// MARK: - Language

/// Settings ▸ General ▸ Language: Basket's own language, independent of macOS (`AppleLanguages`
/// in Basket's defaults domain). macOS reads it at launch, so it applies after a relaunch.
private struct LanguageSettingsRows: View {
    @Environment(AppStore.self) private var store
    @State private var selection = AppLanguage.override ?? ""

    var body: some View {
        Picker("Language", selection: $selection) {
            Text("System", comment: "Language picker: use the language macOS uses").tag("")
            ForEach(AppLanguage.available, id: \.self) { id in
                Text(verbatim: AppLanguage.name(of: id)).tag(id)
            }
        }
        .onChange(of: selection) { _, id in AppLanguage.setOverride(id.isEmpty ? nil : id) }
        .accessibilityIdentifier("settings.language")
        if (selection.isEmpty ? nil : selection) != AppLanguage.atLaunch {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Basket uses the new language after it relaunches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Relaunch Now") {
                    // UI tests and self-tests never quit or reopen the app from here.
                    guard !store.options.isUITest else { return }
                    AppRelaunch.relaunch()
                }
                .controlSize(.small)
                .accessibilityIdentifier("settings.language-relaunch")
            }
        }
    }
}

/// The languages Basket ships (`<lang>.lproj` in the bundle, from the String Catalog) and the
/// user's choice among them.
enum AppLanguage {
    private static let key = "AppleLanguages"
    /// Shown in this order; languages added later follow, by identifier.
    private static let preferredOrder = ["en", "zh-Hans", "zh-Hant", "ja", "fr", "de"]

    static var available: [String] {
        let shipped = Set(Bundle.main.localizations.filter { $0 != "Base" })
        let known = preferredOrder.filter(shipped.contains)
        return known + shipped.subtracting(known).sorted()
    }

    /// Each language's name in that language: "English", "简体中文", "Français".
    static func name(of id: String) -> String {
        let locale = Locale(identifier: id)
        let name = locale.localizedString(forIdentifier: id) ?? id
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// The language chosen in Settings, nil = follow macOS. Read from Basket's own defaults domain:
    /// the merged `AppleLanguages` also holds the macOS list and `-AppleLanguages` launch arguments.
    static var override: String? {
        guard let domain = Bundle.main.bundleIdentifier,
              let list = UserDefaults.standard.persistentDomain(forName: domain)?[key] as? [String],
              let first = list.first else { return nil }
        return Bundle.preferredLocalizations(from: available, forPreferences: [first]).first ?? first
    }

    static func setOverride(_ id: String?) {
        if let id { UserDefaults.standard.set([id], forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// The override this process started with: the one in effect until Basket relaunches.
    @MainActor static let atLaunch: String? = override
}

/// Quits Basket the normal way (it may ask about work in progress) and opens it again.
@MainActor
enum AppRelaunch {
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundle = Bundle.main.bundleURL.path
        // The helper starts only once quitting is certain (willTerminate); it waits for this process
        // to exit, then opens the same bundle.
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            spawnHelper(pid: pid, bundle: bundle)
        }
        NSApp.terminate(nil)
        // `terminate` returns only when quitting was cancelled ("Basket is still working" ▸ Cancel).
        NotificationCenter.default.removeObserver(observer)
    }

    /// `/bin/sh` in its own session, so it outlives Basket.
    nonisolated private static func spawnHelper(pid: Int32, bundle: String) {
        let script = #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open "$2""#
        let argv = ["/bin/sh", "-c", script, "basket-relaunch", String(pid), bundle]
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        let pointers = argv.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        var child: pid_t = 0
        let environment = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), nil]
        defer { environment.forEach { free($0) } }
        let status = pointers.withUnsafeBufferPointer { args in
            environment.withUnsafeBufferPointer { env in
                posix_spawn(&child, "/bin/sh", &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        if status != 0 { NSLog("Basket: couldn't start the relaunch helper: \(String(cString: strerror(status)))") }
    }
}
