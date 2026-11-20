import Darwin
import Foundation
import Testing
@testable import BasketCore

/// Every test works in a throwaway HOME; the real ~/.zshrc, ~/.bash_profile, ~/.config and ~/.basket are
/// never read or written.
@Suite("Docker shim installer")
struct DockerShimInstallerTests {
    /// A temp HOME plus a fake `basket-docker` binary outside it.
    struct Sandbox {
        let temp: TemporaryDirectory
        let home: URL
        let shim: URL
        let pathDir: URL

        init() throws {
            temp = try TemporaryDirectory()
            home = temp.url.appending(path: "home", directoryHint: .isDirectory)
            pathDir = temp.url.appending(path: "usr-local-bin", directoryHint: .isDirectory)
            for directory in [home, pathDir] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            shim = temp.url.appending(path: "Basket.app/Contents/Helpers/basket-docker")
            try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeShim("#!/bin/sh\necho shim v1\n")
        }

        func writeShim(_ body: String) throws {
            try Data(body.utf8).write(to: shim)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        }

        func installer(shell: String = "/bin/zsh", shimSource: URL?? = .none) -> DockerShimInstaller {
            DockerShimInstaller(
                home: home, shimSource: shimSource ?? shim, shellPath: shell, searchPath: [pathDir.path])
        }

        func url(_ relative: String) -> URL { home.appending(path: relative) }

        func read(_ relative: String) -> String? {
            FileManager.default.contents(atPath: url(relative).path).map { String(decoding: $0, as: UTF8.self) }
        }

        func write(_ relative: String, _ text: String, permissions: Int = 0o644) throws {
            let file = url(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
        }

        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }

        func permissions(_ path: String) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
    }

    // MARK: - zsh

    @Test func zshInstallCreatesShimAndBlockThenUninstallRemovesBoth() throws {
        let box = try Sandbox()
        defer { box.temp.cleanup() }
        let installer = box.installer()
        #expect(installer.status().isInstalled == false)

        try installer.install()
        let bin = box.url(".basket/bin/docker").path
        #expect(FileManager.default.contentsEqual(atPath: bin, andPath: box.shim.path))
        #expect(box.permissions(bin) == 0o755)
        let zshrc = try #require(box.read(".zshrc"))
        #expect(zshrc == installer.block(for: "zsh") + "\n")
        #expect(zshrc.hasPrefix(DockerShimInstaller.startMarker))
        #expect(zshrc.contains(#"export PATH="$HOME/.basket/bin:$PATH""#))
        #expect(!box.exists(".zshrc.basket-backup"), "nothing to back up for a new file")

        let status = installer.status()
        #expect(status.isInstalled)
        #expect(status.binPath == bin)
        #expect(status.rcFiles == [box.url(".zshrc").path])
        #expect(status.shell == "zsh")
        #expect(status.currentDocker == bin)
        #expect(status.currentDockerIsOrbStack == false)

        try installer.uninstall()
        #expect(!box.exists(".zshrc"), "Basket created it, so it goes away")
        #expect(!box.exists(".basket"))
        #expect(installer.status().isInstalled == false)
        #expect(installer.status().rcFiles.isEmpty)
    }

    @Test func existingRcKeepsItsContentPermissionsAndIsBackedUpOnce() throws {
        let box = try Sandbox()
        defer { box.temp.cleanup() }
        let original = "# my zshrc\nexport EDITOR=vi\nalias ll='ls -l'\n"
        try box.write(".zshrc", original, permissions: 0o600)
        let installer = box.installer()

        try installer.install()
        let installed = try #require(box.read(".zshrc"))
        #expect(installed == original + "\n" + installer.block(for: "zsh") + "\n")
        #expect(box.permissions(box.url(".zshrc").path) == 0o600)
        #expect(box.read(".zshrc.basket-backup") == original)
        #expect(box.permissions(box.url(".zshrc.basket-backup").path) == 0o600)

        // Idempotent: a second install changes nothing and doesn't add a second block.
        try installer.install()
        #expect(box.read(".zshrc") == installed)

        // The user keeps editing after the block; the backup is not overwritten.
        try box.write(".zshrc", installed + "export LATER=1\n", permissions: 0o600)
        try installer.install()
        #expect(box.read(".zshrc.basket-backup") == original)

        try installer.uninstall()
        #expect(box.read(".zshrc") == original + "export LATER=1\n")
        #expect(box.permissions(box.url(".zshrc").path) == 0o600)
        #expect(box.read(".zshrc.basket-backup") == original, "uninstall leaves the backup alone")
    }

