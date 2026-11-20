import AppKit

/// Walks a window's accessibility tree from inside the app (no TCC permission needed) and
/// produces the same `AXNode` model as the out-of-process `RemoteAXCapture`.
///
/// Details that matter for SwiftUI (verified with `basket-ax capture-demo` on macOS 26):
/// - Children are read through the legacy `accessibilityAttributeValue:` entry point — the one
///   the AX server uses. It returns only *unignored* children and wakes `NSHostingView`'s lazily
///   built accessibility tree (the modern `accessibilityChildren()` returns `[]` until then).
/// - SwiftUI's `AccessibilityNode` answers the modern selectors (`accessibilityRole`, …) but not
///   the legacy attribute getter, and doesn't formally conform to `NSAccessibilityProtocol`, so
///   attributes are read with the modern selector when the object responds to it.
/// - SwiftUI only exposes toolbar items and row contents once an assistive client has set
///   `AXEnhancedUserInterface` on the app (VoiceOver does this). `prepare()` does the same.
/// - Non-elements (`isAccessibilityElement() == false`) are not emitted; their children are
///   spliced into the nearest emitted ancestor. Hidden views are skipped entirely.
public enum InProcessAXCapture {
    /// Captures `window` now. Call `prepare()` (or use `settledSnapshot`) first so SwiftUI has
    /// built its accessibility tree.
    @MainActor
    public static func snapshot(of window: NSWindow, maxDepth: Int = 60) -> AXNode {
        prepare()
        var walker = Walker(maxDepth: maxDepth, primaryScreenHeight: primaryScreenHeight())
        return walker.node(for: window, depth: 0, isRoot: true).first
            ?? AXNode(role: "AXWindow", frame: walker.convert(window.frame))
    }

    /// Captures repeatedly (every `interval`) until two consecutive snapshots are identical or
    /// `timeout` elapses, and returns the last one. Use after navigation, when SwiftUI may still
    /// be updating its accessibility tree.
    @MainActor
    public static func settledSnapshot(
        of window: NSWindow,
        maxDepth: Int = 60,
        timeout: Duration = .seconds(3),
        interval: Duration = .milliseconds(150)
    ) async -> AXNode {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var previous = snapshot(of: window, maxDepth: maxDepth)
        while clock.now < deadline {
            try? await Task.sleep(for: interval)
            let next = snapshot(of: window, maxDepth: maxDepth)
            if next == previous { return next }
            previous = next
        }
        return previous
    }

