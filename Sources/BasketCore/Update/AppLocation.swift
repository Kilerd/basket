import Darwin
import Foundation

/// Can the app at a location replace itself? Not when Gatekeeper runs it translocated (a
/// read-only randomized mount of a quarantined download) or when its folder isn't writable.
public enum AppLocation {
    /// Translocated apps run from `…/AppTranslocation/<uuid>/d/<name>.app`.
    public static func pathLooksTranslocated(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    public static func isTranslocated(_ bundle: URL) -> Bool {
        if pathLooksTranslocated(bundle.path) { return true }
        return secTranslocateIsTranslocated(bundle) ?? false
    }

    /// `SecTranslocateIsTranslocatedURL` (Security, not in the public headers), looked up at run
    /// time; nil when unavailable.
    static func secTranslocateIsTranslocated(_ url: URL) -> Bool? {
        typealias Function = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SecTranslocateIsTranslocatedURL") else { return nil }
        let function = unsafeBitCast(symbol, to: Function.self)
        var translocated = false
        guard function(url as CFURL, &translocated, nil) else { return nil }
        return translocated
    }

    /// The swap renames the bundle within its folder: both need write access.
    public static func isReplaceable(_ bundle: URL) -> Bool {
        let parent = bundle.deletingLastPathComponent()
        return access(parent.path, W_OK) == 0 && access(bundle.path, W_OK) == 0
    }

    /// Why updates can't be installed at `bundle`, or nil when they can.
    public static func problem(with bundle: URL) -> String? {
        guard bundle.pathExtension == "app" else {
            return "Basket isn't running from an app bundle (a development run), so it can't update itself."
        }
        if isTranslocated(bundle) {
            return "macOS runs this copy of Basket from a temporary read-only location because it was opened where it was downloaded. Move Basket to the Applications folder and open it again to get updates."
        }
        guard isReplaceable(bundle) else {
            return "Basket can't replace itself in “\(bundle.deletingLastPathComponent().path)” (no write permission). Move it to a folder you can write to, such as Applications."
        }
        return nil
    }
}
