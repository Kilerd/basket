import AppKit
import SwiftUI

/// The caption above a log: "120 lines · 3 services · following". Each part is a whole phrase so
/// every number gets its own plural.
enum LogStatus {
    static func text(lines: Int, services: Int? = nil, following: Bool) -> String {
        var parts = [String(localized: "\(lines) lines", comment: "Log status: line count")]
        if let services { parts.append(String(localized: "\(services) services", comment: "A number of Compose services")) }
        if following { parts.append(String(localized: "following", comment: "Log status: new lines stream in as they are written")) }
        return parts.joined(separator: " · ")
    }
}

/// The lines a log view shows, applied to its NSTextView incrementally: appends add only the new
/// text and trimming removes only the oldest lines, so a followed log never re-sets the whole text.
@Observable @MainActor
final class LogDocument {
    /// Lines kept; trimming starts once `maxLines + trimSlack` is reached.
    let maxLines: Int
    private let trimSlack: Int
    /// Only set when it changes: every set would re-render the SwiftUI around the text view.
    private(set) var lineCount = 0

    @ObservationIgnored private var lines: [String] = []
    /// UTF-16 length of each line plus the newline that follows it (the last line has none yet).
    @ObservationIgnored private var lengths: [Int] = []
    @ObservationIgnored private weak var textView: NSTextView?
    @ObservationIgnored var followsTail = false

    static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular),
        .foregroundColor: NSColor.labelColor,
    ]

    init(maxLines: Int = 5_000, trimSlack: Int = 0) {
        self.maxLines = maxLines
        self.trimSlack = trimSlack
    }

    var text: String { lines.joined(separator: "\n") }
    var isEmpty: Bool { lines.isEmpty }

    func attach(_ textView: NSTextView) {
        self.textView = textView
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
        scrollIfFollowing(textView, force: true)
    }

    func replace(with newLines: [String]) {
        let kept = Array(newLines.suffix(maxLines))
        lines = kept
        lengths = kept.map { $0.utf16.count + 1 }
        if lineCount != kept.count { lineCount = kept.count }
        if let textView {
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
            scrollIfFollowing(textView, force: true)
        }
    }

    func append(_ newLines: [String]) {
        guard !newLines.isEmpty else { return }
        let added = newLines.joined(separator: "\n")
        let chunk = (lines.isEmpty ? "" : "\n") + added
        lines.append(contentsOf: newLines)
        lengths.append(contentsOf: newLines.map { $0.utf16.count + 1 })

        let excess = lines.count > maxLines + trimSlack ? lines.count - maxLines : 0
        let trimmedLength = excess > 0 ? lengths[..<excess].reduce(0, +) : 0
        if excess > 0 {
            lines.removeFirst(excess)
            lengths.removeFirst(excess)
        }
        if lineCount != lines.count { lineCount = lines.count }

        guard let textView, let storage = textView.textStorage else { return }
        let wasAtBottom = Self.isAtBottom(textView)
        storage.beginEditing()
        storage.append(NSAttributedString(string: chunk, attributes: Self.attributes))
        if trimmedLength > 0 {
            storage.deleteCharacters(in: NSRange(location: 0, length: min(trimmedLength, storage.length)))
        }
        storage.endEditing()
        scrollIfFollowing(textView, force: wasAtBottom)
    }

    private func scrollIfFollowing(_ textView: NSTextView, force: Bool) {
        if followsTail || force { textView.scrollToEndOfDocument(nil) }
    }

    private static func isAtBottom(_ textView: NSTextView) -> Bool {
        guard let scroll = textView.enclosingScrollView else { return true }
        let visible = scroll.contentView.bounds
        return visible.maxY >= textView.frame.height - 4
    }
}

/// Read-only, selectable monospaced text backed by a `LogDocument`. SwiftUI updates never touch the
/// text: the document edits the NSTextView directly.
struct LogTextView: NSViewRepresentable {
    var document: LogDocument
    var followTail: Bool
    var identifier: String
    var label: String

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
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.setAccessibilityIdentifier(identifier)
            textView.setAccessibilityLabel(label)
            document.followsTail = followTail
            document.attach(textView)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        document.followsTail = followTail
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.accessibilityLabel() != label { textView.setAccessibilityLabel(label) }
    }
}
