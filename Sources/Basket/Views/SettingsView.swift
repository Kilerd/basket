import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

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
        .frame(width: 520)
        // As tall as the content up to a height that fits a 13-inch display; the form scrolls.
        .frame(maxHeight: 760)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { store.reloadBackend() }
    }

    private var cliStatus: String {
        let path = cliPath.trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return "Searches /opt/homebrew/bin, /usr/local/bin and your PATH." }
        return FileManager.default.isExecutableFile(atPath: path) ? "Found an executable at this path." : "No executable at this path."
    }

    private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.message = "Choose the container executable"
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
            loginItemError = "Couldn't update the login item: \(error.localizedDescription)"
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
        let rule = "Never stopped: containers started with --rm (stopping deletes them) and ones you exempt in their context menu or details."
        return exempt.isEmpty ? rule : rule + " Exempt now: \(exempt.joined(separator: ", "))."
    }
}
