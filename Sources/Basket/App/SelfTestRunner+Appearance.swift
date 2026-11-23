import AppKit

extension SelfTestRunner {
    /// Every section again in light and in dark, switched live through Settings ▸ General ▸
    /// Appearance (never saved in UI-test runs): `<section>-light.png` and `<section>-dark.png`,
    /// so contrast and alignment are reviewed in both whatever the Mac's own appearance. PNGs
    /// only: the accessibility tree doesn't depend on the appearance and is linted from the main
    /// pass. Ends on the run's own appearance (System, or `BASKET_APPEARANCE`).
    func captureAppearances(_ window: NSWindow) async {
        let initial = store.appearance.selection
        for appearance in [AppAppearance.light, .dark] {
            await switchAppearance(to: appearance, in: window)
            for section in AppSection.allCases {
                store.selectedSection = section
                try? await Task.sleep(for: .milliseconds(700))
                window.layoutIfNeeded()
                window.displayIfNeeded()
                writePNG(of: window, to: directory.appending(path: "\(section.rawValue)-\(appearance.rawValue).png"))
            }
            log("captured every section in \(appearance.rawValue)")
        }
        await switchAppearance(to: initial, in: window)
    }

    /// Chooses `appearance` in Settings and waits for `window` to show it (logged if it doesn't).
    func switchAppearance(to appearance: AppAppearance, in window: NSWindow) async {
        store.appearance.selection = appearance
        try? await Task.sleep(for: .milliseconds(500))
        guard let expected = appearance.appearanceName else { return }
        let shown = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        if shown != expected {
            log("appearance \(appearance.rawValue) did NOT apply: the window shows \(shown?.rawValue ?? "?")")
        }
    }
}
