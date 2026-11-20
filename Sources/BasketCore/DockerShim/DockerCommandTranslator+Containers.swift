import Foundation

/// Why flags are dropped or refused (shared by run/create/exec/build).
enum ShimReason {
    static let restart = "apple/container has no restart policies; the container won't be restarted automatically"
    static let health = "apple/container has no health checks"
    static let logging = "apple/container keeps each container's output itself (read it with docker logs)"
    static let tuning = "apple/container sizes each container's VM with --cpus and --memory only"
    static let networkOption = "apple/container networks don't support this option"
    static let hostname = "the hostname is the container name in apple/container"
    static let vmIsolation = "each container runs in its own VM; there is no equivalent"
    static let privileged = "apple/container runs each container in its own VM without privileged mode or host device access"
    static let hostNamespace = "each container runs in its own VM and can't share the host's or another container's namespaces"
    static let attach = "output is attached unless you pass -d"
    static let detachKeys = "apple/container detaches with its own key sequence"
    static let stop = "apple/container stops containers with SIGTERM and docker stop -t"
}

extension DockerCommandTranslator {
    // MARK: - run / create

    private static func runFlags(create: Bool) -> [DockerFlag] {
        var flags: [DockerFlag] = [
            // Kept: same meaning in apple/container.
            DockerFlag("-i --interactive", .emit("-i")),
            DockerFlag("-t --tty", .emit("-t")),
            DockerFlag("--rm", .emit("--rm")),
            DockerFlag("--init", .emit("--init")),
            DockerFlag("--read-only", .emit("--read-only")),
            DockerFlag("--name", value: true, .emit("--name")),
            DockerFlag("-e --env", value: true, .emit("-e")),
            DockerFlag("--env-file", value: true, .emit("--env-file")),
            DockerFlag("-u --user", value: true, .emit("-u")),
            DockerFlag("-w --workdir", value: true, .emit("-w")),
            DockerFlag("-l --label", value: true, .emit("-l")),
            DockerFlag("--mount", value: true, .emit("--mount")),
            DockerFlag("--entrypoint", value: true, .emit("--entrypoint")),
            DockerFlag("-m --memory", value: true, .emit("-m")),
            DockerFlag("--platform", value: true, .emit("--platform")),
            DockerFlag("--tmpfs", value: true, .emit("--tmpfs")),
            DockerFlag("--dns", value: true, .emit("--dns")),
            DockerFlag("--dns-search", value: true, .emit("--dns-search")),
            DockerFlag("--dns-option --dns-opt", value: true, .emit("--dns-option")),
            DockerFlag("--cap-add", value: true, .emit("--cap-add")),
            DockerFlag("--cap-drop", value: true, .emit("--cap-drop")),
            DockerFlag("--cidfile", value: true, .emit("--cidfile")),
            DockerFlag("--ulimit", value: true, .emit("--ulimit")),
            DockerFlag("--shm-size", value: true, .emit("--shm-size")),
            // Translated.
            DockerFlag("-p --publish", value: true, .custom(publish)),
            DockerFlag("-v --volume", value: true, .custom(volume)),
            DockerFlag("--cpus", value: true, .custom(cpus)),
            DockerFlag("--network --net", value: true, .custom(network)),
            DockerFlag("--restart", value: true, .custom { value, spelling, out in
                if value != "no" { out.drop(spelling, ShimReason.restart) }
            }),
            DockerFlag("--pull", value: true, .custom { value, spelling, out in
                if value != "missing" {
                    out.drop(spelling, "apple/container pulls an image only when it is missing (run docker pull first)")
                }
            }),
            DockerFlag("--pid", value: true, .custom(namespace)),
            DockerFlag("--ipc", value: true, .custom(namespace)),
            DockerFlag("--uts", value: true, .custom(namespace)),
            DockerFlag("--userns", value: true, .custom(namespace)),
            DockerFlag("--cgroupns", value: true, .custom(namespace)),
            // Same as apple/container's default.
            DockerFlag("--disable-content-trust", .ignore),
            // Dropped with a note.
            DockerFlag("-a --attach", value: true, .drop(ShimReason.attach)),
            DockerFlag("-h --hostname", value: true, .drop(ShimReason.hostname)),
            DockerFlag("--domainname", value: true, .drop(ShimReason.hostname)),
            DockerFlag("--expose", value: true, .drop("publish ports with -p host:container")),
            DockerFlag("--stop-signal", value: true, .drop(ShimReason.stop)),
            DockerFlag("--stop-timeout", value: true, .drop(ShimReason.stop)),
            DockerFlag("--no-healthcheck", .drop(ShimReason.health)),
            DockerFlag("--oom-kill-disable", .drop(ShimReason.tuning)),
            DockerFlag("--runtime", value: true, .drop("apple/container uses its own Linux runtime")),
        ]
        flags += ["--health-cmd", "--health-interval", "--health-retries", "--health-start-period",
                  "--health-start-interval", "--health-timeout"]
            .map { DockerFlag($0, value: true, .drop(ShimReason.health)) }
        flags += ["--log-driver", "--log-opt"].map { DockerFlag($0, value: true, .drop(ShimReason.logging)) }
        flags.append(DockerFlag("-c --cpu-shares", value: true, .drop(ShimReason.tuning)))
        flags += ["--cpu-period", "--cpu-quota", "--cpu-rt-period", "--cpu-rt-runtime", "--cpuset-cpus",
                  "--cpuset-mems", "--memory-reservation", "--memory-swap", "--memory-swappiness", "--kernel-memory",
                  "--pids-limit", "--oom-score-adj", "--blkio-weight", "--blkio-weight-device", "--device-read-bps",
                  "--device-read-iops", "--device-write-bps", "--device-write-iops"]
            .map { DockerFlag($0, value: true, .drop(ShimReason.tuning)) }
        flags += ["--network-alias", "--net-alias", "--ip", "--ip6", "--link-local-ip", "--mac-address"]
            .map { DockerFlag($0, value: true, .drop(ShimReason.networkOption)) }
        flags += ["--security-opt", "--sysctl", "--group-add", "--isolation", "--storage-opt", "--annotation",
                  "--cgroup-parent", "--volume-driver"]
            .map { DockerFlag($0, value: true, .drop(ShimReason.vmIsolation)) }
        // Refused: the container would silently behave differently.
        flags += [
            DockerFlag("--privileged", .reject(ShimReason.privileged)),
            DockerFlag("--gpus", value: true, .reject(ShimReason.privileged)),
            DockerFlag("--device", value: true, .reject(ShimReason.privileged)),
            DockerFlag("--device-cgroup-rule", value: true, .reject(ShimReason.privileged)),
            DockerFlag("--add-host", value: true, .reject("apple/container can't add /etc/hosts entries")),
            DockerFlag("-P --publish-all", .reject("apple/container has no random host ports; publish each port with -p host:container")),
            DockerFlag("--volumes-from", value: true, .reject("apple/container can't share another container's volumes; mount the same named volume with -v")),
            DockerFlag("--link", value: true, .reject("legacy links don't exist in apple/container; reach other containers by name on a shared network")),
            DockerFlag("--label-file", value: true, .reject("pass labels with -l key=value")),
            DockerFlag("--use-api-socket", .reject("apple/container has no Docker API socket")),
        ]
        if create {
            flags.append(DockerFlag("-q --quiet", .ignore))
        } else {
            flags += [
                DockerFlag("-d --detach", .emit("-d")),
                DockerFlag("-q --quiet", .custom { _, _, out in out.args += ["--progress", "none"] }),
                DockerFlag("--sig-proxy", .ignore),
                DockerFlag("--detach-keys", value: true, .drop(ShimReason.detachKeys)),
            ]
        }
        return flags
    }

