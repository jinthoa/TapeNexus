import AppKit

/// Programmatic cassette-tape icon. Drawn blind from the cassette-tape
/// silhouette (rounded body + two spool holes + tape window) rather than
/// rasterized from the app icon, so it stays crisp at every menu-bar scale
/// and tints correctly as a template image in light/dark mode.
@MainActor
enum TapeIcon {
    /// Monochrome template image of a cassette tape, sized for the menu-bar
    /// status item. The system tints the opaque parts to the menu-bar color
    /// and leaves the punched-out spool/window holes transparent.
    static func statusImage(pointSize: CGFloat = 16) -> NSImage {
        let s = pointSize
        let img = NSImage(size: NSSize(width: s, height: s))
        img.isTemplate = true
        img.lockFocus()
        defer { img.unlockFocus() }
        guard let ctx = NSGraphicsContext.current else { return img }
        let k = s / 16          // design is laid out in a 16×16 unit space, y-up

        // Body — filled rounded rect (the cassette shell).
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 1.5 * k, y: 3 * k,
                                         width: 13 * k, height: 10 * k),
                      xRadius: 2 * k, yRadius: 2 * k).fill()

        // Punch the spool holes + tape window out of the body (transparent).
        ctx.compositingOperation = .destinationOut
        let reelR = 2.2 * k
        let reelCY = 7.6 * k
        for reelCX in [5.0 * k, 11.0 * k] {
            NSBezierPath(ovalIn: NSRect(x: reelCX - reelR, y: reelCY - reelR,
                                        width: reelR * 2, height: reelR * 2)).fill()
        }
        // Tape window slot strung between the two spools near the top.
        NSBezierPath(roundedRect: NSRect(x: 4 * k, y: 10.4 * k,
                                         width: 8 * k, height: 1.2 * k),
                     xRadius: 0.6 * k, yRadius: 0.6 * k).fill()

        // Hub dots — re-draw filled so each spool reads as a reel, not a hole.
        ctx.compositingOperation = .sourceOver
        NSColor.black.setFill()
        let hubR = 0.6 * k
        for reelCX in [5.0 * k, 11.0 * k] {
            NSBezierPath(ovalIn: NSRect(x: reelCX - hubR, y: reelCY - hubR,
                                        width: hubR * 2, height: hubR * 2)).fill()
        }
        return img
    }
}