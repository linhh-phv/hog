import AppKit
import HogCore

/// The menu bar icon: a monochrome pig face (design system, `MenuBarIcon`). Template when all is normal so macOS
/// tints it like system icons; coloured by the worse of memory pressure and heat (hot → orange, very hot → red).
enum PigIcon {
    static func image(pressure: Pressure?, thermal: ThermalState? = nil, colored: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let critical = pressure == .critical || thermal == .critical
        let warn = pressure == .warn || thermal == .serious
        let tint: NSColor? = colored ? (critical ? .systemRed : (warn ? .systemOrange : nil)) : nil
        let img = NSImage(size: size, flipped: true) { _ in
            (tint ?? .black).setStroke()
            (tint ?? .black).setFill()
            let line: CGFloat = 1.5
            func stroke(_ p: NSBezierPath) { p.lineWidth = line; p.lineJoinStyle = .round; p.lineCapStyle = .round; p.stroke() }
            let ear1 = NSBezierPath(); ear1.move(to: NSPoint(x: 4.2, y: 4.6)); ear1.line(to: NSPoint(x: 2.6, y: 1.4)); ear1.line(to: NSPoint(x: 6.6, y: 3.0)); stroke(ear1)
            let ear2 = NSBezierPath(); ear2.move(to: NSPoint(x: 13.8, y: 4.6)); ear2.line(to: NSPoint(x: 15.4, y: 1.4)); ear2.line(to: NSPoint(x: 11.4, y: 3.0)); stroke(ear2)
            stroke(NSBezierPath(ovalIn: NSRect(x: 2.8, y: 2.4, width: 12.4, height: 12.4)))
            stroke(NSBezierPath(ovalIn: NSRect(x: 6.1, y: 8.4, width: 5.8, height: 4.0)))
            for (x, y, r) in [(7.9, 10.4, 0.55), (10.1, 10.4, 0.55), (6.4, 6.9, 0.6), (11.6, 6.9, 0.6)] as [(CGFloat, CGFloat, CGFloat)] {
                NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)).fill()
            }
            return true
        }
        img.isTemplate = tint == nil
        img.accessibilityDescription = "hog"
        return img
    }
}
