import Foundation

/// What the `docker` shim does with one docker command line (see `DockerCommandTranslator`).
public enum DockerTranslation: Sendable, Equatable {
    /// Run `container <containerArgs>`, printing `notes` (dropped flags etc.) to stderr first.
    case run(containerArgs: [String], notes: [String])
    /// Run several `container` commands in order, stopping at the first failure
    /// (`docker restart` = stop + start, `docker build -t a -t b` = build + tag).
    case sequence(commands: [[String]], notes: [String])
    /// Ask on the terminal before a destructive command, the way `docker … prune` does without `-f`.
    indirect case confirm(prompt: String, then: DockerTranslation)
    /// Print `text` to stdout and exit 0 (`docker`, `docker --help`).
    case help(String)
    /// Hand the arguments to another executable — the hook for a future `docker compose` helper.
    case delegate(executable: String, arguments: [String], notes: [String])
    /// Not translatable: print `message` to stderr and exit 125 (Docker's exit code for CLI errors).
    case unsupported(message: String)

    /// The `container` command lines this translation runs, in order (empty for help/unsupported/delegate).
    public var containerCommands: [[String]] {
        switch self {
        case .run(let args, _): [args]
        case .sequence(let commands, _): commands
        case .confirm(_, let then): then.containerCommands
        case .help, .delegate, .unsupported: []
        }
    }

    /// Warnings printed before running.
    public var notes: [String] {
        switch self {
        case .run(_, let notes), .sequence(_, let notes), .delegate(_, _, let notes): notes
        case .confirm(_, let then): then.notes
        case .help, .unsupported: []
        }
    }
}
