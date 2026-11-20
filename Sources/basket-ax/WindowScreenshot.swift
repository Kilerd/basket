import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Window screenshots via ScreenCaptureKit — only when Screen Recording is already granted
/// (never prompts; the audit is still valid without pictures).
enum WindowScreenshot {
    static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    /// Captures the on-screen window of `pid` whose frame best matches `frame` (AX/CG global
    /// coordinates, top-left origin) and writes it as PNG to `url`.
    static func capture(pid: pid_t, matching frame: CGRect?, to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 1
        }
        guard !candidates.isEmpty else { throw ScreenshotError.noWindow }
        let window: SCWindow
        if let frame {
            window = candidates.min { distance($0.frame, frame) < distance($1.frame, frame) }!
        } else {
            window = candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }!
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenshotError.cannotWrite
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ScreenshotError.cannotWrite }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    enum ScreenshotError: Error, CustomStringConvertible {
        case noWindow, cannotWrite
        var description: String {
            switch self {
            case .noWindow: "no on-screen window of the app"
            case .cannotWrite: "cannot write PNG"
            }
        }
    }
}
