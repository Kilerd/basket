import AppKit
import SwiftUI

/// Fixed, right-aligned number slots for the Overview cards' tables. A slot is as wide as the
/// widest template value in the current locale ("1,023.9 MB", "888,88 Go"), set in the cards'
/// callout font with monospaced digits, so a column doesn't change width when the numbers do.
/// In a `Grid` the column still grows to its widest cell, which covers a localized header
/// ("Récupérable") or a value longer than the template.
@MainActor
enum CardSlot {
    static var memory: CGFloat {
        width([Format.memory(1_073_636_966), Format.memory(954_351_800_000)])  // 1023.9 MiB, 888.81 GiB
    }

    static var disk: CGFloat {
        width([Format.disk(999_900_000), Format.disk(888_880_000_000)])  // 999.9 MB, 888.88 GB
    }

    /// "888 of 888" containers/images/volumes in use.
    static var count: CGFloat {
        width([String(localized: "\(888) of \(888)")])
    }

    private static func width(_ samples: [String]) -> CGFloat {
        let size = NSFont.preferredFont(forTextStyle: .callout).pointSize
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let widest = samples.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return widest.rounded(.up)
    }
}

extension View {
    /// Puts a number in a card's fixed-width, right-aligned slot. The text never truncates: a
    /// longer value widens its slot instead.
    func cardSlot(_ width: CGFloat) -> some View {
        monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: width, alignment: .trailing)
    }
}
