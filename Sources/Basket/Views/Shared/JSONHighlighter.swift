import AppKit
import BasketCore

/// Colours of highlighted JSON. Each token kind takes a system colour, moved toward black (light
/// mode) or white (dark mode) by the smallest step that reaches WCAG AA, 4.5:1, against the
/// text background the Inspect view draws (`ReadableColor`), so the hue stays recognisable and
/// the text stays readable. The colours are dynamic: an appearance change (macOS's or Settings ▸
/// General ▸ Appearance, or Increase Contrast) resolves them again.
///
/// | Token | Base | Light, on #FFFFFF | Dark, on #1E1E1E |
/// |---|---|---|---|
/// | object key | `systemPurple` | #C22DD6, 4.53:1 (base 4.17) | #DB34F2, 4.59:1 |
/// | string value | `systemTeal` | #00838C, 4.54:1 (base 2.16) | #00D2E0, 8.97:1 |
/// | number | `systemOrange` | #B1621B, 4.53:1 (base 2.31) | #FF9230, 7.47:1 |
/// | `true` `false` `null` | `systemBlue` | #0076DE, 4.52:1 (base 3.52) | #0091FF, 5.16:1 |
/// | punctuation `{ } [ ] : ,` | `secondaryLabelColor` | #767676, 4.54:1 (base 3.95) | #9A9A9A, 5.89:1 |
///
/// `textBackgroundColor` and the system colours as macOS 26 resolves them; the dark-mode bases
/// already pass and are used as is. `ContrastRatioTests` checks that system colours reach AA in
/// both appearances. Output that isn't JSON is plain `labelColor` (14.9:1 / 12.2:1).
enum JSONPalette {
    static let key = accessible(.systemPurple)
    static let string = accessible(.systemTeal)
    static let number = accessible(.systemOrange)
    static let literal = accessible(.systemBlue)
    static let punctuation = accessible(.secondaryLabelColor)

    static func color(for kind: JSONToken.Kind) -> NSColor {
        switch kind {
        case .key: key
        case .string: string
        case .number: number
        case .literal: literal
        }
    }

    private static func accessible(_ base: NSColor) -> NSColor {
        ReadableColor.make(base, on: [.textBackgroundColor])
    }
}

/// Turns formatted JSON into attributed text for the Inspect tab. Pure and thread-safe: large
/// documents are highlighted off the main thread.
enum JSONHighlighter {
    // Computed: NSFont isn't Sendable, and AppKit caches the instance anyway.
    static var font: NSFont { .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular) }

    /// Uncoloured text: shown at once, and for output that isn't JSON.
    static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }

    static func highlighted(_ json: FormattedJSON) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: JSONPalette.punctuation]
        let byKind: [JSONToken.Kind: [NSAttributedString.Key: Any]] = Dictionary(
            uniqueKeysWithValues: [JSONToken.Kind.key, .string, .number, .literal].map {
                ($0, [.font: font, .foregroundColor: JSONPalette.color(for: $0)])
            })
        let result = NSMutableAttributedString(string: json.text, attributes: base)
        result.beginEditing()
        for token in json.tokens {
            result.setAttributes(byKind[token.kind], range: NSRange(location: token.location, length: token.length))
        }
        result.endEditing()
        return result
    }

    /// Display columns of the longest line: ASCII counts one, any other character two (CJK and
    /// emoji are double width next to a monospaced font), so the estimate errs wide.
    static func widestLine(in text: String) -> Int {
        var widest = 0
        var current = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                widest = max(widest, current)
                current = 0
            } else if byte < 0x80 {
                current += 1
            } else if byte & 0xC0 != 0x80 {
                current += 2
            }
        }
        return max(widest, current)
    }
}