    private static let runFlagTable = runFlags(create: false)
    private static let createFlagTable = runFlags(create: true)

    static func run(_ args: [String], _ options: Options) throws -> DockerTranslation {
        try runOrCreate(args, command: "run", flags: runFlagTable)
    }

    static func create(_ args: [String], _ options: Options) throws -> DockerTranslation {
        try runOrCreate(args, command: "create", flags: createFlagTable)
    }

    private static func runOrCreate(_ args: [String], command: String, flags: [DockerFlag]) throws -> DockerTranslation {
        let parsed = try parse(args, flags, label: command, helpTarget: [command], interspersed: false)
        guard !parsed.positionals.isEmpty else {
            throw unsupported("docker \(command) requires at least 1 argument (the image).")
        }
        let out = try translatedFlags(parsed, label: command)
        return .run(containerArgs: [command] + out.args + parsed.positionals, notes: out.notes)
    }

    /// `-p 80` / `-p 127.0.0.1::80`: Docker picks a random host port; apple/container needs one, so
    /// the container port is published on the same host port.
    static func publishSpec(_ spec: String) -> (spec: String, filledHostPort: Bool) {
        var body = Substring(spec)
        var proto = ""
        if let slash = body.lastIndex(of: "/") {
            proto = String(body[slash...])
            body = body[..<slash]
        }
        var hostIP: String?
        if body.hasPrefix("["), let close = body.firstIndex(of: "]") {
            hostIP = String(body[...close])
            body = body[body.index(after: close)...]
            guard body.hasPrefix(":") else { return (spec, false) }
            body = body.dropFirst()
        }
        var parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if hostIP == nil, parts.count == 3 { hostIP = parts.removeFirst() }
        let prefix = hostIP.map { $0 + ":" } ?? ""
        switch parts.count {
        case 1 where !parts[0].isEmpty:
            return ("\(prefix)\(parts[0]):\(parts[0])\(proto)", true)
        case 2 where parts[0].isEmpty && !parts[1].isEmpty:
            return ("\(prefix)\(parts[1]):\(parts[1])\(proto)", true)
        default:
            return (spec, false)
        }
    }

