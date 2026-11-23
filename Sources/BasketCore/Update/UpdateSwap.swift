import Darwin
import Foundation

/// Replaces the installed app with a `StagedUpdate` after Basket quits. A `/bin/sh` helper, run as
/// a one-shot launchd job (so it outlives Basket however Basket ends), waits for Basket's pid to
/// exit, checks the staged app's code signature again
/// (`codesign -R` with the same requirement the app checked), parks the old app in the staging
/// folder (a rename on the same volume), renames the new one into place, checks it there once
/// more — putting the old one back if anything fails —, clears quarantine if present, moves the
/// old app to the Trash and relaunches. At every step either the old or the new app sits at the
/// original path, and the new one stays only if it passed the check where it now sits.
public enum UpdateSwap {
    /// The code-signature tool the helper runs. Only DEBUG builds (tests) can swap it in a `Plan`.
    public static let codesignTool = "/usr/bin/codesign"

    public struct Plan: Equatable, Sendable {
        public var pid: Int32
        public var destination: URL
        public var newApp: URL
        public var backup: URL
        /// The Trash of the destination's volume; nil leaves the old app in the staging folder.
        public var trashDirectory: URL?
        /// Name of the old app in the Trash, without `.app` (e.g. “Basket 0.0.1”).
        public var trashName: String
        public var stagingDirectory: URL
        public var relaunch: Bool
        /// Requirement-language text the new app must satisfy before and after the swap
        /// (`CodeSignature.requirement(teamID:)`, the one the app checked).
        public var requirement: String
        #if DEBUG
        /// Tests only: a stand-in for `/usr/bin/codesign`. Release builds always run the real one.
        public var codesign = UpdateSwap.codesignTool
        #endif

        public init(pid: Int32, destination: URL, newApp: URL, backup: URL, trashDirectory: URL?, trashName: String,
                    stagingDirectory: URL, relaunch: Bool, requirement: String) {
            self.pid = pid
            self.destination = destination
            self.newApp = newApp
            self.backup = backup
            self.trashDirectory = trashDirectory
            self.trashName = trashName
            self.stagingDirectory = stagingDirectory
            self.relaunch = relaunch
            self.requirement = requirement
        }
    }

