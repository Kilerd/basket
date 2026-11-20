import BasketCore
import Darwin
import Foundation

/// Runs a translation: execs `container` for single commands, spawns each step of a sequence.
struct ShimRunner {
    let dryRun: Bool
    let environment: [String: String]

    func execute(_ translation: DockerTranslation) -> Int32 {
        switch translation {
        case .help(let text):
            print(text, terminator: "")
            return 0
        case .unsupported(let message):
            printError(message)
            return 125
        case .delegate(let executable, let args, let notes):
            printNotes(notes)
            if dryRun {
                print(DockerShimRuntime.render(args, executable: executable))
                return 0
            }
            return exec(executable, args)
        case .confirm(let prompt, let then):
            if dryRun { return execute(then) }
            print(prompt)
            print("Are you sure you want to continue? [y/N] ", terminator: "")
            fflush(stdout)
            guard let answer = readLine(), DockerCommandTranslator.isConfirmation(answer) else {
                printError("docker: cancelled")
                return 1
            }
            return execute(then)
        case .run(let args, let notes):
            printNotes(notes)
            if dryRun {
                print(DockerShimRuntime.render(args))
                return 0
            }
            guard let cli = containerCLI() else { return 127 }
            return exec(cli, args)
        case .sequence(let commands, let notes):
            printNotes(notes)
            let doomed = DockerShimRuntime.containersDeletedByRestart(translation)
            if !doomed.isEmpty {
                printError(
                    "docker restart: \(doomed.joined(separator: ", ")) was started with --rm, and apple/container "
                        + "deletes such containers when they stop, so a restart would delete it. Nothing was changed.")
                return 1
            }
            if dryRun {
                for command in commands { print(DockerShimRuntime.render(command)) }
                return 0
            }
            guard let cli = containerCLI() else { return 127 }
            for command in commands {
                let status = spawnAndWait(cli, command)
                if status != 0 { return status }
            }
            return 0
        }
    }

    func containerCLI() -> String? {
        do {
            return try DockerShimRuntime.locateContainerCLI(environment: environment).path
        } catch {
            printError(
                "docker: Apple's `container` CLI was not found. Install it from "
                    + "https://github.com/apple/container/releases or set BASKET_CONTAINER_CLI to its path.")
            return nil
        }
    }

    /// Replaces this process with `path args…` (same pid, fds, TTY and signal handling).
    func exec(_ path: String, _ args: [String]) -> Int32 {
        fflush(stdout)
        fflush(stderr)
        withCStrings([path] + args) { argv in _ = execv(path, argv) }
        printError("docker: couldn't run \(path): \(String(cString: strerror(errno)))")
        return 126
    }

    /// One step of a sequence: the child inherits stdin/stdout/stderr; the shim ignores ^C/^\ while it
    /// waits (the terminal sends them to the child too), like a shell does.
    func spawnAndWait(_ path: String, _ args: [String]) -> Int32 {
        fflush(stdout)
        fflush(stderr)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGINT)
        sigaddset(&defaults, SIGQUIT)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))

        var pid: pid_t = 0
        let spawnError = withCStrings([path] + args) { argv in
            posix_spawn(&pid, path, nil, &attributes, argv, environ)
        }
        guard spawnError == 0 else {
            printError("docker: couldn't run \(path): \(String(cString: strerror(spawnError)))")
            return 126
        }
        let previousInt = signal(SIGINT, SIG_IGN)
        let previousQuit = signal(SIGQUIT, SIG_IGN)
        defer {
            signal(SIGINT, previousInt)
            signal(SIGQUIT, previousQuit)
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return 1 }
        }
        let signalNumber = status & 0x7f
        return signalNumber == 0 ? (status >> 8) & 0xff : 128 + signalNumber
    }

    func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    func printNotes(_ notes: [String]) {
        for note in notes { printError("WARNING: \(note)") }
    }

    func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
