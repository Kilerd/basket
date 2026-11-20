import Foundation

/// Translates a docker command line into apple/container commands — the brain of the `docker` shim
/// (`basket-docker`). Pure: no I/O, no environment; `docs/docker-shim.md` documents the mapping.
///
/// Flags with a `container` equivalent are translated, flags without one are dropped with a note
/// (`--restart`, `--health-*`, `--log-*`), and flags whose absence would change what the user gets
/// (`--privileged`, `--device`, `--network host`, `-P`, …) make the command `.unsupported`.
public enum DockerCommandTranslator {
    public struct Options: Sendable, Equatable {
        /// Platform used for `docker pull` without `--platform` (Docker pulls only the host's variant;
        /// `container image pull` would fetch every platform of a multi-arch image).
        public var hostPlatform: String
        /// Executable that handles `docker compose …` (the hook for Basket's Compose); nil = unsupported.
        public var composeExecutable: String?

        public init(hostPlatform: String = DockerCommandTranslator.hostPlatform, composeExecutable: String? = nil) {
            self.hostPlatform = hostPlatform
            self.composeExecutable = composeExecutable
        }
    }

    #if arch(x86_64)
    public static let hostPlatform = "linux/amd64"
    #else
    public static let hostPlatform = "linux/arm64"
    #endif

    public static func translate(_ args: [String]) -> DockerTranslation {
        translate(args, options: Options())
    }

    public static func translate(_ args: [String], options: Options) -> DockerTranslation {
        do {
            return try translateGlobal(args, options)
        } catch let early as ShimEarlyExit {
            return early.translation
        } catch {
            return .unsupported(message: "docker: \(error)")
        }
    }

    // MARK: - Global flags and dispatch

    private static func translateGlobal(_ args: [String], _ options: Options) throws -> DockerTranslation {
        var rest = args[...]
        var debug = false
        var notes: [String] = []
        while let first = rest.first, first.hasPrefix("-"), first != "-" {
            rest = rest.dropFirst()
            let name = String(first.prefix { $0 != "=" })
            switch name {
            case "-h", "--help":
                return .help(helpText)
            case "-v", "--version":
                return .run(containerArgs: ["--version"], notes: [])
            case "-D", "--debug":
                debug = true
            case "-l", "--log-level":
                if !first.contains("=") { rest = rest.dropFirst() }
                notes.append("ignoring \(name): use -D/--debug for apple/container's debug output")
            case "-c", "--context", "-H", "--host", "--config", "--tls", "--tlsverify", "--tlscacert",
                "--tlscert", "--tlskey":
                throw unsupported(
                    "docker \(name) is not supported: Basket's docker shim always talks to the local apple/container "
                        + "service (OrbStack and other Docker engines keep their own `docker` binary)")
            default:
                throw unsupported("docker: unknown or unsupported global flag \(name)")
            }
        }
        guard let command = rest.first else { return .help(helpText) }
        var translation = try dispatch(command, Array(rest.dropFirst()), options)
        if debug { translation = translation.prependingGlobal("--debug") }
        return notes.isEmpty ? translation : translation.addingNotes(notes)
    }

    private static func dispatch(_ command: String, _ args: [String], _ options: Options) throws -> DockerTranslation {
        switch command {
        case "help":
            guard let topic = args.first else { return .help(helpText) }
            return try dispatch(topic, Array(args.dropFirst()) + ["--help"], options)
        case "container":
            return try subcommand("container", args, options, containerSubcommands)
        case "image":
            return try subcommand("image", args, options, imageSubcommands)
        case "buildx", "builder":
            return try subcommand(command, args, options, ["build": build])
        case "volume":
            return try subcommand("volume", args, options, volumeSubcommands)
        case "network":
            return try subcommand("network", args, options, networkSubcommands)
        case "system":
            return try subcommand("system", args, options, systemSubcommands)
        case "compose":
            return compose(args, options)
        default:
            if let handler = topLevelCommands[command] { return try handler(args, options) }
            if unsupportedCommands.contains(command) {
                throw unsupported("docker \(command) is not supported by Basket's docker shim. Run `docker --help` for the supported commands.")
            }
            throw unsupported("docker: '\(command)' is not a docker command. See 'docker --help'.")
        }
    }

    typealias Handler = @Sendable ([String], Options) throws -> DockerTranslation

    private static func subcommand(
        _ group: String, _ args: [String], _ options: Options, _ table: [String: Handler]
    ) throws -> DockerTranslation {
        guard let sub = args.first, !sub.hasPrefix("-") else {
            if args.first == "--help" || args.first == "-h" || args.isEmpty {
                return .help(helpText)
            }
            throw unsupported("docker \(group): unknown or unsupported flag \(args[0])")
        }
        guard let handler = table[sub] else {
            throw unsupported("docker \(group) \(sub) is not supported by Basket's docker shim. Run `docker --help` for the supported commands.")
        }
        return try handler(Array(args.dropFirst()), options)
    }

    private static let topLevelCommands: [String: Handler] = [
        "ps": ps, "run": run, "create": create, "start": start, "stop": stop, "restart": restart, "kill": kill,
        "rm": rm, "logs": logs, "exec": exec, "inspect": inspect, "cp": cp, "stats": stats, "commit": commit,
        "export": export,
        "images": images, "pull": pull, "push": push, "tag": tag, "rmi": rmi, "save": save, "load": load,
        "build": build,
        "login": login, "logout": logout, "version": version, "info": info,
    ]

