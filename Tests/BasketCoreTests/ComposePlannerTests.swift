import Foundation
import Testing
@testable import BasketCore

@Suite("Compose planner")
struct ComposePlannerTests {
    let directory = URL(fileURLWithPath: "/Users/demo/projects/My Shop")
    let options = ComposePlanOptions(hostPathExists: { $0 != "/Users/demo/projects/My Shop/missing" }, homeDirectory: "/Users/demo")

    func plan(_ yaml: String, env: [String: String] = [:], options: ComposePlanOptions? = nil) throws -> ComposePlan {
        var file = try ComposeLoader.load(yaml: yaml, workingDirectory: directory, environment: env)
        file.configFile = directory.appendingPathComponent("compose.yaml")
        return try ComposePlanner.plan(file, options: options ?? self.options)
    }

    static let shop = """
        services:
          web:
            image: nginx:1.27
            ports: ["8080:80"]
            depends_on: [api]
            volumes: [./site:/usr/share/nginx/html:ro, ./missing:/data]
          api:
            image: node:22-alpine
            command: ["node", "server.js"]
            environment: [DATABASE_URL=postgres://db/app]
            depends_on:
              db: {condition: service_healthy}
              cache: {condition: service_started}
            mem_limit: 256m
            cpus: 0.5
            networks:
              default:
              back:
                aliases: [backend]
          db:
            image: postgres:16
            volumes: [pgdata:/var/lib/postgresql/data, /tmp/scratch]
            networks: [back]
            deploy: {resources: {limits: {memory: 1g}}}
          cache:
            image: redis:7-alpine
            container_name: shop-redis
            entrypoint: ["redis-server", "--save"]
            command: ['""']
        networks:
          back:
        volumes:
          pgdata:
        """

