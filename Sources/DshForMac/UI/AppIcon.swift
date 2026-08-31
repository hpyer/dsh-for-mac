import AppKit

enum AppIcon {
    static func image() -> NSImage? {
        guard let whaleImage = dockWhaleImage() else { return nil }
        let iconSize = NSSize(width: 1_024, height: 1_024)
        let icon = NSImage(size: iconSize)
        icon.lockFocus()
        defer { icon.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        let outerInset = iconSize.width * 0.10
        let tileRect = NSRect(
            x: outerInset,
            y: outerInset,
            width: iconSize.width - outerInset * 2,
            height: iconSize.height - outerInset * 2
        )

        let background = NSBezierPath(
            roundedRect: tileRect,
            xRadius: tileRect.width * 0.18,
            yRadius: tileRect.width * 0.18
        )
        NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
        background.fill()
        let inset = tileRect.width * 0.10
        whaleImage.draw(
            in: NSRect(
                x: tileRect.minX + inset,
                y: tileRect.minY + inset,
                width: tileRect.width - inset * 2,
                height: tileRect.height - inset * 2
            ),
            from: NSRect(origin: .zero, size: whaleImage.size),
            operation: .sourceOver,
            fraction: 1
        )
        return icon
    }

    static func menuBarImage() -> NSImage? {
        guard let image = whaleImage()?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 20, height: 20)
        image.isTemplate = true
        return image
    }

    private static func whaleImage() -> NSImage? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        return NSImage(contentsOf: resourceURL.appendingPathComponent("dsh-whale.png"))
    }

    private static func dockWhaleImage() -> NSImage? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        return NSImage(contentsOf: resourceURL.appendingPathComponent("dsh-whale-dock.png"))
    }
}
