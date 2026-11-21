import AppKit
import Testing
@testable import BasketAXKit

@Suite("WCAG contrast")
struct ContrastRatioTests {
    @Test func knownRatios() {
        #expect(ContrastRatio.between(.black, .white) == 21)
        #expect(ContrastRatio.between(.white, .white) == 1)
        // The classic "lightest grey that passes AA on white".
        #expect(abs(ContrastRatio.between(SRGB(hex: 0x767676), .white) - 4.54) < 0.01)
        #expect(abs(ContrastRatio.between(SRGB(hex: 0x777777), .white) - 4.48) < 0.01)
        #expect(SRGB.black.composited(alpha: 0.5, over: .white).description == "#808080")
    }

    @Test func passingColoursAreLeftAlone() {
        let indigo = SRGB(hex: 0x4B3FD6)
        #expect(ContrastRatio.adjusted(indigo, against: [.white]) == indigo)
        #expect(ContrastRatio.adjusted(.white, against: [SRGB(hex: 0x1E1E1E)]) == .white)
    }

    @Test func failingColoursMoveJustFarEnough() {
        let orange = SRGB(hex: 0xFF8D28)
        let onWhite = ContrastRatio.adjusted(orange, against: [.white, SRGB(hex: 0xECECEC)])
        let ratio = ContrastRatio.between(onWhite, SRGB(hex: 0xECECEC))
        #expect(ratio >= ContrastRatio.textAA && ratio < 4.7)
        #expect(onWhite.red > onWhite.green && onWhite.green > onWhite.blue) // still orange

        let indigo = SRGB(hex: 0x3F2FD0)
        let onDark = ContrastRatio.adjusted(indigo, against: [SRGB(hex: 0x1E1E1E)])
        #expect(onDark.relativeLuminance > indigo.relativeLuminance)
        let darkRatio = ContrastRatio.between(onDark, SRGB(hex: 0x1E1E1E))
        #expect(darkRatio >= ContrastRatio.textAA && darkRatio < 4.7)
    }

    /// Any system colour reaches AA against the text and window backgrounds of both appearances,
    /// which is how the Inspect JSON palette is built.
    @Test @MainActor func systemColoursReachAA() throws {
        let colors: [NSColor] = [.systemPurple, .systemTeal, .systemOrange, .systemBlue, .systemYellow, .labelColor,
                                 .secondaryLabelColor]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var worst = Double.infinity
            appearance.performAsCurrentDrawingAppearance {
                let backgrounds = [NSColor.textBackgroundColor, .windowBackgroundColor].map { Self.srgb($0) }
                for color in colors {
                    let converted = color.usingColorSpace(.sRGB)!
                    let base = Self.srgb(color).composited(alpha: converted.alphaComponent, over: backgrounds[0])
                    let adjusted = ContrastRatio.adjusted(base, against: backgrounds)
                    worst = min(worst, backgrounds.map { ContrastRatio.between(adjusted, $0) }.min()!)
                }
            }
            #expect(worst >= ContrastRatio.textAA, "\(name.rawValue): \(worst)")
        }
    }

    static func srgb(_ color: NSColor) -> SRGB {
        let c = color.usingColorSpace(.sRGB)!
        return SRGB(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
    }
}
