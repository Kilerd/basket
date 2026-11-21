import Foundation

/// A gamma-encoded sRGB colour, components 0…1.
public struct SRGB: Sendable, Hashable, CustomStringConvertible {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    public static let black = SRGB(red: 0, green: 0, blue: 0)
    public static let white = SRGB(red: 1, green: 1, blue: 1)

    /// WCAG 2.x relative luminance.
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// This colour drawn with `alpha` over `background` (how `secondaryLabelColor` reaches the eye).
    public func composited(alpha: Double, over background: SRGB) -> SRGB {
        background.blended(toward: self, fraction: alpha)
    }

    public func blended(toward other: SRGB, fraction: Double) -> SRGB {
        SRGB(red: red + (other.red - red) * fraction, green: green + (other.green - green) * fraction,
             blue: blue + (other.blue - blue) * fraction)
    }

    public var description: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()),
               Int((blue * 255).rounded()))
    }
}

/// WCAG 2.x contrast ratios, and the smallest change that makes a colour readable as text.
public enum ContrastRatio {
    /// AA for body text (WCAG 2.x, 1.4.3).
    public static let textAA = 4.5

    public static func between(_ a: SRGB, _ b: SRGB) -> Double {
        let (x, y) = (a.relativeLuminance, b.relativeLuminance)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `foreground` itself when it reaches `target` against every background; otherwise blended
    /// toward black (light backgrounds) or white (dark ones) by the smallest fraction that does,
    /// so the hue survives. Rounded to 8 bits toward the ink, which only adds contrast.
    public static func adjusted(_ foreground: SRGB, against backgrounds: [SRGB], target: Double = textAA) -> SRGB {
        func worst(_ color: SRGB) -> Double { backgrounds.map { between(color, $0) }.min() ?? .infinity }
        guard let weakest = backgrounds.min(by: { between(foreground, $0) < between(foreground, $1) }),
              worst(foreground) < target else { return foreground }
        // Above ≈ 0.18 luminance black contrasts more than white.
        let ink: SRGB = weakest.relativeLuminance > 0.18 ? .black : .white
        var (low, high) = (0.0, 1.0)
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if worst(foreground.blended(toward: ink, fraction: middle)) >= target { high = middle } else { low = middle }
        }
        let blended = foreground.blended(toward: ink, fraction: high)
        func quantized(_ c: Double) -> Double {
            (ink == .black ? (c * 255).rounded(.down) : (c * 255).rounded(.up)) / 255
        }
        return SRGB(red: quantized(blended.red), green: quantized(blended.green), blue: quantized(blended.blue))
    }
}
