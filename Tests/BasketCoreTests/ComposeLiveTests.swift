import Foundation
import Testing
@testable import BasketCore

/// Real compose round trip against the installed `container` CLI. Opt in with
/// `BASKET_COMPOSE_LIVE=1`. Creates project `basket-test-cmp` (redis + alpine, from a compose file in
/// a temporary directory), proves `app` reaches `db` by service name, then takes everything down.
@Suite("Compose (real container CLI)", .enabled(if: ProcessInfo.processInfo.environment["BASKET_COMPOSE_LIVE"] == "1"), .serialized)
struct ComposeLiveTests {
    let backend = CLIBackend()
    let project = "basket-test-cmp"

    @Test func upReachByServiceNameDown() async throws {
        let directory = URL(fileURLWithPath: "/tmp/basket-test-cmp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let compose = directory.appendingPathComponent("compose.yaml")
        try """
            name: basket-test-cmp
            services:
              db:
                image: redis:7-alpine
                mem_limit: 256m
                volumes: [data:/data]
              app:
                image: alpine:latest
                command: ["sh", "-c", "sleep 600"]
                depends_on: [db]
                mem_limit: 256m
            volumes:
              data:
            """.write(to: compose, atomically: true, encoding: .utf8)

        let plan = try ComposePlanner.plan(try ComposeLoader.load(fileAt: compose))
        #expect(plan.project == project)
        for line in plan.commandLines() { print("[compose] plan: \(line)") }
        let ops = ComposeOperations(backend: backend)
        do {
            try await ops.up(plan) { print("[compose] up: \($0)") }
            let hosts = try await backend.exec("\(project)-app-1", command: ["cat", "/etc/hosts"], user: nil)
            print("[compose] app /etc/hosts:\n\(hosts)")
            // Redis answers PING with +PONG: a real TCP round trip to “db” by name.
            var reply = ""
            for _ in 0..<10 {
                reply = (try? await backend.exec(
                    "\(project)-app-1", command: ["sh", "-c", "printf 'PING\\r\\n' | nc -w 2 db 6379"], user: nil)) ?? ""
                if reply.contains("PONG") { break }
                try await Task.sleep(for: .seconds(1))
            }
            print("[compose] app → db:6379 PING reply: \(reply.trimmingCharacters(in: .whitespacesAndNewlines))")
            #expect(reply.contains("+PONG"))
        } catch {
            print("[compose] failed: \(error.localizedDescription)")
            Issue.record(error)
        }
        try await ops.down(project: project, removeVolumes: true) { print("[compose] down: \($0)") }

        let containers = try await backend.listContainers().filter { $0.id.hasPrefix(project) }
        let networks = try await backend.listNetworks().filter { $0.name.hasPrefix(project) }
        let volumes = try await backend.listVolumes().filter { $0.name.hasPrefix(project) }
        print("[compose] left after down: containers \(containers.map(\.id)), networks \(networks.map(\.name)), volumes \(volumes.map(\.name))")
        #expect(containers.isEmpty && networks.isEmpty && volumes.isEmpty)
    }
}
