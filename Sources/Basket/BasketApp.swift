import SwiftUI
import BasketCore

@main
struct BasketApp: App {
    @NSApplicationDelegateAdaptor(BasketAppDelegate.self) private var appDelegate
    @State private var store = AppStore.makeDefault()

    var body: some Scene {
        Window("Basket", id: "main") {
            MainView()
                .environment(store)
        }
        .defaultSize(width: 1280, height: 820)
        .restorationBehavior(store.options.isUITest ? .disabled : .automatic)
        // "Set Up Basket" opens instead on first launch or when the container CLI is missing.
        .defaultLaunchBehavior(store.onboarding.showsAtLaunch ? .suppressed : .automatic)
        .commands {
            BasketCommands(store: store)
            OnboardingCommands()
            UpdateCommands(store: store)
        }

        Window("Set Up Basket", id: OnboardingWindow.id) {
            OnboardingView()
                .environment(store)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(store.onboarding.showsAtLaunch ? .presented : .suppressed)

        MenuBarExtra {
            MenuBarContent()
                .environment(store)
        } label: {
            Label("Basket", systemImage: store.runningContainers.isEmpty ? "basket" : "basket.fill")
                .modifier(OnboardingLaunchPresenter(store: store))
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

struct BasketCommands: Commands {
    let store: AppStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(store.newItemTitle) { store.newItem() }
                .keyboardShortcut("n")
            Button("Compose Up…") { store.chooseComposeFile() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(store.availability != .running)
        }
        CommandGroup(before: .toolbar) {
            Button("Refresh") { Task { await store.refreshAll() } }
                .keyboardShortcut("r")
            Button("Search") { store.focusSearch() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(store.selectedSection == .overview)
            Divider()
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { store.selectedSection = section }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
        }
        CommandMenu("Container") {
            Button("Delete…") { store.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!store.canDeleteSelection)
            Divider()
            Button("Reclaim Disk Space…") { store.activeSheet = .reclaim }
            Button("Reclaim Stranded Memory…") { store.activeSheet = .reclaimMemory }
                .disabled(store.memoryInsights.totals.strandedCount == 0)
            Button("Stop Idle Containers") { Task { await store.stopIdleContainers() } }
                .disabled(store.idleContainers.isEmpty)
            if store.availability == .running {
                Button("Stop Container System…") { store.confirmStopSystem() }
            } else {
                Button("Start Container System") { Task { await store.startSystem() } }
            }
        }
    }
}
