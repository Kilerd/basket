import Foundation

/// A YAML 1.2 reader for the subset real-world Compose files use: block mappings and sequences,
/// plain / single- / double-quoted scalars (multi-line folding included), literal `|` and folded `>`
/// block scalars with chomping and indentation indicators, flow `[a, b]` / `{k: v}` collections,
/// comments, anchors, aliases, merge keys (`<<: *base`) and `!!str`-style tags. One document per file.
///
/// Not supported (reported as errors): complex keys (`? `), multiple documents.
public enum YAMLParser {
    public static func parse(_ text: String) throws -> YAMLValue {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        var reader = YAMLReader(Array(normalized))
        return try reader.parseDocument()
    }
}

struct YAMLReader {
    let chars: [Character]
    var pos = 0
    var line = 1
    var lineStart = 0
    var anchors: [String: YAMLValue] = [:]

    init(_ chars: [Character]) {
        self.chars = chars
    }

    // MARK: Cursor

    struct Mark {
        var pos: Int
        var line: Int
        var lineStart: Int
    }

    var mark: Mark { Mark(pos: pos, line: line, lineStart: lineStart) }

    mutating func reset(to mark: Mark) {
        pos = mark.pos
        line = mark.line
        lineStart = mark.lineStart
    }

    var atEnd: Bool { pos >= chars.count }
    var column: Int { pos - lineStart }

    func peek(_ offset: Int = 0) -> Character? {
        let i = pos + offset
        return i >= 0 && i < chars.count ? chars[i] : nil
    }

    mutating func advance(_ count: Int = 1) {
        for _ in 0..<count where pos < chars.count {
            if chars[pos] == "\n" {
                line += 1
                lineStart = pos + 1
            }
            pos += 1
        }
    }

    static func isBlank(_ c: Character?) -> Bool { c == nil || c == " " || c == "\t" || c == "\n" }
    static func isFlowIndicator(_ c: Character?) -> Bool { c == "," || c == "[" || c == "]" || c == "{" || c == "}" }

    func error(_ message: LocalizedStringResource, at mark: Mark? = nil) -> YAMLError {
        let m = mark ?? self.mark
        return YAMLError(line: m.line, column: m.pos - m.lineStart + 1, message: String(localized: message))
    }

    mutating func skipInlineSpaces() {
        while peek() == " " || peek() == "\t" { advance() }
    }

    mutating func skipComment() {
        guard peek() == "#" else { return }
        while let c = peek(), c != "\n" { advance() }
    }

    /// Skips whitespace, comments and line breaks up to the next content character.
    mutating func skipToNextContent() {
        while let c = peek() {
            if c == " " || c == "\t" || c == "\n" {
                advance()
            } else if c == "#" {
                skipComment()
            } else {
                break
            }
        }
    }

    /// Whether only whitespace precedes the cursor on its line.
    var isAtLineContentStart: Bool {
        chars[lineStart..<min(pos, chars.count)].allSatisfy { $0 == " " || $0 == "\t" }
    }

    func isDocumentMarker(_ marker: String) -> Bool {
        guard column == 0 else { return false }
        let m = Array(marker)
        return peek() == m[0] && peek(1) == m[1] && peek(2) == m[2] && Self.isBlank(peek(3))
    }

    var atDocumentBoundary: Bool { isDocumentMarker("---") || isDocumentMarker("...") }

    /// YAML forbids tabs in indentation; say so instead of failing obscurely later.
    func checkIndentation() throws {
        guard isAtLineContentStart, chars[lineStart..<pos].contains("\t") else { return }
        throw YAMLError(line: line, column: 1, message: String(localized: "tabs can't be used for indentation; use spaces", bundle: .main))
    }

    /// After a value: only spaces and a comment may follow on its line.
    mutating func finishLine() throws {
        skipInlineSpaces()
        skipComment()
        guard atEnd || peek() == "\n" || isAtLineContentStart else {
            throw error("unexpected text “\(String(chars[pos..<min(chars.count, pos + 20)]))” after a value")
        }
        skipToNextContent()
    }

