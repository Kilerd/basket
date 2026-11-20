import Darwin
import Foundation

/// State of the `docker` shim shell integration (see `DockerShimInstaller`).
public struct DockerShimStatus: Sendable, Equatable {
    /// Shim present at `binPath` AND the rc block present in at least one rc file.
    public var isInstalled: Bool
    /// `~/.basket/bin/docker`, expanded.
    public var binPath: String
    /// rc files that contain the Basket block.
    public var rcFiles: [String]
    /// Detected login shell name: "zsh", "bash", "fish", …
    public var shell: String
    /// What `docker` resolves to on the user's PATH today (e.g. /usr/local/bin/docker → OrbStack), nil if none.
    public var currentDocker: String?
    public var currentDockerIsOrbStack: Bool

    public init(
        isInstalled: Bool, binPath: String, rcFiles: [String], shell: String,
        currentDocker: String?, currentDockerIsOrbStack: Bool
    ) {
        self.isInstalled = isInstalled
        self.binPath = binPath
        self.rcFiles = rcFiles
        self.shell = shell
        self.currentDocker = currentDocker
        self.currentDockerIsOrbStack = currentDockerIsOrbStack
    }
}

public enum DockerShimError: Error, LocalizedError, Equatable {
    /// `install()` needs the `basket-docker` binary from the app bundle.
    case missingShimSource
    /// The login shell has no known rc file.
    case unsupportedShell(String)
    /// A start marker without an end marker: the file was edited by hand; Basket won't guess.
    case unterminatedBlock(file: String)
    /// The rc file isn't UTF-8 text.
    case unreadableFile(String)

    public var errorDescription: String? {
        switch self {
        case .missingShimSource:
            "The docker shim (basket-docker) wasn't found inside Basket.app."
        case .unsupportedShell(let shell):
            "Basket can set up zsh, bash and fish; for \(shell), add ~/.basket/bin to PATH yourself."
        case .unterminatedBlock(let file):
            "\(file) has a “\(DockerShimInstaller.startMarker)” line without its end marker. Fix or remove it, then try again."
        case .unreadableFile(let file):
            "\(file) isn't a UTF-8 text file, so Basket won't edit it."
        }
    }
}

/// Installs the `docker` → apple/container shim: copies `basket-docker` to `~/.basket/bin/docker` and adds a
/// marked PATH block to the login shell's rc file (zsh `~/.zshrc`, bash `~/.bash_profile`, fish
/// `~/.config/fish/conf.d/basket.fish`). Idempotent and reversible: `uninstall()` removes exactly the block
/// and the shim. rc files are written through symlinks with their permissions kept, and backed up once
/// (`<rc>.basket-backup`) before Basket first changes them.
public struct DockerShimInstaller: Sendable {
    public static let startMarker = "# >>> basket docker shim >>>"
    public static let endMarker = "# <<< basket docker shim <<<"

