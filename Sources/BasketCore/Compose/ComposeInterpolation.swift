import Foundation

/// Compose variable interpolation: `$VAR`, `${VAR}`, `${VAR:-default}`, `${VAR-default}`,
/// `${VAR:?error}`, `${VAR?error}`, `${VAR:+replacement}`, `${VAR+replacement}` and `$$` for a
/// literal `$`. Defaults may nest (`${A:-${B}}`). Only values are interpolated, never keys.
public enum ComposeInterpolation {
    /// `unset` collects variables that were referenced without a default and aren't set.
    public static func interpolate(
        _ text: String, path: String, unset: inout [String], lookup: (String) -> String?
    ) throws -> String {
        guard text.contains("$") else { return text }
        let chars = Array(text)
        var result = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "$" else {
                result.append(c)
                i += 1
                continue
            }
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if next == "$" {
                result.append("$")
                i += 2
            } else if next == "{" {
                var depth = 1
                var j = i + 2
                while j < chars.count {
                    if chars[j] == "$", j + 1 < chars.count, chars[j + 1] == "{" {
                        depth += 1
                        j += 2
                        continue
                    }
                    if chars[j] == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    j += 1
                }
                guard j < chars.count else {
                    throw ComposeError.invalid(path: path, message: "unterminated “${” in “\(text)”; use “$$” for a literal $")
                }
                result += try braced(String(chars[(i + 2)..<j]), text: text, path: path, unset: &unset, lookup: lookup)
                i = j + 1
            } else if let n = next, n == "_" || n.isASCII && n.isLetter {
                var j = i + 1
                while j < chars.count, chars[j] == "_" || chars[j].isASCII && (chars[j].isLetter || chars[j].isNumber) { j += 1 }
                let name = String(chars[(i + 1)..<j])
                if let value = lookup(name) {
                    result += value
                } else if !unset.contains(name) {
                    unset.append(name)
                }
                i = j
            } else {
                throw ComposeError.invalid(path: path, message: "invalid “$” in “\(text)”; use “$$” for a literal $")
            }
        }
        return result
    }

    private static func braced(
        _ body: String, text: String, path: String, unset: inout [String], lookup: (String) -> String?
    ) throws -> String {
        let nameEnd = body.firstIndex { !($0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber)) } ?? body.endIndex
        let name = String(body[..<nameEnd])
        guard let first = name.first, first == "_" || first.isLetter else {
            throw ComposeError.invalid(path: path, message: "invalid variable “${\(body)}” in “\(text)”")
        }
        let rest = body[nameEnd...]
        let value = lookup(name)
        if rest.isEmpty {
            if value == nil, !unset.contains(name) { unset.append(name) }
            return value ?? ""
        }
        let colon = rest.hasPrefix(":")
        let op = colon ? rest.dropFirst().first : rest.first
        let argument = String(rest.dropFirst(colon ? 2 : 1))
        // With a colon, an empty value counts as unset.
        let isSet = colon ? !(value ?? "").isEmpty : value != nil
        switch op {
        case "-":
            return isSet ? value! : try interpolate(argument, path: path, unset: &unset, lookup: lookup)
        case "+":
            return isSet ? try interpolate(argument, path: path, unset: &unset, lookup: lookup) : ""
        case "?":
            guard isSet else {
                throw ComposeError.missingVariable(
                    name: name, message: try interpolate(argument, path: path, unset: &unset, lookup: lookup), path: path)
            }
            return value!
        default:
            throw ComposeError.invalid(path: path, message: "invalid variable “${\(body)}” in “\(text)”")
        }
    }

    /// Interpolates every string scalar in `value` (mapping keys stay as written).
    public static func interpolate(
        _ value: YAMLValue, path: String, unset: inout [String], lookup: (String) -> String?
    ) throws -> YAMLValue {
        switch value {
        case .string(let s):
            return .string(try interpolate(s, path: path, unset: &unset, lookup: lookup))
        case .sequence(let items):
            return .sequence(try items.enumerated().map {
                try interpolate($0.element, path: "\(path)[\($0.offset)]", unset: &unset, lookup: lookup)
            })
        case .mapping(let mapping):
            var result = YAMLMapping()
            for entry in mapping.entries {
                // Extension fields (x-…) are templates for anchors; they're never used directly.
                let child = path.isEmpty ? entry.key : "\(path).\(entry.key)"
                let interpolated = entry.key.hasPrefix("x-")
                    ? entry.value : try interpolate(entry.value, path: child, unset: &unset, lookup: lookup)
                result.set(entry.key, interpolated)
            }
            return .mapping(result)
        default:
            return value
        }
    }
}

