import Foundation

/// JSON helpers shared by the CLI and fixture backends.
enum RawJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                if let date = parseDate(string) { return date }
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date \(string)")
            }
            // Foundation's default Date encoding (seconds since 2001) — older CLI builds.
            return Date(timeIntervalSinceReferenceDate: try container.decode(Double.self))
        }
        return decoder
    }

    static func encoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        return encoder
    }

    /// ISO-8601 with or without fractional seconds (the CLI emits both; image configs use nanoseconds).
    static func parseDate(_ string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
        if let date = try? Date.ISO8601FormatStyle().parse(string) { return date }
        // Fall back for fractional precision / offsets the format styles reject.
        let trimmed = string.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression)
        return try? Date.ISO8601FormatStyle().parse(trimmed)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, command: String) throws -> T {
        do {
            return try decoder().decode(type, from: data)
        } catch {
            throw BackendError.decodingFailed(command: command, detail: describe(error))
        }
    }

    /// Decodes a JSON array, skipping elements that fail to decode instead of failing the whole list.
    static func decodeList<T: Decodable>(_ type: T.Type, from data: Data, command: String) throws -> [T] {
        let trimmed = data.trimmingWhitespace()
        if trimmed.isEmpty { return [] }
        return try decode([Lossy<T>].self, from: trimmed, command: command).compactMap(\.value)
    }

    /// Re-indents JSON (sorted keys, unescaped slashes); returns the input unchanged if it isn't JSON.
    static func prettyPrinted(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(decoding: pretty, as: UTF8.self)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            "missing key '\(key.stringValue)' at \(path(context))"
        case DecodingError.typeMismatch(let type, let context):
            "type mismatch (\(type)) at \(path(context)): \(context.debugDescription)"
        case DecodingError.valueNotFound(let type, let context):
            "missing value (\(type)) at \(path(context))"
        case DecodingError.dataCorrupted(let context):
            "corrupted data at \(path(context)): \(context.debugDescription)"
        default:
            String(describing: error)
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? "<root>" : path
    }
}

/// Wraps an element so one undecodable entry doesn't sink the whole list.
struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// Coding key for dictionaries with dynamic keys (e.g. the mount `type` object).
struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        stringValue = string
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension Data {
    func trimmingWhitespace() -> Data {
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        guard let start = firstIndex(where: { !whitespace.contains($0) }),
              let end = lastIndex(where: { !whitespace.contains($0) })
        else { return Data() }
        return self[start...end]
    }
}
