import AppKit
import ApplicationServices

/// A handle on one element of another process's accessibility tree (AXUIElement), bound to the
/// pid it was created for: actions refuse to touch elements of any other process.
@MainActor
public struct RemoteAXElement {
    public let ref: AXUIElement
    public let pid: pid_t

    init(_ ref: AXUIElement, pid: pid_t) {
        self.ref = ref
        self.pid = pid
    }

    /// The application element of `pid`.
    public static func application(pid: pid_t) -> RemoteAXElement {
        RemoteAXElement(AXUIElementCreateApplication(pid), pid: pid)
    }

    // MARK: Reading

    public func attribute(_ name: String) -> CFTypeRef? {
        copy(name).value
    }

    /// The raw read; failures are recorded in `AXErrorLog`.
    public func copy(_ name: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(ref, name as CFString, &value)
        if error != .success { AXErrorLog.record("copy \(name)", error) }
        return (error == .success ? value : nil, error)
    }

    public func string(_ name: String) -> String? { RemoteAXCapture.text(attribute(name)) }
    public var role: String? { string(kAXRoleAttribute) }
    public var subrole: String? { string(kAXSubroleAttribute) }
    public var identifier: String? { string(kAXIdentifierAttribute) }
    public var title: String? { string(kAXTitleAttribute) }

    public var children: [RemoteAXElement] { elements(kAXChildrenAttribute) }
    public var windows: [RemoteAXElement] { elements(kAXWindowsAttribute) }

    public var parent: RemoteAXElement? {
        guard let raw = attribute(kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return RemoteAXElement(raw as! AXUIElement, pid: pid)
    }

    public var frame: AXRect? {
        RemoteAXCapture.frame(position: attribute(kAXPositionAttribute), size: attribute(kAXSizeAttribute))
    }

    public var actionNames: [String] {
        var names: CFArray?
        let error = AXUIElementCopyActionNames(ref, &names)
        if error != .success { AXErrorLog.record("actions", error) }
        guard error == .success, let names else { return [] }
        return (names as? [String]) ?? []
    }

    public func isSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(ref, attribute as CFString, &settable)
        if error != .success { AXErrorLog.record("settable \(attribute)", error) }
        return error == .success && settable.boolValue
    }

    func elements(_ name: String) -> [RemoteAXElement] {
        guard let raw = attribute(name), let array = raw as? [AnyObject] else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? RemoteAXElement(item as! AXUIElement, pid: pid) : nil
        }
    }

    // MARK: Acting (only on the bound process)

    /// The pid that really owns this element; actions verify it equals `pid`.
    public var owningPid: pid_t? {
        var p: pid_t = 0
        return AXUIElementGetPid(ref, &p) == .success ? p : nil
    }

    @discardableResult
    public func perform(_ action: String) -> AXError {
        guard owningPid == pid else {
            AXErrorLog.note("refused \(action): element belongs to pid \(owningPid.map(String.init) ?? "?"), not \(pid)")
            return .cannotComplete
        }
        let error = AXUIElementPerformAction(ref, action as CFString)
        AXErrorLog.record("perform \(action)", error, always: true)
        return error
    }

    @discardableResult
    public func set(_ attribute: String, _ value: CFTypeRef) -> AXError {
        guard owningPid == pid else {
            AXErrorLog.note("refused set \(attribute): element belongs to pid \(owningPid.map(String.init) ?? "?"), not \(pid)")
            return .cannotComplete
        }
        let error = AXUIElementSetAttributeValue(ref, attribute as CFString, value)
        AXErrorLog.record("set \(attribute)", error, always: true)
        return error
    }
}

/// Collects AXError codes from remote calls so the runner can log them. Routine "no value" /
/// "unsupported attribute" answers are only counted; anything else (and every action/set
/// result when `always`) goes to `sink` immediately.
@MainActor
public enum AXErrorLog {
    public static var sink: ((String) -> Void)?
    private static var counts: [String: Int] = [:]
    private static var lastLine = ""
    private static var repeats = 0

