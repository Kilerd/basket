import Foundation
import Testing
@testable import BasketCore

/// Splits a test command line on spaces (no quoting needed in these tables).
private func words(_ line: String) -> [String] {
    line.split(separator: " ").map(String.init)
}

private func translate(_ line: String, compose: String? = nil) -> DockerTranslation {
    DockerCommandTranslator.translate(
        words(line), options: .init(hostPlatform: "linux/arm64", composeExecutable: compose))
}

@Suite("Docker shim translator")
struct DockerCommandTranslatorTests {
    /// docker command line → the single `container` command line it runs, with no notes.
    static let plainMappings: [(String, String)] = [
        // Containers
        ("ps", "list"),
        ("ps -a -q", "list --all --quiet"),
        ("ps -aq --no-trunc", "list --all --quiet"),
        ("ps --format json", "list --format json"),
        ("container ls -a", "list --all"),
        ("container list", "list"),
        ("run -d --name web -p 8080:80 nginx", "run -d --name web -p 8080:80 nginx"),
        ("run -it --rm alpine sh", "run -i -t --rm alpine sh"),
        ("run -dit alpine", "run -d -i -t alpine"),
        ("run --memory=1g -p8080:80 --cpus 2 alpine", "run -m 1g -p 8080:80 --cpus 2 alpine"),
        ("run -e A=1 --env B=2 --env-file .env -w /app -u 1000:1000 --entrypoint sh alpine",
         "run -e A=1 -e B=2 --env-file .env -w /app -u 1000:1000 --entrypoint sh alpine"),
        ("run -v /data:/data:ro --mount type=volume,source=db,target=/db --tmpfs /run alpine",
         "run -v /data:/data:ro --mount type=volume,source=db,target=/db --tmpfs /run alpine"),
        ("run --network backend --platform linux/amd64 -l app=web --init --read-only alpine",
         "run --network backend --platform linux/amd64 -l app=web --init --read-only alpine"),
        ("run --net=backend alpine", "run --network backend alpine"),
        ("run --network bridge alpine", "run alpine"),
        ("run --network none alpine", "run --network none alpine"),
        ("run --dns 1.1.1.1 --dns-search example.org --dns-opt ndots:1 --dns-option edns0 alpine",
         "run --dns 1.1.1.1 --dns-search example.org --dns-option ndots:1 --dns-option edns0 alpine"),
        ("run --cap-add NET_ADMIN --cap-drop ALL --ulimit nofile=1024 --shm-size 64m --cidfile /tmp/id alpine",
         "run --cap-add NET_ADMIN --cap-drop ALL --ulimit nofile=1024 --shm-size 64m --cidfile /tmp/id alpine"),
        ("run --restart no --pull missing --rm=false alpine", "run alpine"),
        ("run -q alpine", "run --progress none alpine"),
        ("run --cpus 2.0 alpine", "run --cpus 2 alpine"),
        ("run alpine ls -la --name x -p 1", "run alpine ls -la --name x -p 1"),
        ("run -- alpine echo hi", "run alpine echo hi"),
        ("run -p 127.0.0.1:8080:80/udp -p 8000-8001:80-81 alpine",
         "run -p 127.0.0.1:8080:80/udp -p 8000-8001:80-81 alpine"),
        ("create --name db -e POSTGRES_PASSWORD=example postgres",
         "create --name db -e POSTGRES_PASSWORD=example postgres"),
        ("container run -d alpine", "run -d alpine"),
        ("start web", "start web"),
        ("start -ai web", "start --attach --interactive web"),
        ("stop web db", "stop web db"),
        ("stop -t 5 web", "stop --time 5 web"),
        ("stop --time=5 --signal SIGINT web", "stop --time 5 --signal SIGINT web"),
        ("kill web", "kill web"),
        ("kill -s HUP web", "kill --signal HUP web"),
        ("rm web", "delete web"),
        ("rm -f web db", "delete --force web db"),
        ("container rm --force web", "delete --force web"),
        ("logs web", "logs web"),
        ("logs -f --tail 10 web", "logs --follow -n 10 web"),
        ("logs -n 5 web", "logs -n 5 web"),
        ("logs --tail=all --details web", "logs web"),
        ("exec web echo hi", "exec web echo hi"),
        ("exec -it web sh", "exec -i -t web sh"),
        ("exec -d -e A=1 -u root -w /tmp web ls -l", "exec -d -e A=1 -u root -w /tmp web ls -l"),
        ("inspect web", "inspect web"),
        ("inspect --type image alpine", "image inspect alpine"),
        ("inspect --type=volume data", "volume inspect data"),
        ("inspect -f json web", "inspect web"),
        ("container inspect web", "inspect web"),
        ("cp web:/etc/hosts ./hosts", "copy web:/etc/hosts ./hosts"),
        ("cp ./app.conf web:/etc/app.conf", "copy ./app.conf web:/etc/app.conf"),
        ("stats", "stats"),
        ("stats --no-stream web", "stats --no-stream web"),
        ("commit web snapshot:1", "commit web snapshot:1"),
        ("export -o fs.tar web", "export --output fs.tar web"),
        ("export web", "export web"),
        // Images
        ("images", "image list"),
        ("images -q", "image list --quiet"),
        ("images -a --digests", "image list --verbose"),
        ("image ls", "image list"),
        ("image list --format json", "image list --format json"),
        ("pull alpine", "image pull --platform linux/arm64 alpine"),
        ("pull --platform linux/amd64 nginx:1.27", "image pull --platform linux/amd64 nginx:1.27"),
        ("pull -q redis", "image pull --platform linux/arm64 --progress none redis"),
        ("image pull alpine", "image pull --platform linux/arm64 alpine"),
        ("push ghcr.io/acme/app:1", "image push ghcr.io/acme/app:1"),
        ("tag alpine ghcr.io/acme/alpine:1", "image tag alpine ghcr.io/acme/alpine:1"),
        ("rmi alpine", "image delete alpine"),
        ("rmi -f alpine redis", "image delete --force alpine redis"),
        ("image rm alpine", "image delete alpine"),
        ("save -o alpine.tar alpine", "image save --output alpine.tar alpine"),
        ("save alpine", "image save alpine"),
        ("load -i alpine.tar", "image load --input alpine.tar"),
        ("load", "image load"),
        ("image inspect alpine", "image inspect alpine"),
        ("image prune -f", "image prune"),
        ("image prune -a -f", "image prune --all"),
        ("build .", "build ."),
        ("build", "build ."),
        ("build -t app -f Dockerfile.dev --build-arg A=1 --target prod --no-cache --platform linux/arm64 --progress plain .",
         "build --tag app --file Dockerfile.dev --build-arg A=1 --target prod --no-cache --platform linux/arm64 --progress plain ."),
        ("build -q --label a=b --pull --load --secret id=npm,src=.npmrc --ssh default -o type=local,dest=out ctx",
         "build --quiet --label a=b --pull --secret id=npm,src=.npmrc --ssh default --output type=local,dest=out ctx"),
        ("build --progress=quiet .", "build --quiet ."),
        ("buildx build -t app .", "build --tag app ."),
        ("image build -t app .", "build --tag app ."),
        // Volumes and networks
        ("volume create data", "volume create data"),
        ("volume create --name data --label a=b -o size=1G -d local", "volume create --label a=b --opt size=1G data"),
        ("volume ls", "volume list"),
        ("volume ls -q", "volume list --quiet"),
        ("volume rm data cache", "volume delete data cache"),
        ("volume inspect data", "volume inspect data"),
        ("volume prune -a -f", "volume prune"),
        ("network create backend", "network create backend"),
        ("network create -d bridge --subnet 10.10.0.0/24 --internal --label a=b -o mtu=1400 backend",
         "network create --subnet 10.10.0.0/24 --internal --label a=b --option mtu=1400 backend"),
        ("network create --subnet fd00::/64 v6", "network create --subnet-v6 fd00::/64 v6"),
        ("network ls", "network list"),
        ("network ls -q", "network list --quiet"),
        ("network rm backend", "network delete backend"),
        ("network inspect backend", "network inspect backend"),
        ("network prune -f", "network prune"),
        // Registry and system
        ("login", "registry login docker.io"),
        ("login ghcr.io -u demo --password-stdin", "registry login --username demo --password-stdin ghcr.io"),
        ("login https://index.docker.io/v1/", "registry login docker.io"),
        ("login http://localhost:5000", "registry login --scheme http localhost:5000"),
        ("logout", "registry logout docker.io"),
        ("logout ghcr.io", "registry logout ghcr.io"),
        ("system df", "system df"),
        ("system df --format json", "system df --format json"),
        ("system info", "system status"),
        ("info", "system status"),
        ("version", "system version"),
        ("version -f json", "system version --format json"),
        ("--version", "--version"),
        ("-v", "--version"),
        ("--debug ps", "--debug list"),
        ("-D images", "--debug image list"),
    ]

