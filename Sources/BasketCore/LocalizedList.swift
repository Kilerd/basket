import Foundation

extension Sequence where Element == String {
    /// Names joined for a message in the user's language: "a, b, c" in English, "a、b和c" in
    /// Chinese, "a, b und c" in German (`ListFormatStyle`, narrow width).
    public var localizedList: String {
        Array(self).formatted(.list(type: .and, width: .narrow))
    }

    /// Names joined with the language's list separator and no conjunction ("a, b", "a、b"): for
    /// table cells, where "and" only costs width.
    public var compactList: String {
        joined(separator: ListSeparator.separator())
    }
}

public enum ListSeparator {
    /// The separator `ListFormatStyle` puts between the first two of three items in `locale`
    /// (", " in English and German, "、" in Chinese and Japanese).
    public static func separator(for locale: Locale = .current) -> String {
        let first = "\u{E000}", second = "\u{E001}"
        let list = [first, second, "\u{E002}"].formatted(.list(type: .and, width: .narrow).locale(locale))
        guard let start = list.range(of: first), let end = list.range(of: second), start.upperBound <= end.lowerBound
        else { return ", " }
        let separator = String(list[start.upperBound..<end.lowerBound])
        return separator.isEmpty ? ", " : separator
    }
}