    @Test func installThenUninstallRestoresTheFileExactly() throws {
        let box = try Sandbox()
        defer { box.temp.cleanup() }
        let installer = box.installer()
        for original in ["", "a\n", "a\n\n", "export PATH=/x:$PATH\n# end\n"] {
            try box.write(".zshrc", original)
            try installer.install()
            #expect(box.read(".zshrc") != original)
            try installer.uninstall()
            #expect(box.read(".zshrc") == original, "original: \(original.debugDescription)")
        }
        // Without a final newline, the only difference is the newline Basket added.
        try box.write(".zshrc", "a")
        try installer.install()
        try installer.uninstall()
        #expect(box.read(".zshrc") == "a\n")
    }

    @Test func symlinkedRcIsWrittenThroughTheLink() throws {
        let box = try Sandbox()
        defer { box.temp.cleanup() }
        try box.write("dotfiles/zshrc", "export A=1\n", permissions: 0o640)
        try FileManager.default.createSymbolicLink(atPath: box.url(".zshrc").path, withDestinationPath: "dotfiles/zshrc")
        let installer = box.installer()

        try installer.install()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.url(".zshrc").path) == "dotfiles/zshrc")
        let target = try #require(box.read("dotfiles/zshrc"))
        #expect(target.contains(DockerShimInstaller.startMarker))
        #expect(box.permissions(box.url("dotfiles/zshrc").path) == 0o640)
        #expect(box.read(".zshrc.basket-backup") == "export A=1\n")
        #expect(installer.status().rcFiles == [box.url(".zshrc").path])

        try installer.uninstall()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.url(".zshrc").path) == "dotfiles/zshrc")
        #expect(box.read("dotfiles/zshrc") == "export A=1\n")
    }

    @Test func outdatedBlockIsReplacedInPlace() throws {
        let box = try Sandbox()
        defer { box.temp.cleanup() }
        let old = "\(DockerShimInstaller.startMarker)\nexport PATH=\"$HOME/.basket/bin:$PATH\"\n\(DockerShimInstaller.endMarker)"
        try box.write(".zshrc", "before\n\n\(old)\nafter\n")
        let installer = box.installer()
        try installer.install()
        #expect(box.read(".zshrc") == "before\n\n\(installer.block(for: "zsh"))\nafter\n")
        try installer.uninstall()
        #expect(box.read(".zshrc") == "before\nafter\n")
    }

    @Test func unterminatedBlockIsLeftAlone() throws {
        let box = try Sandbox()
        defer { box.temp.cleanup() }
        let broken = "a\n\(DockerShimInstaller.startMarker)\nexport PATH=x\n"
        try box.write(".zshrc", broken)
        let installer = box.installer()
        #expect(throws: DockerShimError.unterminatedBlock(file: box.url(".zshrc").path)) { try installer.install() }
        #expect(box.read(".zshrc") == broken)
        #expect(installer.status().rcFiles.isEmpty)
    }

    // MARK: - bash and fish

    @Test func bashWritesBashProfile() throws {
        let box = try Sandbox()
        defer { box.temp.cleanup() }
        let installer = box.installer(shell: "/bin/bash")
        #expect(installer.plannedChanges().map(\.file) == [box.url(".bash_profile").path])
        try installer.install()
        #expect(box.read(".bash_profile") == installer.block(for: "bash") + "\n")
        #expect(installer.status().shell == "bash")
        #expect(installer.status().isInstalled)
        try installer.uninstall()
        #expect(!box.exists(".bash_profile"))
    }

    @Test func bashUsesAnExistingProfileInsteadOfShadowingIt() throws {
        let box = try Sandbox()
        defer { box.temp.cleanup() }
        try box.write(".profile", "export LANG=en_US.UTF-8\n")
        let installer = box.installer(shell: "/usr/local/bin/bash")
        try installer.install()
        #expect(!box.exists(".bash_profile"), "creating it would stop bash from reading .profile")
        #expect(box.read(".profile")?.contains(DockerShimInstaller.startMarker) == true)
        try installer.uninstall()
        #expect(box.read(".profile") == "export LANG=en_US.UTF-8\n")
    }

    @Test func fishGetsItsOwnConfFile() throws {
        let box = try Sandbox()
        defer { box.temp.cleanup() }
        try box.write(".config/fish/config.fish", "set -gx EDITOR vi\n")
        let installer = box.installer(shell: "/opt/homebrew/bin/fish")
        try installer.install()
        let conf = try #require(box.read(".config/fish/conf.d/basket.fish"))
        #expect(conf.contains("set -gx PATH $HOME/.basket/bin $PATH"))
        #expect(!conf.contains("export "))
        #expect(installer.status().rcFiles == [box.url(".config/fish/conf.d/basket.fish").path])
        #expect(box.read(".config/fish/config.fish") == "set -gx EDITOR vi\n")
        try installer.uninstall()
        #expect(!box.exists(".config/fish/conf.d/basket.fish"))
        #expect(box.read(".config/fish/config.fish") == "set -gx EDITOR vi\n")
    }

    @Test func uninstallRemovesBlocksFromEveryShell() throws {
        let box = try Sandbox()
        defer { box.temp.cleanup() }
        try box.write(".zshrc", "z\n")
        try box.write(".bash_profile", "b\n")
        try box.installer(shell: "/bin/zsh").install()
        try box.installer(shell: "/bin/bash").install()
        let status = box.installer().status()
        #expect(status.rcFiles == [box.url(".zshrc").path, box.url(".bash_profile").path])
        try box.installer(shell: "/opt/homebrew/bin/fish").uninstall()
        #expect(box.read(".zshrc") == "z\n")
        #expect(box.read(".bash_profile") == "b\n")
    }

    @Test func unsupportedShellIsReported() throws {
        let box = try Sandbox()
        defer { box.temp.cleanup() }
        let installer = box.installer(shell: "/bin/tcsh")
        #expect(installer.plannedChanges().isEmpty)
        #expect(throws: DockerShimError.unsupportedShell("tcsh")) { try installer.install() }
        #expect(!box.exists(".basket"))
    }

    // MARK: - Shim copy

    @Test func missingShimSourceChangesNothing() throws {
        let box = try Sandbox()
        defer { box.temp.cleanup() }
        let installer = box.installer(shimSource: .some(nil))
        #expect(throws: DockerShimError.missingShimSource) { try installer.install() }
        #expect(!box.exists(".zshrc"))
        let missing = box.installer(shimSource: box.temp.url.appending(path: "nope"))
        #expect(throws: DockerShimError.missingShimSource) { try missing.install() }
    }

    @Test func refreshReplacesAnOutdatedShimOnlyWhenInstalled() throws {
        let box = try Sandbox()
        defer { box.temp.cleanup() }
        let installer = box.installer()
        try installer.refreshShimIfNeeded()
        #expect(!box.exists(".basket/bin/docker"), "not installed: nothing to refresh")

        try installer.install()
        try box.writeShim("#!/bin/sh\necho shim v2\n")
        try installer.refreshShimIfNeeded()
        #expect(box.read(".basket/bin/docker") == "#!/bin/sh\necho shim v2\n")
        #expect(box.permissions(box.url(".basket/bin/docker").path) == 0o755)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: box.url(".basket/bin").path)
        #expect(leftovers == ["docker"])
    }

    @Test func quarantineIsNotCopied() throws {
        let box = try Sandbox()
        defer { box.temp.cleanup() }
        let value = "0081;00000000;Basket;"
        setxattr(box.shim.path, "com.apple.quarantine", value, value.utf8.count, 0, 0)
        try box.installer().install()
        #expect(getxattr(box.url(".basket/bin/docker").path, "com.apple.quarantine", nil, 0, 0, 0) == -1)
    }

    // MARK: - Status

    @Test func reportsTheDockerOnPathAndOrbStack() throws {
        let box = try Sandbox()
        defer { box.temp.cleanup() }
        #expect(box.installer().status().currentDocker == nil)

        // OrbStack's CLI symlinked into a PATH directory.
        let orbDocker = box.temp.url.appending(path: "Applications/OrbStack.app/Contents/MacOS/xbin/docker")
        try FileManager.default.createDirectory(at: orbDocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: orbDocker)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orbDocker.path)
        let link = box.pathDir.appending(path: "docker").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: orbDocker.path)

        let before = box.installer().status()
        #expect(before.currentDocker == link)
        #expect(before.currentDockerIsOrbStack)

        try box.installer().install()
        let after = box.installer().status()
        #expect(after.currentDocker == box.url(".basket/bin/docker").path)
        #expect(after.currentDockerIsOrbStack == false)

        #expect(box.installer().isOrbStack(box.url(".orbstack/bin/docker").path))
    }

    @Test func plannedChangesShowTheExactBlock() throws {
        let box = try Sandbox()
        defer { box.temp.cleanup() }
        let installer = box.installer()
        let changes = installer.plannedChanges()
        #expect(changes.count == 1)
        #expect(changes[0].file == box.url(".zshrc").path)
        try installer.install()
        #expect(box.read(".zshrc") == changes[0].contents)
    }

    @Test func publicInitUsesTheGivenHome() throws {
        let box = try Sandbox()
        defer { box.temp.cleanup() }
        let status = DockerShimInstaller(home: box.home, shimSource: box.shim).status()
        #expect(status.binPath == box.url(".basket/bin/docker").path)
        #expect(status.isInstalled == false)
        #expect(!status.shell.isEmpty)
    }
}