    public let home: URL
    public let shimSource: URL?
    /// Login shell path (`/bin/zsh`); nil = detect.
    let shellPath: String?
    /// Directories searched for `currentDocker` after `~/.basket/bin`; nil = this process's PATH + common locations.
    let searchPath: [String]?

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, shimSource: URL? = nil) {
        self.init(home: home, shimSource: shimSource, shellPath: nil, searchPath: nil)
    }

    init(home: URL, shimSource: URL?, shellPath: String?, searchPath: [String]?) {
        self.home = home
        self.shimSource = shimSource
        self.shellPath = shellPath
        self.searchPath = searchPath
    }

    // MARK: - Paths

    var binDirectory: URL { home.appending(path: ".basket/bin", directoryHint: .isDirectory) }
    var binURL: URL { binDirectory.appending(path: "docker") }

    var shell: String {
        let path = shellPath ?? Self.loginShellPath() ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "zsh" : name
    }

    private static func loginShellPath() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }

    var fishFile: URL { home.appending(path: ".config/fish/conf.d/basket.fish") }

    /// bash reads the first of these at login; creating `.bash_profile` next to an existing `.profile`
    /// would stop bash from reading `.profile`, so the block goes into the first one that exists.
    var bashCandidates: [URL] { [".bash_profile", ".bash_login", ".profile"].map { home.appending(path: $0) } }

    /// The rc file `install()` writes for `shell`.
    func rcFile(for shell: String) throws -> URL {
        switch shell {
        case "zsh": return home.appending(path: ".zshrc")
        case "bash":
            return bashCandidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? bashCandidates[0]
        case "fish": return fishFile
        default: throw DockerShimError.unsupportedShell(shell)
        }
    }

    /// Every file a block may have been written to (the user may have changed shells since).
    var allRCFiles: [URL] { [home.appending(path: ".zshrc")] + bashCandidates + [fishFile] }

    // MARK: - Block text

    func block(for shell: String) -> String {
        let header = """
            \(Self.startMarker)
            # Added by Basket: `docker` runs Apple's container CLI via ~/.basket/bin/docker.
            # Turn it off in Basket's settings, or delete this block.
            """
        let body = shell == "fish"
            ? """
            if not contains -- $HOME/.basket/bin $PATH
                set -gx PATH $HOME/.basket/bin $PATH
            end
            """
            : """
            case ":$PATH:" in
              *":$HOME/.basket/bin:"*) ;;
              *) export PATH="$HOME/.basket/bin:$PATH" ;;
            esac
            """
        return header + "\n" + body + "\n" + Self.endMarker
    }

    // MARK: - API

    public func status() -> DockerShimStatus {
        let rcFiles = allRCFiles.filter { (try? Self.blockRange(in: readText($0) ?? "", file: $0.path)) != nil }
            .map(\.path)
        let shimPresent = FileManager.default.isExecutableFile(atPath: binURL.path)
        let docker = resolveDocker(blockActive: shimPresent && !rcFiles.isEmpty)
        return DockerShimStatus(
            isInstalled: shimPresent && !rcFiles.isEmpty,
            binPath: binURL.path,
            rcFiles: rcFiles,
            shell: shell,
            currentDocker: docker,
            currentDockerIsOrbStack: docker.map(isOrbStack) ?? false)
    }

    /// The rc file and the exact block `install()` puts into it (whether or not it is already there).
    public func plannedChanges() -> [(file: String, contents: String)] {
        guard let file = try? rcFile(for: shell) else { return [] }
        return [(file: file.path, contents: block(for: shell) + "\n")]
    }

    public func install() throws {
        let file = try rcFile(for: shell)
        _ = try Self.blockRange(in: readText(file) ?? "", file: file.path)  // refuse a hand-broken block first
        try installShim()
        try ensureBlock(block(for: shell), in: file)
    }

    public func uninstall() throws {
        for file in allRCFiles { try removeBlock(from: file) }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: binURL.path) || isSymlink(binURL) {
            try fileManager.removeItem(at: binURL)
        }
        removeIfEmptyDirectory(binDirectory)
        removeIfEmptyDirectory(binDirectory.deletingLastPathComponent())
    }

    public func refreshShimIfNeeded() throws {
        guard let source = shimSource?.resolvingSymlinksInPath(),
              FileManager.default.fileExists(atPath: binURL.path),
              FileManager.default.fileExists(atPath: source.path),
              !FileManager.default.contentsEqual(atPath: source.path, andPath: binURL.path)
        else { return }
        try copyShim(from: source)
    }

    // MARK: - Shim

    private func installShim() throws {
        guard let source = shimSource?.resolvingSymlinksInPath(),
              FileManager.default.fileExists(atPath: source.path)
        else {
            // Already there (e.g. installed by an earlier version): keep it.
            if FileManager.default.isExecutableFile(atPath: binURL.path) { return }
            throw DockerShimError.missingShimSource
        }
        if FileManager.default.fileExists(atPath: binURL.path),
           FileManager.default.contentsEqual(atPath: source.path, andPath: binURL.path) {
            return
        }
        try copyShim(from: source)
    }

    /// Copy next to the destination, then rename over it: a running `docker` never sees a half-written file.
    private func copyShim(from source: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let temporary = binDirectory.appending(path: ".docker.\(UUID().uuidString).tmp")
        do {
            try fileManager.copyItem(at: source, to: temporary)
            removexattr(temporary.path, "com.apple.quarantine", XATTR_NOFOLLOW)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
            guard rename(temporary.path, binURL.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: binURL.path])
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    // MARK: - rc files

    private func ensureBlock(_ block: String, in file: URL) throws {
        let original = readText(file)
        let text = original ?? ""
        let updated: String
        if let range = try Self.blockRange(in: text, file: file.path) {
            var lines = text.components(separatedBy: "\n")
            guard lines[range].joined(separator: "\n") != block else { return }
            lines.replaceSubrange(range, with: block.components(separatedBy: "\n"))
            updated = lines.joined(separator: "\n")
        } else if text.isEmpty {
            updated = block + "\n"
        } else {
            updated = text + (text.hasSuffix("\n") ? "\n" : "\n\n") + block + "\n"
        }
        if original != nil { try backUpOnce(file) }
        try writeText(updated, to: file)
    }

    private func removeBlock(from file: URL) throws {
        guard let text = readText(file), var range = try Self.blockRange(in: text, file: file.path) else { return }
        var lines = text.components(separatedBy: "\n")
        var remaining = text
        while true {
            // Also drop the blank separator line `install()` put before the block.
            let start = range.lowerBound > 0 && lines[range.lowerBound - 1].isEmpty ? range.lowerBound - 1 : range.lowerBound
            lines.removeSubrange(start...range.upperBound)
            remaining = lines.joined(separator: "\n")
            guard let next = try Self.blockRange(in: remaining, file: file.path) else { break }
            range = next
        }
        let createdByBasket = !FileManager.default.fileExists(atPath: backupURL(for: file).path)
        if file == fishFile || createdByBasket,
           remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Basket created it: remove it (through a symlink, the target Basket created).
            try FileManager.default.removeItem(at: resolvedTarget(file))
            return
        }
        try writeText(remaining, to: file)
    }

    /// Line range of the first complete block (start marker … end marker), nil if none.
    static func blockRange(in text: String, file: String) throws -> ClosedRange<Int>? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == startMarker }) else {
            return nil
        }
        guard let end = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == endMarker })
        else { throw DockerShimError.unterminatedBlock(file: file) }
        return start...end
    }

    private func backupURL(for file: URL) -> URL {
        file.deletingLastPathComponent().appending(path: file.lastPathComponent + ".basket-backup")
    }

    private func backUpOnce(_ file: URL) throws {
        let backup = backupURL(for: file)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: backup.path), !isSymlink(backup) else { return }
        let target = resolvedTarget(file)
        try fileManager.copyItem(at: target, to: backup)
    }

    private func readText(_ file: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: resolvedTarget(file).path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Writes through symlinks, keeping the target's permissions.
    private func writeText(_ text: String, to file: URL) throws {
        let target = resolvedTarget(file)
        let fileManager = FileManager.default
        let permissions = (try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions ?? 0o644], ofItemAtPath: target.path)
    }

    /// Follows a chain of symlinks (also a dangling one: writing creates its target).
    func resolvedTarget(_ file: URL) -> URL {
        var current = file
        for _ in 0..<32 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path) else { break }
            current = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appending(path: destination)
        }
        return current.standardizedFileURL
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func removeIfEmptyDirectory(_ url: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path), contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Which docker is on PATH

    /// The first `docker` a new login shell would run: `~/.basket/bin` when the block is active, then PATH.
    private func resolveDocker(blockActive: Bool) -> String? {
        let binDirectory = binDirectory.path
        var directories = blockActive ? [binDirectory] : []
        directories += (searchPath ?? defaultSearchPath()).filter { $0 != binDirectory }
        var seen = Set<String>()
        for directory in directories where seen.insert(directory).inserted {
            let candidate = (directory as NSString).appendingPathComponent("docker")
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private func defaultSearchPath() -> [String] {
        let environmentPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return environmentPath + CLIRunner.standardPathDirectories + [
            home.appending(path: ".orbstack/bin").path,
            home.appending(path: ".docker/bin").path,
            home.appending(path: ".rd/bin").path,
            "/Applications/Docker.app/Contents/Resources/bin",
        ]
    }

    func isOrbStack(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved.contains("/OrbStack.app/") || resolved.hasPrefix(home.appending(path: ".orbstack").path + "/")
            || path.hasPrefix(home.appending(path: ".orbstack").path + "/")
    }
}
