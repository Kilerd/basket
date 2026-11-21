import SwiftUI
import AppKit

/// Native NSSearchField for the toolbar. `.searchable` can't carry an accessibility identifier,
/// which the AX contract (`<section>.search`) needs.
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String
    var identifier: String
    var onCreate: (NSSearchField) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.setAccessibilityIdentifier(identifier)
        field.setAccessibilityLabel(prompt)
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.stringValue = text
        field.controlSize = .regular
        // AppKit exposes the search field through its cell; label both so the id survives.
        field.cell?.setAccessibilityIdentifier(identifier)
        onCreate(field)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if field.identifier?.rawValue != identifier {
            field.identifier = NSUserInterfaceItemIdentifier(identifier)
            field.setAccessibilityIdentifier(identifier)
            field.cell?.setAccessibilityIdentifier(identifier)
        }
        if field.placeholderString != prompt {
            field.placeholderString = prompt
            field.setAccessibilityLabel(prompt)
        }
        onCreate(field)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// Read-only, selectable monospaced text (logs, JSON). NSTextView keeps large outputs fast and
/// brings Find (⌘F) for free.
struct MonospacedTextView: NSViewRepresentable {
    var text: String
    var followTail = false
    var identifier: String
    /// VoiceOver name ("Inspect output for web"); a literal at the call site is localized.
    var label: LocalizedStringResource

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.drawsBackground = false
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
            textView.textColor = .labelColor
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.setAccessibilityIdentifier(identifier)
            textView.setAccessibilityLabel(String(localized: label))
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        let wasAtBottom = scroll.verticalScroller.map { $0.floatValue >= 0.999 } ?? true
        textView.string = text
        if followTail || (wasAtBottom && context.coordinator.hasScrolledOnce) {
            textView.scrollToEndOfDocument(nil)
        }
        context.coordinator.hasScrolledOnce = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hasScrolledOnce = false
    }
}

/// Hands the hosting NSWindow to `onWindow` once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowTrackingView {
        let view = WindowTrackingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowTrackingView, context: Context) {
        view.onWindow = onWindow
    }

    final class WindowTrackingView: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
