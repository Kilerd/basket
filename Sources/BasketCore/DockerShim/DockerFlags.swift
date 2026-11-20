import Foundation

/// One docker flag the shim understands, and what it becomes for `container`.
struct DockerFlag: Sendable {
    /// Spellings with dashes, e.g. `["-p", "--publish"]`.
    let names: [String]
    let takesValue: Bool
    let rule: DockerFlagRule

    /// `spellings`: space-separated, e.g. `"-p --publish"`.
    init(_ spellings: String, value: Bool = false, _ rule: DockerFlagRule) {
        self.names = spellings.split(separator: " ").map(String.init)
        self.takesValue = value
        self.rule = rule
    }

    /// The long spelling (`--publish`), used in notes and for lookups by handlers.
    var canonical: String { names.first { $0.hasPrefix("--") } ?? names[0] }
}

enum DockerFlagRule: Sendable {
    /// Emit this `container` flag (with the value, for value flags).
    case emit(String)
    /// Same meaning as `container`'s default: drop silently.
    case ignore
    /// No `container` equivalent; drop and warn with this reason.
    case drop(String)
    /// Changes behaviour in a way `container` can't provide; refuse the command with this reason.
    case reject(String)
    /// The command handler reads this flag itself.
    case handled
    /// Custom translation of the value (nil for boolean flags).
    case custom(@Sendable (_ value: String?, _ spelling: String, _ out: inout FlagOutput) -> Void)
}

/// Translated flags of one command line.
struct FlagOutput: Sendable {
    var args: [String] = []
    var notes: [String] = []
    var error: String?

    mutating func note(_ text: String) {
        if !notes.contains(text) { notes.append(text) }
    }

    mutating func drop(_ spelling: String, _ reason: String) {
        note("ignoring \(spelling): \(reason)")
    }

    mutating func reject(_ spelling: String, _ reason: String) {
        if error == nil { error = "\(spelling) is not supported: \(reason)" }
    }
}

/// A parsed docker command line (pflag rules: `--flag=value`, `--flag value`, `-abc` clusters,
/// `-p8080:80`, `--` ends flags; with `interspersed == false` the first positional ends flags too).
struct ParsedDockerArgs: Sendable {
    struct Occurrence: Sendable {
        let flag: DockerFlag
        let spelling: String
        let value: String?
    }

    var flags: [Occurrence] = []
    var positionals: [String] = []
    var wantsHelp = false

    func has(_ canonical: String) -> Bool { flags.contains { $0.flag.canonical == canonical } }
    func values(_ canonical: String) -> [String] {
        flags.filter { $0.flag.canonical == canonical }.compactMap(\.value)
    }
    func last(_ canonical: String) -> String? { values(canonical).last }

    /// Applies every flag's rule in command-line order.
    func translateFlags() -> FlagOutput {
        var out = FlagOutput()
        for occurrence in flags {
            switch occurrence.flag.rule {
            case .emit(let name):
                out.args.append(name)
                if let value = occurrence.value { out.args.append(value) }
            case .ignore, .handled:
                break
            case .drop(let reason):
                out.drop(occurrence.spelling, reason)
            case .reject(let reason):
                out.reject(occurrence.spelling, reason)
            case .custom(let transform):
                transform(occurrence.value, occurrence.spelling, &out)
            }
        }
        return out
    }
}

enum DockerArgParseError: Error, Equatable {
    case unknownFlag(String)
    case missingValue(String)

    var message: String {
        switch self {
        case .unknownFlag(let flag): "unknown or unsupported flag \(flag)"
        case .missingValue(let flag): "flag needs an argument: \(flag)"
        }
    }
}

enum DockerArgParser {
    static func parse(
        _ args: [String], flags: [DockerFlag], interspersed: Bool = true
    ) -> Result<ParsedDockerArgs, DockerArgParseError> {
        var lookup: [String: DockerFlag] = [:]
        for flag in flags {
            for name in flag.names { lookup[name] = flag }
        }
        var parsed = ParsedDockerArgs()
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if arg == "--" {
                parsed.positionals += args[index...]
                break
            }
            if arg.hasPrefix("--") {
                let body = arg.dropFirst(2)
                let name = "--" + String(body.prefix { $0 != "=" })
                let inline = body.firstIndex(of: "=").map { String(body[body.index(after: $0)...]) }
                if name == "--help", lookup[name] == nil {
                    parsed.wantsHelp = true
                    continue
                }
                guard let flag = lookup[name] else { return .failure(.unknownFlag(name)) }
                if flag.takesValue {
                    if let inline {
                        parsed.flags.append(.init(flag: flag, spelling: name, value: inline))
                    } else if index < args.count {
                        parsed.flags.append(.init(flag: flag, spelling: name, value: args[index]))
                        index += 1
                    } else {
                        return .failure(.missingValue(name))
                    }
                } else if !isFalse(inline) {
                    parsed.flags.append(.init(flag: flag, spelling: name, value: nil))
                }
                continue
            }
            if arg.hasPrefix("-"), arg.count > 1 {
                var rest = Substring(arg.dropFirst())
                while let char = rest.first {
                    rest = rest.dropFirst()
                    let name = "-\(char)"
                    guard let flag = lookup[name] else {
                        if char == "h" {
                            parsed.wantsHelp = true
                            continue
                        }
                        return .failure(.unknownFlag(name))
                    }
                    guard flag.takesValue else {
                        parsed.flags.append(.init(flag: flag, spelling: name, value: nil))
                        continue
                    }
                    if rest.first == "=" { rest = rest.dropFirst() }
                    if !rest.isEmpty {
                        parsed.flags.append(.init(flag: flag, spelling: name, value: String(rest)))
                    } else if index < args.count {
                        parsed.flags.append(.init(flag: flag, spelling: name, value: args[index]))
                        index += 1
                    } else {
                        return .failure(.missingValue(name))
                    }
                    break
                }
                continue
            }
            parsed.positionals.append(arg)
            if !interspersed {
                parsed.positionals += args[index...]
                break
            }
        }
        return .success(parsed)
    }

    private static func isFalse(_ inline: String?) -> Bool {
        guard let inline else { return false }
        return ["false", "0", "f", "F", "FALSE", "False"].contains(inline)
    }
}