/// `.env` / `env_file` syntax: `KEY=value`, optional `export `, `#` comments, single quotes
/// (literal), double quotes (escapes and `${VAR}` expansion), unquoted values (trimmed, ` #`
/// starts a comment, `${VAR}` expanded). A bare `KEY` has no value (nil).
public enum ComposeDotEnv {
    public static func parse(_ text: String, file: String, lookup: (String) -> String?) throws -> [(key: String, value: String?)] {
        var result: [(key: String, value: String?)] = []
        var defined: [String: String] = [:]
        let resolve: (String) -> String? = { defined[$0] ?? lookup($0) }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var index = 0
        while index < lines.count {
            let number = index + 1
            var line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else {
                guard line.allSatisfy({ $0 == "_" || $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else {
                    throw ComposeError.invalid(path: "\(file):\(number)", message: "expected KEY=value")
                }
                result.append((line, nil))
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" ") else {
                throw ComposeError.invalid(path: "\(file):\(number)", message: "invalid variable name “\(key)”")
            }
            var raw = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            var value: String
            if let quote = raw.first, quote == "'" || quote == "\"" {
                // Quoted values may span lines.
                while !closesQuote(raw, quote), index < lines.count {
                    raw += "\n" + lines[index]
                    index += 1
                }
                guard closesQuote(raw, quote), let close = closingQuoteIndex(raw, quote) else {
                    throw ComposeError.invalid(path: "\(file):\(number)", message: "unterminated \(quote) quote")
                }
                let inner = String(raw[raw.index(after: raw.startIndex)..<close])
                if quote == "'" {
                    value = inner
                } else {
                    var unset: [String] = []
                    value = try ComposeInterpolation.interpolate(
                        unescape(inner), path: "\(file):\(number)", unset: &unset, lookup: resolve)
                }
            } else {
                if let comment = raw.range(of: " #") { raw = String(raw[..<comment.lowerBound]) }
                var unset: [String] = []
                value = try ComposeInterpolation.interpolate(
                    raw.trimmingCharacters(in: .whitespaces), path: "\(file):\(number)", unset: &unset, lookup: resolve)
            }
            defined[key] = value
            result.append((key, value))
        }
        return result
    }

    private static func closingQuoteIndex(_ raw: String, _ quote: Character) -> String.Index? {
        var i = raw.index(after: raw.startIndex)
        while i < raw.endIndex {
            if quote == "\"", raw[i] == "\\" {
                i = raw.index(after: i)
                if i < raw.endIndex { i = raw.index(after: i) }
                continue
            }
            if raw[i] == quote { return i }
            i = raw.index(after: i)
        }
        return nil
    }

    private static func closesQuote(_ raw: String, _ quote: Character) -> Bool {
        closingQuoteIndex(raw, quote) != nil
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var escaped = false
        for c in text {
            if escaped {
                switch c {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                default: result.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                result.append(c)
            }
        }
        return result
    }
}

/// POSIX-style word splitting for `command: "npm run start"` (quotes and backslashes honoured).
public enum ComposeShell {
    public static func split(_ line: String, path: String = "command") throws -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var inWord = false
        var escaped = false
        for ch in line {
            if escaped {
                // Inside double quotes a backslash only escapes $ ` " \ and a line break.
                if quote == "\"", !"$`\"\\\n".contains(ch) { current.append("\\") }
                current.append(ch)
                escaped = false
                inWord = true
                continue
            }
            if ch == "\\", quote != "'" {
                escaped = true
                continue
            }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                inWord = true
                continue
            }
            if ch.isWhitespace {
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
                continue
            }
            current.append(ch)
            inWord = true
        }
        if quote != nil || escaped {
            throw ComposeError.invalid(path: path, message: "unterminated quote or escape in “\(line)”")
        }
        if inWord { words.append(current) }
        return words
    }
}
