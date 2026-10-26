import AppKit
import SwiftUI

/// Tokens from docs/design/design-system.md. Change them there first.
enum Theme {
    static func dyn(_ light: UInt32, _ dark: UInt32, alpha: (CGFloat, CGFloat) = (1, 1)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: isDark ? alpha.1 : alpha.0)
        })
    }

    static let bg = dyn(0xF4F4F5, 0x2A2A2C)
    static let raised = dyn(0xFFFFFF, 0x3A3A3C)
    static let text = dyn(0x1D1D1F, 0xF5F5F7)
    static let text2 = dyn(0x5D5D62, 0xB0B0B5)
    static let sep = dyn(0x000000, 0xFFFFFF, alpha: (0.10, 0.12))
    static let fill = dyn(0x000000, 0xFFFFFF, alpha: (0.05, 0.07))
    static let accent = dyn(0x0062CC, 0x4DA3FF)
    static let accentBg = dyn(0x0062CC, 0x1F6FD6)
    static let ok = dyn(0x1A7F37, 0x4CD964)
    static let warn = dyn(0xA14A00, 0xFFB340)
    static let red = dyn(0xC4001A, 0xFF6B6B)
    static let redBg = dyn(0xC4001A, 0xC8242F)
    static let bars = [dyn(0x0062CC, 0x4DA3FF), dyn(0x5E5CE6, 0x8D8BFF), dyn(0xA14A00, 0xFFB340), dyn(0x8E8E93, 0x8E8E93)]

    // Type
    static let title = Font.system(size: 15, weight: .semibold)
    static let metric = Font.system(size: 14, weight: .semibold).monospacedDigit()
    static let body = Font.system(size: 13)
    static let small = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let captionBold = Font.system(size: 11, weight: .semibold)

    // Spacing, radius, size
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
    static let rMenu: CGFloat = 12, rTile: CGFloat = 10, rButton: CGFloat = 6
    static let width: CGFloat = 340
}

extension View {
    /// Raised tile/card: `raised` fill, 0.5 pt `sep` border, radius 10.
    func tile() -> some View {
        self.background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.rTile))
            .overlay(RoundedRectangle(cornerRadius: Theme.rTile).strokeBorder(Theme.sep, lineWidth: 0.5))
    }
}