    // MARK: Document

    mutating func parseDocument() throws -> YAMLValue {
        skipToNextContent()
        while column == 0, peek() == "%" {
            while let c = peek(), c != "\n" { advance() }
            skipToNextContent()
        }
        var explicitStart = false
        if isDocumentMarker("---") {
            advance(3)
            explicitStart = true
        }
        var value = YAMLValue.null
        skipInlineSpaces()
        skipComment()
        if peek() == "\n" || atEnd || !explicitStart { skipToNextContent() }
        if !atEnd, !atDocumentBoundary {
            value = try parseNode(parentIndent: -1, allowCompactSequence: false, inline: false)
            try finishLine()
        }
        if isDocumentMarker("...") {
            advance(3)
            skipToNextContent()
        }
        if !atEnd {
            if isDocumentMarker("---") {
                throw error("the file holds more than one YAML document; Compose files have exactly one")
            }
            throw error("unexpected content; check the indentation")
        }
        return value
    }

    // MARK: Block nodes

    /// Parses the node after `key:`, `- ` or at the document start: optional anchor/tag, then either
    /// content on the same line or a nested block on the following lines (indented more than
    /// `parentIndent`; a sequence may sit at the same indentation as its mapping key).
    mutating func parseNode(parentIndent: Int, allowCompactSequence: Bool, inline: Bool) throws -> YAMLValue {
        skipInlineSpaces()
        let (anchor, tag) = try parseProperties(inFlow: false)
        var value: YAMLValue
        skipInlineSpaces()
        skipComment()
        if atEnd || peek() == "\n" {
            skipToNextContent()
            let isSequence = peek() == "-" && Self.isBlank(peek(1))
            if !atEnd, !atDocumentBoundary,
               column > parentIndent || (allowCompactSequence && column == parentIndent && isSequence) {
                try checkIndentation()
                value = try parseBlockNode(parentIndent: parentIndent, inline: false, tag: tag)
            } else {
                value = tag == .string ? .string("") : .null
            }
        } else {
            value = try parseBlockNode(parentIndent: parentIndent, inline: inline, tag: tag)
        }
        value = try apply(tag, to: value)
        if let anchor { anchors[anchor] = value }
        return value
    }

    mutating func parseBlockNode(parentIndent: Int, inline: Bool, tag: Tag?) throws -> YAMLValue {
        let start = mark
        switch peek() {
        case "-" where Self.isBlank(peek(1)):
            if inline { throw error("a list can't start on the same line as its key; put “- item” on the next line") }
            return try parseBlockSequence(indent: column)
        case "[", "{":
            let value = try parseFlowNode()
            skipInlineSpaces()
            if peek() == ":", Self.isBlank(peek(1)) {
                throw error("collections can't be used as mapping keys", at: start)
            }
            return value
        case "|", ">":
            return .string(try parseBlockScalar(parentIndent: parentIndent))
        case "*":
            return try parseAlias()
        case "?" where Self.isBlank(peek(1)):
            throw error("complex mapping keys (“? ”) aren't supported")
        case "&", "!":
            throw error("a node can't have two sets of anchors or tags")
        default:
            if implicitKeyAhead() {
                if inline {
                    throw error("unexpected “: ” in a value; quote the value, or move a nested mapping to the next line and indent it")
                }
                return try parseBlockMapping(indent: column)
            }
            if peek() == "\"" || peek() == "'" {
                return .string(try parseQuoted())
            }
            let text = try parsePlainScalar(parentIndent: parentIndent)
            return tag == .string ? .string(text) : Self.resolve(plain: text)
        }
    }