    @Test func namesOrderAndLabels() throws {
        let plan = try plan(Self.shop)
        #expect(plan.project == "myshop")  // directory name, normalised
        #expect(plan.services.map(\.name) == ["db", "cache", "api", "web"])
        #expect(plan.networks.map(\.name) == ["myshop_default", "myshop_back"])
        #expect(plan.volumes.map(\.name) == ["myshop_pgdata", "myshop_db_tmp-scratch"])

        let api = try #require(plan.services.first { $0.name == "api" })
        #expect(api.containerName == "myshop-api-1")
        #expect(api.spec.memory == "256M" && api.spec.cpus == 1)
        #expect(api.spec.network == "myshop_default" && api.spec.additionalNetworks == ["myshop_back"])
        #expect(api.dependsOn == ["db", "cache"])
        #expect(api.hostNames == ["api", "myshop-api-1", "backend"])
        #expect(api.spec.labels == [
            "com.docker.compose.project": "myshop",
            "com.docker.compose.service": "api",
            "com.docker.compose.container-number": "1",
            "com.docker.compose.oneoff": "False",
            "com.docker.compose.project.working_dir": "/Users/demo/projects/My Shop",
            "com.docker.compose.project.config_files": "/Users/demo/projects/My Shop/compose.yaml",
            "com.docker.compose.depends_on": "db:service_healthy:false,cache:service_started:false",
            "dev.basket.compose": "1",
            "dev.basket.compose.aliases": "backend",
        ])

        let cache = try #require(plan.services.first { $0.name == "cache" })
        #expect(cache.containerName == "shop-redis")
        #expect(cache.hostNames == ["cache", "shop-redis", "myshop-cache-1"])
        #expect(cache.spec.entrypoint == "redis-server")
        #expect(cache.spec.command == ["--save", "\"\""])

        let web = try #require(plan.services.first { $0.name == "web" })
        #expect(web.spec.ports == ["8080:80"])
        #expect(web.portsSummary == "8080→80")
        #expect(web.spec.volumes == [
            "/Users/demo/projects/My Shop/site:/usr/share/nginx/html:ro", "/Users/demo/projects/My Shop/missing:/data",
        ])
        #expect(web.bindDirectories == ["/Users/demo/projects/My Shop/missing"])

        let db = try #require(plan.services.first { $0.name == "db" })
        #expect(db.spec.network == "myshop_back")
        #expect(db.spec.volumes == ["myshop_pgdata:/var/lib/postgresql/data", "myshop_db_tmp-scratch:/tmp/scratch"])
        #expect(db.memoryBytes == 1 << 30 && !db.memoryIsDefault)
        #expect(plan.networks[0].labels == [
            "com.docker.compose.project": "myshop", "com.docker.compose.network": "default", "dev.basket.compose": "1",
        ])
    }

    @Test func defaultsAndResourceSummary() throws {
        let plan = try plan(Self.shop, options: ComposePlanOptions(defaultMemory: "512M", defaultCPUs: 2, hostPathExists: { _ in true }))
        let web = try #require(plan.services.first { $0.name == "web" })
        #expect(web.spec.memory == "512M" && web.memoryIsDefault && web.spec.cpus == 2)
        #expect(plan.resources.services == 4)
        #expect(plan.resources.memoryLimitBytes == (512 + 512 + 256 + 1024) << 20)
        // 238 MiB per VM up to 256 MiB, +25 MiB per doubling above it (see MemoryInsights).
        #expect(plan.resources.overheadBytes == (263 + 263 + 238 + 288) << 20)
        #expect(plan.resources.cpus == 2 + 2 + 1 + 2 && plan.resources.defaultCPUServices == 0)
        let memoryNote = try #require(plan.warnings.first { $0.topic == "Memory" })
        #expect(memoryNote.message == "cache, web set no memory limit. Each container is its own VM, so they get 512M each; set mem_limit to change it.")
    }

    @Test func warningsExplainWhatDoesNotCarryOver() throws {
        let plan = try plan(Self.shop)
        let topics = plan.warnings.map { "\($0.service ?? "*"):\($0.topic)" }
        #expect(topics.first == "*:Service names")
        #expect(topics.contains("api:depends_on"))
        #expect(topics.contains("api:CPUs"))
        #expect(topics.contains("web:Bind mount"))
        #expect(topics.contains("db:Anonymous volume"))
        let hosts = try #require(plan.warnings.first)
        #expect(hosts.message.contains("/etc/hosts"))
    }

    @Test func commandLinesMatchTheCLIBackend() throws {
        let plan = try plan(Self.shop)
        let lines = plan.commandLines()
        #expect(lines[0] == "container network create --label com.docker.compose.network=default --label com.docker.compose.project=myshop --label dev.basket.compose=1 myshop_default")
        #expect(lines[2].hasPrefix("container volume create --label com.docker.compose.project=myshop"))
        let web = try #require(lines.first { $0.contains("--name myshop-web-1") })
        #expect(web.hasPrefix("container run --detach --progress none --name myshop-web-1 --memory 512M --publish 8080:80 --volume '/Users/demo/projects/My Shop/site:/usr/share/nginx/html:ro'"))
        #expect(web.hasSuffix(" nginx:1.27"))
        #expect(lines.last?.hasPrefix("# then") == true)
        #expect(lines.count == 2 + 2 + 4 + 1)
    }

    @Test func projectNamePrecedenceAndNormalisation() throws {
        #expect(ComposePlanner.normalizeProjectName("My Shop!") == "myshop")
        #expect(ComposePlanner.normalizeProjectName("__Demo-App_2") == "demo-app_2")
        #expect(try plan("name: Storefront\nservices: {a: {image: x}}\n").project == "storefront")
        #expect(try plan("name: Storefront\nservices: {a: {image: x}}\n", env: ["COMPOSE_PROJECT_NAME": "other"]).project == "other")
        var custom = options
        custom.projectName = "basket-test-x"
        #expect(try plan("name: Storefront\nservices: {a: {image: x}}\n", options: custom).project == "basket-test-x")
    }

    @Test func profilesAndDependencies() throws {
        let yaml = """
            services:
              app: {image: app, depends_on: [db]}
              db: {image: postgres, profiles: [data]}
              debug: {image: busybox, profiles: [debug]}
            """
        let plan = try plan(yaml)
        #expect(plan.services.map(\.name) == ["db", "app"])
        #expect(plan.skippedServices == ["debug"])
        #expect(try self.plan(yaml, env: ["COMPOSE_PROFILES": "debug"]).services.map(\.name) == ["db", "app", "debug"])
    }

    @Test func cyclesAreReported() {
        let yaml = """
            services:
              a: {image: x, depends_on: [b]}
              b: {image: x, depends_on: [c]}
              c: {image: x, depends_on: [a]}
            """
        #expect(throws: ComposeError.dependencyCycle(["a", "b", "c", "a"])) { try plan(yaml) }
    }

    @Test func buildOnlyServicesUseTheComposeImageName() throws {
        let plan = try plan("services:\n  api:\n    build: ./api\n")
        #expect(plan.services[0].spec.image == "myshop-api")
        #expect(plan.warnings.contains { $0.topic == "Build" && $0.severity == .warning && $0.message.contains("container build -t myshop-api ./api") })
    }

    @Test func portRangesAndRandomHostPorts() throws {
        let plan = try plan("""
            services:
              a:
                image: x
                ports: ["9000-9002:8000-8002", "127.0.0.1:5000-5010:5000", "7000", "53:53/udp"]
            """)
        #expect(plan.services[0].spec.ports == [
            "9000:8000", "9001:8001", "9002:8002", "127.0.0.1:5000:5000", "7000:7000", "53:53/udp",
        ])
        #expect(plan.services[0].portsSummary == "9000-9002→8000-8002, 5000→5000, 7000→7000, 53→53/udp")
        #expect(throws: ComposeError.self) { try self.plan("services: {a: {image: x, ports: ['9000-9001:8000-8002']}}") }
    }

    @Test func externalResourcesKeepTheirNames() throws {
        let plan = try plan("""
            services:
              a:
                image: x
                networks: [shared]
                volumes: [data:/data]
            networks:
              shared: {external: true, name: corp}
            volumes:
              data: {external: true}
            """)
        #expect(plan.networks.map(\.name) == ["corp"] && plan.networks[0].external && plan.networks[0].labels.isEmpty)
        #expect(plan.volumes.map(\.name) == ["data"] && plan.volumes[0].external)
        #expect(!plan.commandLines().contains { $0.contains("network create") || $0.contains("volume create") })
    }

    @Test func memoryFlags() {
        #expect(ComposePlanner.memoryFlag(512 << 20) == "512M")
        #expect(ComposePlanner.memoryFlag(1 << 30) == "1G")
        #expect(ComposePlanner.memoryFlag(1_500_000_000) == "1431M")
        #expect(ComposePlanner.memoryFlag(1) == "1M")
    }
}

