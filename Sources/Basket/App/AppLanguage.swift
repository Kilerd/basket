import AppKit
import Observation

/// The languages Basket ships (`<lang>.lproj` in the bundle, from the String Catalog) and the
/// user's choice among them.
///
/// The choice applies after a relaunch, not live: SwiftUI would re-resolve `Text("…")` literals
/// with an injected `\.locale`, but the ~650 `String(localized:)` texts (sidebar, titles, status
/// bars, states, BasketCore messages), the formatters and the AppKit menus keep the launch
/// language — a half-switched window. See docs/ARCHITECTURE.md, "Localization".
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

    /// The localization on screen now (fixed for the life of the process).
    static var current: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// The localization Basket shows after a relaunch with `override` (nil = follow macOS).
    static func resolved(_ override: String?) -> String {
        let preferences = override.map { [$0] }
            ?? UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? [String]
            ?? Locale.preferredLanguages
        return Bundle.preferredLocalizations(from: available, forPreferences: preferences).first ?? "en"
    }
}

/// Settings ▸ General ▸ Language: what the picker shows and whether a relaunch is pending.
/// UI-test runs use the defaults domain of the build under test (the debug build's,
/// `dev.basket.app.debug`, which a developer also runs by hand), so there the choice is never
/// written (the self-test sets it to capture the relaunch prompt).
@Observable @MainActor
final class LanguageChoice {
    /// "" = follow macOS, else a shipped localization id.
    var selection: String {
        didSet {
            guard persistent, selection != oldValue else { return }
            AppLanguage.setOverride(selection.isEmpty ? nil : selection)
        }
    }

    @ObservationIgnored private let persistent: Bool
    /// The selection this process started with.
    @ObservationIgnored private let initial: String

    init(persistent: Bool) {
        self.persistent = persistent
        initial = persistent ? AppLanguage.override ?? "" : ""
        selection = initial
    }

    /// The language Basket will show after a relaunch, when that differs from the one on screen.
    var pendingLanguage: String? {
        guard selection != initial else { return nil }
        let next = AppLanguage.resolved(selection.isEmpty ? nil : selection)
        return next == AppLanguage.current ? nil : next
    }
}

/// Quits Basket the normal way (it may ask about work in progress) and opens it again.
@MainActor
enum AppRelaunch {
    private static let reopenKey = "relaunchReopenSection"

    /// `reopen`: the section the relaunched app shows first (Settings after a language change).
    static func relaunch(reopen section: AppSection? = nil) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundle = Bundle.main.bundleURL.path
        if let section { UserDefaults.standard.set(section.rawValue, forKey: reopenKey) }
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
        UserDefaults.standard.removeObject(forKey: reopenKey)
    }

    /// The section a relaunch asked for, once (nil otherwise).
    static func takeReopenSection() -> AppSection? {
        guard let raw = UserDefaults.standard.string(forKey: reopenKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: reopenKey)
        return AppSection(rawValue: raw)
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
