import Foundation

/// A highlightable piece of formatted JSON. Everything outside the tokens is punctuation
/// (`{ } [ ] : ,`) or whitespace.
public struct JSONToken: Sendable, Hashable {
    public enum Kind: UInt8, Sendable {
        /// An object key, quotes included.
        case key
        /// A string value, quotes included.
        case string
        case number
        /// `true`, `false` or `null`.
        case literal
    }

    public var kind: Kind
    /// UTF-16 offset into `FormattedJSON.text` (what `NSRange` and `NSAttributedString` use).
    public var location: Int
    /// Length in UTF-16 code units.
    public var length: Int

    public init(kind: Kind, location: Int, length: Int) {
        self.kind = kind
        self.location = location
        self.length = length
    }
}

public struct FormattedJSON: Sendable, Equatable {
    public var text: String
    /// In document order, non-overlapping.
    public var tokens: [JSONToken]
}

/// Re-emits a JSON document in one pass: two-space indentation, `"key": value`, `[]` / `{}` for
/// empty containers. Keys keep their order; strings (escapes included) and numbers are copied
/// byte for byte. Linear in the input; nesting depth only costs a stack entry per level.
public enum JSONFormatter {
    /// The formatted document and its tokens, or nil if `text` isn't exactly one JSON value
    /// (RFC 8259; surrounding whitespace allowed).
    public static func format(_ text: String, indentWidth: Int = 2) -> FormattedJSON? {
        var text = text
        text.makeContiguousUTF8()
        return text.utf8.withContiguousStorageIfAvailable { bytes -> FormattedJSON? in
            var formatter = Formatter(input: bytes, indentWidth: max(0, indentWidth))
            return formatter.run()
        } ?? nil
    }

    /// The formatted text, or `text` unchanged if it isn't JSON.
    public static func tidy(_ text: String) -> String {
        format(text)?.text ?? text
    }
}

// MARK: - Tokenizer + printer

private enum Byte {
    static let quote: UInt8 = 0x22, backslash: UInt8 = 0x5C, slash: UInt8 = 0x2F
    static let openBrace: UInt8 = 0x7B, closeBrace: UInt8 = 0x7D
    static let openBracket: UInt8 = 0x5B, closeBracket: UInt8 = 0x5D
    static let colon: UInt8 = 0x3A, comma: UInt8 = 0x2C
    static let space: UInt8 = 0x20, tab: UInt8 = 0x09, newline: UInt8 = 0x0A, carriageReturn: UInt8 = 0x0D
    static let minus: UInt8 = 0x2D, plus: UInt8 = 0x2B, dot: UInt8 = 0x2E
    static let zero: UInt8 = 0x30, nine: UInt8 = 0x39
    static let lowerE: UInt8 = 0x65, upperE: UInt8 = 0x45
    static let lowerU: UInt8 = 0x75
}

private struct Formatter {
    let input: UnsafeBufferPointer<UInt8>
    let indentWidth: Int
    var position = 0
    var output: [UInt8] = []
    /// UTF-16 length of `output` so far.
    var utf16Count = 0
    var tokens: [JSONToken] = []
    /// Open containers, innermost last: true = object, false = array.
    var stack: [Bool] = []

    init(input: UnsafeBufferPointer<UInt8>, indentWidth: Int) {
        self.input = input
        self.indentWidth = indentWidth
        // Re-indenting usually grows compact JSON and shrinks the CLI's padded pretty-print.
        output.reserveCapacity(input.count + input.count / 2)
        tokens.reserveCapacity(input.count / 16)
    }

    mutating func run() -> FormattedJSON? {
        guard document() else { return nil }
        return FormattedJSON(text: String(decoding: output, as: UTF8.self), tokens: tokens)
    }

    /// The whole grammar as a loop over an explicit stack, so deep nesting can't overflow the
    /// call stack.
    private mutating func document() -> Bool {
        var expectingValue = true
        while true {
            if expectingValue {
                skipWhitespace()
                guard position < input.count else { return false }
                switch input[position] {
                case Byte.openBrace, Byte.openBracket:
                    let isObject = input[position] == Byte.openBrace
                    let close = isObject ? Byte.closeBrace : Byte.closeBracket
                    position += 1
                    skipWhitespace()
                    if position < input.count, input[position] == close {
                        position += 1
                        emit(isObject ? Byte.openBrace : Byte.openBracket)
                        emit(close)
                    } else {
                        emit(isObject ? Byte.openBrace : Byte.openBracket)
                        stack.append(isObject)
                        newline()
                        if isObject {
                            guard member() else { return false }
                        }
                        continue
                    }
                case Byte.quote:
                    guard string(as: .string) else { return false }
                case Byte.minus, Byte.zero...Byte.nine:
                    guard number() else { return false }
                case 0x74: // t
                    guard literal("true") else { return false }
                case 0x66: // f
                    guard literal("false") else { return false }
                case 0x6E: // n
                    guard literal("null") else { return false }
                default:
                    return false
                }
                expectingValue = false
            }
            // A value just ended: a separator, the end of its container, or the end of input.
            skipWhitespace()
            guard let isObject = stack.last else { return position == input.count }
            guard position < input.count else { return false }
            switch input[position] {
            case Byte.comma:
                position += 1
                emit(Byte.comma)
                newline()
                if isObject {
                    guard member() else { return false }
                }
                expectingValue = true
            case Byte.closeBrace where isObject, Byte.closeBracket where !isObject:
                let close = input[position]
                position += 1
                stack.removeLast()
                newline()
                emit(close)
            default:
                return false
            }
        }
    }