    private static let containerSubcommands: [String: Handler] = [
        "ls": ps, "list": ps, "ps": ps, "run": run, "create": create, "start": start, "stop": stop,
        "restart": restart, "kill": kill, "rm": rm, "remove": rm, "logs": logs, "exec": exec,
        "inspect": { args, options in try inspect(args, options, type: "container") },
        "cp": cp, "stats": stats, "prune": containerPrune, "commit": commit, "export": export,
    ]

    private static let imageSubcommands: [String: Handler] = [
        "ls": images, "list": images, "pull": pull, "push": push, "tag": tag, "rm": rmi, "remove": rmi,
        "save": save, "load": load, "build": build, "inspect": imageInspect, "prune": imagePrune,
    ]

    /// Docker commands the shim knows but can't translate (a clearer message than "unknown command").
    private static let unsupportedCommands: Set<String> = [
        "attach", "diff", "events", "history", "import", "pause", "unpause", "port", "rename", "search", "top",
        "update", "wait", "swarm", "service", "stack", "node", "secret", "config", "plugin", "trust", "manifest",
        "context", "checkpoint", "scout", "init", "sbom", "debug", "model", "mcp", "ai", "offload",
    ]

    // MARK: - compose hook

    private static func compose(_ args: [String], _ options: Options) -> DockerTranslation {
        if let executable = options.composeExecutable {
            return .delegate(executable: executable, arguments: args, notes: [])
        }
        return .unsupported(
            message: "docker compose is not supported by the shim yet. In Basket, use Containers → "
                + "Compose Up… (⇧⌘O) to run a compose.yaml with apple/container.")
    }

    // MARK: - Helpers shared by the command handlers

    /// Parses `args` for `docker <label>`; `--help` shows `container <helpTarget> --help`.
    static func parse(
        _ args: [String], _ flags: [DockerFlag], label: String, helpTarget: [String]?, interspersed: Bool = true
    ) throws -> ParsedDockerArgs {
        switch DockerArgParser.parse(args, flags: flags, interspersed: interspersed) {
        case .failure(let error):
            throw unsupported("docker \(label): \(error.message)")
        case .success(let parsed):
            if parsed.wantsHelp {
                guard let helpTarget else { throw ShimEarlyExit(translation: .help(helpText)) }
                throw ShimEarlyExit(
                    translation: .run(
                        containerArgs: helpTarget + ["--help"],
                        notes: ["`docker \(label)` runs `container \(helpTarget.joined(separator: " "))`; "
                            + "docker flags are translated (see docs/docker-shim.md)"]))
            }
            return parsed
        }
    }

    /// Applies the flag rules; a rejected flag makes the whole command unsupported.
    static func translatedFlags(_ parsed: ParsedDockerArgs, label: String) throws -> FlagOutput {
        let out = parsed.translateFlags()
        if let error = out.error { throw unsupported("docker \(label): \(error)") }
        return out
    }

    static func requirePositionals(_ parsed: ParsedDockerArgs, _ range: ClosedRange<Int>, label: String) throws {
        let count = parsed.positionals.count
        guard !range.contains(count) else { return }
        if range.lowerBound == range.upperBound {
            throw unsupported("docker \(label) requires exactly \(range.lowerBound) argument\(range.lowerBound == 1 ? "" : "s").")
        }
        if count < range.lowerBound {
            throw unsupported("docker \(label) requires at least \(range.lowerBound) argument\(range.lowerBound == 1 ? "" : "s").")
        }
        throw unsupported("docker \(label) accepts at most \(range.upperBound) argument\(range.upperBound == 1 ? "" : "s").")
    }

    static func unsupported(_ message: String) -> ShimEarlyExit {
        ShimEarlyExit(translation: .unsupported(message: message))
    }

    /// `--format`: `table` is the default, `json` maps to container's JSON, Go templates can't be translated.
    static let formatFlag = DockerFlag("--format", value: true, .custom { value, spelling, out in
        switch value ?? "" {
        case "", "table":
            break
        case "json", "{{json .}}":
            out.args += ["--format", "json"]
            out.note("--format json prints apple/container's JSON, whose fields differ from Docker's")
        default:
            out.reject(spelling, "Go templates can't be translated; use --format json (apple/container's fields) with jq")
        }
    })

    static let filterFlag = DockerFlag(
        "-f --filter", value: true, .reject("apple/container can't filter lists; pipe the output through grep"))

    /// Answers that confirm a Docker-style prompt.
    public static func isConfirmation(_ answer: String) -> Bool {
        ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// Thrown by handlers to return a translation early (help, errors).
struct ShimEarlyExit: Error {
    let translation: DockerTranslation
}

extension DockerTranslation {
    func prependingGlobal(_ flag: String) -> DockerTranslation {
        switch self {
        case .run(let args, let notes): .run(containerArgs: [flag] + args, notes: notes)
        case .sequence(let commands, let notes): .sequence(commands: commands.map { [flag] + $0 }, notes: notes)
        case .confirm(let prompt, let then): .confirm(prompt: prompt, then: then.prependingGlobal(flag))
        case .help, .delegate, .unsupported: self
        }
    }

    func addingNotes(_ extra: [String]) -> DockerTranslation {
        switch self {
        case .run(let args, let notes): .run(containerArgs: args, notes: extra + notes)
        case .sequence(let commands, let notes): .sequence(commands: commands, notes: extra + notes)
        case .confirm(let prompt, let then): .confirm(prompt: prompt, then: then.addingNotes(extra))
        case .delegate(let executable, let arguments, let notes):
            .delegate(executable: executable, arguments: arguments, notes: extra + notes)
        case .help, .unsupported: self
        }
    }
}
