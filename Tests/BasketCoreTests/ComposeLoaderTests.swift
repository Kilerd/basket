import Foundation
import Testing
@testable import BasketCore

@Suite("Compose interpolation")
struct ComposeInterpolationTests {
    func run(_ text: String, _ env: [String: String] = [:]) throws -> (String, [String]) {
        var unset: [String] = []
        let result = try ComposeInterpolation.interpolate(text, path: "x", unset: &unset) { env[$0] }
        return (result, unset)
    }

    @Test func forms() throws {
        let env = ["TAG": "1.27", "EMPTY": "", "PORT": "8080"]
        #expect(try run("nginx:${TAG}", env).0 == "nginx:1.27")
        #expect(try run("nginx:$TAG-alpine", env).0 == "nginx:1.27-alpine")
        #expect(try run("${MISSING:-fallback}", env).0 == "fallback")
        #expect(try run("${EMPTY:-fallback}", env).0 == "fallback")
        #expect(try run("${EMPTY-fallback}", env).0 == "")
        #expect(try run("${MISSING-fallback}", env).0 == "fallback")
        #expect(try run("${PORT:+set}", env).0 == "set")
        #expect(try run("${EMPTY:+set}", env).0 == "")
        #expect(try run("${EMPTY+set}", env).0 == "set")
        #expect(try run("${MISSING:-${PORT}}", env).0 == "8080")
        #expect(try run("${MISSING:-a-${OTHER:-b}-c}", env).0 == "a-b-c")
        #expect(try run("cost $$5 and $${HOME}", env).0 == "cost $5 and ${HOME}")
        #expect(try run("no variables", env).0 == "no variables")
    }

    @Test func unsetVariablesBecomeEmptyAndAreReported() throws {
        let (value, unset) = try run("${A}/$B/${A}")
        #expect(value == "//")
        #expect(unset == ["A", "B"])
    }

    @Test func requiredVariables() throws {
        #expect(try run("${PW:?set PW}", ["PW": "x"]).0 == "x")
        #expect(throws: ComposeError.missingVariable(name: "PW", message: "set PW", path: "x")) { try run("${PW:?set PW}") }
        #expect(throws: ComposeError.missingVariable(name: "PW", message: "empty", path: "x")) { try run("${PW:?empty}", ["PW": ""]) }
        #expect(try run("${PW?unset only}", ["PW": ""]).0 == "")
    }

    @Test func invalidSyntax() {
        #expect(throws: ComposeError.self) { try run("${UNCLOSED") }
        #expect(throws: ComposeError.self) { try run("price: $5") }
        #expect(throws: ComposeError.self) { try run("${1BAD}") }
    }

    @Test func dotEnv() throws {
        let entries = try ComposeDotEnv.parse("""
            # comment
            export TAG=1.27
            NAME = shop   # trailing comment
            SINGLE='literal ${TAG} # kept'
            DOUBLE="tag ${TAG}\\nline two"
            MULTI="first
            second"
            REF=${TAG}-alpine
            FROM_ENV=${HOME_DIR:-none}
            BARE
            """, file: ".env", lookup: { $0 == "HOME_DIR" ? "/Users/demo" : nil })
        let values = Dictionary(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(entries.map(\.key) == ["TAG", "NAME", "SINGLE", "DOUBLE", "MULTI", "REF", "FROM_ENV", "BARE"])
        #expect(values["TAG"] == "1.27")
        #expect(values["NAME"] == "shop")
        #expect(values["SINGLE"] == "literal ${TAG} # kept")
        #expect(values["DOUBLE"] == "tag 1.27\nline two")
        #expect(values["MULTI"] == "first\nsecond")
        #expect(values["REF"] == "1.27-alpine")
        #expect(values["FROM_ENV"] == "/Users/demo")
        #expect(values["BARE"] == .some(nil))
    }

    @Test func shellSplitting() throws {
        #expect(try ComposeShell.split("npm run start") == ["npm", "run", "start"])
        #expect(try ComposeShell.split(#"sh -c "echo \"hi\" && sleep 1" 'it''s'"#) == ["sh", "-c", #"echo "hi" && sleep 1"#, "its"])
        #expect(try ComposeShell.split(#"a\ b "c\d" 'e\f'"#) == ["a b", #"c\d"#, #"e\f"#])
        #expect(try ComposeShell.split("  ") == [])
        #expect(throws: ComposeError.self) { try ComposeShell.split("echo 'open") }
    }
}

@Suite("Compose loader")
struct ComposeLoaderTests {
    let directory = URL(fileURLWithPath: "/Users/demo/projects/shop")