    /// The plan for `staged`, waiting for `pid` (normally this process).
    public static func plan(for staged: StagedUpdate, requirement: String, pid: Int32 = getpid(), relaunch: Bool = true) -> Plan {
        let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                 appropriateFor: staged.destination, create: true)
        let name = staged.destination.deletingPathExtension().lastPathComponent
        return Plan(pid: pid, destination: staged.destination, newApp: staged.newApp, backup: staged.backup,
                    trashDirectory: trash, trashName: "\(name) \(staged.previousVersion)",
                    stagingDirectory: staged.stagingDirectory, relaunch: relaunch, requirement: requirement)
    }

    /// Paths and the requirement travel as positional parameters ("$2"…), never spliced into the
    /// script text.
    public static let script = #"""
    pid="$1"; dest="$2"; new="$3"; backup="$4"; trash="$5"; trashname="$6"; stage="$7"; relaunch="$8"; req="$9"; codesign="${10}"
    log() { printf '%s basket-update: %s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
    reopen() { if [ "$relaunch" = 1 ]; then /usr/bin/open "$1" || log "could not open $1"; fi; }
    cleanup() { case "$stage" in /?*/?*) /bin/rm -rf "$stage" ;; esac; }
    # The app's own check, repeated where the bundle is about to be (and then is) installed.
    verified() {
      case "$codesign" in /?*) ;; *) log "no code-signature tool"; return 1 ;; esac
      if [ -z "$req" ]; then log "no code requirement"; return 1; fi
      "$codesign" --verify --deep --strict -R "=$req" "$1"
    }
    # Puts the previous version back at $dest (empty again); fails if it can't.
    restore() {
      [ -e "$backup" ] || return 0
      if [ ! -e "$dest" ] && /bin/mv "$backup" "$dest"; then reopen "$dest"; return 0; fi
      log "could not restore it; the previous version is at $backup"; /usr/bin/open -R "$backup"; return 1
    }
    n=0
    while kill -0 "$pid" 2>/dev/null; do
      n=$((n + 1))
      if [ "$n" -ge 1200 ]; then log "Basket (pid $pid) is still running after 2 minutes; update not installed"; cleanup; exit 1; fi
      /bin/sleep 0.1
    done
    if [ ! -d "$new" ]; then log "the staged update is missing; Basket was not changed"; reopen "$dest"; exit 1; fi
    if ! verified "$new"; then
      log "the staged update failed the code-signature check; Basket was not changed"; cleanup; reopen "$dest"; exit 1
    fi
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      /bin/mkdir -p "$(/usr/bin/dirname "$backup")"
      if [ -e "$backup" ] || ! /bin/mv "$dest" "$backup"; then
        log "could not move $dest aside; Basket was not changed"; cleanup; reopen "$dest"; exit 1
      fi
    fi
    if [ -e "$dest" ] || ! /bin/mv "$new" "$dest"; then
      log "could not move the update into place; restoring the previous version"
      restore
      exit 1
    fi
    if ! verified "$dest"; then
      log "the update failed the code-signature check in place; restoring the previous version"
      if ! /bin/mv "$dest" "$stage/rejected"; then
        log "could not move the rejected update away from $dest"
        if [ -e "$backup" ]; then log "the previous version is at $backup"; /usr/bin/open -R "$backup"; fi
        exit 1
      fi
      if restore; then cleanup; fi
      exit 1
    fi
    if /usr/bin/xattr -p com.apple.quarantine "$dest" >/dev/null 2>&1; then
      /usr/bin/xattr -dr com.apple.quarantine "$dest" || log "could not clear the quarantine flag of $dest"
    fi
    if [ ! -e "$backup" ]; then
      cleanup
    elif [ -n "$trash" ] && [ -d "$trash" ]; then
      target="$trash/$trashname.app"; i=2
      while [ -e "$target" ]; do target="$trash/$trashname ($i).app"; i=$((i + 1)); done
      if /bin/mv "$backup" "$target"; then cleanup; else log "could not move the previous version to the Trash; it is at $backup"; fi
    else
      log "no Trash folder; the previous version is at $backup"
    fi
    log "installed $dest"
    reopen "$dest"
    exit 0
    """#

    /// `/bin/sh -c <script> basket-update <args…>`.
    public static func arguments(_ plan: Plan) -> [String] {
        #if DEBUG
        let codesign = plan.codesign
        #else
        let codesign = codesignTool
        #endif
        return ["/bin/sh", "-c", script, "basket-update",
                String(plan.pid), plan.destination.path, plan.newApp.path, plan.backup.path,
                plan.trashDirectory?.path ?? "", plan.trashName, plan.stagingDirectory.path, plan.relaunch ? "1" : "0",
                plan.requirement, codesign]
    }

    /// Prefix of the helper's launchd job labels; the rest is a UUID.
    public static let jobLabelPrefix = "\(UpdatePolicy.bundleIdentifier).update."

    /// The helper's launchd job: one run in the user's GUI session (`RunAtLoad`, no `KeepAlive`),
    /// which launchd removes once the helper exits (`LaunchOnlyOnce`), output appended to `log`.
    public static func job(_ plan: Plan, label: String, log: URL?) -> [String: Any] {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        if let home = ProcessInfo.processInfo.environment["HOME"] { environment["HOME"] = home }
        let output = log?.path ?? "/dev/null"
        return [
            "Label": label,
            "ProgramArguments": arguments(plan),
            "RunAtLoad": true,
            "LaunchOnlyOnce": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "EnvironmentVariables": environment,
            "StandardInPath": "/dev/null",
            "StandardOutPath": output,
            "StandardErrorPath": output,
        ]
    }

    /// Starts the helper as a launchd job of its own (`job(_:label:log:)`) and returns its label.
    /// Not as a child of Basket: a child stays in Basket's process coalition whatever its session,
    /// and a Force Quit — ⌥⌘⎋, the Dock or Activity Monitor, all LaunchServices' force quit —
    /// ends every process of the app's coalition, so the helper died with Basket (#41).
    @discardableResult
    public static func launchDetached(_ plan: Plan, log: URL?) throws -> String {
        guard plan.stagingDirectory.path.split(separator: "/").count >= 2,
              plan.destination.path != "/",
              plan.newApp.resolvingSymlinksInPath().path.hasPrefix(plan.stagingDirectory.resolvingSymlinksInPath().path + "/")
        else { throw UpdateError.installFailed(String(localized: "the staged update is in an unexpected place", bundle: .main)) }
        guard !plan.requirement.isEmpty else { throw UpdateError.installFailed(String(localized: "the installer has no code requirement", bundle: .main)) }
        let label = jobLabelPrefix + UUID().uuidString
        // launchctl reads the job from a file, which isn't needed once `bootstrap` returns. launchd
        // refuses one that isn't plainly the user's (as on a volume that ignores ownership, where
        // the staging folder may be), so it goes into the user's own temporary folder.
        let file = jobFile(label: label)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try PropertyListSerialization.data(fromPropertyList: job(plan, label: label, log: log), format: .xml, options: 0)
                .write(to: file)
            // Nobody else may write it, whatever the umask.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", file.path], output: log)
        } catch {
            throw UpdateError.installFailed(String(localized: "the installer couldn't start (\(error.localizedDescription))", bundle: .main))
        }
        return label
    }

    /// Where `launchDetached` writes the job for launchctl: the user's temporary folder.
    static func jobFile(label: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(label).plist")
    }

    /// Runs `tool` to completion (it returns quickly), output appended to `output`; throws unless it
    /// exits with status 0.
    private static func run(_ tool: String, _ arguments: [String], output: URL?) throws {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, output?.path ?? "/dev/null", O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        var pid: pid_t = 0
        let spawned = withCStringArray([tool] + arguments) { argv in
            withCStringArray(["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]) { env in
                posix_spawn(&pid, tool, &actions, &attributes, argv, env)
            }
        }
        let command = ([URL(fileURLWithPath: tool).lastPathComponent] + arguments.prefix(1)).joined(separator: " ")
        guard spawned == 0 else { throw ToolFailure(errorDescription: "\(command): \(String(cString: strerror(spawned)))") }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { throw ToolFailure(errorDescription: "\(command): \(String(cString: strerror(errno)))") }
        }
        // WIFEXITED / WEXITSTATUS / WTERMSIG: macros Swift can't import.
        let signal = status & 0x7f, code = (status >> 8) & 0xff
        guard signal == 0 else { throw ToolFailure(errorDescription: "\(command) ended by signal \(signal)") }
        guard code == 0 else { throw ToolFailure(errorDescription: "\(command) exited with status \(code)") }
    }

    private struct ToolFailure: LocalizedError {
        var errorDescription: String?
    }

    private static func withCStringArray<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
