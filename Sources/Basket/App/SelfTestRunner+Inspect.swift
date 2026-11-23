import AppKit

extension SelfTestRunner {
    /// The container Inspect tab in light and dark mode whatever the Mac's own appearance, switched
    /// through Settings ▸ General ▸ Appearance (`containers-inspect-light.png`,
    /// `containers-inspect-dark.png`; the tab's AX dump is `containers-inspect.ax.json`), then ⌘F as
    /// the keyboard sends it, which must open the text view's find bar (logged). No picture of the
    /// find bar: it shows the Mac's shared find text.
    func captureInspectExtras(_ window: NSWindow) async {
        store.containerDetailTab = .inspect
        let initial = store.appearance.selection
        for appearance in [AppAppearance.light, .dark] {
            await switchAppearance(to: appearance, in: window)
            try? await Task.sleep(for: .milliseconds(200))
            window.displayIfNeeded()
            writePNG(of: window, to: directory.appending(path: "containers-inspect-\(appearance.rawValue).png"))
        }
        await switchAppearance(to: initial, in: window)

        window.makeKeyAndOrderFront(nil)
        if let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f",
            isARepeat: false, keyCode: 3) {
            NSApp.sendEvent(event)
        }
        try? await Task.sleep(for: .milliseconds(700))
        let scroll = Self.firstSubview(of: NoWrapScrollView.self, in: window.contentView)
        log(scroll?.isFindBarVisible == true ? "inspect: ⌘F opened the find bar" : "inspect: ⌘F did NOT open the find bar")
        if let textView = scroll?.documentView as? NSTextView {
            let hide = NSMenuItem()
            hide.tag = NSTextFinder.Action.hideFindInterface.rawValue
            textView.performTextFinderAction(hide)
        }
    }

    private static func firstSubview<T: NSView>(of type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = firstSubview(of: type, in: child) { return match }
        }
        return nil
    }
}
