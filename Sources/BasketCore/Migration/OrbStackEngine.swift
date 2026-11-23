import Darwin
import Foundation

/// Whether OrbStack's Docker engine is actually up — not just some process inside OrbStack.app (the
/// GUI with the engine stopped, or a user's own `xbin/docker`). A docker call while the engine is
/// down might start it, so Basket only calls docker when this says yes.
public enum OrbStackEngine {
    /// The socket the `orbstack` docker context points at.
    public static var socketPath: String { NSHomeDirectory() + "/.orbstack/run/docker.sock" }

    /// The VM manager (`OrbStack Helper vmgr`) runs, and only then: the docker socket accepts a
    /// connection. The socket is never touched while the VM manager is down. `appPath`: OrbStack.app
    /// outside the standard folders (`OrbStackLocator`).
    public static func isUp(socketPath: String = socketPath, appPath: String? = nil) -> Bool {
        vmManagerRunning(appPath: appPath) && socketAcceptsConnections(socketPath)
    }

    /// `…/OrbStack.app/Contents/Frameworks/OrbStack Helper.app/Contents/MacOS/OrbStack Helper vmgr …`.
    static func vmManagerRunning(appPath: String? = nil) -> Bool {
        let prefixes = (OrbStackLocator.standardPaths + [appPath].compactMap { $0 }).map { $0 + "/" }
        return ProcessInspector.allPIDs().contains { pid in
            guard let path = ProcessInspector.executablePath(of: pid), prefixes.contains(where: path.hasPrefix),
                  path.hasSuffix("/OrbStack Helper")
            else { return false }
            return ProcessInspector.arguments(of: pid)?.dropFirst().first == "vmgr"
        }
    }

    /// A non-blocking `connect(2)` to a Unix socket; closed immediately, nothing is sent.
    static func socketAcceptsConnections(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return result == 0
    }
}
