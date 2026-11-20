import Foundation

/// The block structure of release notes (a CHANGELOG section): headings, bullets and paragraphs.
/// Inline Markdown inside each block is left for `AttributedString(markdown:)`, which SwiftUI's
/// `Text` renders; it doesn't lay out block elements itself.
public enum ReleaseNotes {
    public enum Block: Equatable, Sendable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    public static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var current: Block?
        func flush() {
            if let current { blocks.append(current) }
            current = nil
        }
        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { blocks.append(.heading(title)) }
            } else if let item = bulletText(line) {
                flush()
                current = .bullet(item)
            } else if case .bullet(let text)? = current, rawLine.first?.isWhitespace == true {
                current = .bullet(text + " " + line)
            } else if case .paragraph(let text)? = current {
                current = .paragraph(text + " " + line)
            } else {
                flush()
                current = .paragraph(line)
            }
        }
        flush()
        return blocks
    }

    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
