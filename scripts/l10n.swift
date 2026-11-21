// String Catalog helper for Basket (Resources/Localization/Localizable.xcstrings). Apple frameworks
// only; writes the catalog in the same layout as Xcode and `xcstringstool` (sorted keys, " : ").
//
//   swift scripts/l10n.swift check <catalog>                 every key translated in every language,
//                                                            placeholders match, no stale or empty keys
//   swift scripts/l10n.swift stats <catalog>                 keys and translations per language
//   swift scripts/l10n.swift missing <catalog> <lang>        JSON of the keys <lang> still needs
//   swift scripts/l10n.swift apply <catalog> <lang> <json>   merge translations from JSON
//   swift scripts/l10n.swift prune <catalog>                 drop keys marked stale
//   swift scripts/l10n.swift diff <catalog> <synced>         keys a sync would add or mark stale
//   swift scripts/l10n.swift format <catalog>                rewrite in the canonical layout
//
// `apply` JSON: { "<key>": "<translation>" } or, for plurals, { "<key>": { "one": "…", "other": "…" } }
// (CLDR categories: zero, one, two, few, many, other). Use positional specifiers (%1$@, %2$lld)
// when a translation has more than one placeholder.
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

// MARK: - Catalog I/O

typealias JSONObject = [String: Any]

func load(_ path: String) -> JSONObject {
    guard let data = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? JSONObject else { fail("\(path) is not a JSON object") }
    return object
}