    /// `quiet`: count only (per-attribute answers inside a snapshot; summarised per capture).
    static func record(_ operation: String, _ error: AXError, always: Bool = false, quiet: Bool = false) {
        let routine = error == .noValue || error == .attributeUnsupported || error == .parameterizedAttributeUnsupported
        if error != .success { counts["\(operation) → \(name(error))", default: 0] += 1 }
        guard always || (error != .success && !routine && !quiet) else { return }
        note("\(operation) → \(name(error))")
    }

    static func note(_ line: String) {
        guard line != lastLine else { repeats += 1; return }
        if repeats > 0 { sink?("AX   (previous line repeated \(repeats)×)") }
        lastLine = line
        repeats = 0
        sink?("AX " + line)
    }

    /// Error counts since the last call, most frequent first (then reset).
    public static func drainSummary() -> String? {
        defer { counts = [:] }
        guard !counts.isEmpty else { return nil }
        return counts.sorted { $0.value > $1.value }.prefix(12).map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
    }

    public static func name(_ error: AXError) -> String {
        switch error {
        case .success: "success"
        case .failure: "failure(-25200)"
        case .illegalArgument: "illegalArgument(-25201)"
        case .invalidUIElement: "invalidUIElement(-25202)"
        case .invalidUIElementObserver: "invalidUIElementObserver(-25203)"
        case .cannotComplete: "cannotComplete(-25204)"
        case .attributeUnsupported: "attributeUnsupported(-25205)"
        case .actionUnsupported: "actionUnsupported(-25206)"
        case .notificationUnsupported: "notificationUnsupported(-25207)"
        case .notImplemented: "notImplemented(-25208)"
        case .notificationAlreadyRegistered: "notificationAlreadyRegistered(-25209)"
        case .notificationNotRegistered: "notificationNotRegistered(-25210)"
        case .apiDisabled: "apiDisabled(-25211)"
        case .noValue: "noValue(-25212)"
        case .parameterizedAttributeUnsupported: "parameterizedAttributeUnsupported(-25213)"
        case .notEnoughPrecision: "notEnoughPrecision(-25214)"
        @unknown default: "AXError(\(error.rawValue))"
        }
    }
}

/// Out-of-process capture through the Accessibility API (needs the Accessibility permission).
/// Produces the same `AXNode` model as `InProcessAXCapture`.
@MainActor
public enum RemoteAXCapture {
    /// Whether this process may use the Accessibility API. With `prompt`, macOS shows its
    /// "would like to control this computer" dialog when it may not.
    public static func isTrusted(prompt: Bool) -> Bool {
        // The literal value of kAXTrustedCheckOptionPrompt (a C global, awkward under Swift 6).
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Bounds every AX call against `app` (seconds) so a hung app can't hang the runner.
    public static func setMessagingTimeout(_ seconds: Float, for app: RemoteAXElement) {
        AXUIElementSetMessagingTimeout(app.ref, seconds)
    }

    /// Sets the default timeout for *all* elements (children included), via the system-wide
    /// element; a per-element timeout only covers that one element.
    public static func setGlobalMessagingTimeout(_ seconds: Float) {
        let error = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
        AXErrorLog.record("set global messaging timeout", error, always: true)
    }

    /// Cooperative run deadline: once passed, `snapshot` stops descending and `find` gives up,
    /// so a wedged app (every call timing out) can't stretch a run to many minutes.
    public static var deadline: Date?

    static var isPastDeadline: Bool { deadline.map { Date() >= $0 } ?? false }

    /// Asks the app to expose its full tree, as VoiceOver does (SwiftUI builds toolbar items and
    /// row contents lazily otherwise).
    public static func enableEnhancedUserInterface(_ app: RemoteAXElement) {
        app.set("AXEnhancedUserInterface", kCFBooleanTrue)
    }

    private static let snapshotAttributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute, kAXPlaceholderValueAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXFocusedAttribute,
        kAXSelectedAttribute, kAXChildrenAttribute, kAXTitleUIElementAttribute,
    ] as [String]

    /// Captures `element` and its descendants.
    public static func snapshot(of element: RemoteAXElement, maxDepth: Int = 60) -> AXNode {
        node(element, depth: 0, maxDepth: maxDepth)
            ?? AXNode(role: element.role ?? "AXUnknown", frame: element.frame)
    }

