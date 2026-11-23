import CryptoKit
import Foundation

// Read-only access to OrbStack's docker engine.
//
// Every docker invocation goes through `DockerReadOnlyPolicy.validate` first. OrbStack is never
// started, stopped or modified: only listing, inspecting, `version` and `save` (to a file) are
// allowed, always against `--context orbstack`.

enum DockerReadOnlyPolicy {
    static let context = "orbstack"

    /// Subcommands (after `--context orbstack`) that only read.
    static let allowed: [[String]] = [
        ["image", "ls"], ["image", "inspect"], ["ps"], ["inspect"], ["save"], ["version"],
    ]

    /// Options that would point docker somewhere other than OrbStack or change its config.
    static let forbiddenOptions: Set<String> = [
        "-H", "--host", "--context", "-c", "--config", "--tls", "--tlsverify", "--tlscacert", "--tlscert", "--tlskey",
    ]

    /// `--host`, `--host=tcp://…`, and the attached short forms `-Htcp://…` / `-cdefault`.
    static func isForbiddenOption(_ argument: String) -> Bool {
        if forbiddenOptions.contains(argument) { return true }
        if argument.hasPrefix("--") {
            let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            return forbiddenOptions.contains(name)
        }
        if argument.hasPrefix("-"), argument.count > 2 {
            return forbiddenOptions.contains(String(argument.prefix(2)))
        }
        return false
    }

    /// Throws unless `arguments` is `--context orbstack <allowed subcommand> …`; `save` must write
    /// to a file (`-o`), never stdout.
    static func validate(_ arguments: [String]) throws {
        let command = (["docker"] + arguments).map(shellQuoteIfNeeded).joined(separator: " ")
        guard arguments.count >= 3, arguments[0] == "--context", arguments[1] == context else {
            throw MigrationError.forbiddenDockerCommand(command)
        }
        let rest = Array(arguments.dropFirst(2))
        guard let head = allowed.first(where: { rest.starts(with: $0) }) else {
            throw MigrationError.forbiddenDockerCommand(command)
        }
        let options = rest.dropFirst(head.count)
        if options.contains(where: isForbiddenOption) {
            throw MigrationError.forbiddenDockerCommand(command)
        }
        if head == ["save"], !options.contains(where: { $0 == "-o" || $0 == "--output" || $0.hasPrefix("--output=") }) {
            throw MigrationError.forbiddenDockerCommand(command)
        }
    }
}

/// Runs docker. Implementations don't enforce the policy; `OrbStackMigrator.docker(_:)` does.
public protocol OrbStackDockerClient: Sendable {
    /// Non-zero exits are returned, not thrown; cancellation terminates the process.
    func run(_ arguments: [String], timeout: Duration?) async throws -> CLIResult
}

/// The real docker CLI.
public struct ProcessDockerClient: OrbStackDockerClient {
    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    /// `BASKET_DOCKER_CLI`, then the places OrbStack installs `docker`.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates: [String] = []
        if let explicit = environment["BASKET_DOCKER_CLI"], !explicit.isEmpty { candidates.append(explicit) }
        candidates += [
            "/usr/local/bin/docker", "/opt/homebrew/bin/docker", NSHomeDirectory() + "/.orbstack/bin/docker",
            "/Applications/OrbStack.app/Contents/MacOS/xbin/docker",
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }

    public func run(_ arguments: [String], timeout: Duration?) async throws -> CLIResult {
        try await CLIRunner(executableURL: executableURL).run(arguments, timeout: timeout)
    }
}

/// Serves raw docker output captured from OrbStack (`Fixtures/<set>/orbstack-*.json`), and fakes
/// `save` by writing a synthetic OCI archive of the requested platform after a short delay.
public struct FixtureDockerClient: OrbStackDockerClient {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    static let files = (
        images: "orbstack-images.json", imageInspect: "orbstack-image-inspect.json",
        imageInspectAMD64: "orbstack-image-inspect-amd64.json", containers: "orbstack-containers.json",
        inspect: "orbstack-inspect.json", version: "orbstack-version.json"
    )