@Suite("Compose projects")
struct ComposeProjectTests {
    func container(_ id: String, project: String?, service: String? = nil, state: ContainerState = .running,
                   dependsOn: String? = nil) -> ContainerSummary {
        var labels: [String: String] = [:]
        if let project {
            labels[ComposeLabels.project] = project
            labels[ComposeLabels.service] = service ?? id
            labels[ComposeLabels.workingDir] = "/Users/demo/\(project)"
            labels[ComposeLabels.configFiles] = "/Users/demo/\(project)/compose.yaml"
        }
        if let dependsOn { labels[ComposeLabels.dependsOn] = dependsOn }
        return ContainerSummary(id: id, imageReference: "x", state: state, labels: labels)
    }

    @Test func groupsByProjectLabel() {
        let (projects, standalone) = ComposeProject.group([
            container("solo", project: nil),
            container("shop-web-1", project: "shop", service: "web"),
            container("blog-db-1", project: "blog", service: "db", state: .stopped),
            container("shop-api-1", project: "shop", service: "api", state: .stopped),
            container("other", project: nil),
        ])
        #expect(projects.map(\.name) == ["blog", "shop"])
        #expect(standalone.map(\.id) == ["solo", "other"])
        let shop = projects[1]
        #expect(shop.services == ["api", "web"])
        #expect(shop.runningCount == 1 && shop.totalCount == 2 && shop.state == .partial)
        #expect(projects[0].state == .stopped)
        #expect(shop.workingDirectory == "/Users/demo/shop")
        #expect(shop.configFile?.path == "/Users/demo/shop/compose.yaml")
    }

    @Test func startOrderFollowsDependsOnLabels() {
        let project = ComposeProject(name: "p", containers: [
            container("p-web-1", project: "p", service: "web", dependsOn: "api:service_started:false"),
            container("p-api-1", project: "p", service: "api", dependsOn: "db:service_healthy:false,cache:service_started:false"),
            container("p-db-1", project: "p", service: "db"),
            container("p-cache-1", project: "p", service: "cache"),
        ])
        #expect(project.startOrder.map(\.id) == ["p-cache-1", "p-db-1", "p-api-1", "p-web-1"])
        #expect(project.state == .running)
    }
}