    private static func node(_ element: RemoteAXElement, depth: Int, maxDepth: Int) -> AXNode? {
        guard !isPastDeadline else { return nil }
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element.ref, snapshotAttributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        guard status == .success, let values = raw as? [AnyObject], values.count == snapshotAttributes.count else {
            AXErrorLog.record("copyMultiple", status == .success ? .failure : status)
            return nil
        }
        func value(_ i: Int) -> CFTypeRef? {
            let v = values[i]
            // Per-attribute failures come back as AXValues of type .axError.
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError {
                var code = AXError.success
                if AXValueGetValue(v as! AXValue, .axError, &code) {
                    AXErrorLog.record("snapshot \(snapshotAttributes[i])", code, quiet: true)
                }
                return nil
            }
            if CFGetTypeID(v) == CFNullGetTypeID() { return nil }
            return v
        }
        let role = text(value(0)) ?? "AXUnknown"
        var node = AXNode(role: role)
        node.subrole = text(value(1))
        node.identifier = text(value(2))
        node.title = text(value(3)) ?? titleFromElement(value(14), pid: element.pid)
        node.label = text(value(4))
        node.help = text(value(5))
        node.value = text(value(6))
        node.placeholder = text(value(7))
        node.frame = frame(position: value(8), size: value(9))
        node.isEnabled = bool(value(10))
        node.isFocused = bool(value(11)) == true ? true : nil
        node.isSelected = bool(value(12)) == true ? true : nil
        // Table columns re-expose cells that are already reachable through rows.
        if depth < maxDepth, role != "AXColumn", let kids = value(13) as? [AnyObject] {
            node.children = kids.compactMap { kid in
                guard CFGetTypeID(kid) == AXUIElementGetTypeID() else { return nil }
                return self.node(RemoteAXElement(kid as! AXUIElement, pid: element.pid), depth: depth + 1, maxDepth: maxDepth)
            }
        }
        return node
    }

    private static func titleFromElement(_ raw: CFTypeRef?, pid: pid_t) -> String? {
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = RemoteAXElement(raw as! AXUIElement, pid: pid)
        return element.string(kAXValueAttribute) ?? element.title
    }

    // MARK: Searching

    /// Breadth-first search (nearest match first) below `root`, at most `maxDepth` levels deep.
    public static func find(
        in root: RemoteAXElement, maxDepth: Int = 40, where predicate: (RemoteAXElement) -> Bool
    ) -> RemoteAXElement? {
        var level = [root]
        for _ in 0...maxDepth {
            var next: [RemoteAXElement] = []
            for element in level {
                if isPastDeadline { return nil }
                if predicate(element) { return element }
                if element.role != "AXColumn" { next += element.children }
            }
            if next.isEmpty { return nil }
            level = next
        }
        return nil
    }

    public static func find(identifier: String, in root: RemoteAXElement, maxDepth: Int = 40) -> RemoteAXElement? {
        find(in: root, maxDepth: maxDepth) { $0.identifier == identifier }
    }

    // MARK: Value conversion

    public nonisolated static func text(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        let type = CFGetTypeID(value)
        if type == CFStringGetTypeID() { return nonEmpty(value as? String) }
        if type == CFAttributedStringGetTypeID() { return nonEmpty((value as? NSAttributedString)?.string) }
        if type == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) ? "1" : "0" }
        if type == CFNumberGetTypeID() { return (value as? NSNumber)?.stringValue }
        if type == CFURLGetTypeID() { return (value as? URL)?.absoluteString }
        return nil
    }

    nonisolated static func bool(_ value: CFTypeRef?) -> Bool? {
        guard let value else { return nil }
        let type = CFGetTypeID(value)
        if type == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) }
        if type == CFNumberGetTypeID() { return (value as? NSNumber)?.boolValue }
        return nil
    }

    nonisolated static func frame(position: CFTypeRef?, size: CFTypeRef?) -> AXRect? {
        guard let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        if point == .zero, extent == .zero { return nil }
        return AXRect(x: Double(point.x), y: Double(point.y), width: Double(extent.width), height: Double(extent.height))
    }
}
