import AppKit

/// Programmatically-drawn menu bar icon: the ting's microphone grille — a
/// circle crossed by horizontal lines at equal spacing, gap thickness equal
/// to line thickness. Dictating = the circle fills solid ("recording").
///
/// A colored status dot in the bottom-right corner gives at-a-glance state:
///
///   no dot        no ting detected / idle
///   orange dot    searching for the ting (beacon scan) or beacon gone stale
///   green dot     ting present (serial connected or beacon-locked)
///   red dot       trigger held / dictation live
///
/// `needsAttention` overlays an orange "!" badge in the top-right corner —
/// shown whenever a required permission (microphone / accessibility) is
/// missing, independent of the detection dot.
///
/// The glyph is drawn in labelColor (adapts to light/dark); the dot needs
/// real color, so these are NOT template images.
enum MenuBarIcon {
    private static let side: CGFloat = 18
    /// Grille line thickness == gap thickness.
    private static let stripe: CGFloat = 2

    enum Dot {
        case none
        case searching  // orange
        case present    // green
        case active     // red
        case busy       // yellow: flashing the device
        case polishing  // blue: AI rewrite pass in flight

        var color: NSColor? {
            switch self {
            case .none: return nil
            case .searching: return .systemOrange
            case .present: return .systemGreen
            case .active: return .systemRed
            case .busy: return .systemYellow
            case .polishing: return .systemBlue
            }
        }
    }

    static func image(dictating: Bool, dot: Dot, dimmed: Bool = false, needsAttention: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            let circleRect = NSRect(x: 1, y: 1, width: side - 2, height: side - 2)
            let circle = NSBezierPath(ovalIn: circleRect)
            (dimmed ? NSColor.tertiaryLabelColor : NSColor.labelColor).set()

            if dictating {
                circle.fill()
            } else {
                NSGraphicsContext.current?.saveGraphicsState()
                circle.addClip()
                // Stripes across the full width, clipped to the circle:
                // 2pt line, 2pt gap, centered vertically.
                var y = circleRect.minY + 1
                while y < circleRect.maxY {
                    NSBezierPath(rect: NSRect(x: 0, y: y, width: side, height: stripe)).fill()
                    y += stripe * 2
                }
                NSGraphicsContext.current?.restoreGraphicsState()
            }

            if let color = dot.color {
                // Punch a 1pt gap around the dot so it reads over the glyph.
                let dotRect = NSRect(x: side - 8, y: side - 8, width: 8, height: 8)
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: dotRect.insetBy(dx: -1, dy: -1)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                color.set()
                NSBezierPath(ovalIn: dotRect).fill()
            }

            if needsAttention {
                // "!" badge, top-right (the dot owns bottom-right). Same
                // punch-out trick so it reads over the grille.
                let badgeRect = NSRect(x: side - 9, y: 0, width: 9, height: 9)
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1, dy: -1)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.systemOrange.set()
                NSBezierPath(ovalIn: badgeRect).fill()
                NSColor.white.set()
                // Flipped coords: stem hangs from the top of the badge.
                let cx = badgeRect.midX
                NSBezierPath(rect: NSRect(x: cx - 0.75, y: badgeRect.minY + 1.5, width: 1.5, height: 3.75)).fill()
                NSBezierPath(ovalIn: NSRect(x: cx - 0.75, y: badgeRect.maxY - 3, width: 1.5, height: 1.5)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
