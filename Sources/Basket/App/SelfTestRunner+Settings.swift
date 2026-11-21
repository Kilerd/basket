import AppKit

extension SelfTestRunner {
    /// With the Settings section on screen: the end of the scrolling form (`settings-end`, where
    /// Updates is) and the relaunch prompt after choosing another language (`settings-language`).
    /// UI-test runs never write the language choice to defaults.
    func captureSettingsStates(_ window: NSWindow) async {
        guard let scroll = Self.settingsScrollView(in: window) else {
            log("settings form scroll view not found")
            return
        }
        let top = scroll.contentView.bounds.origin
        scrollForm(scroll, toEnd: true)
        try? await Task.sleep(for: .milliseconds(500))
        await capture(window, as: "settings-end")

        scroll.contentView.scroll(to: top)
        scroll.reflectScrolledClipView(scroll.contentView)
        let language = store.language
        let other = AppLanguage.available.last { $0 != AppLanguage.current } ?? "en"
        language.selection = other
        try? await Task.sleep(for: .milliseconds(700))
        if language.pendingLanguage == nil { log("no relaunch prompt after choosing \(other)") }
        await capture(window, as: "settings-language")
        language.selection = ""
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func scrollForm(_ scroll: NSScrollView, toEnd: Bool) {
        guard let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let bottom = document.frame.height - clip.bounds.height + clip.contentInsets.bottom
        let y: CGFloat = document.isFlipped ? max(-clip.contentInsets.top, bottom) : -clip.contentInsets.bottom
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    /// The form's scroll view: the widest one in the window (the sidebar's lists are narrow).
    private static func settingsScrollView(in window: NSWindow) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return found.filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
            .max { $0.frame.width < $1.frame.width }
    }
}