    /// Turns on the accessibility behaviour an assistive client would (idempotent): sets
    /// `AXEnhancedUserInterface` on the application so SwiftUI exposes its full tree.
    @MainActor
    public static func prepare() {
        guard !prepared, let app = NSApp else { return }
        prepared = true
        let selector = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if app.responds(to: selector) {
            _ = app.perform(selector, with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        }
    }

    @MainActor private static var prepared = false

    @MainActor
    static func primaryScreenHeight() -> Double {
        // AX coordinates are relative to the top-left of the primary (menu bar) screen.
        Double(NSScreen.screens.first?.frame.height ?? 0)
    }

    @MainActor
    private struct Walker {
        let maxDepth: Int
        let primaryScreenHeight: Double
        var visited: Set<ObjectIdentifier> = []

        init(maxDepth: Int, primaryScreenHeight: Double) {
            self.maxDepth = maxDepth
            self.primaryScreenHeight = primaryScreenHeight
        }

        func convert(_ r: NSRect) -> AXRect {
            AXRect(
                x: Double(r.origin.x),
                y: primaryScreenHeight - Double(r.origin.y) - Double(r.size.height),
                width: Double(r.size.width),
                height: Double(r.size.height)
            )
        }

        /// One node when `object` is an accessibility element, otherwise its flattened children.
        mutating func node(for object: Any, depth: Int, isRoot: Bool = false) -> [AXNode] {
            guard depth <= maxDepth, let element = object as? NSObject else { return [] }
            let id = ObjectIdentifier(element)
            guard !visited.contains(id) else { return [] }
            visited.insert(id)
            if let view = element as? NSView, view.isHiddenOrHasHiddenAncestor { return [] }

            let ax = Element(object: element)
            let role = ax.role ?? "AXUnknown"
            var children: [AXNode] = []
            // Table columns re-expose cells that are already reachable through rows.
            if role != NSAccessibility.Role.column.rawValue {
                for child in ax.children {
                    children.append(contentsOf: node(for: child, depth: depth + 1))
                }
            }
            guard isRoot || ax.isElement else { return children }
            // Opaque placeholders (e.g. remote view-service elements) carry no information.
            if ax.role == nil, children.isEmpty, ax.frame == nil { return [] }

            var node = AXNode(role: role, children: children)
            node.subrole = ax.subrole
            node.identifier = ax.identifier
            node.title = ax.title
            node.label = ax.label
            node.help = ax.help
            node.value = ax.value
            node.placeholder = ax.placeholder
            if let frame = ax.frame, frame != .zero { node.frame = convert(frame) }
            node.isEnabled = ax.isEnabled
            node.isFocused = ax.isFocused == true ? true : nil
            node.isSelected = ax.isSelected == true ? true : nil
            return [node]
        }
    }

    /// Reads one element through whichever accessibility entry point it implements.
    @MainActor
    private struct Element {
        let object: NSObject
        /// Modern NSAccessibility view of `object`. Only call a method after `responds(_:)`:
        /// SwiftUI's nodes implement the selectors without declaring the protocol conformance.
        let modern: any NSAccessibilityProtocol

        init(object: NSObject) {
            self.object = object
            self.modern = unsafeBitCast(object, to: (any NSAccessibilityProtocol).self)
        }

        func responds(_ name: String) -> Bool { object.responds(to: NSSelectorFromString(name)) }

        func legacy(_ attribute: NSAccessibility.Attribute) -> Any? {
            let selector = NSSelectorFromString("accessibilityAttributeValue:")
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector, with: attribute.rawValue)?.takeUnretainedValue()
        }

        var children: [Any] {
            // Always ask the legacy way first: it is what wakes SwiftUI's lazy tree.
            let unignored = legacy(.children) as? [Any]
            if responds("accessibilityChildren"), let direct = modern.accessibilityChildren(), !direct.isEmpty {
                return direct
            }
            return unignored ?? []
        }

        var isElement: Bool {
            responds("isAccessibilityElement") ? modern.isAccessibilityElement() : true
        }

        var role: String? {
            (responds("accessibilityRole") ? nonEmpty(modern.accessibilityRole()?.rawValue) : nil)
                ?? text(legacy(.role))
        }
        var subrole: String? {
            (responds("accessibilitySubrole") ? nonEmpty(modern.accessibilitySubrole()?.rawValue) : nil)
                ?? text(legacy(.subrole))
        }
        var identifier: String? {
            (responds("accessibilityIdentifier") ? nonEmpty(modern.accessibilityIdentifier()) : nil)
                ?? text(legacy(.identifier))
        }
        var title: String? {
            (responds("accessibilityTitle") ? nonEmpty(modern.accessibilityTitle()) : nil)
                ?? text(legacy(.title)) ?? titleFromTitleElement
        }
        var label: String? {
            (responds("accessibilityLabel") ? nonEmpty(modern.accessibilityLabel()) : nil)
                ?? text(legacy(.description))
        }
        var help: String? {
            (responds("accessibilityHelp") ? nonEmpty(modern.accessibilityHelp()) : nil)
                ?? text(legacy(.help))
        }
        var value: String? {
            (responds("accessibilityValue") ? text(modern.accessibilityValue()) : nil)
                ?? text(legacy(.value))
        }
        var placeholder: String? {
            (responds("accessibilityPlaceholderValue") ? nonEmpty(modern.accessibilityPlaceholderValue()) : nil)
                ?? text(legacy(.placeholderValue))
        }
        var frame: NSRect? {
            if responds("accessibilityFrame") { return modern.accessibilityFrame() }
            guard let pos = (legacy(.position) as? NSValue)?.pointValue,
                  let size = (legacy(.size) as? NSValue)?.sizeValue else { return nil }
            return NSRect(origin: pos, size: size)
        }
        var isEnabled: Bool? {
            responds("isAccessibilityEnabled") ? modern.isAccessibilityEnabled() : bool(legacy(.enabled))
        }
        var isFocused: Bool? {
            responds("isAccessibilityFocused") ? modern.isAccessibilityFocused() : bool(legacy(.focused))
        }
        var isSelected: Bool? {
            responds("isAccessibilitySelected") ? modern.isAccessibilitySelected() : bool(legacy(.selected))
        }

        private var titleFromTitleElement: String? {
            let raw: Any? = responds("accessibilityTitleUIElement")
                ? modern.accessibilityTitleUIElement() : legacy(.titleUIElement)
            guard let titleObject = raw as? NSObject else { return nil }
            let t = Element(object: titleObject)
            return t.value ?? nonEmpty(t.responds("accessibilityTitle") ? t.modern.accessibilityTitle() : nil)
        }

        private func text(_ value: Any?) -> String? {
            switch value {
            case let s as String: return nonEmpty(s)
            case let s as NSAttributedString: return nonEmpty(s.string)
            case let n as NSNumber: return n.stringValue
            case let u as URL: return u.absoluteString
            default: return nil
            }
        }

        private func bool(_ value: Any?) -> Bool? { (value as? NSNumber)?.boolValue }
    }
}

func nonEmpty(_ s: String?) -> String? {
    guard let s, !s.isEmpty else { return nil }
    return s
}
