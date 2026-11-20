import Foundation

extension DockerCommandTranslator {
    // MARK: - images / image ls

    private static let imagesFlags: [DockerFlag] = [
        DockerFlag("-q --quiet", .emit("--quiet")),
        DockerFlag("--digests", .emit("--verbose")),
        DockerFlag("-a --all", .ignore),
        DockerFlag("--no-trunc", .ignore),
        DockerFlag("--tree", .reject("apple/container has no tree view; docker images lists every image")),
        formatFlag,
        filterFlag,
    ]

    static func images(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, imagesFlags, label: "images", helpTarget: ["image", "list"])
        if !parsed.positionals.isEmpty {
            throw unsupported("docker images REPOSITORY is not supported: apple/container lists every image; pipe through grep.")
        }
        let out = try translatedFlags(parsed, label: "images")
        return .run(containerArgs: ["image", "list"] + out.args, notes: out.notes)
    }

    // MARK: - pull / push / tag / rmi

    private static let pullFlags: [DockerFlag] = [
        DockerFlag("--platform", value: true, .emit("--platform")),
        DockerFlag("-q --quiet", .custom { _, _, out in out.args += ["--progress", "none"] }),
        DockerFlag("--disable-content-trust", .ignore),
        DockerFlag("-a --all-tags", .reject("pull each tag by name")),
    ]

    /// Docker pulls only the host's platform; `container image pull` would store every variant of a
    /// multi-arch image (~10 for alpine), so the shim adds `--platform <host>` unless one is given.
    static func pull(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, pullFlags, label: "pull", helpTarget: ["image", "pull"])
        try requirePositionals(parsed, 1...1, label: "pull")
        let out = try translatedFlags(parsed, label: "pull")
        let platform = parsed.has("--platform") ? [] : ["--platform", options.hostPlatform]
        return .run(containerArgs: ["image", "pull"] + platform + out.args + parsed.positionals, notes: out.notes)
    }

    private static let pushFlags: [DockerFlag] = [
        DockerFlag("--platform", value: true, .emit("--platform")),
        DockerFlag("-q --quiet", .custom { _, _, out in out.args += ["--progress", "none"] }),
        DockerFlag("--disable-content-trust", .ignore),
        DockerFlag("-a --all-tags", .reject("push each tag by name")),
    ]

    static func push(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, pushFlags, label: "push", helpTarget: ["image", "push"])
        try requirePositionals(parsed, 1...1, label: "push")
        let out = try translatedFlags(parsed, label: "push")
        return .run(containerArgs: ["image", "push"] + out.args + parsed.positionals, notes: out.notes)
    }

    static func tag(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, [], label: "tag", helpTarget: ["image", "tag"])
        try requirePositionals(parsed, 2...2, label: "tag")
        return .run(containerArgs: ["image", "tag"] + parsed.positionals, notes: [])
    }

    private static let rmiFlags: [DockerFlag] = [
        DockerFlag("-f --force", .emit("--force")),
        DockerFlag("--no-prune", .ignore),
        DockerFlag("--platform", value: true, .reject("apple/container deletes an image with all its platforms")),
    ]

    static func rmi(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, rmiFlags, label: "rmi", helpTarget: ["image", "delete"])
        guard !parsed.positionals.isEmpty else { throw unsupported("docker rmi requires at least 1 argument.") }
        let out = try translatedFlags(parsed, label: "rmi")
        return .run(containerArgs: ["image", "delete"] + out.args + parsed.positionals, notes: out.notes)
    }

    // MARK: - save / load / image inspect / image prune

    private static let saveFlags: [DockerFlag] = [
        DockerFlag("-o --output", value: true, .emit("--output")),
        DockerFlag("--platform", value: true, .emit("--platform")),
    ]

    static func save(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, saveFlags, label: "save", helpTarget: ["image", "save"])
        guard !parsed.positionals.isEmpty else { throw unsupported("docker save requires at least 1 argument.") }
        let out = try translatedFlags(parsed, label: "save")
        return .run(containerArgs: ["image", "save"] + out.args + parsed.positionals, notes: out.notes)
    }

    private static let loadFlags: [DockerFlag] = [
        DockerFlag("-i --input", value: true, .emit("--input")),
        DockerFlag("-q --quiet", .ignore),
        DockerFlag("--platform", value: true, .drop("apple/container loads every platform in the archive")),
    ]

    static func load(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, loadFlags, label: "load", helpTarget: ["image", "load"])
        try requirePositionals(parsed, 0...0, label: "load")
        let out = try translatedFlags(parsed, label: "load")
        return .run(containerArgs: ["image", "load"] + out.args, notes: out.notes)
    }

    private static let imageInspectFlags: [DockerFlag] = [
        DockerFlag("-f --format", value: true, .custom { value, spelling, out in
            if value != "json", value != "{{json .}}" {
                out.reject(spelling, "Go templates can't be translated; pipe apple/container's JSON through jq")
            }
        }),
        DockerFlag("--platform", value: true, .drop("apple/container shows every platform of the image")),
    ]

    static func imageInspect(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, imageInspectFlags, label: "image inspect", helpTarget: ["image", "inspect"])
        guard !parsed.positionals.isEmpty else { throw unsupported("docker image inspect requires at least 1 argument.") }
        let out = try translatedFlags(parsed, label: "image inspect")
        return .run(containerArgs: ["image", "inspect"] + parsed.positionals, notes: out.notes)
    }

    private static let imagePruneFlags: [DockerFlag] = [
        DockerFlag("-a --all", .emit("--all")),
        DockerFlag("-f --force", .handled),
        DockerFlag("--filter", value: true, .reject("apple/container can't filter what it prunes")),
    ]

    static func imagePrune(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, imagePruneFlags, label: "image prune", helpTarget: ["image", "prune"])
        try requirePositionals(parsed, 0...0, label: "image prune")
        let out = try translatedFlags(parsed, label: "image prune")
        let run = DockerTranslation.run(containerArgs: ["image", "prune"] + out.args, notes: out.notes)
        if parsed.has("--force") { return run }
        let what = parsed.has("--all")
            ? "all images without at least one container associated to them" : "all dangling images"
        return .confirm(prompt: "WARNING! This will remove \(what).", then: run)
    }

    // MARK: - build

    private static let buildFlags: [DockerFlag] = {
        var flags: [DockerFlag] = [
            DockerFlag("-t --tag", value: true, .handled),
            DockerFlag("--push", .handled),
            DockerFlag("-f --file", value: true, .custom { value, spelling, out in
                if value == "-" {
                    out.reject("\(spelling) -", "pass the Dockerfile as a file")
                } else {
                    out.args += ["--file", value ?? ""]
                }
            }),
            DockerFlag("--build-arg", value: true, .emit("--build-arg")),
            DockerFlag("--target", value: true, .emit("--target")),
            DockerFlag("--no-cache", .emit("--no-cache")),
            DockerFlag("--platform", value: true, .emit("--platform")),
            DockerFlag("--progress", value: true, .custom { value, spelling, out in
                switch value ?? "" {
                case "auto", "plain", "tty": out.args += ["--progress", value ?? ""]
                case "quiet": out.args.append("--quiet")
                default:
                    out.args += ["--progress", "plain"]
                    out.note("using --progress plain instead of \(value ?? ""): apple/container supports auto, plain and tty")
                }
            }),
            DockerFlag("-q --quiet", .emit("--quiet")),
            DockerFlag("--label", value: true, .emit("--label")),
            DockerFlag("--pull", .emit("--pull")),
            DockerFlag("--secret", value: true, .emit("--secret")),
            DockerFlag("--ssh", value: true, .emit("--ssh")),
            DockerFlag("-o --output", value: true, .emit("--output")),
            DockerFlag("-m --memory", value: true, .emit("--memory")),
            DockerFlag("--network", value: true, .custom { value, spelling, out in
                if value != "default" { out.drop(spelling, "apple/container's builder uses its own network") }
            }),
            DockerFlag("--load", .ignore),
            DockerFlag("--rm", .ignore),
            DockerFlag("--force-rm", .ignore),
            DockerFlag("--disable-content-trust", .ignore),
            DockerFlag("--add-host", value: true, .reject("apple/container's builder can't add /etc/hosts entries")),
            DockerFlag("--build-context", value: true, .reject("apple/container builds from one context directory")),
            DockerFlag("--call", value: true, .reject("apple/container's builder has no build checks")),
            DockerFlag("--check", .reject("apple/container's builder has no build checks")),
            DockerFlag("--squash", .drop("apple/container's builder doesn't squash layers")),
            DockerFlag("--compress", .ignore),
            DockerFlag("-c --cpu-shares", value: true, .drop(ShimReason.tuning)),
        ]
        flags += ["--cache-from", "--cache-to", "--no-cache-filter"]
            .map { DockerFlag($0, value: true, .drop("apple/container's builder manages its own cache")) }
        flags += ["--iidfile", "--metadata-file", "--provenance", "--sbom", "--attest", "--annotation"]
            .map { DockerFlag($0, value: true, .drop("apple/container's builder doesn't write this metadata")) }
        flags += ["--builder", "--allow", "--shm-size", "--ulimit", "--cgroup-parent", "--security-opt", "--isolation",
                  "--memory-swap", "--cpu-period", "--cpu-quota", "--cpuset-cpus", "--cpuset-mems"]
            .map { DockerFlag($0, value: true, .drop("apple/container's builder has no equivalent")) }
        return flags
    }()

    /// `container build` takes one `-t`: extra tags become `image tag`, and `--push` pushes every tag.
    static func build(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, buildFlags, label: "build", helpTarget: ["build"])
        try requirePositionals(parsed, 0...1, label: "build")
        let context = parsed.positionals.first ?? "."
        if context == "-" || context.contains("://") || context.hasPrefix("git@") {
            throw unsupported("docker build: apple/container builds from a local directory, not \(context).")
        }
        let out = try translatedFlags(parsed, label: "build")
        let tags = parsed.values("--tag")
        var commands = [["build"] + (tags.first.map { ["--tag", $0] } ?? []) + out.args + [context]]
        for extra in tags.dropFirst() { commands.append(["image", "tag", tags[0], extra]) }
        if parsed.has("--push") {
            guard !tags.isEmpty else { throw unsupported("docker build --push needs a name (-t).") }
            commands += tags.map { ["image", "push", $0] }
        }
        if commands.count == 1 { return .run(containerArgs: commands[0], notes: out.notes) }
        return .sequence(commands: commands, notes: out.notes)
    }
}
