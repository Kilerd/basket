import AppKit

/// PNG of one of our own windows, toolbar included, without Screen Recording permission.
@MainActor
enum WindowSnapshot {
    static func png(of window: NSWindow) -> Data? {
        if let image = windowServerImage(of: window) {
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }
        return cachedDisplayPNG(of: window)
    }

    /// The window server's composited image of the window. macOS lets a process capture its own
    /// windows without the Screen Recording permission. `CGWindowListCreateImage` is marked
    /// obsolete in the macOS 15+ SDK but still exported, so it is resolved at runtime;
    /// ScreenCaptureKit would require the permission even for our own window.
    private static func windowServerImage(of window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard window.windowNumber > 0,
              let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // Window-server coordinates: origin at the top-left of the primary screen.
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let f = window.frame
        let rect = CGRect(x: f.minX, y: screenHeight - f.maxY, width: f.width, height: f.height)
        let includingWindow: UInt32 = 1 << 3       // kCGWindowListOptionIncludingWindow
        let bestResolution: UInt32 = 1 << 3        // kCGWindowImageBestResolution
        return create(rect, includingWindow, UInt32(window.windowNumber), bestResolution)?.takeRetainedValue()
    }

    /// AppKit's own rendering. Misses SwiftUI/Core Animation content on recent macOS, so it is
    /// only a fallback.
    private static func cachedDisplayPNG(of window: NSWindow) -> Data? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