    mutating func parseBlockSequence(indent: Int) throws -> YAMLValue {
        var items: [YAMLValue] = []
        while true {
            advance()  // "-"
            items.append(try parseNode(parentIndent: indent, allowCompactSequence: false, inline: false))
            try finishLine()
            if atEnd || atDocumentBoundary { break }
            try checkIndentation()
            if column == indent, peek() == "-", Self.isBlank(peek(1)) { continue }
            if column <= indent { break }
            throw error("bad indentation: list items under this list start at column \(indent + 1)")
        }
        return .sequence(items)
    }

    enum MappingItem {
        case entry(String, YAMLValue)
        case merge(YAMLValue, Mark)
    }

    mutating func parseBlockMapping(indent: Int) throws -> YAMLValue {
        var items: [MappingItem] = []
        var seen: Set<String> = []
        while true {
            let keyMark = mark
            if peek() == "-", Self.isBlank(peek(1)) {
                throw error("a list item can't appear among mapping keys; indent the list under its key")
            }
            if peek() == "?", Self.isBlank(peek(1)) { throw error("complex mapping keys (“? ”) aren't supported") }
            let (key, isMerge) = try parseImplicitKey()
            skipInlineSpaces()
            guard peek() == ":" else { throw error("expected “:” after the key “\(key)”") }
            advance()
            let value = try parseNode(parentIndent: indent, allowCompactSequence: true, inline: true)
            if isMerge {
                items.append(.merge(value, keyMark))
            } else {
                guard seen.insert(key).inserted else {
                    throw error("duplicate key “\(key)”", at: keyMark)
                }
                items.append(.entry(key, value))
            }
            try finishLine()
            if atEnd || atDocumentBoundary { break }
            try checkIndentation()
            if column == indent { continue }
            if column < indent { break }
            throw error("bad indentation: keys of this mapping start at column \(indent + 1)")
        }
        return .mapping(try buildMapping(items))
    }

    /// Explicit keys win over merged ones; earlier merge sources win over later ones.
    func buildMapping(_ items: [MappingItem]) throws -> YAMLMapping {
        var explicit: Set<String> = []
        for case .entry(let key, _) in items { explicit.insert(key) }
        var result = YAMLMapping()
        var added: Set<String> = []
        for item in items {
            switch item {
            case .entry(let key, let value):
                result.set(key, value)
                added.insert(key)
            case .merge(let value, let mark):
                let sources: [YAMLValue]
                switch value {
                case .mapping: sources = [value]
                case .sequence(let list): sources = list
                default: throw error("a merge key (<<) needs a mapping or a list of mappings, but found \(value.kindPhrase)", at: mark)
                }
                for source in sources {
                    guard let mapping = source.mapping else {
                        throw error("a merge key (<<) needs a mapping or a list of mappings, but found \(source.kindPhrase)", at: mark)
                    }
                    for entry in mapping.entries where !explicit.contains(entry.key) && !added.contains(entry.key) {
                        result.set(entry.key, entry.value)
                        added.insert(entry.key)
                    }
                }
            }
        }
        return result
    }

    /// Whether the current line, from the cursor, reads `key:` (a quoted or plain scalar followed by
    /// a colon and a space or line end).
    func implicitKeyAhead() -> Bool {
        var i = pos
        func at(_ j: Int) -> Character? { j < chars.count ? chars[j] : nil }
        if let quote = at(i), quote == "\"" || quote == "'" {
            i += 1
            while let c = at(i), c != "\n" {
                if quote == "\"", c == "\\" { i += 2; continue }
                if c == quote {
                    if quote == "'", at(i + 1) == "'" { i += 2; continue }
                    break
                }
                i += 1
            }
            guard at(i) == quote else { return false }
            i += 1
            while at(i) == " " || at(i) == "\t" { i += 1 }
            return at(i) == ":" && Self.isBlank(at(i + 1))
        }
        while let c = at(i), c != "\n" {
            if c == ":", Self.isBlank(at(i + 1)) { return i > pos }
            if c == "#", i > pos, at(i - 1) == " " || at(i - 1) == "\t" { return false }
            i += 1
        }
        return false
    }

