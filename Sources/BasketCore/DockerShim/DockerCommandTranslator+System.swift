import Foundation

extension DockerCommandTranslator {
    // MARK: - volume

    static let volumeSubcommands: [String: Handler] = [
        "create": volumeCreate, "ls": volumeList, "list": volumeList, "rm": volumeRemove, "remove": volumeRemove,
        "inspect": volumeInspect, "prune": volumePrune,
    ]

    private static let volumeCreateFlags: [DockerFlag] = [
        DockerFlag("--name", value: true, .handled),
        DockerFlag("-d --driver", value: true, .custom { value, spelling, out in
            if value != "local" { out.reject("\(spelling) \(value ?? "")", "apple/container has only local volumes") }
        }),
        DockerFlag("--label", value: true, .emit("--label")),
        DockerFlag("-o --opt", value: true, .emit("--opt")),
    ]

    static func volumeCreate(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, volumeCreateFlags, label: "volume create", helpTarget: ["volume", "create"])
        try requirePositionals(parsed, 0...1, label: "volume create")
        let out = try translatedFlags(parsed, label: "volume create")
        guard let name = parsed.positionals.first ?? parsed.last("--name") else {
            throw unsupported("docker volume create needs a name: apple/container has no anonymous volumes.")
        }
        return .run(containerArgs: ["volume", "create"] + out.args + [name], notes: out.notes)
    }

    private static let listFlags: [DockerFlag] = [
        DockerFlag("-q --quiet", .emit("--quiet")),
        DockerFlag("--no-trunc", .ignore),
        formatFlag,
        filterFlag,
    ]

    static func volumeList(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, listFlags, label: "volume ls", helpTarget: ["volume", "list"])
        try requirePositionals(parsed, 0...0, label: "volume ls")
        let out = try translatedFlags(parsed, label: "volume ls")
        return .run(containerArgs: ["volume", "list"] + out.args, notes: out.notes)
    }

    static func volumeRemove(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let flags = [DockerFlag("-f --force", .drop("apple/container refuses to delete a volume that is in use"))]
        let parsed = try parse(args, flags, label: "volume rm", helpTarget: ["volume", "delete"])
        guard !parsed.positionals.isEmpty else { throw unsupported("docker volume rm requires at least 1 argument.") }
        let out = try translatedFlags(parsed, label: "volume rm")
        return .run(containerArgs: ["volume", "delete"] + parsed.positionals, notes: out.notes)
    }

    static func volumeInspect(_ args: [String], _ options: Options) throws -> DockerTranslation {
        try namedInspect(args, group: "volume")
    }

    /// apple/container's `volume prune` deletes every unused volume, named ones included — Docker does
    /// that only with `--all`, so the shim requires it.
    static func volumePrune(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let flags = [
            DockerFlag("-a --all", .handled), DockerFlag("-f --force", .handled),
            DockerFlag("--filter", value: true, .reject("apple/container can't filter what it prunes")),
        ]
        let parsed = try parse(args, flags, label: "volume prune", helpTarget: ["volume", "prune"])
        try requirePositionals(parsed, 0...0, label: "volume prune")
        _ = try translatedFlags(parsed, label: "volume prune")
        guard parsed.has("--all") else {
            throw unsupported(
                "docker volume prune: apple/container removes every unused volume, named ones included "
                    + "(Docker does that only with --all). Run `docker volume prune --all` to confirm.")
        }
        let run = DockerTranslation.run(containerArgs: ["volume", "prune"], notes: [])
        if parsed.has("--force") { return run }
        return .confirm(prompt: "WARNING! This will remove all volumes not used by at least one container.", then: run)
    }

    // MARK: - network

    static let networkSubcommands: [String: Handler] = [
        "create": networkCreate, "ls": networkList, "list": networkList, "rm": networkRemove, "remove": networkRemove,
        "inspect": networkInspect, "prune": networkPrune,
    ]

    private static let networkCreateFlags: [DockerFlag] = [
        DockerFlag("-d --driver", value: true, .custom { value, spelling, out in
            if value != "bridge" {
                out.reject("\(spelling) \(value ?? "")", "apple/container networks are host-local (bridge-like)")
            }
        }),
        DockerFlag("--subnet", value: true, .custom { value, _, out in
            let subnet = value ?? ""
            out.args += [subnet.contains(":") ? "--subnet-v6" : "--subnet", subnet]
        }),
        DockerFlag("--internal", .emit("--internal")),
        DockerFlag("--label", value: true, .emit("--label")),
        DockerFlag("-o --opt", value: true, .emit("--option")),
        DockerFlag("--ipv6", .ignore),
        DockerFlag("--ipv4", .ignore),
        DockerFlag("--attachable", .ignore),
        DockerFlag("--gateway", value: true, .reject(ShimReason.networkOption)),
        DockerFlag("--ip-range", value: true, .reject(ShimReason.networkOption)),
        DockerFlag("--aux-address", value: true, .reject(ShimReason.networkOption)),
        DockerFlag("--ipam-driver", value: true, .reject(ShimReason.networkOption)),
        DockerFlag("--ipam-opt", value: true, .reject(ShimReason.networkOption)),
        DockerFlag("--ingress", .reject("apple/container has no swarm networks")),
        DockerFlag("--scope", value: true, .reject("apple/container has no swarm networks")),
        DockerFlag("--config-from", value: true, .reject(ShimReason.networkOption)),
        DockerFlag("--config-only", .reject(ShimReason.networkOption)),
    ]

    static func networkCreate(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, networkCreateFlags, label: "network create", helpTarget: ["network", "create"])
        try requirePositionals(parsed, 1...1, label: "network create")
        let out = try translatedFlags(parsed, label: "network create")
        return .run(containerArgs: ["network", "create"] + out.args + parsed.positionals, notes: out.notes)
    }

    static func networkList(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, listFlags, label: "network ls", helpTarget: ["network", "list"])
        try requirePositionals(parsed, 0...0, label: "network ls")
        let out = try translatedFlags(parsed, label: "network ls")
        return .run(containerArgs: ["network", "list"] + out.args, notes: out.notes)
    }

    static func networkRemove(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let flags = [DockerFlag("-f --force", .ignore)]
        let parsed = try parse(args, flags, label: "network rm", helpTarget: ["network", "delete"])
        guard !parsed.positionals.isEmpty else { throw unsupported("docker network rm requires at least 1 argument.") }
        let out = try translatedFlags(parsed, label: "network rm")
        return .run(containerArgs: ["network", "delete"] + parsed.positionals, notes: out.notes)
    }

    static func networkInspect(_ args: [String], _ options: Options) throws -> DockerTranslation {
        try namedInspect(args, group: "network")
    }

    static func networkPrune(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let flags = [
            DockerFlag("-f --force", .handled),
            DockerFlag("--filter", value: true, .reject("apple/container can't filter what it prunes")),
        ]
        let parsed = try parse(args, flags, label: "network prune", helpTarget: ["network", "prune"])
        try requirePositionals(parsed, 0...0, label: "network prune")
        _ = try translatedFlags(parsed, label: "network prune")
        let run = DockerTranslation.run(containerArgs: ["network", "prune"], notes: [])
        if parsed.has("--force") { return run }
        return .confirm(prompt: "WARNING! This will remove all custom networks not used by at least one container.", then: run)
    }

    private static func namedInspect(_ args: [String], group: String) throws -> DockerTranslation {
        let flags = [
            DockerFlag("-f --format", value: true, .custom { value, spelling, out in
                if value != "json", value != "{{json .}}" {
                    out.reject(spelling, "Go templates can't be translated; pipe apple/container's JSON through jq")
                }
            }),
            DockerFlag("-v --verbose", .ignore),
        ]
        let parsed = try parse(args, flags, label: "\(group) inspect", helpTarget: [group, "inspect"])
        guard !parsed.positionals.isEmpty else { throw unsupported("docker \(group) inspect requires at least 1 argument.") }
        let out = try translatedFlags(parsed, label: "\(group) inspect")
        return .run(containerArgs: [group, "inspect"] + parsed.positionals, notes: out.notes)
    }

    // MARK: - login / logout

    /// Docker Hub, as `docker login` without a server means.
    static let defaultRegistry = "docker.io"

    private static let loginFlags: [DockerFlag] = [
        DockerFlag("-u --username", value: true, .emit("--username")),
        DockerFlag("--password-stdin", .emit("--password-stdin")),
        DockerFlag("-p --password", value: true, .reject("pass the password on stdin with --password-stdin")),
    ]

    static func login(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, loginFlags, label: "login", helpTarget: ["registry", "login"])
        try requirePositionals(parsed, 0...1, label: "login")
        let out = try translatedFlags(parsed, label: "login")
        let (server, scheme) = registryServer(parsed.positionals.first)
        return .run(containerArgs: ["registry", "login"] + scheme + out.args + [server], notes: out.notes)
    }

    static func logout(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, [], label: "logout", helpTarget: ["registry", "logout"])
        try requirePositionals(parsed, 0...1, label: "logout")
        return .run(containerArgs: ["registry", "logout", registryServer(parsed.positionals.first).server], notes: [])
    }

    /// `https://index.docker.io/v1/` → `docker.io`; `http://host:5000` → `host:5000` + `--scheme http`.
    static func registryServer(_ raw: String?) -> (server: String, scheme: [String]) {
        guard var server = raw, !server.isEmpty else { return (defaultRegistry, []) }
        var scheme: [String] = []
        if server.hasPrefix("http://") {
            scheme = ["--scheme", "http"]
            server.removeFirst("http://".count)
        } else if server.hasPrefix("https://") {
            server.removeFirst("https://".count)
        }
        if let slash = server.firstIndex(of: "/") { server = String(server[..<slash]) }
        if ["index.docker.io", "registry-1.docker.io", "registry.hub.docker.com"].contains(server) {
            server = defaultRegistry
        }
        return (server, scheme)
    }

    // MARK: - system / version / info

    static let systemSubcommands: [String: Handler] = [
        "df": systemDF, "info": info, "prune": systemPrune,
    ]

    static func systemDF(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let flags = [DockerFlag("-v --verbose", .drop("apple/container shows totals per category")), formatFlag]
        let parsed = try parse(args, flags, label: "system df", helpTarget: ["system", "df"])
        try requirePositionals(parsed, 0...0, label: "system df")
        let out = try translatedFlags(parsed, label: "system df")
        return .run(containerArgs: ["system", "df"] + out.args, notes: out.notes)
    }

    static func version(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, [formatFlagShort], label: "version", helpTarget: ["system", "version"])
        try requirePositionals(parsed, 0...0, label: "version")
        let out = try translatedFlags(parsed, label: "version")
        return .run(containerArgs: ["system", "version"] + out.args, notes: out.notes)
    }

    static func info(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, [formatFlagShort], label: "info", helpTarget: ["system", "status"])
        try requirePositionals(parsed, 0...0, label: "info")
        let out = try translatedFlags(parsed, label: "info")
        return .run(containerArgs: ["system", "status"] + out.args, notes: out.notes)
    }

    /// `-f/--format` (version, info).
    private static let formatFlagShort = DockerFlag("-f --format", value: true, formatFlag.rule)

    /// Docker's system prune = stopped containers + unused networks + dangling (or, with -a, unused) images.
    static func systemPrune(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let flags = [
            DockerFlag("-a --all", .handled), DockerFlag("-f --force", .handled),
            DockerFlag("--volumes", .reject("apple/container's volume prune also removes named volumes; run docker volume prune --all separately")),
            DockerFlag("--filter", value: true, .reject("apple/container can't filter what it prunes")),
        ]
        let parsed = try parse(args, flags, label: "system prune", helpTarget: nil)
        try requirePositionals(parsed, 0...0, label: "system prune")
        _ = try translatedFlags(parsed, label: "system prune")
        let all = parsed.has("--all")
        let sequence = DockerTranslation.sequence(
            commands: [["prune"], ["network", "prune"], ["image", "prune"] + (all ? ["--all"] : [])],
            notes: ["build cache is not pruned: apple/container's builder manages its own (docker builder is not translated)"])
        if parsed.has("--force") { return sequence }
        let images = all ? "all images without at least one container associated to them" : "all dangling images"
        return .confirm(
            prompt: """
                WARNING! This will remove:
                  - all stopped containers
                  - all networks not used by at least one container
                  - \(images)
                """,
            then: sequence)
    }
}