    @Test(arguments: plainMappings)
    func translatesWithoutNotes(_ docker: String, _ container: String) {
        let result = translate(docker)
        guard case .run(let args, let notes) = result else {
            Issue.record("docker \(docker) → \(result)")
            return
        }
        #expect(args == words(container), "docker \(docker)")
        let allowedNotes = docker.contains("--format json") || docker.contains("-f json")
        #expect(notes.isEmpty || allowedNotes, "docker \(docker): \(notes)")
    }

    /// docker command line → container command line + a note mentioning the given text.
    static let mappingsWithNotes: [(String, String, String)] = [
        ("run --restart always alpine", "run alpine", "--restart"),
        ("run --restart=unless-stopped -d alpine", "run -d alpine", "restart policies"),
        ("run --health-cmd true --health-interval 5s alpine", "run alpine", "health checks"),
        ("run --log-driver none --log-opt max-size=1m alpine", "run alpine", "--log-driver"),
        ("run --pull always alpine", "run alpine", "--pull"),
        ("run -p 80 alpine", "run -p 80:80 alpine", "no random host ports"),
        ("run -p 127.0.0.1::80/udp alpine", "run -p 127.0.0.1:80:80/udp alpine", "127.0.0.1::80/udp"),
        ("run -p [::1]::443 alpine", "run -p [::1]:443:443 alpine", "random host ports"),
        ("run -v ./site:/usr/share/nginx/html:cached nginx", "run -v ./site:/usr/share/nginx/html nginx", "cached"),
        ("run -v ./src:/src:ro,delegated alpine", "run -v ./src:/src:ro alpine", "delegated"),
        ("run --cpus 1.5 alpine", "run --cpus 2 alpine", "whole CPUs"),
        ("run --cpus=0.5 alpine", "run --cpus 1 alpine", "rounding --cpus 0.5 up to 1"),
        ("run -h db --hostname=db alpine", "run alpine", "container name"),
        ("run -c 512 --memory-swap 1g --pids-limit 100 alpine", "run alpine", "--cpus and --memory"),
        ("run --stop-timeout 30 alpine", "run alpine", "--stop-timeout"),
        ("run --network-alias db --network backend alpine", "run --network backend alpine", "--network-alias"),
        ("run --security-opt seccomp=unconfined --sysctl a=1 alpine", "run alpine", "own VM"),
        ("run -a stdout alpine", "run alpine", "attached"),
        ("run --expose 80 alpine", "run alpine", "-p host:container"),
        ("create --restart always alpine", "create alpine", "--restart"),
        ("rm -v web", "delete web", "anonymous volumes"),
        ("logs --since 1h -t web", "logs web", "by time"),
        ("stats -a", "stats", "running containers only"),
        ("cp -a web:/a ./a", "copy web:/a ./a", "uid/gid"),
        ("volume rm -f data", "volume delete data", "in use"),
        ("load --platform linux/arm64 -i a.tar", "image load --input a.tar", "every platform"),
        ("build --cache-from type=registry,ref=x -t app .", "build --tag app .", "cache"),
        ("build --network host .", "build .", "--network"),
        ("build --progress rawjson .", "build --progress plain .", "rawjson"),
        ("system df -v", "system df", "-v"),
        ("ps --format json", "list --format json", "differ from Docker"),
        ("--log-level debug ps", "list", "--log-level"),
    ]

