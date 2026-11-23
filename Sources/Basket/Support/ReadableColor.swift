import AppKit
import BasketAXKit
import Synchronization

/// Dynamic text colours that reach WCAG AA (4.5:1) in every appearance: `base` as it resolves in
/// that appearance, moved toward black (light) or white (dark) by the smallest step that reaches
/// AA against every background it sits on (`ContrastRatio.adjusted`), so the hue stays
/// recognisable. Each appearance is resolved once and remembered, so a live switch (macOS's or
/// Settings ▸ General ▸ Appearance) and Increase Contrast apply at once.
enum ReadableColor {
    /// The surfaces list and card content sits on, as macOS 26 draws the main window (measured in
    /// self-test captures, light / dark): rows #FFFFFF / #252628, cards #F8F8F8 / #2B2C2E,
    /// alternating rows #F4F5F5 / #2F3032. Text readable on both ends is readable on all of them.
    static let contentBackgrounds: [NSColor] = [
        NSColor(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x252628)),
        NSColor(light: NSColor(hex: 0xF4F5F5), dark: NSColor(hex: 0x2F3032)),
    ]

    /// `base` readable on each of `backgrounds` (translucent ones are drawn over the first), with
    /// an optional translucent `fill` drawn on them first (a tinted capsule: colour and opacity).
    static func make(_ base: NSColor, on backgrounds: [NSColor], fill: (color: NSColor, opacity: Double)? = nil,
                     target: Double = ContrastRatio.textAA) -> NSColor {
        let cache = Cache()
        return NSColor(name: nil) { appearance in
            let key = appearance.bestMatch(from: variants) ?? appearance.name
            if let known = cache.colors.withLock({ $0[key] }) { return known }
            let resolved = resolve(base, on: backgrounds, fill: fill, target: target, in: appearance)
            cache.colors.withLock { $0[key] = resolved }
            return resolved
        }
    }

    /// `base` as it resolves in `appearance`, made opaque and adjusted to AA.
    static func resolve(_ base: NSColor, on backgrounds: [NSColor], fill: (color: NSColor, opacity: Double)? = nil,
                        target: Double = ContrastRatio.textAA, in appearance: NSAppearance) -> NSColor {
        var result = base
        appearance.performAsCurrentDrawingAppearance {
            var surfaces: [SRGB] = []
            for background in backgrounds {
                guard let color = rgba(background) else { continue }
                surfaces.append(color.alpha < 1 ? color.rgb.composited(alpha: color.alpha, over: surfaces.first ?? .white) : color.rgb)
            }
            if let fill, let tint = rgba(fill.color) {
                surfaces = surfaces.map { tint.rgb.composited(alpha: tint.alpha * fill.opacity, over: $0) }
            }
            guard let color = rgba(base), let first = surfaces.first else { return }
            let readable = ContrastRatio.adjusted(color.rgb.composited(alpha: color.alpha, over: first), against: surfaces,
                                                  target: target)
            result = NSColor(srgbRed: readable.red, green: readable.green, blue: readable.blue, alpha: 1)
        }
        return result
    }

    private static func rgba(_ color: NSColor) -> (rgb: SRGB, alpha: Double)? {
        color.usingColorSpace(.sRGB).map {
            (SRGB(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent), $0.alphaComponent)
        }
    }

    /// The text system resolves a colour for every run it draws: remember each appearance's result.
    private final class Cache: Sendable {
        let colors = Mutex<[NSAppearance.Name: NSColor]>([:])
    }

    /// Increase Contrast keeps the appearance's name but matches the high-contrast variants.
    private static let variants: [NSAppearance.Name] = [
        .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua, .aqua, .darkAqua,
    ]
}