    private static func publish(_ value: String?, _ spelling: String, _ out: inout FlagOutput) {
        let (spec, filled) = publishSpec(value ?? "")
        out.args += ["-p", spec]
        if filled {
            out.note("publishing \(value ?? "") as \(spec): apple/container has no random host ports")
        }
    }

    /// Mount options Docker Desktop/OrbStack accept that apple/container's virtiofs mounts don't.
    static let ignoredVolumeOptions: Set<String> = ["cached", "delegated", "consistent", "z", "Z", "nocopy"]

    static func volumeSpec(_ spec: String) -> (spec: String, removed: [String]) {
        var parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 || (parts.count == 2 && !parts[1].hasPrefix("/")) else { return (spec, []) }
        let options = parts.removeLast().split(separator: ",").map(String.init)
        let removed = options.filter { ignoredVolumeOptions.contains($0) }
        guard !removed.isEmpty else { return (spec, []) }
        let kept = options.filter { !ignoredVolumeOptions.contains($0) }
        if !kept.isEmpty { parts.append(kept.joined(separator: ",")) }
        return (parts.joined(separator: ":"), removed)
    }

    private static func volume(_ value: String?, _ spelling: String, _ out: inout FlagOutput) {
        let (spec, removed) = volumeSpec(value ?? "")
        out.args += ["-v", spec]
        if !removed.isEmpty {
            out.note("ignoring volume option \(removed.joined(separator: ",")) in \(value ?? ""): not used by apple/container")
        }
    }

    private static func cpus(_ value: String?, _ spelling: String, _ out: inout FlagOutput) {
        let raw = value ?? ""
        guard let number = Double(raw), number > 0, number < 1024 else {
            out.args += ["--cpus", raw]
            return
        }
        let whole = Int(number.rounded(.up))
        out.args += ["--cpus", String(whole)]
        if Double(whole) != number {
            out.note("rounding --cpus \(raw) up to \(whole): apple/container allocates whole CPUs")
        }
    }