    @Test(arguments: mappingsWithNotes)
    func translatesWithNote(_ docker: String, _ container: String, _ noteFragment: String) {
        let result = translate(docker)
        guard case .run(let args, let notes) = result else {
            Issue.record("docker \(docker) → \(result)")
            return
        }
        #expect(args == words(container), "docker \(docker)")
        #expect(notes.contains { $0.contains(noteFragment) }, "docker \(docker): \(notes)")
    }

    /// docker command lines the shim refuses, with a fragment of the message.
    static let rejections: [(String, String)] = [
        ("run --privileged alpine", "--privileged is not supported"),
        ("run --gpus all alpine", "--gpus"),
        ("run --device /dev/fuse alpine", "--device"),
        ("run --device-cgroup-rule a alpine", "--device-cgroup-rule"),
        ("run --add-host db:10.0.0.2 alpine", "--add-host"),
        ("run -P nginx", "-P is not supported"),
        ("run --publish-all nginx", "--publish-all"),
        ("run --pid host alpine", "--pid host"),
        ("run --ipc=host alpine", "--ipc host"),
        ("run --userns host alpine", "--userns host"),
        ("run --uts host alpine", "--uts host"),
        ("run --pid container:web alpine", "--pid container:web"),
        ("run --network host alpine", "--network host"),
        ("run --net container:web alpine", "container:web"),
        ("run --volumes-from web alpine", "--volumes-from"),
        ("run --link db:db alpine", "--link"),
        ("run --label-file labels alpine", "--label-file"),
        ("run --bogus alpine", "unknown or unsupported flag --bogus"),
        ("run -Z alpine", "unknown or unsupported flag -Z"),
        ("run --name", "flag needs an argument: --name"),
        ("run -d", "requires at least 1 argument"),
        ("create -d alpine", "unknown or unsupported flag -d"),
        ("create --privileged alpine", "--privileged"),
        ("exec --privileged web sh", "--privileged"),
        ("exec web", "requires at least 2 arguments"),
        ("ps --filter name=web", "--filter"),
        ("ps -f status=exited", "-f is not supported"),
        ("ps --format {{.Names}}", "Go templates"),
        ("ps -n 3", "-n"),
        ("images alpine", "REPOSITORY"),
        ("inspect -f {{.State.Status}} web", "Go templates"),
        ("inspect --type plugin x", "--type plugin"),
        ("cp - web:/tmp", "tar stream"),
        ("logs a b", "exactly 1 argument"),
        ("start -a a b", "one container at a time"),
        ("pull -a alpine", "-a is not supported: pull each tag"),
        ("pull", "exactly 1 argument"),
        ("rmi --platform linux/amd64 alpine", "--platform"),
        ("build -f - .", "-f -"),
        ("build https://github.com/acme/app.git", "local directory"),
        ("build --push .", "needs a name"),
        ("build --add-host a:1.2.3.4 .", "--add-host"),
        ("volume create", "needs a name"),
        ("volume create -d nfs data", "-d nfs"),
        ("volume prune", "--all"),
        ("volume prune -f", "named ones included"),
        ("network create -d overlay mesh", "-d overlay"),
        ("network create --gateway 10.0.0.1 n", "--gateway"),
        ("network connect backend web", "network connect is not supported"),
        ("login -p secret", "--password-stdin"),
        ("system prune --volumes", "--volumes"),
        ("system events", "system events is not supported"),
        ("--context orbstack ps", "--context is not supported"),
        ("-H tcp://127.0.0.1:2375 ps", "-H is not supported"),
        ("--config /tmp/docker ps", "--config is not supported"),
        ("--tlsverify ps", "--tlsverify"),
        ("--bogus ps", "global flag --bogus"),
        ("compose up -d", "docker compose is not supported"),
        ("top web", "docker top is not supported"),
        ("frobnicate", "'frobnicate' is not a docker command"),
        ("container frobnicate", "container frobnicate is not supported"),
        ("image history alpine", "image history is not supported"),
    ]

