import Foundation

extension Sequence where Element == String {
    /// Names joined for a message in the user's language: "a, b, c" in English, "a、b和c" in
    /// Chinese, "a, b und c" in German (`ListFormatStyle`, narrow width).
    public var localizedList: String {
        Array(self).formatted(.list(type: .and, width: .narrow))
    }
}