    func load(_ yaml: String, env: [String: String] = [:]) throws -> ComposeFile {
        try ComposeLoader.load(yaml: yaml, workingDirectory: directory, environment: env)
    }

    @Test func servicesAndTheirSettings() throws {
        let file = try load("""
            name: shop
            services:
              web:
                image: nginx:${NGINX_TAG:-1.27}
                ports:
                  - "8080:80"
                  - 127.0.0.1:8443:443/tcp
                  - 9000
                  - "[::1]:5353:53/udp"
                  - target: 3000
                    published: "3001"
                    host_ip: 0.0.0.0
                depends_on: [api]
                volumes:
                  - ./site:/usr/share/nginx/html:ro
                  - type: bind
                    source: ~/certs
                    target: /etc/certs
                    read_only: true
                  - type: tmpfs
                    target: /var/cache/nginx
              api:
                build: ./api
                image: shop/api:dev
                command: node server.js --port 3000
                entrypoint: ["docker-entrypoint.sh"]
                environment:
                  NODE_ENV: production
                  DEBUG: false
                  RETRIES: 3
                  FROM_SHELL:
                working_dir: /app
                user: "1000:1000"
                mem_limit: 768m
                cpus: 1.5
                labels:
                  com.example.team: storefront
                depends_on:
                  db:
                    condition: service_healthy
                  cache:
                    condition: service_started
                    required: false
                links: ["db:database"]
                extra_hosts:
                  - "host.docker.internal:host-gateway"
                  - "metrics=10.0.0.5"
              db:
                image: postgres:16
                environment:
                  - POSTGRES_PASSWORD=basket
                  - POSTGRES_DB
                volumes:
                  - pgdata:/var/lib/postgresql/data
                  - /var/lib/postgresql/conf
                deploy:
                  resources:
                    limits:
                      memory: 1G
                      cpus: "2"
              cache:
                image: redis:7-alpine
                command: ["redis-server", "--save", ""]
                ulimits:
                  nofile: {soft: 1024, hard: 2048}
                  nproc: 512
                cap_add: [NET_ADMIN]
                read_only: true
                init: true
                tty: true
                stdin_open: true
                shm_size: 64m
                dns: 1.1.1.1
                tmpfs: /run:size=64m
            volumes:
              pgdata:
            """, env: ["FROM_SHELL": "yes", "POSTGRES_DB": "shop"])
        #expect(file.name == "shop")
        #expect(file.services.map(\.name) == ["web", "api", "db", "cache"])

        let web = try #require(file.service("web"))
        #expect(web.image == "nginx:1.27")
        #expect(web.ports == [
            ComposePort(published: "8080", target: "80"),
            ComposePort(hostIP: "127.0.0.1", published: "8443", target: "443"),
            ComposePort(published: nil, target: "9000"),
            ComposePort(hostIP: "::1", published: "5353", target: "53", proto: "udp"),
            ComposePort(hostIP: "0.0.0.0", published: "3001", target: "3000"),
        ])
        #expect(web.mounts == [
            ComposeMount(kind: .bind, source: "./site", target: "/usr/share/nginx/html", readOnly: true),
            ComposeMount(kind: .bind, source: "~/certs", target: "/etc/certs", readOnly: true),
            ComposeMount(kind: .tmpfs, source: nil, target: "/var/cache/nginx"),
        ])
        #expect(web.dependsOn == [.init(service: "api", condition: "service_started", required: true)])

        let api = try #require(file.service("api"))
        #expect(api.build?.context == "./api")
        #expect(api.command == ["node", "server.js", "--port", "3000"])
        #expect(api.entrypoint == ["docker-entrypoint.sh"])
        #expect(api.environment == ["NODE_ENV=production", "DEBUG=false", "RETRIES=3", "FROM_SHELL=yes"])
        #expect(api.workingDir == "/app" && api.user == "1000:1000")
        #expect(api.memoryBytes == 768 << 20)
        #expect(api.cpus == 1.5)
        #expect(api.labels == ["com.example.team": "storefront"])
        #expect(api.dependsOn.map(\.condition) == ["service_healthy", "service_started"])
        #expect(api.dependsOn.map(\.required) == [true, false])
        #expect(api.links == [ComposeLink("db", "database")])
        #expect(api.extraHosts == [ComposeLink("host.docker.internal", "host-gateway"), ComposeLink("metrics", "10.0.0.5")])

        let db = try #require(file.service("db"))
        #expect(db.environment == ["POSTGRES_PASSWORD=basket", "POSTGRES_DB=shop"])
        #expect(db.memoryBytes == 1 << 30)
        #expect(db.cpus == 2)
        #expect(db.mounts == [
            ComposeMount(kind: .volume, source: "pgdata", target: "/var/lib/postgresql/data"),
            ComposeMount(kind: .volume, source: nil, target: "/var/lib/postgresql/conf"),
        ])

        let cache = try #require(file.service("cache"))
        #expect(cache.command == ["redis-server", "--save", ""])
        #expect(cache.ulimits == ["nofile=1024:2048", "nproc=512"])
        #expect(cache.capAdd == ["NET_ADMIN"])
        #expect(cache.readOnly && cache.initProcess && cache.tty && cache.stdinOpen)
        #expect(cache.shmSize == "64M")
        #expect(cache.dns == ["1.1.1.1"])
        #expect(cache.tmpfs == ["/run"])
        #expect(cache.warnings.contains { $0.topic == "tmpfs" })
        #expect(file.volumes == [ComposeVolume(key: "pgdata")])
    }

    @Test func unsupportedKeysBecomeWarnings() throws {
        let file = try load("""
            services:
              app:
                image: alpine
                restart: unless-stopped
                healthcheck:
                  test: ["CMD", "true"]
                privileged: true
                devices: ["/dev/fuse"]
                network_mode: host
                secrets: [token]
                logging: {driver: json-file}
                sysctls: {net.core.somaxconn: 1024}
                x-custom: ignored
                bogus: 1
              quiet:
                image: alpine
                restart: "no"
                healthcheck:
                  disable: true
            secrets:
              token: {file: ./token}
            x-anchors: {}
            """)
        let topics = Set(file.service("app")!.warnings.map(\.topic))
        #expect(topics.isSuperset(of: ["Restart policy", "Healthcheck", "Privileged", "Devices", "network_mode", "Secrets", "logging", "sysctls", "Unknown key"]))
        #expect(file.service("app")!.warnings.first { $0.topic == "logging" }?.severity == .info)
        #expect(file.service("quiet")!.warnings.isEmpty)
        #expect(file.warnings.map(\.topic) == ["Top-level secrets"])
    }

    @Test func dotEnvAndProcessEnvironment() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        try "TAG=7-alpine\nPORT=6379\n".write(to: temp.url.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "FROM_FILE=1\nSHARED=file\n".write(to: temp.url.appendingPathComponent("app.env"), atomically: true, encoding: .utf8)
        let yaml = """
            services:
              cache:
                image: redis:${TAG}
                ports: ["${PORT}:6379"]
                env_file:
                  - app.env
                  - path: ./optional.env
                    required: false
                environment:
                  SHARED: compose
                  UNSET_VAR: ${NOT_THERE}
            """
        let file = try ComposeLoader.load(yaml: yaml, workingDirectory: temp.url, environment: ["PORT": "16379"])
        let cache = try #require(file.service("cache"))
        #expect(cache.image == "redis:7-alpine")
        #expect(cache.ports.first?.published == "16379")  // the shell wins over .env
        #expect(cache.environment == ["FROM_FILE=1", "SHARED=compose", "UNSET_VAR="])
        #expect(file.warnings.map(\.message).contains { $0.hasPrefix("NOT_THERE isn't set") })

        let missing = yaml.replacingOccurrences(of: "  - app.env\n", with: "  - missing.env\n")
        #expect(throws: ComposeError.self) { try ComposeLoader.load(yaml: missing, workingDirectory: temp.url) }
    }

    @Test func loadsFromDiskAndRemembersTheFile() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        let url = temp.url.appendingPathComponent("compose.yaml")
        try "services:\n  web:\n    image: nginx\n".write(to: url, atomically: true, encoding: .utf8)
        let file = try ComposeLoader.load(fileAt: url, environment: [:])
        #expect(file.configFile == url)
        #expect(file.workingDirectory.standardizedFileURL == temp.url.standardizedFileURL)
        #expect(throws: ComposeError.self) { try ComposeLoader.load(fileAt: temp.url.appendingPathComponent("nope.yaml")) }
    }

    @Test(arguments: [
        ("services: {}\n", "services: the file defines no services"),
        ("", "(top level): the file is empty"),
        ("services:\n  web:\n    ports: [80]\n", "services.web: the service needs an “image” (or a “build”)"),
        ("services:\n  web:\n    image: x\n    ports: [\"80:http\"]\n", "services.web.ports[0]: ports must be numbers or ranges like 8000-8010"),
        ("services:\n  web:\n    image: x\n    volumes: [data:/d]\n", "services.web.volumes: uses volume “data”, which isn't declared under the top-level “volumes:”"),
        ("services:\n  web:\n    image: x\n    networks: [front]\n", "services.web.networks: uses network “front”, which isn't declared under the top-level “networks:”"),
        ("services:\n  web:\n    image: x\n    depends_on: [db]\n", "services.web.depends_on: depends on undefined service “db”"),
        ("services:\n  web:\n    image: x\n    environment: [1, [2]]\n", "services.web.environment[1]: expected a string, found a list"),
        ("services:\n  web:\n    image: [x]\n", "services.web.image: expected a string, found a list"),
        ("services:\n  web:\n    image: x\n    mem_limit: lots\n", "services.web.mem_limit: expected a size like 512m or 1g, found “lots”"),
        ("services:\n  web:\n    image: ${IMAGE:?pick an image}\n", "services.web.image: required variable IMAGE is not set (pick an image)"),
        ("services:\n  web:\n    image: x\n  web:\n    image: y\n", "Invalid YAML at line 4, column 3: duplicate key “web”"),
    ])
    func errorsNameTheLocation(_ yaml: String, _ message: String) {
        do {
            _ = try load(yaml)
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription == message)
        }
    }

    @Test func networksAndVolumesTopLevel() throws {
        let file = try load("""
            services:
              web:
                image: nginx
                networks:
                  front:
                    aliases: [www, site]
                  back:
                    ipv4_address: 10.5.0.9
                volumes: [shared:/srv]
            networks:
              front:
                ipam:
                  config:
                    - subnet: 10.4.0.0/24
              back:
                external: true
                name: corp-back
              legacy:
                driver: overlay
                internal: true
            volumes:
              shared:
                external: {name: team-shared}
            """)
        #expect(file.networks == [
            ComposeNetwork(key: "front", subnet: "10.4.0.0/24"),
            ComposeNetwork(key: "back", name: "corp-back", external: true),
            ComposeNetwork(key: "legacy"),
        ])
        #expect(file.volumes == [ComposeVolume(key: "shared", name: "team-shared", external: true)])
        let web = try #require(file.service("web"))
        #expect(web.networks == [
            .init(name: "front", aliases: ["www", "site"], ipv4Address: nil),
            .init(name: "back", aliases: [], ipv4Address: "10.5.0.9"),
        ])
        #expect(web.warnings.map(\.topic) == ["Static IP"])
        #expect(file.warnings.map(\.topic) == ["Network driver", "Internal network"])
    }
}