    @Test(arguments: rejections)
    func refuses(_ docker: String, _ messageFragment: String) {
        let result = translate(docker)
        guard case .unsupported(let message) = result else {
            Issue.record("docker \(docker) should be unsupported, got \(result)")
            return
        }
        #expect(message.contains(messageFragment), "docker \(docker): \(message)")
    }

    // MARK: - Sequences, confirmations, help, hooks

    @Test func restartIsStopThenStartForEachContainer() {
        #expect(translate("restart -t 3 web db") == .sequence(
            commands: [["stop", "--time", "3", "web", "db"], ["start", "web"], ["start", "db"]], notes: []))
        #expect(translate("container restart web") == .sequence(commands: [["stop", "web"], ["start", "web"]], notes: []))
    }

    @Test func startingSeveralContainersStartsEachInTurn() {
        #expect(translate("start web db") == .sequence(commands: [["start", "web"], ["start", "db"]], notes: []))
    }

    @Test func buildWithSeveralTagsTagsAndPushes() {
        #expect(translate("build -t app:1 -t app:latest --push .") == .sequence(
            commands: [
                ["build", "--tag", "app:1", "."], ["image", "tag", "app:1", "app:latest"],
                ["image", "push", "app:1"], ["image", "push", "app:latest"],
            ],
            notes: []))
    }

    @Test func debugFlagPrefixesEveryCommand() {
        #expect(translate("-D restart web") == .sequence(
            commands: [["--debug", "stop", "web"], ["--debug", "start", "web"]], notes: []))
    }

    @Test func prunesAskFirstUnlessForced() {
        #expect(translate("container prune") == .confirm(
            prompt: "WARNING! This will remove all stopped containers.",
            then: .run(containerArgs: ["prune"], notes: [])))
        #expect(translate("container prune -f") == .run(containerArgs: ["prune"], notes: []))
        guard case .confirm(let prompt, let then) = translate("image prune -a") else {
            Issue.record("image prune -a should confirm")
            return
        }
        #expect(prompt.contains("without at least one container"))
        #expect(then == .run(containerArgs: ["image", "prune", "--all"], notes: []))
        guard case .confirm(_, let networkThen) = translate("network prune") else {
            Issue.record("network prune should confirm")
            return
        }
        #expect(networkThen.containerCommands == [["network", "prune"]])
        guard case .confirm(_, let volumeThen) = translate("volume prune --all") else {
            Issue.record("volume prune --all should confirm")
            return
        }
        #expect(volumeThen.containerCommands == [["volume", "prune"]])
    }

    @Test func systemPruneIsContainersNetworksAndImages() {
        let forced = translate("system prune -f")
        #expect(forced.containerCommands == [["prune"], ["network", "prune"], ["image", "prune"]])
        #expect(forced.notes.contains { $0.contains("build cache") })
        guard case .confirm(let prompt, let then) = translate("system prune -a") else {
            Issue.record("system prune should confirm")
            return
        }
        #expect(prompt.contains("all stopped containers"))
        #expect(then.containerCommands == [["prune"], ["network", "prune"], ["image", "prune", "--all"]])
    }

    @Test func helpForNoArgumentsAndGlobalHelp() {
        for line in ["", "--help", "-h", "help", "container", "image --help"] {
            guard case .help(let text) = translate(line) else {
                Issue.record("docker \(line) should print help")
                continue
            }
            #expect(text.contains("Usage:  docker COMMAND"))
            #expect(text.contains("BASKET_DOCKER_DRYRUN"))
        }
    }

    @Test func commandHelpShowsContainersHelp() {
        guard case .run(let args, let notes) = translate("run --help") else {
            Issue.record("run --help")
            return
        }
        #expect(args == ["run", "--help"])
        #expect(notes.first?.contains("container run") == true)
        #expect(translate("help ps").containerCommands == [["list", "--help"]])
        #expect(translate("ps -h").containerCommands == [["list", "--help"]])
        #expect(translate("pull --help").containerCommands == [["image", "pull", "--help"]])
        // -h is --hostname for run, not help.
        #expect(translate("run -h db alpine").containerCommands == [["run", "alpine"]])
    }

    @Test func composeIsDelegatedWhenAHelperExists() {
        #expect(translate("compose up -d", compose: "/opt/basket/basket-compose")
            == .delegate(executable: "/opt/basket/basket-compose", arguments: ["up", "-d"], notes: []))
    }

    @Test func pullUsesTheConfiguredHostPlatform() {
        let result = DockerCommandTranslator.translate(["pull", "alpine"], options: .init(hostPlatform: "linux/amd64"))
        #expect(result.containerCommands == [["image", "pull", "--platform", "linux/amd64", "alpine"]])
        #expect(DockerCommandTranslator.translate(["pull", "alpine"]).containerCommands
            == [["image", "pull", "--platform", DockerCommandTranslator.hostPlatform, "alpine"]])
    }

    @Test func notesAreNotRepeated() {
        let notes = translate("run --restart always --restart always alpine").notes
        #expect(notes.count == 1)
    }

    @Test func confirmationAnswers() {
        #expect(DockerCommandTranslator.isConfirmation("y\n"))
        #expect(DockerCommandTranslator.isConfirmation("YES"))
        #expect(!DockerCommandTranslator.isConfirmation(""))
        #expect(!DockerCommandTranslator.isConfirmation("n"))
    }

    // MARK: - Pieces

    @Test(arguments: [
        ("80", "80:80", true), ("8080:80", "8080:80", false), ("80/udp", "80:80/udp", true),
        ("127.0.0.1:8080:80", "127.0.0.1:8080:80", false), ("127.0.0.1::80", "127.0.0.1:80:80", true),
        ("8000-8001", "8000-8001:8000-8001", true), ("[::1]:8080:80", "[::1]:8080:80", false),
    ])
    func publishSpecs(_ docker: String, _ container: String, _ filled: Bool) {
        let result = DockerCommandTranslator.publishSpec(docker)
        #expect(result.spec == container)
        #expect(result.filledHostPort == filled)
    }

    @Test(arguments: [
        ("/a:/b", "/a:/b"), ("/a:/b:ro", "/a:/b:ro"), ("/a:/b:cached", "/a:/b"), ("/a:/b:ro,z", "/a:/b:ro"),
        ("data:/var/lib/data:nocopy", "data:/var/lib/data"), ("/anonymous", "/anonymous"),
    ])
    func volumeSpecs(_ docker: String, _ container: String) {
        #expect(DockerCommandTranslator.volumeSpec(docker).spec == container)
    }

    @Test func parserFollowsPflagRules() throws {
        let flags = [
            DockerFlag("-d --detach", .emit("-d")), DockerFlag("-e --env", value: true, .emit("-e")),
            DockerFlag("--rm", .emit("--rm")),
        ]
        let parsed = try DockerArgParser.parse(
            ["-de=A=1", "--rm=true", "--env", "B=2", "image", "-d", "--rm"], flags: flags, interspersed: false).get()
        #expect(parsed.flags.map(\.spelling) == ["-d", "-e", "--rm", "--env"])
        #expect(parsed.values("--env") == ["A=1", "B=2"])
        #expect(parsed.positionals == ["image", "-d", "--rm"])
        let interspersed = try DockerArgParser.parse(["a", "-d", "b", "--", "-e"], flags: flags).get()
        #expect(interspersed.positionals == ["a", "b", "-e"])
        #expect(interspersed.has("--detach"))
        #expect(DockerArgParser.parse(["-x"], flags: flags).failureValue == .unknownFlag("-x"))
        #expect(DockerArgParser.parse(["-e"], flags: flags).failureValue == .missingValue("-e"))
    }

    // MARK: - Runtime helpers

    @Test func rendersShellReadyCommands() {
        #expect(DockerShimRuntime.render(["run", "alpine", "sh", "-c", "echo hi"]) == "container run alpine sh -c 'echo hi'")
    }

    @Test func restartRefusesContainersThatAreDeletedOnStop() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        for (id, autoRemove) in [("basket-test-rm", true), ("basket-test-keep", false)] {
            let dir = temp.url.appending(path: "containers/\(id)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(#"{"autoRemove": \#(autoRemove)}"#.utf8).write(to: dir.appending(path: "options.json"))
        }
        let restart = translate("restart basket-test-rm basket-test-keep basket-test-unknown")
        #expect(DockerShimRuntime.containersDeletedByRestart(restart, appRoot: temp.url) == ["basket-test-rm"])
        #expect(DockerShimRuntime.containersDeletedByRestart(translate("start basket-test-rm basket-test-keep"), appRoot: temp.url).isEmpty)
    }

    @Test func composeHookFindsAnExplicitHelper() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        let helper = try temp.script("basket-compose", "exit 0")
        #expect(DockerShimRuntime.composeExecutable(environment: ["BASKET_COMPOSE_CLI": helper], shimPath: "/nonexistent/docker") == helper)
        let sibling = DockerShimRuntime.composeExecutable(environment: [:], shimPath: temp.url.appending(path: "docker").path)
        #expect(sibling == URL(fileURLWithPath: helper).resolvingSymlinksInPath().path)
        #expect(DockerShimRuntime.composeExecutable(environment: [:], shimPath: "/nonexistent/docker") == nil)
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
