import AppKit
import BasketCore

/// Things Basket asks macOS to do on the user's behalf.
@MainActor
enum HostActions {
    /// Opens `commandLine` in a new Terminal window.
    ///
    /// Uses a self-deleting `.command` file opened with Terminal instead of AppleScript: it needs
    /// no Automation (Apple Events) permission and works the same from an unsigned debug build.
    static func openInTerminal(_ commandLine: String, title: String, onError: (String, Error) -> Void) {
        do {
            let dir = FileManager.default.temporaryDirectory.appending(path: "basket-shell", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeTitle = title.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
            let url = dir.appending(path: "\(safeTitle.isEmpty ? "shell" : safeTitle)-\(UUID().uuidString.prefix(8)).command")
            let script = """
            #!/bin/zsh -l
            rm -f -- "$0"
            printf '\\e]0;%s\\a' \(shellQuote(title))
            \(commandLine)
            """
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            let workspace = NSWorkspace.shared
            guard let terminal = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                workspace.open(url)
                return
            }
            workspace.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    Task { @MainActor in NSSound.beep(); NSLog("Basket: failed to open Terminal: \(error)") }
                }
            }
        } catch {
            onError("Couldn't open a shell", error)
        }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func openInBrowser(_ port: PortMapping) {
        let host = (port.hostAddress == "0.0.0.0" || port.hostAddress.isEmpty || port.hostAddress == "::") ? "localhost" : port.hostAddress
        let scheme = [443, 8443].contains(port.hostPort) ? "https" : "http"
        if let url = URL(string: "\(scheme)://\(host):\(port.hostPort)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    static func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
