import CoreText
import Foundation

/// Measures single-line text width with the system font (CoreText: thread-safe, no AppKit).
public enum TextMeasure {
    public static func width(of text: String, fontSize: Double) -> Double {
        guard !text.isEmpty else { return 0 }
        let font = CTFontCreateUIFontForLanguage(.system, CGFloat(fontSize), nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, CGFloat(fontSize), nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        return Double(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// System font sizes and the height SwiftUI/AppKit give a single line of each (measured on
    /// macOS 26 with `capture-demo`: 10→13, 11→14, 12→15, 13→16, 14→17, 15→19, 17→20 pt).
    static let lineHeights: [(fontSize: Double, lineHeight: Double)] = [
        (10, 13), (11, 14), (12, 15), (13, 16), (14, 17), (15, 19), (17, 20),
    ]

    /// Best guess at the font of a text frame: `(fontSize, lines)`.
    ///
    /// A frame up to one 17 pt line tall is a single line of the size whose line height is
    /// closest (ties go to the smaller font, which under- rather than over-reports truncation).
    /// Taller frames are either several lines or a large title; both are judged as wrapped 10 pt
    /// lines, which only flags gross overflow.
    public static func estimateFont(forFrameHeight height: Double) -> (fontSize: Double, lines: Int) {
        if height <= 20.5 {
            var best = lineHeights[0]
            for entry in lineHeights where abs(entry.lineHeight - height) < abs(best.lineHeight - height) {
                best = entry
            }
            return (best.fontSize, 1)
        }
        return (10, max(1, Int((height + 1) / 13)))
    }
}