    private static func network(_ value: String?, _ spelling: String, _ out: inout FlagOutput) {
        let name = value ?? ""
        switch name {
        case "bridge", "default":
            break  // Docker's default network = apple/container's default network.
        case "host":
            out.reject("\(spelling) host", "each container runs in its own VM with its own network; publish ports with -p")
        case _ where name.hasPrefix("container:"):
            out.reject("\(spelling) \(name)", ShimReason.hostNamespace)
        default:
            out.args += ["--network", name]
        }
    }

    private static func namespace(_ value: String?, _ spelling: String, _ out: inout FlagOutput) {
        let mode = value ?? ""
        if mode == "host" || mode.hasPrefix("container:") {
            out.reject("\(spelling) \(mode)", ShimReason.hostNamespace)
        }
    }

    // MARK: - exec

    private static let execFlags: [DockerFlag] = [
        DockerFlag("-d --detach", .emit("-d")),
        DockerFlag("-i --interactive", .emit("-i")),
        DockerFlag("-t --tty", .emit("-t")),
        DockerFlag("-e --env", value: true, .emit("-e")),
        DockerFlag("--env-file", value: true, .emit("--env-file")),
        DockerFlag("-u --user", value: true, .emit("-u")),
        DockerFlag("-w --workdir", value: true, .emit("-w")),
        DockerFlag("--detach-keys", value: true, .drop(ShimReason.detachKeys)),
        DockerFlag("--privileged", .reject(ShimReason.privileged)),
    ]