    /// Reads a block mapping key (single line); returns its text and whether it is the merge key.
    mutating func parseImplicitKey() throws -> (String, Bool) {
        if peek() == "\"" || peek() == "'" {
            let startLine = line
            let key = try parseQuoted()
            if line != startLine { throw error("a mapping key must fit on one line") }
            return (key, false)
        }
        if peek() == "*" {
            let alias = try parseAlias()
            guard let text = alias.scalarText else { throw error("an alias used as a key must refer to a scalar") }
            return (text, false)
        }
        var text = ""
        while let c = peek(), c != "\n" {
            if c == ":", Self.isBlank(peek(1)) { break }
            text.append(c)
            advance()
        }
        while text.last == " " || text.last == "\t" { text.removeLast() }
        return (text, text == "<<")
    }

    // MARK: Scalars

    /// A plain scalar in block context; continuation lines indented more than `parentIndent` fold
    /// into it (a single line break becomes a space, blank lines become newlines).
    mutating func parsePlainScalar(parentIndent: Int) throws -> String {
        if let c = peek(), "@`%".contains(c) || Self.isFlowIndicator(c) && c != "[" && c != "{" {
            throw error("a plain value can't start with “\(String(c))”; quote it")
        }
        var text = try plainLine()
        var end = mark
        while peek() == "\n" {
            var breaks = 0
            advance()
            while true {
                var j = pos
                while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                if j < chars.count, chars[j] == "\n" {
                    advance(j - pos + 1)
                    breaks += 1
                } else {
                    break
                }
            }
            skipInlineSpaces()
            if atEnd || column <= parentIndent || peek() == "#" || (column == 0 && atDocumentBoundary) {
                reset(to: end)
                break
            }
            if implicitKeyAhead() {
                throw error("this line reads as a mapping key inside a multi-line value; check the indentation")
            }
            let more = try plainLine()
            text += (breaks == 0 ? " " : String(repeating: "\n", count: breaks)) + more
            end = mark
        }
        return text
    }

    /// One line of a block plain scalar, stopping before a comment or line end (trailing spaces trimmed).
    mutating func plainLine() throws -> String {
        var text = ""
        while let c = peek(), c != "\n" {
            if c == ":", Self.isBlank(peek(1)) {
                throw error("unexpected “: ” inside a value; quote the value or move a nested mapping to its own line")
            }
            if c == "#", text.last == " " || text.last == "\t" { break }
            text.append(c)
            advance()
        }
        while text.last == " " || text.last == "\t" {
            text.removeLast()
        }
        return text
    }

    mutating func parseQuoted() throws -> String {
        let start = mark
        let quote = peek()!
        advance()
        var result = ""
        while true {
            guard let c = peek() else {
                throw error(quote == "\"" ? "unterminated double-quoted string" : "unterminated single-quoted string", at: start)
            }
            if c == quote {
                if quote == "'", peek(1) == "'" {
                    result.append("'")
                    advance(2)
                    continue
                }
                advance()
                return result
            }
            if quote == "\"", c == "\\" {
                if peek(1) == "\n" {
                    advance(2)
                    skipInlineSpaces()
                    continue
                }
                result += try parseEscape()
                continue
            }
            if c == " " || c == "\t" || c == "\n" {
                // Whitespace before a line break is dropped; the break folds to a space (or to
                // newlines when blank lines follow).
                var j = pos
                while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                if j < chars.count, chars[j] == "\n" {
                    advance(j - pos + 1)
                    var breaks = 0
                    while true {
                        var k = pos
                        while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
                        if k < chars.count, chars[k] == "\n" {
                            advance(k - pos + 1)
                            breaks += 1
                        } else {
                            break
                        }
                    }
                    skipInlineSpaces()
                    if column == 0, atDocumentBoundary { throw error("unterminated quoted string", at: start) }
                    result += breaks == 0 ? " " : String(repeating: "\n", count: breaks)
                } else {
                    result.append(contentsOf: chars[pos..<j])
                    advance(j - pos)
                }
                continue
            }
            result.append(c)
            advance()
        }
    }

