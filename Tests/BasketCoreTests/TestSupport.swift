import Foundation
import Testing
@testable import BasketCore

enum TestFixtures {
    /// Real `container` 1.7.1 output bundled with the tests.
    static var realDirectory: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    static func real(_ name: String) throws -> Data {
        try Data(contentsOf: realDirectory.appendingPathComponent(name))
    }

    /// `Fixtures/<set>` at the repository root (demo, empty, stopped).
    static func set(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
    }

    static func date(_ iso: String) -> Date {
        RawJSON.parseDate(iso)!
    }
}

/// A throwaway directory removed by `cleanup()`.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("basket-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Writes a `/bin/sh` script and returns the path of an executable that runs it.
    ///
    /// The executable is a hard link to `ScriptLauncher`, not a new file: macOS checks every newly
    /// written executable on its first launch, one at a time system-wide (~0.1 s each, more under
    /// load), so the suite's fresh fakes, launched in parallel, queued for many seconds and missed
    /// short timeouts such as the 5 s version probe (#20). The body is kept beside the link as
    /// `.<name>.sh`; `$0`, `$$`, the arguments and the exit status are the fake's own.
    func script(_ name: String, _ body: String) throws -> String {
        let path = url.appendingPathComponent(name).path
        try (body + "\n").write(toFile: ScriptLauncher.bodyPath(of: path), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: path)
        try FileManager.default.linkItem(atPath: ScriptLauncher.path, toPath: path)
        return path
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The one executable behind every fake CLI (`TemporaryDirectory.script`): it sources the body stored
/// beside the name it was started under. It lives in the temporary directory, next to every
/// `TemporaryDirectory` (hard links can't cross volumes), and is launched once up front, so its
/// first-launch check is paid here rather than inside a test's timeout.
enum ScriptLauncher {
    static let source = "#!/bin/sh\n# Basket test fake: runs the script body stored beside this name.\n. \"${0%/*}/.${0##*/}.sh\"\n"

    static let path: String = {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("basket-tests-launcher.sh").path
        if (try? String(contentsOfFile: path, encoding: .utf8)) != source || !FileManager.default.isExecutableFile(atPath: path) {
            // Swapped in with rename: fakes another test process already linked keep their inode.
            let staging = path + ".\(UUID().uuidString)"
            try! source.write(toFile: staging, atomically: false, encoding: .utf8)
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging)
            precondition(rename(staging, path) == 0, "can't place \(path)")
        }
        let warmUp = Process()
        warmUp.executableURL = URL(fileURLWithPath: path)
        warmUp.standardOutput = FileHandle.nullDevice
        warmUp.standardError = FileHandle.nullDevice
        if (try? warmUp.run()) != nil { warmUp.waitUntilExit() }
        return path
    }()

    static func bodyPath(of path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).sh").path
    }
}

func collect(_ stream: AsyncThrowingStream<String, Error>, limit: Int = .max) async throws -> [String] {
    var lines: [String] = []
    for try await line in stream {
        lines.append(line)
        if lines.count >= limit { break }
    }
    return lines
}