    /// `"key":` up to (not including) the value.
    private mutating func member() -> Bool {
        skipWhitespace()
        guard position < input.count, input[position] == Byte.quote, string(as: .key) else { return false }
        skipWhitespace()
        guard position < input.count, input[position] == Byte.colon else { return false }
        position += 1
        emit(Byte.colon)
        emit(Byte.space)
        return true
    }

    private mutating func skipWhitespace() {
        while position < input.count {
            switch input[position] {
            case Byte.space, Byte.tab, Byte.newline, Byte.carriageReturn: position += 1
            default: return
            }
        }
    }

    private mutating func emit(_ byte: UInt8) {
        output.append(byte)
        utf16Count += 1
    }

    private mutating func newline() {
        output.append(Byte.newline)
        let width = stack.count * indentWidth
        output.append(contentsOf: repeatElement(Byte.space, count: width))
        utf16Count += 1 + width
    }

    /// Copies `input[start..<position]` and records it as a token.
    private mutating func copyToken(_ kind: JSONToken.Kind, from start: Int, utf16Length: Int) {
        output.append(contentsOf: UnsafeBufferPointer(rebasing: input[start..<position]))
        tokens.append(JSONToken(kind: kind, location: utf16Count, length: utf16Length))
        utf16Count += utf16Length
    }

    private mutating func string(as kind: JSONToken.Kind) -> Bool {
        let start = position
        position += 1 // opening quote
        var utf16Length = 1
        while position < input.count {
            let byte = input[position]
            switch byte {
            case Byte.quote:
                position += 1
                copyToken(kind, from: start, utf16Length: utf16Length + 1)
                return true
            case Byte.backslash:
                guard position + 1 < input.count else { return false }
                switch input[position + 1] {
                case Byte.quote, Byte.backslash, Byte.slash,
                     0x62, 0x66, 0x6E, 0x72, 0x74: // b f n r t
                    position += 2
                    utf16Length += 2
                case Byte.lowerU:
                    guard position + 5 < input.count,
                          (2...5).allSatisfy({ Self.isHexDigit(input[position + $0]) }) else { return false }
                    position += 6
                    utf16Length += 6
                default:
                    return false
                }
            case 0..<0x20:
                return false // control characters must be escaped
            default:
                // UTF-8 → UTF-16: every scalar's lead byte counts one unit, 4-byte scalars two.
                if byte & 0xC0 != 0x80 { utf16Length += byte >= 0xF0 ? 2 : 1 }
                position += 1
            }
        }
        return false
    }

    private mutating func number() -> Bool {
        let start = position
        if input[position] == Byte.minus { position += 1 }
        guard position < input.count, Self.isDigit(input[position]) else { return false }
        if input[position] == Byte.zero {
            position += 1
        } else {
            skipDigits()
        }
        if position < input.count, input[position] == Byte.dot {
            position += 1
            guard position < input.count, Self.isDigit(input[position]) else { return false }
            skipDigits()
        }
        if position < input.count, input[position] == Byte.lowerE || input[position] == Byte.upperE {
            position += 1
            if position < input.count, input[position] == Byte.plus || input[position] == Byte.minus { position += 1 }
            guard position < input.count, Self.isDigit(input[position]) else { return false }
            skipDigits()
        }
        copyToken(.number, from: start, utf16Length: position - start)
        return true
    }

    private mutating func skipDigits() {
        while position < input.count, Self.isDigit(input[position]) { position += 1 }
    }

    private mutating func literal(_ word: StaticString) -> Bool {
        let count = word.utf8CodeUnitCount
        guard position + count <= input.count else { return false }
        let expected = UnsafeBufferPointer(start: word.utf8Start, count: count)
        for offset in 0..<count where input[position + offset] != expected[offset] { return false }
        let start = position
        position += count
        copyToken(.literal, from: start, utf16Length: count)
        return true
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= Byte.zero && byte <= Byte.nine }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    }
}
