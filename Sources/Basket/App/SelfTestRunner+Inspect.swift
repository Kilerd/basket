import AppKit

extension SelfTestRunner {
    /// The container Inspect tab in light and dark mode whatever the Mac's own appearance
    /// (`containers-inspect-light.png`, `containers-inspect-dark.png`; the tab's AX dump is
    /// `containers-inspect.ax.json`), then ⌘F as the keyboard sends it, which must open the text
    /// view's find bar (logged). No picture of the find bar: it shows the Mac's shared find text.
    func captureInspectExtras(_ window: NSWindow) async {
        store.containerDetailTab = .inspect
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(for: .milliseconds(700))
            writeInspectPNG(window, "containers-inspect-\(suffix)")
        }
        NSApp.appearance = nil
        try? await Task.sleep(for: .milliseconds(300))

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

    private func writeInspectPNG(_ window: NSWindow, _ name: String) {
        window.displayIfNeeded()
        guard let png = WindowSnapshot.png(of: window) else { return log("cannot render \(name)") }
        do { try png.write(to: directory.appending(path: "\(name).png")) } catch { log("write \(name).png: \(error)") }
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
