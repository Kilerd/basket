import Foundation

/// A parsed YAML node (see `YAMLParser`). Scalars are resolved with the YAML 1.2 core schema, the
/// way Compose reads its files: `true`/`false`, integers, floats and `null`/`~`/empty become typed
/// values, quoted and block scalars always stay strings.
public indirect enum YAMLValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case float(Double)
    case string(String)
    case sequence([YAMLValue])
    case mapping(YAMLMapping)

    public var isNull: Bool { self == .null }

    public var mapping: YAMLMapping? {
        if case .mapping(let m) = self { return m }
        return nil
    }

    public var sequence: [YAMLValue]? {
        if case .sequence(let s) = self { return s }
        return nil
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The scalar as text (`8080` → "8080", `true` → "true"); nil for null and collections.
    public var scalarText: String? {
        switch self {
        case .string(let s): s
        case .int(let i): String(i)
        case .bool(let b): b ? "true" : "false"
        case .float(let d): YAMLValue.format(d)
        case .null, .sequence, .mapping: nil
        }
    }

    public var int: Int? {
        switch self {
        case .int(let i): i
        case .float(let d) where d == d.rounded() && abs(d) < 1e15: Int(d)
        case .string(let s): Int(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    public var double: Double? {
        switch self {
        case .int(let i): Double(i)
        case .float(let d): d
        case .string(let s): Double(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let b): b
        case .string(let s):
            switch s.lowercased() {
            case "true", "yes", "on": true
            case "false", "no", "off": false
            default: nil
            }
        default: nil
        }
    }

    /// Short type name for error messages.
    /// The kind with an article in the user's language ("a list", "an integer"): the object of
    /// “found …” in error messages.
    public var kindPhrase: String {
        switch self {
        case .null: String(localized: "a null value", bundle: .main, comment: "YAML value kind: “expected …, found a null value”")
        case .bool: String(localized: "a boolean", bundle: .main, comment: "YAML value kind: “expected …, found a boolean”")
        case .int: String(localized: "an integer", bundle: .main, comment: "YAML value kind: “expected …, found an integer”")
        case .float: String(localized: "a number", bundle: .main, comment: "YAML value kind: “expected …, found a number”")
        case .string: String(localized: "a string", bundle: .main, comment: "YAML value kind: “expected …, found a string”")
        case .sequence: String(localized: "a list", bundle: .main, comment: "YAML value kind: “expected …, found a list”")
        case .mapping: String(localized: "a mapping", bundle: .main, comment: "YAML value kind: “expected …, found a mapping”")
        }
    }

    public var kind: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .int: "integer"
        case .float: "number"
        case .string: "string"
        case .sequence: "list"
        case .mapping: "mapping"
        }
    }

    public subscript(key: String) -> YAMLValue? { mapping?[key] }

    static func format(_ value: Double) -> String {
        if value.isNaN { return ".nan" }
        if value.isInfinite { return value < 0 ? "-.inf" : ".inf" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }
}

/// A YAML mapping that keeps the file's key order.
public struct YAMLMapping: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public var key: String
        public var value: YAMLValue

        public init(key: String, value: YAMLValue) {
            self.key = key
            self.value = value
        }
    }

    public private(set) var entries: [Entry]

    public init(_ entries: [Entry] = []) {
        self.entries = entries
    }

    public init(_ pairs: KeyValuePairs<String, YAMLValue>) {
        entries = pairs.map { Entry(key: $0.key, value: $0.value) }
    }

    public var keys: [String] { entries.map(\.key) }
    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    public subscript(key: String) -> YAMLValue? {
        entries.first { $0.key == key }?.value
    }

    public func contains(_ key: String) -> Bool { entries.contains { $0.key == key } }

    /// Replaces the value of an existing key in place, or appends a new entry.
    public mutating func set(_ key: String, _ value: YAMLValue) {
        if let i = entries.firstIndex(where: { $0.key == key }) {
            entries[i].value = value
        } else {
            entries.append(Entry(key: key, value: value))
        }
    }
}

/// A YAML syntax error with a 1-based position.
public struct YAMLError: Error, LocalizedError, Sendable, Equatable {
    public var line: Int
    public var column: Int
    public var message: String

    public init(line: Int, column: Int, message: String) {
        self.line = line
        self.column = column
        self.message = message
    }

    public var errorDescription: String? {
        String(localized: "line \(line), column \(column): \(message)", bundle: .main,
               comment: "Position of a syntax error in a YAML file, then the problem")
    }
}
