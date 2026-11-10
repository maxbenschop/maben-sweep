import AppKit
import SwiftUI

/// The Sweep glyph: a broom, drawn by hand so the menu bar, the menu and the window share it.
/// A template image, so macOS tints it for light and dark menu bars.
enum MenuIcon {
    /// - Parameter dot: a small dot at the top right, shown while a cleanup is scheduled.
    static func image(size: CGFloat = 18, dot: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            NSColor.black.set()
            let s = size / 18
            let turn = NSAffineTransform()
            turn.translateX(by: 10.3 * s, yBy: 9.4 * s)
            turn.rotate(byDegrees: -38)
            turn.scale(by: s * 0.86)
            turn.translateX(by: -9, yBy: -9.6)

            // Handle, the band that holds the bristles, and the bristles fanning out.
            let handle = NSBezierPath(roundedRect: NSRect(x: 8.2, y: 8.6, width: 1.6, height: 9.6), xRadius: 0.8, yRadius: 0.8)
            let band = NSBezierPath(roundedRect: NSRect(x: 5.6, y: 6.9, width: 6.8, height: 2.3), xRadius: 0.9, yRadius: 0.9)
            let bristles = NSBezierPath()
            bristles.move(to: NSPoint(x: 6.0, y: 6.0))
            bristles.line(to: NSPoint(x: 12.0, y: 6.0))
            bristles.line(to: NSPoint(x: 13.6, y: 0.4))
            bristles.line(to: NSPoint(x: 4.4, y: 0.4))
            bristles.close()
            for path in [handle, band, bristles] {
                path.transform(using: turn as AffineTransform)
                path.fill()
            }
            if dot {
                NSBezierPath(ovalIn: NSRect(x: 12.6 * s, y: 12.6 * s, width: 4.6 * s, height: 4.6 * s)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The broom as a SwiftUI view, in the current foreground colour.
struct BroomGlyph: View {
    var size: CGFloat = 16
    var body: some View {
        Image(nsImage: MenuIcon.image(size: size)).renderingMode(.template).resizable().frame(width: size, height: size)
    }
}
