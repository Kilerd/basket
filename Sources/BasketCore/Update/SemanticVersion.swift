import Foundation

/// A release version, strictly `X.Y.Z` (docs/updates.md): three decimal numbers without leading
/// zeros, no pre-release or build suffix.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Self.component(part) else { return nil }
            numbers.append(number)
        }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    /// Digits only, `0` or no leading zero, at most 9 digits (no overflow tricks).
    static func component(_ part: Substring) -> Int? {
        guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard part == "0" || part.first != "0" else { return nil }
        return Int(part)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// A macOS version such as `26`, `26.0` or `26.3.1` (`minimum_system_version`).
public struct SystemVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init(_ os: OperatingSystemVersion) {
        self.init(os.majorVersion, os.minorVersion, os.patchVersion)
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = SemanticVersion.component(part) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    public static var current: SystemVersion { SystemVersion(ProcessInfo.processInfo.operatingSystemVersion) }

    public var description: String { patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)" }

    public static func < (lhs: SystemVersion, rhs: SystemVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
