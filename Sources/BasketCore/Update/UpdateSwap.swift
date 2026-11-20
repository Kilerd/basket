import Darwin
import Foundation

/// Replaces the installed app with a `StagedUpdate` after Basket quits. A detached `/bin/sh`
/// helper waits for Basket's pid to exit, parks the old app in the staging folder (a rename on
/// the same volume), renames the new one into place — putting the old one back if that fails —,
/// clears quarantine if present, moves the old app to the Trash and relaunches. At every step
/// either the old or the new app sits at the original path.
public enum UpdateSwap {
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

        public init(pid: Int32, destination: URL, newApp: URL, backup: URL, trashDirectory: URL?, trashName: String,
                    stagingDirectory: URL, relaunch: Bool) {
            self.pid = pid
            self.destination = destination
            self.newApp = newApp
            self.backup = backup
            self.trashDirectory = trashDirectory
            self.trashName = trashName
            self.stagingDirectory = stagingDirectory
            self.relaunch = relaunch
        }
    }

    /// The plan for `staged`, waiting for `pid` (normally this process).
    public static func plan(for staged: StagedUpdate, pid: Int32 = getpid(), relaunch: Bool = true) -> Plan {
        let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                 appropriateFor: staged.destination, create: true)
        let name = staged.destination.deletingPathExtension().lastPathComponent
        return Plan(pid: pid, destination: staged.destination, newApp: staged.newApp, backup: staged.backup,
                    trashDirectory: trash, trashName: "\(name) \(staged.previousVersion)",
                    stagingDirectory: staged.stagingDirectory, relaunch: relaunch)
    }

    /// Paths travel as positional parameters ("$2"…), never spliced into the script text.
    public static let script = #"""
    pid="$1"; dest="$2"; new="$3"; backup="$4"; trash="$5"; trashname="$6"; stage="$7"; relaunch="$8"
    log() { printf '%s basket-update: %s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
    reopen() { if [ "$relaunch" = 1 ]; then /usr/bin/open "$1" || log "could not open $1"; fi; }
    cleanup() { case "$stage" in /?*/?*) /bin/rm -rf "$stage" ;; esac; }
    n=0
    while kill -0 "$pid" 2>/dev/null; do
      n=$((n + 1))
      if [ "$n" -ge 1200 ]; then log "Basket (pid $pid) is still running after 2 minutes; update not installed"; cleanup; exit 1; fi
      /bin/sleep 0.1
    done
    if [ ! -d "$new" ]; then log "the staged update is missing; Basket was not changed"; reopen "$dest"; exit 1; fi
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      /bin/mkdir -p "$(/usr/bin/dirname "$backup")"
      if [ -e "$backup" ] || ! /bin/mv "$dest" "$backup"; then
        log "could not move $dest aside; Basket was not changed"; cleanup; reopen "$dest"; exit 1
      fi
    fi
    if [ -e "$dest" ] || ! /bin/mv "$new" "$dest"; then
      log "could not move the update into place; restoring the previous version"
      if [ -e "$backup" ]; then
        if [ ! -e "$dest" ] && /bin/mv "$backup" "$dest"; then reopen "$dest"
        else log "could not restore it; the previous version is at $backup"; /usr/bin/open -R "$backup"; fi
      fi
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
        ["/bin/sh", "-c", script, "basket-update",
         String(plan.pid), plan.destination.path, plan.newApp.path, plan.backup.path,
         plan.trashDirectory?.path ?? "", plan.trashName, plan.stagingDirectory.path, plan.relaunch ? "1" : "0"]
    }

    /// Starts the helper in its own session (it outlives Basket), output appended to `log`.
    @discardableResult
    public static func launchDetached(_ plan: Plan, log: URL?) throws -> pid_t {
        guard plan.stagingDirectory.path.split(separator: "/").count >= 2,
              plan.destination.path != "/",
              plan.newApp.resolvingSymlinksInPath().path.hasPrefix(plan.stagingDirectory.resolvingSymlinksInPath().path + "/")
        else { throw UpdateError.installFailed("the staged update is in an unexpected place") }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log?.path ?? "/dev/null", O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        let argv = arguments(plan)
        var environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        if let home = ProcessInfo.processInfo.environment["HOME"] { environment.append("HOME=\(home)") }
        var pid: pid_t = 0
        let status = withCStringArray(argv) { argvPointer in
            withCStringArray(environment) { envPointer in
                posix_spawn(&pid, "/bin/sh", &actions, &attributes, argvPointer, envPointer)
            }
        }
        guard status == 0 else {
            throw UpdateError.installFailed("the installer couldn't start (\(String(cString: strerror(status))))")
        }
        return pid
    }

    private static func withCStringArray<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
