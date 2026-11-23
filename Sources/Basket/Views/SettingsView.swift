import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import BasketCore

/// The Settings section of the main window (sidebar ▸ Settings, ⌘,): one grouped form, General
/// with the language and the appearance first.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage(DefaultsKey.containerCLIPath) private var cliPath = ""
    @AppStorage(DefaultsKey.refreshInterval) private var refreshInterval = 2.0
    @AppStorage(DefaultsKey.defaultCPUs) private var defaultCPUs = 1
    @AppStorage(DefaultsKey.defaultMemoryMB) private var defaultMemoryMB = 512
    @State private var width: CGFloat = 0

    /// Wide enough for German and French labels next to their controls; centred in wider windows.
    private static let maxFormWidth: CGFloat = 720

    var body: some View {
        Form {
            GeneralSettingsSection()
            Section("container CLI") {
                // Baseline-aligned, so the field and the button line up (centring leaves 2 pt).
                HStack(alignment: .firstTextBaseline) {
                    TextField("Path", text: $cliPath, prompt: Text("Automatic (/opt/homebrew/bin/container)"))
                        // Bordered: reads as editable (not as a value) and is a full-height target.
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { store.reloadBackend() }
                        .accessibilityIdentifier("settings.cli-path")
                    Button("Choose…") { chooseCLI() }
                        .accessibilityIdentifier("settings.cli-choose")
                }
                Text(cliStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.options.explicitCLIPath != nil {
                    Text("Overridden by BASKET_CONTAINER_CLI for this launch.").font(.caption).foregroundStyle(Color.warningText)
                }
            }
            SetupSettingsSection()
            Section("Refresh") {
                Picker("Update containers every", selection: $refreshInterval) {
                    // "1 second", "5 seconds" in the user's language (DurationFormatStyle).
                    ForEach([1.0, 2.0, 5.0, 10.0], id: \.self) { seconds in
                        Text(verbatim: Format.duration(seconds, width: .wide)).tag(seconds)
                    }
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
            UpdateSettingsSection()
        }
        .formStyle(.grouped)
        // The form scrolls across the whole detail pane; its groups stay readable in wide windows.
        .contentMargins(.horizontal, max(20, (width - Self.maxFormWidth) / 2), for: .scrollContent)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle("Settings")
        // A CLI path typed without pressing Return takes effect when you leave Settings.
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
}

extension AppStore {
    /// ⌘, and "Settings…" (app menu, menu bar): the Settings section of the main window.
    func showSettings(_ openWindow: OpenWindowAction) {
        selectedSection = .settings
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// Language first: the setting people look for when Basket isn't in their language. Appearance
/// right after it.
private struct GeneralSettingsSection: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Section("General") {
            LanguageSettingsRows()
            AppearanceSettingsRow()
            Toggle("Launch Basket at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                .accessibilityIdentifier("settings.launch-at-login")
            if let loginItemError {
                Text(loginItemError).font(.caption).foregroundStyle(Color.warningText)
            }
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

// MARK: - Appearance

/// Settings ▸ General ▸ Appearance: System, Light or Dark, applied at once to every window, sheet,
/// alert, menu and the menu bar extra (`AppearanceChoice`).
private struct AppearanceSettingsRow: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var appearance = store.appearance
        Picker(selection: $appearance.selection) {
            ForEach(AppAppearance.allCases) { Text(verbatim: $0.title).tag($0) }
        } label: {
            Text("Appearance", comment: "Settings ▸ General: light or dark, as in System Settings ▸ Appearance")
        }
        .accessibilityIdentifier("settings.appearance")
    }
}

// MARK: - Language

/// Settings ▸ General ▸ Language: Basket's own language, independent of macOS (`AppleLanguages`
/// in Basket's defaults domain). macOS reads it at launch, so a change asks for a relaunch right
/// here, naming the language it switches to (`AppLanguage` explains why it isn't applied live).
private struct LanguageSettingsRows: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var language = store.language
        Picker("Language", selection: $language.selection) {
            Text("System", comment: "Language and Appearance pickers: follow macOS").tag("")
            ForEach(AppLanguage.available, id: \.self) { id in
                Text(verbatim: AppLanguage.name(of: id)).tag(id)
            }
        }
        .accessibilityIdentifier("settings.language")
        if let pending = language.pendingLanguage {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Relaunch Basket to switch to \(AppLanguage.name(of: pending)).",
                     comment: "Settings ▸ General, after choosing another language. The placeholder is that language's name in itself, e.g. “Deutsch”")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Relaunch Now") {
                    // UI tests and self-tests never quit or reopen the app from here.
                    guard !store.options.isUITest else { return }
                    AppRelaunch.relaunch(reopen: .settings)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("settings.language-relaunch")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.language-pending")
        }
    }
}