    static func exec(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, execFlags, label: "exec", helpTarget: ["exec"], interspersed: false)
        guard parsed.positionals.count >= 2 else {
            throw unsupported("docker exec requires at least 2 arguments (container and command).")
        }
        let out = try translatedFlags(parsed, label: "exec")
        return .run(containerArgs: ["exec"] + out.args + parsed.positionals, notes: out.notes)
    }

    // MARK: - ps

    private static let psFlags: [DockerFlag] = [
        DockerFlag("-a --all", .emit("--all")),
        DockerFlag("-q --quiet", .emit("--quiet")),
        formatFlag,
        filterFlag,
        DockerFlag("--no-trunc", .ignore),
        DockerFlag("-s --size", .drop("apple/container doesn't report container sizes (see docker system df)")),
        DockerFlag("-n --last", value: true, .reject("list all containers with -a instead")),
        DockerFlag("-l --latest", .reject("list all containers with -a instead")),
    ]

    static func ps(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, psFlags, label: "ps", helpTarget: ["list"])
        try requirePositionals(parsed, 0...0, label: "ps")
        let out = try translatedFlags(parsed, label: "ps")
        return .run(containerArgs: ["list"] + out.args, notes: out.notes)
    }

    // MARK: - start / stop / restart / kill / rm

    private static let startFlags: [DockerFlag] = [
        DockerFlag("-a --attach", .emit("--attach")),
        DockerFlag("-i --interactive", .emit("--interactive")),
        DockerFlag("--detach-keys", value: true, .drop(ShimReason.detachKeys)),
        DockerFlag("--checkpoint", value: true, .reject("apple/container has no checkpoints")),
        DockerFlag("--checkpoint-dir", value: true, .reject("apple/container has no checkpoints")),
    ]

    static func start(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, startFlags, label: "start", helpTarget: ["start"])
        guard !parsed.positionals.isEmpty else { throw unsupported("docker start requires at least 1 argument.") }
        let out = try translatedFlags(parsed, label: "start")
        // `container start` takes one container; Docker starts each in turn.
        let commands = parsed.positionals.map { ["start"] + out.args + [$0] }
        if commands.count == 1 { return .run(containerArgs: commands[0], notes: out.notes) }
        if parsed.has("--attach") || parsed.has("--interactive") {
            throw unsupported("docker start: attaching works with one container at a time.")
        }
        return .sequence(commands: commands, notes: out.notes)
    }

    private static let stopFlags: [DockerFlag] = [
        DockerFlag("-s --signal", value: true, .emit("--signal")),
        DockerFlag("-t --timeout --time", value: true, .emit("--time")),
    ]

    static func stop(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, stopFlags, label: "stop", helpTarget: ["stop"])
        guard !parsed.positionals.isEmpty else { throw unsupported("docker stop requires at least 1 argument.") }
        let out = try translatedFlags(parsed, label: "stop")
        return .run(containerArgs: ["stop"] + out.args + parsed.positionals, notes: out.notes)
    }

    /// `container` has no restart: stop, then start each container again. (The shim refuses to do this
    /// for containers started with `--rm`, which apple/container deletes on stop — see `DockerShimSafety`.)
    static func restart(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, stopFlags, label: "restart", helpTarget: nil)
        guard !parsed.positionals.isEmpty else { throw unsupported("docker restart requires at least 1 argument.") }
        let out = try translatedFlags(parsed, label: "restart")
        let commands = [["stop"] + out.args + parsed.positionals] + parsed.positionals.map { ["start", $0] }
        return .sequence(commands: commands, notes: out.notes)
    }

    private static let killFlags: [DockerFlag] = [DockerFlag("-s --signal", value: true, .emit("--signal"))]

    static func kill(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, killFlags, label: "kill", helpTarget: ["kill"])
        guard !parsed.positionals.isEmpty else { throw unsupported("docker kill requires at least 1 argument.") }
        let out = try translatedFlags(parsed, label: "kill")
        return .run(containerArgs: ["kill"] + out.args + parsed.positionals, notes: out.notes)
    }

    private static let rmFlags: [DockerFlag] = [
        DockerFlag("-f --force", .emit("--force")),
        DockerFlag("-v --volumes", .drop("anonymous volumes are kept; remove them with docker volume rm")),
        DockerFlag("-l --link", .reject("legacy links don't exist in apple/container")),
    ]

    static func rm(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, rmFlags, label: "rm", helpTarget: ["delete"])
        guard !parsed.positionals.isEmpty else { throw unsupported("docker rm requires at least 1 argument.") }
        let out = try translatedFlags(parsed, label: "rm")
        return .run(containerArgs: ["delete"] + out.args + parsed.positionals, notes: out.notes)
    }

    static func containerPrune(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let flags = [DockerFlag("-f --force", .handled), DockerFlag("--filter", value: true, .reject("apple/container can't filter what it prunes"))]
        let parsed = try parse(args, flags, label: "container prune", helpTarget: ["prune"])
        try requirePositionals(parsed, 0...0, label: "container prune")
        _ = try translatedFlags(parsed, label: "container prune")
        let run = DockerTranslation.run(containerArgs: ["prune"], notes: [])
        if parsed.has("--force") { return run }
        return .confirm(prompt: "WARNING! This will remove all stopped containers.", then: run)
    }

    // MARK: - logs / inspect / cp / stats / commit / export

    private static let logsFlags: [DockerFlag] = [
        DockerFlag("-f --follow", .emit("--follow")),
        DockerFlag("-n --tail", value: true, .custom { value, _, out in
            if let value, value != "all" { out.args += ["-n", value] }
        }),
        DockerFlag("--since", value: true, .drop("apple/container can't filter logs by time")),
        DockerFlag("--until", value: true, .drop("apple/container can't filter logs by time")),
        DockerFlag("-t --timestamps", .drop("apple/container doesn't record log timestamps")),
        DockerFlag("--details", .ignore),
    ]

    static func logs(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, logsFlags, label: "logs", helpTarget: ["logs"])
        try requirePositionals(parsed, 1...1, label: "logs")
        let out = try translatedFlags(parsed, label: "logs")
        return .run(containerArgs: ["logs"] + out.args + parsed.positionals, notes: out.notes)
    }

    private static let inspectFlags: [DockerFlag] = [
        DockerFlag("-f --format", value: true, .custom { value, spelling, out in
            if value != "json", value != "{{json .}}" {
                out.reject(spelling, "Go templates can't be translated; pipe apple/container's JSON through jq")
            }
        }),
        DockerFlag("-s --size", .ignore),
        DockerFlag("--type", value: true, .handled),
    ]

    static func inspect(_ args: [String], _ options: Options) throws -> DockerTranslation {
        try inspect(args, options, type: nil)
    }

    static func inspect(_ args: [String], _ options: Options, type fixedType: String?) throws -> DockerTranslation {
        let parsed = try parse(args, inspectFlags, label: "inspect", helpTarget: ["inspect"])
        guard !parsed.positionals.isEmpty else { throw unsupported("docker inspect requires at least 1 argument.") }
        let out = try translatedFlags(parsed, label: "inspect")
        let type = fixedType ?? parsed.last("--type") ?? "container"
        let command: [String]
        switch type {
        case "container": command = ["inspect"]
        case "image": command = ["image", "inspect"]
        case "volume": command = ["volume", "inspect"]
        case "network": command = ["network", "inspect"]
        default: throw unsupported("docker inspect --type \(type) is not supported (container, image, volume or network).")
        }
        return .run(containerArgs: command + parsed.positionals, notes: out.notes)
    }

    private static let cpFlags: [DockerFlag] = [
        DockerFlag("-a --archive", .drop("apple/container copies without preserving uid/gid")),
        DockerFlag("-L --follow-link", .drop("apple/container copies links as they are")),
        DockerFlag("-q --quiet", .ignore),
    ]

    static func cp(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, cpFlags, label: "cp", helpTarget: ["copy"])
        try requirePositionals(parsed, 2...2, label: "cp")
        if parsed.positionals.contains("-") {
            throw unsupported("docker cp with - (a tar stream on stdin/stdout) is not supported; copy to or from a path.")
        }
        let out = try translatedFlags(parsed, label: "cp")
        return .run(containerArgs: ["copy"] + parsed.positionals, notes: out.notes)
    }

    private static let statsFlags: [DockerFlag] = [
        DockerFlag("-a --all", .drop("apple/container shows running containers only")),
        DockerFlag("--no-stream", .emit("--no-stream")),
        DockerFlag("--no-trunc", .ignore),
        formatFlag,
    ]

    static func stats(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, statsFlags, label: "stats", helpTarget: ["stats"])
        let out = try translatedFlags(parsed, label: "stats")
        return .run(containerArgs: ["stats"] + out.args + parsed.positionals, notes: out.notes)
    }

    private static let commitFlags: [DockerFlag] = [
        DockerFlag("-a --author", value: true, .drop("apple/container doesn't record an author")),
        DockerFlag("-m --message", value: true, .drop("apple/container doesn't record a commit message")),
        DockerFlag("-p --pause", .ignore),
        DockerFlag("-c --change", value: true, .reject("apple/container can't apply Dockerfile instructions on commit")),
    ]

    static func commit(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, commitFlags, label: "commit", helpTarget: ["commit"])
        guard parsed.positionals.count == 2 else {
            throw unsupported("docker commit needs a container and an image name (apple/container has no untagged commits).")
        }
        let out = try translatedFlags(parsed, label: "commit")
        return .run(containerArgs: ["commit"] + parsed.positionals, notes: out.notes)
    }

    private static let exportFlags: [DockerFlag] = [DockerFlag("-o --output", value: true, .emit("--output"))]

    static func export(_ args: [String], _ options: Options) throws -> DockerTranslation {
        let parsed = try parse(args, exportFlags, label: "export", helpTarget: ["export"])
        try requirePositionals(parsed, 1...1, label: "export")
        let out = try translatedFlags(parsed, label: "export")
        return .run(containerArgs: ["export"] + out.args + parsed.positionals, notes: out.notes)
    }
}
