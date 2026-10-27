import AppKit
import HogCore
import SwiftUI

/// macOS 26+ look (Liquid Glass): the menu is system glass, each part is a Control Center–style module of glass on it,
/// buttons are glass capsules. System semantic colours follow the accent colour, light/dark, Increase Contrast and Reduce
/// Transparency. Only sizes are hog's own. docs/design/design-system.md lists the rules.
enum Theme {
    // Spacing (multiples of 4), radius of a module, width of the menu.
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
    static let rModule: CGFloat = 18
    static let rSheet: CGFloat = 24
    static let width: CGFloat = 340

    /// Off-screen renders (`HogBar --render`) cannot draw glass: the window server composites it. They draw a flat fill
    /// instead, so the layout still shows.
    @MainActor static var offscreen = false

    /// A module's shape: concentric with the menu's corners where it meets them, never under `rModule`.
    static var moduleShape: ConcentricRectangle { ConcentricRectangle(corners: .concentric(minimum: .fixed(rModule)), isUniform: true) }

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
    /// A Control Center–style module: a block of system glass on the menu's glass.
    @MainActor @ViewBuilder func module() -> some View {
        if Theme.offscreen {
            background(.quaternary.opacity(0.6), in: Theme.moduleShape)
        } else {
            glassEffect(.regular, in: Theme.moduleShape)
        }
    }

    /// A glass button (prominent: tinted with the accent colour, or `.tint`); bordered in off-screen renders.
    @MainActor @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        switch (Theme.offscreen, prominent) {
        case (true, true): buttonStyle(.borderedProminent)
        case (true, false): buttonStyle(.bordered)
        case (false, true): buttonStyle(.glassProminent)
        case (false, false): buttonStyle(.glass)
        }
    }

    /// The search field: a capsule of glass, like the search fields of macOS 26.
    @MainActor @ViewBuilder func searchField() -> some View {
        if Theme.offscreen {
            background(.quaternary.opacity(0.6), in: Capsule())
        } else {
            glassEffect(.regular, in: Capsule())
        }
    }

    /// A row that lights up under the pointer, like the rows of macOS menus.
    func hoverRow() -> some View { modifier(HoverRow()) }
}

struct HoverRow: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(hover ? 0.07 : 0)).padding(.horizontal, -6)
            }
            .onHover { hover = $0 }
    }
}
