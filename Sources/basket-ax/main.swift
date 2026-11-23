import AppKit
import BasketAXKit

// basket-ax — accessibility (VoiceOver-tree) E2E runner for Basket.
// Top-level code runs on the main actor.

let usage = """
usage:
  basket-ax lint <dir>
      Audit <section>.ax.json snapshots written by the app's self-test (BASKET_SELFTEST_DIR).
      Writes <dir>/report.json and <dir>/report.md. Exit 1 on any error finding.
  basket-ax audit --app <Basket.app> [--fixtures <dir>] --out <dir> [--sections a,b,...] [--deadline seconds]
                  [--language <id>] [--locale <id>]
      Launch Basket.app with the fixtures backend, drive it through AXUIElement, capture and
      audit every section out of process. The whole run is capped at --deadline (default 300 s).
      --language runs the app in that language (e.g. zh-Hans; -AppleLanguages for this run only),
      --locale with that region format (e.g. zh_CN; -AppleLocale).
      Exit 0 ok, 1 findings, 2 runner failure, 3 Accessibility permission missing.
  basket-ax update-install --app <Basket.app> --feed <latest.json URL> --public-key <base64>
                           --expect-version <X.Y.Z> --out <dir> [--fixtures <dir>] [--quit-timeout seconds]
      The real-UI update test (scripts/update-e2e.sh): launch a DEBUG Basket.app with a test
      feed, choose Check for Updates…, press Install and Relaunch through AXPress, and check that
      it quits within --quit-timeout (default 10 s) of installing and comes back as the new version.
      Exit 0 ok, 1 the update didn't install, 2 runner failure, 3 Accessibility permission missing.
"""

var arguments = Array(CommandLine.arguments.dropFirst())
// `open --args` may pass a -psn_ argument on older systems; ignore it.
arguments.removeAll { $0.hasPrefix("-psn_") }

guard let command = arguments.first else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(64)
}
let rest = Array(arguments.dropFirst())

switch command {
case "lint":
    exit(LintCommand.run(rest))
case "audit":
    exit(await AuditCommand.run(rest))
case "update-install":
    exit(await UpdateInstallCommand.run(rest))
case "capture-demo":  // hidden: verifies SwiftUI → NSAccessibility exposure in-process
    exit(CaptureDemo.run(rest))
case "-h", "--help", "help":
    print(usage)
    exit(0)
default:
    FileHandle.standardError.write(Data("unknown command: \(command)\n\(usage)\n".utf8))
    exit(64)
}