/// Xcode's layout: two-space indent, `"key" : value`, keys in Swift `String` order, empty
/// objects as "{\n\n<indent>}", no newline at the end.
func serialize(_ value: Any, indent: String = "") -> String {
    let inner = indent + "  "
    switch value {
    case let dict as JSONObject:
        if dict.isEmpty { return "{\n\n\(indent)}" }
        let body = dict.keys.sorted().map { "\(inner)\(quote($0)) : \(serialize(dict[$0]!, indent: inner))" }
        return "{\n" + body.joined(separator: ",\n") + "\n\(indent)}"
    case let array as [Any]:
        if array.isEmpty { return "[\n\n\(indent)]" }
        return "[\n" + array.map { inner + serialize($0, indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
    case let string as String:
        return quote(string)
    case let number as NSNumber:
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        return number.stringValue
    default:
        fail("unsupported JSON value \(value)")
    }
}

func quote(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out + "\""
}

func save(_ catalog: JSONObject, to path: String) {
    do {
        try serialize(catalog).write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        fail("can't write \(path): \(error)")
    }
}

func strings(_ catalog: JSONObject) -> [String: JSONObject] {
    (catalog["strings"] as? [String: JSONObject]) ?? [:]
}

func sourceLanguage(_ catalog: JSONObject) -> String {
    (catalog["sourceLanguage"] as? String) ?? "en"
}

/// Every language that appears in the catalog, source language first.
func languages(_ catalog: JSONObject) -> [String] {
    var found = Set<String>()
    for entry in strings(catalog).values {
        for language in ((entry["localizations"] as? JSONObject) ?? [:]).keys { found.insert(language) }
    }
    let source = sourceLanguage(catalog)
    found.remove(source)
    return [source] + found.sorted()
}

// MARK: - Placeholders

/// printf placeholders of a format string, by position: "%@ has %lld" → [1: "@", 2: "int"].
func placeholders(_ format: String) -> [Int: String]? {
    let pattern = #/%(?:(\d+)\$)?[-+ 0#']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGaAcCsSp%])/#
    var result: [Int: String] = [:]
    var next = 1
    for match in format.matches(of: pattern) {
        let conversion = String(match.output.3)
        if conversion == "%" { continue }
        let kind: String
        switch conversion {
        case "@": kind = "@"
        case "d", "D", "i", "u", "U", "x", "X", "o", "O", "c", "C": kind = "int"
        case "f", "F", "e", "E", "g", "G", "a", "A": kind = "double"
        case "s", "S": kind = "cstring"
        default: kind = "pointer"
        }
        let position: Int
        if let explicit = match.output.1 { position = Int(explicit)! } else { position = next; next += 1 }
        if let existing = result[position], existing != kind { return nil }
        result[position] = kind
    }
    return result
}

/// Whether some placeholder has no explicit position ("%@" rather than "%1$@").
func hasImplicitPlaceholders(_ format: String) -> Bool {
    format.matches(of: #/%(\d+\$)?[-+ 0#']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGaAcCsSp%])/#)
        .contains { $0.output.1 == nil && $0.output.2 != "%" }
}

/// Whether a key holds text a translator has to look at (anything beyond placeholders,
/// digits and punctuation).
func needsTranslation(_ key: String, _ entry: JSONObject) -> Bool {
    if (entry["shouldTranslate"] as? Bool) == false { return false }
    let stripped = key.replacing(#/%(?:\d+\$)?[-+ 0#']*(?:\d+)?(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?[@dDiuUxXoOfFeEgGaAcCsSp%]/#, with: "")
    return stripped.unicodeScalars.contains { CharacterSet.letters.contains($0) }
}

/// Languages without plural categories for integers (CLDR: only "other").
let pluralFree: Set<String> = ["ja", "ko", "zh-Hans", "zh-Hant", "zh", "th", "vi", "id", "ms", "yue"]

// MARK: - Translations

enum Translation {
    case missing
    case plain(String, translated: Bool)
    case plural([String: String], translated: Bool)
}

func translation(_ entry: JSONObject, _ language: String) -> Translation {
    guard let localization = (entry["localizations"] as? JSONObject)?[language] as? JSONObject else { return .missing }
    if let unit = localization["stringUnit"] as? JSONObject, let value = unit["value"] as? String {
        return .plain(value, translated: (unit["state"] as? String) == "translated")
    }
    if let plural = (localization["variations"] as? JSONObject)?["plural"] as? JSONObject {
        var forms: [String: String] = [:]
        var translated = true
        for (category, variant) in plural {
            guard let unit = (variant as? JSONObject)?["stringUnit"] as? JSONObject, let value = unit["value"] as? String else { continue }
            forms[category] = value
            if (unit["state"] as? String) != "translated" { translated = false }
        }
        return forms.isEmpty ? .missing : .plural(forms, translated: translated)
    }
    return .missing
}

func isStale(_ entry: JSONObject) -> Bool { (entry["extractionState"] as? String) == "stale" }

// MARK: - Commands

func check(_ path: String) {
    let catalog = load(path)
    let entries = strings(catalog)
    let source = sourceLanguage(catalog)
    let targets = languages(catalog).filter { $0 != source }
    var problems: [String] = []
    var missingCount: [String: Int] = [:]

    for key in entries.keys.sorted() {
        let entry = entries[key]!
        if key.isEmpty { problems.append("empty key: use Text(verbatim: \"\") for empty text"); continue }
        if isStale(entry) { problems.append("stale key (no longer in the sources): \(quote(key))"); continue }
        guard let keyPlaceholders = placeholders(key) else {
            problems.append("key mixes placeholder types at one position: \(quote(key))"); continue
        }
        let sourcePlural: Bool
        switch translation(entry, source) {
        case .plural(let forms, _):
            sourcePlural = true
            if forms["one"] == nil || forms["other"] == nil {
                problems.append("[\(source)] plural needs \"one\" and \"other\": \(quote(key))")
            }
            for (category, form) in forms {
                problems += placeholderProblems(form, keyPlaceholders, language: "\(source):\(category)", key: key, exact: true)
            }
        case .plain(let value, _):
            sourcePlural = false
            problems += placeholderProblems(value, keyPlaceholders, language: source, key: key, exact: true)
        case .missing:
            sourcePlural = false
        }
        guard needsTranslation(key, entry) else { continue }
        for language in targets {
            switch translation(entry, language) {
            case .missing:
                missingCount[language, default: 0] += 1
                problems.append("[\(language)] not translated: \(quote(key))")
            case .plain(let value, let translated):
                if !translated || value.isEmpty {
                    missingCount[language, default: 0] += 1
                    problems.append("[\(language)] not marked translated: \(quote(key))")
                }
                if sourcePlural && !pluralFree.contains(language) {
                    problems.append("[\(language)] needs plural forms (one/other) like the English: \(quote(key))")
                }
                problems += placeholderProblems(value, keyPlaceholders, language: language, key: key, exact: true)
            case .plural(let forms, let translated):
                if !translated {
                    missingCount[language, default: 0] += 1
                    problems.append("[\(language)] plural not marked translated: \(quote(key))")
                }
                if forms["other"] == nil { problems.append("[\(language)] plural needs \"other\": \(quote(key))") }
                for (category, form) in forms {
                    problems += placeholderProblems(form, keyPlaceholders, language: "\(language):\(category)", key: key, exact: true)
                }
            }
        }
    }

    if problems.isEmpty {
        print("l10n: \(entries.count) keys, languages \(languages(catalog).joined(separator: " ")): complete")
        return
    }
    for problem in problems.prefix(200) { warn(problem) }
    if problems.count > 200 { warn("… and \(problems.count - 200) more") }
    let summary = targets.map { "\($0) \(missingCount[$0, default: 0])" }.joined(separator: ", ")
    fail("\(problems.count) localization problem(s); untranslated per language: \(summary)")
}

/// A translation must use all of the key's placeholders with the same types. Plural forms too:
/// `xcstringstool compile` rejects a plural form without the number ("an image").
func placeholderProblems(_ value: String, _ expected: [Int: String], language: String, key: String, exact: Bool) -> [String] {
    guard let found = placeholders(value) else { return ["[\(language)] placeholder types clash in \(quote(value))"] }
    let multiple = expected.count > 1
    var problems: [String] = []
    for (position, kind) in found where expected[position] != kind {
        problems.append("[\(language)] placeholder %\(position)$ (\(kind)) doesn't match the key \(quote(key)): \(quote(value))")
    }
    if exact {
        for position in expected.keys where found[position] == nil {
            problems.append("[\(language)] placeholder %\(position)$ missing in \(quote(value)) for \(quote(key))")
        }
    }
    if multiple, found.count > 1, hasImplicitPlaceholders(value) {
        problems.append("[\(language)] use positional placeholders (%1$@, %2$lld) with more than one: \(quote(value))")
    }
    return problems
}

func stats(_ path: String) {
    let catalog = load(path)
    let entries = strings(catalog).filter { !isStale($0.value) }
    let translatable = entries.filter { needsTranslation($0.key, $0.value) }
    print("keys: \(entries.count) (\(translatable.count) need translation)")
    for language in languages(catalog) {
        let done = translatable.filter {
            switch translation($0.value, language) {
            case .plain(_, true), .plural(_, true): true
            default: false
            }
        }.count
        let plurals = entries.filter { if case .plural = translation($0.value, language) { true } else { false } }.count
        print("  \(language): \(done) translated, \(plurals) with plural forms")
    }
}

func missing(_ path: String, _ language: String) {
    let catalog = load(path)
    let source = sourceLanguage(catalog)
    var out: JSONObject = [:]
    for (key, entry) in strings(catalog) where !isStale(entry) && needsTranslation(key, entry) {
        switch translation(entry, language) {
        case .plain(_, true), .plural(_, true): continue
        default: break
        }
        var item: JSONObject = [:]
        switch translation(entry, source) {
        case .plural(let forms, _): item[source] = forms
        case .plain(let value, _): item[source] = value
        case .missing: item[source] = key
        }
        if let comment = entry["comment"] as? String, !comment.isEmpty { item["comment"] = comment }
        out[key] = item
    }
    print(serialize(out))
}

func apply(_ path: String, _ language: String, _ jsonPath: String) {
    var catalog = load(path)
    var entries = strings(catalog)
    let updates = load(jsonPath)
    var applied = 0, unknown: [String] = []
    for (key, value) in updates {
        guard var entry = entries[key] else { unknown.append(key); continue }
        var localizations = (entry["localizations"] as? JSONObject) ?? [:]
        switch value {
        case let text as String:
            localizations[language] = ["stringUnit": ["state": "translated", "value": text]]
        case let forms as [String: String]:
            var plural: JSONObject = [:]
            for (category, text) in forms {
                guard ["zero", "one", "two", "few", "many", "other"].contains(category) else {
                    fail("\(quote(key)): \"\(category)\" is not a plural category")
                }
                plural[category] = ["stringUnit": ["state": "translated", "value": text]]
            }
            localizations[language] = ["variations": ["plural": plural]]
        default:
            fail("\(quote(key)): expected a string or an object of plural forms")
        }
        entry["localizations"] = localizations
        entries[key] = entry
        applied += 1
    }
    catalog["strings"] = entries
    save(catalog, to: path)
    print("applied \(applied) \(language) translation(s)")
    if !unknown.isEmpty {
        for key in unknown.sorted() { warn("not in the catalog (skipped): \(quote(key))") }
        fail("\(unknown.count) key(s) not in the catalog", code: 3)
    }
}

func prune(_ path: String) {
    var catalog = load(path)
    let entries = strings(catalog)
    let kept = entries.filter { !isStale($0.value) }
    catalog["strings"] = kept
    save(catalog, to: path)
    print("removed \(entries.count - kept.count) stale key(s)")
}

/// What a sync changed: keys added, keys newly marked stale, anything else rewritten.
func diff(_ oldPath: String, _ newPath: String) {
    let old = strings(load(oldPath)), new = strings(load(newPath))
    let added = new.keys.filter { old[$0] == nil }.sorted()
    let removed = old.keys.filter { new[$0] == nil }.sorted()
    let staled = new.keys.filter { key in old[key].map { !isStale($0) } == true && isStale(new[key]!) }.sorted()
    let revived = new.keys.filter { key in old[key].map(isStale) == true && !isStale(new[key]!) }.sorted()
    let changed = new.keys.filter { key in
        guard let before = old[key] else { return false }
        return !(before as NSDictionary).isEqual(to: new[key]!) && !staled.contains(key) && !revived.contains(key)
    }.sorted()
    for key in added { print("+ \(quote(key))") }
    for key in staled { print("stale \(quote(key))") }
    for key in revived { print("back in use \(quote(key))") }
    for key in removed { print("- \(quote(key))") }
    for key in changed { print("~ \(quote(key))") }
    if added.isEmpty && removed.isEmpty && staled.isEmpty && revived.isEmpty && changed.isEmpty { return }
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
switch (args.first, args.count) {
case ("check", 2): check(args[1])
case ("stats", 2): stats(args[1])
case ("missing", 3): missing(args[1], args[2])
case ("apply", 4): apply(args[1], args[2], args[3])
case ("prune", 2): prune(args[1])
case ("diff", 3): diff(args[1], args[2])
case ("format", 2): save(load(args[1]), to: args[1])
default:
    fail("usage: l10n.swift check|stats|prune|format <catalog> | missing <catalog> <lang> | apply <catalog> <lang> <json> | diff <catalog> <synced>", code: 64)
}
