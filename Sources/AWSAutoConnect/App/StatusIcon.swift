import AppKit

/// The "Tunnel" mark (Assets/MenuBarIcon.svg) in the menu bar's text colour: dimmed
/// when nothing is connected, a green dot when all is well, yellow while working, red when it needs you.
enum StatusIcon {
    static func image(for health: ConnectorStatus.Health) -> NSImage {
        let dot: NSColor? = switch health {
        case .idle: nil
        case .ok: .systemGreen
        case .busy: .systemYellow
        case .attention: .systemRed
        }
        let alpha: CGFloat = health == .idle ? 0.45 : 1
        #if DEV
        let mark = NSColor.systemOrange
        #else
        // A template image follows the light/dark menu bar; its alpha carries the dimming.
        guard dot != nil else { return glyph(alpha: alpha) }
        // labelColor resolves at draw time, so it follows the light/dark menu bar.
        let mark = NSColor.labelColor
        #endif

        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side + 3, height: side), flipped: false) { rect in
            drawGlyph(in: NSRect(x: 0, y: 0, width: side, height: side), color: mark, alpha: alpha)
            guard let dot else { return true }

            let d: CGFloat = 7
            let dotRect = NSRect(x: rect.width - d, y: 0.5, width: d, height: d)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            dot.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.accessibilityDescription = "AWS Auto Connect"
        return image
    }

    /// The bare mark as a template image (menu bar without a dot).
    static func glyph(side: CGFloat = 18, alpha: CGFloat = 1) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            drawGlyph(in: rect, color: .black, alpha: alpha)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "AWS Auto Connect"
        return image
    }

    /// Nested arches over a ground line, from the SVG's 0…100 box (y flipped for AppKit).
    private static func drawGlyph(in rect: NSRect, color: NSColor, alpha: CGFloat) {
        let cg = NSGraphicsContext.current?.cgContext
        // One layer, so the dimming applies to the mark as a whole, not to each overlapping stroke.
        cg?.saveGState()
        cg?.setAlpha(alpha)
        cg?.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { cg?.endTransparencyLayer(); cg?.restoreGState() }
        let s = rect.width / 100
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * s, y: rect.minY + (100 - y) * s) }
        func arch(left: CGFloat, right: CGFloat, top: CGFloat, alpha: CGFloat) {
            let r = (right - left) / 2
            let path = NSBezierPath()
            path.move(to: p(left, 82))
            path.line(to: p(left, top))
            path.appendArc(withCenter: p(left + r, top), radius: r * s, startAngle: 180, endAngle: 0, clockwise: true)
            path.line(to: p(right, 82))
            stroke(path, color.withAlphaComponent(alpha))
        }
        func stroke(_ path: NSBezierPath, _ c: NSColor) {
            path.lineWidth = 7 * s
            path.lineCapStyle = .round
            c.setStroke()
            path.stroke()
        }
        arch(left: 18, right: 82, top: 52, alpha: 1)
        arch(left: 31, right: 69, top: 54, alpha: 0.6)
        arch(left: 44, right: 56, top: 57, alpha: 0.3)
        let ground = NSBezierPath()
        ground.move(to: p(12, 82))
        ground.line(to: p(88, 82))
        stroke(ground, color)
    }
}