    public func run(_ arguments: [String], timeout: Duration?) async throws -> CLIResult {
        let rest = Array(arguments.dropFirst(2))
        func file(_ name: String) -> Data { (try? Data(contentsOf: directory.appendingPathComponent(name))) ?? Data() }
        func ok(_ data: Data) -> CLIResult { CLIResult(exitCode: 0, stdout: data, stderr: Data()) }
        switch rest.first {
        case "version":
            return ok(file(Self.files.version))
        case "ps":
            return ok(file(Self.files.containers))
        case "inspect":
            return ok(Self.select(file(Self.files.inspect), ids: Self.operands(rest.dropFirst())) { element in
                [element["Id"] as? String, (element["Name"] as? String).map { String($0.drop(while: { $0 == "/" })) }]
            })
        case "image" where rest.dropFirst().first == "ls":
            return ok(file(Self.files.images))
        case "image" where rest.dropFirst().first == "inspect":
            let operands = Self.operands(rest.dropFirst(2))
            guard let index = rest.firstIndex(of: "--platform"), index + 1 < rest.count else {
                return ok(Self.select(file(Self.files.imageInspect), ids: operands) { [$0["Id"] as? String] })
            }
            // Like docker: one element per image that has the platform (naming its platform
            // manifest), the others reported on stderr.
            let platform = rest[index + 1]
            var selected: [[String: Any]] = []
            var missing: [String] = []
            for id in operands {
                if let element = platformElement(id: id, platform: platform) { selected.append(element) } else { missing.append(id) }
            }
            let stdout = (try? JSONSerialization.data(withJSONObject: selected, options: [.withoutEscapingSlashes])) ?? Data("[]".utf8)
            let stderr = missing.map { "Error response from daemon: image with reference \($0) was found but does not provide the specified platform (\(platform))" }
            return CLIResult(exitCode: missing.isEmpty ? 0 : 1, stdout: stdout, stderr: Data(stderr.joined(separator: "\n").utf8))
        case "save":
            guard let index = rest.firstIndex(of: "-o"), index + 1 < rest.count, let reference = rest.last, reference != rest[index + 1] else {
                return CLIResult(exitCode: 1, stdout: Data(), stderr: Data("requires -o and a reference".utf8))
            }
            let url = URL(fileURLWithPath: rest[index + 1])
            let platform = rest.firstIndex(of: "--platform").flatMap { $0 + 1 < rest.count ? rest[$0 + 1] : nil } ?? MigrationPlatform.host
            guard let id = imageID(of: reference), let element = platformElement(id: id, platform: platform) else {
                return CLIResult(exitCode: 1, stdout: Data(), stderr: Data(
                    "Error response from daemon: no suitable export target found: image with reference \(reference) was found but does not provide the specified platform (\(platform))".utf8))
            }
            for step in 1...3 {
                try await Task.sleep(for: .milliseconds(60))
                try Data(count: step * 256 * 1024).write(to: url)
            }
            // An OCI archive like docker's: the platform manifest `image inspect --platform` names.
            let descriptor = element["Descriptor"] as? [String: Any]
            let variant = ImageVariant(
                platform: Self.platform(of: element) ?? platform, digest: descriptor?["digest"] as? String ?? "",
                sizeBytes: (element["Size"] as? NSNumber)?.int64Value ?? 0)
            try ImageArchive.writeSynthetic(reference: normalizeImageReference(reference), variants: [variant], to: url)
            return ok(Data())
        default:
            return CLIResult(exitCode: 1, stdout: Data(), stderr: Data("unsupported in fixtures: \(rest.joined(separator: " "))".utf8))
        }
    }

