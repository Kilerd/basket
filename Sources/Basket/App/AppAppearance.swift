import AppKit
import Observation

/// Settings ▸ General ▸ Appearance: Basket light or dark independently of macOS, or following it.
///
/// Applied app-wide through `NSApp.appearance`, so every window, sheet, alert, menu and the menu
/// bar extra follow it, and live: AppKit and SwiftUI re-resolve dynamic colours when a view's
/// effective appearance changes. Colours must therefore stay dynamic (`Color(light:dark:)`,
/// system colours, `JSONPalette`); a colour resolved once would keep the old appearance.
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    /// Whatever macOS shows (including when macOS itself is on Auto).
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System", comment: "Language and Appearance pickers: follow macOS")
        case .light: String(localized: "Light", comment: "Appearance picker: always light, as in System Settings ▸ Appearance")
        case .dark: String(localized: "Dark", comment: "Appearance picker: always dark, as in System Settings ▸ Appearance")
        }
    }

    /// nil = inherit macOS's appearance.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    /// Sets the app-wide appearance (no-op before `NSApplication` exists).
    @MainActor func apply() {
        NSApp?.appearance = appearanceName.flatMap { NSAppearance(named: $0) }
    }
}

/// The appearance chosen in Settings, saved in Basket's own defaults domain (the running
/// bundle's, so a debug build never changes an installed Basket). UI-test runs neither read nor
/// write it, so they start at System whatever a developer chose in the debug build;
/// `BASKET_APPEARANCE` overrides it for one run and is never saved either.
@Observable @MainActor
final class AppearanceChoice {
    var selection: AppAppearance {
        didSet {
            guard selection != oldValue else { return }
            selection.apply()
            guard persistent else { return }
            if selection == .system {
                UserDefaults.standard.removeObject(forKey: DefaultsKey.appearance)
            } else {
                UserDefaults.standard.set(selection.rawValue, forKey: DefaultsKey.appearance)
            }
        }
    }

    @ObservationIgnored private let persistent: Bool

    init(persistent: Bool, override: AppAppearance? = nil) {
        self.persistent = persistent && override == nil
        selection = override
            ?? (persistent ? UserDefaults.standard.string(forKey: DefaultsKey.appearance).flatMap(AppAppearance.init) : nil)
            ?? .system
        selection.apply()
    }

    /// Applies the current choice again (at launch, before the first window).
    func apply() { selection.apply() }
}