    mutating func parseEscape() throws -> String {
        let start = mark
        advance()  // backslash
        guard let c = peek() else { throw error("unterminated escape sequence", at: start) }
        advance()
        switch c {
        case "0": return "\0"
        case "a": return "\u{07}"
        case "b": return "\u{08}"
        case "t", "\t": return "\t"
        case "n": return "\n"
        case "v": return "\u{0B}"
        case "f": return "\u{0C}"
        case "r": return "\r"
        case "e": return "\u{1B}"
        case " ": return " "
        case "\"": return "\""
        case "/": return "/"
        case "\\": return "\\"
        case "N": return "\u{85}"
        case "_": return "\u{A0}"
        case "L": return "\u{2028}"
        case "P": return "\u{2029}"
        case "x", "u", "U":
            let length = c == "x" ? 2 : c == "u" ? 4 : 8
            var hex = ""
            for _ in 0..<length {
                guard let h = peek(), h.isHexDigit else { throw error("invalid \\\(String(c)) escape: expected \(length) hex digits", at: start) }
                hex.append(h)
                advance()
            }
            guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                throw error("invalid \\\(String(c)) escape", at: start)
            }
            return String(Character(scalar))
        default:
            throw error("unknown escape sequence “\\\(String(c))”", at: start)
        }
    }

    /// `|` / `>` with optional chomping (`-` strip, `+` keep) and indentation (1–9) indicators.
    mutating func parseBlockScalar(parentIndent: Int) throws -> String {
        let headerMark = mark
        let folded = peek() == ">"
        advance()
        var chomp: Character = " "
        var explicitIndent: Int?
        for _ in 0..<2 {
            if let c = peek(), c == "-" || c == "+", chomp == " " {
                chomp = c
                advance()
            } else if let c = peek(), let d = c.wholeNumberValue, (1...9).contains(d), explicitIndent == nil {
                explicitIndent = d
                advance()
            }
        }
        skipInlineSpaces()
        skipComment()
        guard atEnd || peek() == "\n" else {
            throw error("invalid block scalar header; only “|” or “>” with “-”, “+” or a digit may precede the line break", at: headerMark)
        }
        advance()
        var contentIndent = explicitIndent.map { parentIndent >= 0 ? parentIndent + $0 : $0 }
        var lines: [String] = []
        var leadingEmptyIndent = 0
        var hadFinalBreak = false
        while !atEnd {
            var j = pos
            while j < chars.count, chars[j] == " " { j += 1 }
            let indent = j - pos
            var lineEnd = j
            while lineEnd < chars.count, chars[lineEnd] != "\n" { lineEnd += 1 }
            let isEmpty = chars[j..<lineEnd].allSatisfy { $0 == " " || $0 == "\t" }
            if contentIndent == nil {
                if isEmpty {
                    leadingEmptyIndent = max(leadingEmptyIndent, indent)
                    lines.append("")
                    advance(lineEnd - pos + 1)
                    hadFinalBreak = lineEnd < chars.count
                    continue
                }
                if indent <= parentIndent { break }
                if indent < leadingEmptyIndent {
                    throw error("a leading blank line of this block scalar is indented more than its text")
                }
                contentIndent = indent
            }
            let n = contentIndent!
            if isEmpty {
                // Spaces beyond the indentation of a blank line are content in literal scalars.
                lines.append(indent > n && !folded ? String(repeating: " ", count: indent - n) : "")
                advance(lineEnd - pos + 1)
                hadFinalBreak = lineEnd < chars.count
                continue
            }
            if indent < n { break }
            if indent == 0, (pos..<lineEnd).count >= 3, atDocumentBoundary { break }
            lines.append(String(chars[(pos + n)..<lineEnd]))
            advance(lineEnd - pos + 1)
            hadFinalBreak = lineEnd < chars.count
        }
        var trailing = 0
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
            trailing += 1
        }
        if lines.isEmpty {
            return chomp == "+" ? String(repeating: "\n", count: trailing) : ""
        }
        let body = folded ? Self.fold(lines) : lines.joined(separator: "\n")
        switch chomp {
        case "-": return body
        case "+": return body + "\n" + String(repeating: "\n", count: trailing)
        default: return body + (hadFinalBreak || trailing > 0 ? "\n" : "")
        }
    }

    /// Folding for `>` scalars: a single break between two normal lines becomes a space, blank
    /// lines become newlines, and more-indented lines keep their breaks.
    static func fold(_ lines: [String]) -> String {
        var result = ""
        var pendingBreaks = 0
        var previousMoreIndented = false
        var first = true
        for line in lines {
            if line.isEmpty {
                pendingBreaks += 1
                continue
            }
            let moreIndented = line.first == " " || line.first == "\t"
            if first {
                result += String(repeating: "\n", count: pendingBreaks)
            } else if pendingBreaks == 0 {
                result += moreIndented || previousMoreIndented ? "\n" : " "
            } else {
                result += (moreIndented || previousMoreIndented ? "\n" : "") + String(repeating: "\n", count: pendingBreaks)
            }
            result += line
            pendingBreaks = 0
            previousMoreIndented = moreIndented
            first = false
        }
        return result
    }

    // MARK: Anchors, aliases, tags

    enum Tag: Equatable {
        case string, int, float, bool, null, other
    }

    mutating func parseProperties(inFlow: Bool) throws -> (anchor: String?, tag: Tag?) {
        var anchor: String?
        var tag: Tag?
        while let c = peek(), c == "&" || c == "!" {
            let start = mark
            advance()
            var name = ""
            while let n = peek(), !Self.isBlank(n), !(inFlow && Self.isFlowIndicator(n)) {
                name.append(n)
                advance()
            }
            if c == "&" {
                guard !name.isEmpty else { throw error("an anchor (&) needs a name", at: start) }
                guard anchor == nil else { throw error("a node can only have one anchor", at: start) }
                anchor = name
            } else {
                guard tag == nil else { throw error("a node can only have one tag", at: start) }
                switch name {
                case "!str", "<tag:yaml.org,2002:str>": tag = .string
                case "!int", "<tag:yaml.org,2002:int>": tag = .int
                case "!float", "<tag:yaml.org,2002:float>": tag = .float
                case "!bool", "<tag:yaml.org,2002:bool>": tag = .bool
                case "!null", "<tag:yaml.org,2002:null>": tag = .null
                default: tag = .other  // e.g. Compose's `!reset` / `!override`: no meaning for a single file
                }
            }
            if inFlow {
                skipFlowWhitespace()
            } else {
                skipInlineSpaces()
            }
        }
        return (anchor, tag)
    }

    func apply(_ tag: Tag?, to value: YAMLValue) throws -> YAMLValue {
        guard let tag, tag != .other, tag != .string else {
            if tag == .string, let text = value.scalarText { return .string(text) }
            return value
        }
        let text = value.scalarText ?? ""
        switch tag {
        case .int:
            if case .int = value { return value }
            if let resolved = Self.resolveInt(text) { return .int(resolved) }
            throw error("“\(text)” is not an integer (!!int)")
        case .float:
            if let d = value.double { return .float(d) }
            if case .float(let d) = Self.resolve(plain: text) { return .float(d) }
            throw error("“\(text)” is not a number (!!float)")
        case .bool:
            if case .bool = value { return value }
            if case .bool(let b) = Self.resolve(plain: text) { return .bool(b) }
            throw error("“\(text)” is not a boolean (!!bool)")
        case .null:
            return .null
        case .string, .other:
            return value
        }
    }

    mutating func parseAlias() throws -> YAMLValue {
        let start = mark
        advance()
        var name = ""
        while let c = peek(), !Self.isBlank(c), !Self.isFlowIndicator(c) {
            name.append(c)
            advance()
        }
        guard let value = anchors[name] else {
            throw error(name.isEmpty ? "an alias (*) needs a name" : "unknown alias “*\(name)” (anchors must be defined before use)", at: start)
        }
        return value
    }

    // MARK: Flow collections

    mutating func skipFlowWhitespace() {
        while let c = peek() {
            if c == " " || c == "\t" || c == "\n" {
                advance()
            } else if c == "#", pos == 0 || Self.isBlank(chars[pos - 1]) {
                skipComment()
            } else {
                break
            }
        }
    }

    mutating func parseFlowNode() throws -> YAMLValue {
        let (anchor, tag) = try parseProperties(inFlow: true)
        var value: YAMLValue
        switch peek() {
        case "[": value = try parseFlowSequence()
        case "{": value = try parseFlowMapping()
        case "\"", "'": value = .string(try parseQuoted())
        case "*": value = try parseAlias()
        case nil: throw error("unexpected end of file inside a flow collection")
        case ",", "]", "}":
            value = tag == .string ? .string("") : .null
        default:
            let text = try parseFlowPlain()
            value = tag == .string ? .string(text) : Self.resolve(plain: text)
        }
        value = try apply(tag, to: value)
        if let anchor { anchors[anchor] = value }
        return value
    }

    /// A plain scalar inside `[...]` / `{...}`: ends at `,`, a bracket, `: ` or a comment.
    mutating func parseFlowPlain() throws -> String {
        var text = ""
        while let c = peek() {
            if Self.isFlowIndicator(c) { break }
            if c == ":", Self.isBlank(peek(1)) || Self.isFlowIndicator(peek(1)) { break }
            if c == "#", text.last == " " || text.last == "\t" || text.last == "\n" { break }
            if c == "\n" {
                // Multi-line plain scalar: the break folds into a space.
                var j = pos
                while j < chars.count, chars[j] == " " || chars[j] == "\t" || chars[j] == "\n" { j += 1 }
                if j >= chars.count || Self.isFlowIndicator(chars[j]) || chars[j] == "#" || chars[j] == ":" { break }
                advance(j - pos)
                while text.last == " " || text.last == "\t" { text.removeLast() }
                text.append(" ")
                continue
            }
            text.append(c)
            advance()
        }
        while let last = text.last, last == " " || last == "\t" { text.removeLast() }
        if text.isEmpty { throw error("expected a value") }
        return text
    }

    /// Key text of a flow entry: plain scalars keep their spelling (`80`, `null`).
    mutating func parseFlowKey() throws -> (String, Bool) {
        switch peek() {
        case "\"", "'": return (try parseQuoted(), false)
        case "[", "{": throw error("collections can't be used as mapping keys")
        case "?": throw error("complex mapping keys (“? ”) aren't supported")
        case "*":
            let alias = try parseAlias()
            guard let text = alias.scalarText else { throw error("an alias used as a key must refer to a scalar") }
            return (text, false)
        default:
            let text = try parseFlowPlain()
            return (text, text == "<<")
        }
    }

    mutating func parseFlowSequence() throws -> YAMLValue {
        let start = mark
        advance()  // "["
        var items: [YAMLValue] = []
        while true {
            skipFlowWhitespace()
            guard let c = peek() else { throw error("unterminated flow sequence “[”", at: start) }
            if c == "]" {
                advance()
                break
            }
            if c == "," { throw error("unexpected “,” in a flow sequence") }
            let isPlainKey = !"\"'[{*&!".contains(c)
            let itemMark = mark
            var item: YAMLValue
            if isPlainKey, flowPairAhead() {
                let (key, _) = try parseFlowKey()
                item = try flowPairValue(key: key)
            } else {
                item = try parseFlowNode()
                skipFlowWhitespace()
                if peek() == ":" {
                    guard let key = item.scalarText else { throw error("collections can't be used as mapping keys", at: itemMark) }
                    item = try flowPairValue(key: key)
                }
            }
            items.append(item)
            skipFlowWhitespace()
            if peek() == "," {
                advance()
            } else if peek() == "]" {
                advance()
                break
            } else if atEnd {
                throw error("unterminated flow sequence “[”", at: start)
            } else {
                throw error("expected “,” or “]” in a flow sequence")
            }
        }
        return .sequence(items)
    }

    /// Single-pair mapping inside a flow sequence (`[a: 1]`).
    mutating func flowPairValue(key: String) throws -> YAMLValue {
        skipFlowWhitespace()
        guard peek() == ":" else { return .mapping(YAMLMapping([.init(key: key, value: .null)])) }
        advance()
        skipFlowWhitespace()
        let value: YAMLValue = peek() == "," || peek() == "]" ? .null : try parseFlowNode()
        return .mapping(YAMLMapping([.init(key: key, value: value)]))
    }

    /// Whether a plain scalar at the cursor is followed by `: ` before the next flow indicator.
    func flowPairAhead() -> Bool {
        var i = pos
        while i < chars.count {
            let c = chars[i]
            if Self.isFlowIndicator(c) || c == "\n" { return false }
            if c == ":", i + 1 >= chars.count || Self.isBlank(chars[i + 1]) || Self.isFlowIndicator(chars[i + 1]) { return true }
            i += 1
        }
        return false
    }

    mutating func parseFlowMapping() throws -> YAMLValue {
        let start = mark
        advance()  // "{"
        var items: [MappingItem] = []
        var seen: Set<String> = []
        while true {
            skipFlowWhitespace()
            guard let c = peek() else { throw error("unterminated flow mapping “{”", at: start) }
            if c == "}" {
                advance()
                break
            }
            if c == "," { throw error("unexpected “,” in a flow mapping") }
            let keyMark = mark
            let (key, isMerge) = try parseFlowKey()
            skipFlowWhitespace()
            var value = YAMLValue.null
            if peek() == ":" {
                advance()
                skipFlowWhitespace()
                if peek() != ",", peek() != "}" { value = try parseFlowNode() }
            }
            if isMerge {
                items.append(.merge(value, keyMark))
            } else {
                guard seen.insert(key).inserted else { throw error("duplicate key “\(key)”", at: keyMark) }
                items.append(.entry(key, value))
            }
            skipFlowWhitespace()
            if peek() == "," {
                advance()
            } else if peek() == "}" {
                advance()
                break
            } else if atEnd {
                throw error("unterminated flow mapping “{”", at: start)
            } else {
                throw error("expected “,” or “}” in a flow mapping")
            }
        }
        return .mapping(try buildMapping(items))
    }

    // MARK: Scalar resolution (YAML 1.2 core schema)

    static func resolve(plain text: String) -> YAMLValue {
        switch text {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF": return .float(.infinity)
        case "-.inf", "-.Inf", "-.INF": return .float(-.infinity)
        case ".nan", ".NaN", ".NAN": return .float(.nan)
        default: break
        }
        guard let first = text.first, first.isNumber || first == "-" || first == "+" || first == "." else {
            return .string(text)
        }
        if let i = resolveInt(text) { return .int(i) }
        if text.wholeMatch(of: /[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?/) != nil, let d = Double(text) {
            return .float(d)
        }
        return .string(text)
    }

    static func resolveInt(_ text: String) -> Int? {
        if text.wholeMatch(of: /[-+]?[0-9]+/) != nil { return Int(text.hasPrefix("+") ? String(text.dropFirst()) : text) }
        if text.hasPrefix("0o"), text.count > 2 { return Int(text.dropFirst(2), radix: 8) }
        if text.hasPrefix("0x"), text.count > 2 { return Int(text.dropFirst(2), radix: 16) }
        return nil
    }
}