    private func json(_ name: String) -> [[String: Any]] {
        let data = (try? Data(contentsOf: directory.appendingPathComponent(name))) ?? Data()
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// The image ID `reference` ("busybox:latest", "acme/web@sha256:…") names in `orbstack-images.json`.
    func imageID(of reference: String) -> String? {
        let data = (try? Data(contentsOf: directory.appendingPathComponent(Self.files.images))) ?? Data()
        for line in DockerFormat.decodeLines(RawDockerImageLine.self, from: data) {
            guard let repository = line.Repository, let id = line.ID else { continue }
            if reference == "\(repository):\(line.Tag ?? "")" || reference == "\(repository)@\(line.Digest ?? "")" { return id }
        }
        return nil
    }

    /// `image inspect --platform P` for one image: the captured linux/amd64 element (paired through
    /// its RepoTags) for foreign platforms, else the default element when it has that platform, with
    /// its descriptor turned into the platform manifest's (a stable fake digest). nil = not provided.
    func platformElement(id: String, platform: String) -> [String: Any]? {
        let base = json(Self.files.imageInspect).first { $0["Id"] as? String == id }
        if !MigrationPlatform.isHost(platform), let tags = base?["RepoTags"] as? [String],
           let captured = json(Self.files.imageInspectAMD64).first(where: { $0["RepoTags"] as? [String] == tags }) {
            return captured
        }
        guard var element = base, let actual = Self.platform(of: element),
              ImageContentComparison.samePlatform(actual, platform)
        else { return nil }
        let descriptor = element["Descriptor"] as? [String: Any]
        if !DockerFormat.manifestMediaTypes.contains(descriptor?["mediaType"] as? String ?? "") {
            element["Descriptor"] = [
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "digest": Self.manifestDigest(id: id, platform: actual), "size": 1_024,
            ] as [String: Any]
        }
        return element
    }

    static func platform(of element: [String: Any]) -> String? {
        guard let os = element["Os"] as? String, !os.isEmpty, let arch = element["Architecture"] as? String, !arch.isEmpty else {
            return nil
        }
        if let variant = element["Variant"] as? String, !variant.isEmpty { return "\(os)/\(arch)/\(variant)" }
        return "\(os)/\(arch)"
    }

    /// A stable stand-in for the platform manifest digest of a fixture image.
    static func manifestDigest(id: String, platform: String) -> String {
        let base = platform.split(separator: "/").prefix(2).joined(separator: "/")
        return "sha256:" + SHA256.hash(data: Data("\(id)|\(base)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Positional arguments (skips `--flag value` pairs and bare flags).
    static func operands<S: Sequence<String>>(_ arguments: S) -> [String] {
        var result: [String] = []
        var skipNext = false
        for argument in arguments {
            if skipNext { skipNext = false; continue }
            if ["--platform", "--format", "-f", "--type"].contains(argument) { skipNext = true; continue }
            if argument.hasPrefix("-") { continue }
            result.append(argument)
        }
        return result
    }

    /// The elements of a JSON array whose keys match `ids`, in request order.
    static func select(_ data: Data, ids: [String], keys: ([String: Any]) -> [String?]) -> Data {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return Data("[]".utf8) }
        let selected = ids.compactMap { id in array.first { keys($0).contains(id) } }
        return (try? JSONSerialization.data(withJSONObject: selected, options: [.withoutEscapingSlashes])) ?? Data("[]".utf8)
    }
}

/// Whether OrbStack is installed / its Docker engine is up, without touching it.
public struct OrbStackPresence: Sendable {
    public var isInstalled: @Sendable () async -> Bool
    /// The Docker engine is up (checked before every docker call).
    public var isRunning: @Sendable () async -> Bool

    public init(isInstalled: @escaping @Sendable () async -> Bool, isRunning: @escaping @Sendable () async -> Bool) {
        self.isInstalled = isInstalled
        self.isRunning = isRunning
    }

    /// OrbStack.app on disk (in the standard folders); engine up per `OrbStackEngine.isUp()` (VM
    /// manager + live docker socket).
    public static let host = host(locator: .standardFolders)

    /// OrbStack.app wherever `locator` finds it; engine up per `OrbStackEngine.isUp()`.
    public static func host(locator: OrbStackLocator) -> OrbStackPresence {
        OrbStackPresence(
            isInstalled: { locator.appPath() != nil },
            isRunning: { OrbStackEngine.isUp(appPath: locator.appPath()) })
    }

    /// From `orbstack.json` (an encoded `OrbStackSnapshot`) in a fixture set.
    public static func fixture(_ directory: URL) -> OrbStackPresence {
        OrbStackPresence(
            isInstalled: { OrbStackInspector.fixtureSnapshot(directory).isInstalled },
            isRunning: { OrbStackInspector.fixtureSnapshot(directory).isRunning })
    }

    public static let always = OrbStackPresence(isInstalled: { true }, isRunning: { true })
    public static let absent = OrbStackPresence(isInstalled: { false }, isRunning: { false })
}
