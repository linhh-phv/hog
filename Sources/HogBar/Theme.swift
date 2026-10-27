import AppKit
import HogCore
import SwiftUI

/// Native macOS look (task ui-compact, user: "làm UI giống với macos"): system semantic colours that follow the
/// accent colour, light/dark and Increase Contrast; system fonts and materials. Only sizes are hog's own.
/// docs/design/design-system.md lists the rules.
enum Theme {
    // Spacing (multiples of 4), radius, width of the menu.
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
    static let rModule: CGFloat = 10
    static let width: CGFloat = 340

    /// State colours: green fine, orange strain/hot, red struggling. Always paired with a word and a shape.
    static func tone(_ t: Overview.Tone) -> Color {
        switch t { case .ok: .green; case .warn: .orange; case .critical: .red }
    }

    static func pressure(_ p: Pressure?) -> Color {
        switch p { case .normal?: .green; case .warn?: .orange; case .critical?: .red; case nil: .secondary }
    }

    static func thermal(_ t: ThermalState?) -> Color {
        switch t { case .nominal?: .green; case .fair?: .primary; case .serious?: .orange; case .critical?: .red; case nil: .secondary }
    }
}

extension View {
    /// A Control Center–style module: a translucent rounded block on the menu's material.
    func module() -> some View {
        self.background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.rModule, style: .continuous))
    }
}
