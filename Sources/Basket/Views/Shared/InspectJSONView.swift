import AppKit
import SwiftUI
import BasketCore

/// The Inspect tab of containers and images: the backend's inspect JSON, re-indented
/// (`JSONFormatter`) and highlighted (`JSONHighlighter`), with Find (⌘F) and Copy JSON.
struct InspectJSONView: View {
    @Environment(AppStore.self) private var store
    var identifier: String
    var subject: String
    var load: @Sendable (any ContainerBackend) async throws -> String
    @State private var document = InspectDocument()
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                (error.map { Text(verbatim: $0) } ?? Text("container inspect output", comment: "Caption above raw JSON; `container inspect` is the CLI command and stays untranslated"))
                    .font(.caption).foregroundStyle(error == nil ? Color.secondary : Color.warningText)
                    .lineLimit(1)
                Spacer()
                Button(String(localized: "Find", comment: "Button: opens the find bar to search the inspect JSON (⌘F)"),
                       systemImage: "magnifyingglass") { document.showFindBar() }
                    .keyboardShortcut("f")
                    .disabled(document.text.isEmpty)
                    .accessibilityIdentifier("\(identifier).find")
                Button("Copy JSON", systemImage: "doc.on.doc") { HostActions.copy(document.text) }
                    .disabled(document.text.isEmpty)
                    .accessibilityIdentifier("\(identifier).copy")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            Divider()
            JSONTextView(document: document, identifier: identifier,
                         label: String(localized: "Inspect output for \(subject)"))
        }
        .task(id: subject) {
            error = nil
            do {
                let output = try await load(store.backend)
                await document.load(output)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
                document.clear()
            }
        }
    }
}

/// What the Inspect text view shows. Formatting and highlighting run off the main thread; a large
/// document appears as plain text first and gets its colours when they are ready. The text view
/// is edited directly, so SwiftUI never diffs a multi-megabyte string.
@Observable @MainActor
final class InspectDocument {
    /// What is shown and what Copy JSON copies: the formatted JSON, or the output unchanged when
    /// it isn't JSON.
    private(set) var text = ""
    @ObservationIgnored private var content = NSAttributedString()
    @ObservationIgnored private var columns = 0
    @ObservationIgnored private weak var textView: NSTextView?
    @ObservationIgnored private var generation = 0

    /// Up to this many UTF-16 units the colours come with the first display.
    nonisolated static let inlineHighlightLimit = 200_000

    /// Hands an `NSAttributedString` (immutable once built) from a background task to the main actor.
    private struct Rendered: @unchecked Sendable {
        var text: String
        var attributed: NSAttributedString
        var columns: Int
        /// Still to highlight (large documents).
        var pending: FormattedJSON?
    }

    func attach(_ textView: NSTextView) {
        self.textView = textView
        show(content, columns: columns, keepingPosition: false)
    }

    func load(_ output: String) async {
        generation &+= 1
        let current = generation
        let first = await Self.render(output)
        guard current == generation else { return }
        text = first.text
        show(first.attributed, columns: first.columns, keepingPosition: false)
        guard let pending = first.pending else { return }
        let colored = await Self.highlight(pending, columns: first.columns)
        guard current == generation else { return }
        show(colored.attributed, columns: colored.columns, keepingPosition: true)
    }

    func clear() {
        generation &+= 1
        text = ""
        show(NSAttributedString(), columns: 0, keepingPosition: false)
    }

    /// The text view's find bar, focused (⌘F).
    func showFindBar() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        let action = NSMenuItem()
        action.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(action)
    }

    @concurrent private nonisolated static func render(_ output: String) async -> Rendered {
        guard let json = JSONFormatter.format(output) else {
            return Rendered(text: output, attributed: JSONHighlighter.plain(output),
                            columns: JSONHighlighter.widestLine(in: output))
        }
        let columns = JSONHighlighter.widestLine(in: json.text)
        if json.text.utf16.count <= inlineHighlightLimit {
            return Rendered(text: json.text, attributed: JSONHighlighter.highlighted(json), columns: columns)
        }
        return Rendered(text: json.text, attributed: JSONHighlighter.plain(json.text), columns: columns, pending: json)
    }

    @concurrent private nonisolated static func highlight(_ json: FormattedJSON, columns: Int) async -> Rendered {
        Rendered(text: json.text, attributed: JSONHighlighter.highlighted(json), columns: columns)
    }

    /// Same text with colours (`keepingPosition`) keeps the selection and scroll position; a new
    /// document starts at the top.
    private func show(_ attributed: NSAttributedString, columns: Int, keepingPosition: Bool) {
        content = attributed
        self.columns = columns
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRanges
        let origin = textView.enclosingScrollView?.contentView.bounds.origin
        (textView.enclosingScrollView as? NoWrapScrollView)?.columns = columns
        storage.setAttributedString(attributed)
        if keepingPosition {
            let length = storage.length
            let valid = selection.filter { NSMaxRange($0.rangeValue) <= length }
            if !valid.isEmpty { textView.selectedRanges = valid }
            if let origin { textView.scroll(origin) }
        } else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scroll(.zero)
        }
    }
}

/// Read-only, selectable JSON: no line wrapping (long values scroll sideways so the indentation
/// stays readable), the find bar, VoiceOver reads the whole text.
struct JSONTextView: NSViewRepresentable {
    var document: InspectDocument
    var identifier: String
    var label: String

    func makeNSView(context: Context) -> NoWrapScrollView {
        let scroll = NoWrapScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        // Its own background: the palette is checked for contrast against exactly this colour (the
        // window behind can be tinted by the desktop picture).
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = JSONHighlighter.font
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityIdentifier(identifier)
        textView.setAccessibilityLabel(label)
        scroll.documentView = textView
        document.attach(textView)
        return scroll
    }

    func updateNSView(_ scroll: NoWrapScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.accessibilityLabel() != label { textView.setAccessibilityLabel(label) }
        if textView.accessibilityIdentifier() != identifier { textView.setAccessibilityIdentifier(identifier) }
    }
}

/// Keeps its text view as wide as the widest line (and at least as wide as the visible area), so
/// nothing wraps. An unbounded text container would do the same, but TextKit 2 then lays out the
/// whole document to learn its width: seconds for a few MB, against milliseconds when only the
/// visible part is laid out.
final class NoWrapScrollView: NSScrollView {
    /// Display columns of the widest line (`JSONHighlighter.widestLine`).
    var columns = 0 {
        didSet { if columns != oldValue { tile() } }
    }

    /// A line longer than this (a huge string value) wraps rather than making a view millions of
    /// points wide.
    static let maximumColumns = 20_000

    override func tile() {
        super.tile()
        guard let textView = documentView as? NSTextView else { return }
        let advance = ("0" as NSString).size(withAttributes: [.font: JSONHighlighter.font]).width
        let padding = 2 * (textView.textContainerInset.width + (textView.textContainer?.lineFragmentPadding ?? 0))
        let visible = contentView.bounds.size
        let needed = CGFloat(min(columns, Self.maximumColumns) + 1) * advance + padding
        let width = max(visible.width, needed.rounded(.up))
        if textView.minSize.height != visible.height { textView.minSize = NSSize(width: 0, height: visible.height) }
        if abs(textView.frame.width - width) > 0.5 {
            textView.setFrameSize(NSSize(width: width, height: max(textView.frame.height, visible.height)))
        }
    }
}
