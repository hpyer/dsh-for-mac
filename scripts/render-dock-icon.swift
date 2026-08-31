import AppKit

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: render-dock-icon.swift <source-png> <output-png-or-icns>\n", stderr)
    exit(EXIT_FAILURE)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let whaleImage = NSImage(contentsOf: sourceURL) else {
    fputs("Unable to load source image: \(sourceURL.path)\n", stderr)
    exit(EXIT_FAILURE)
}

do {
    if outputURL.pathExtension.lowercased() == "icns" {
        let iconVariants: [(type: String, pixels: Int)] = [
            ("icp4", 16),
            ("icp5", 32),
            ("ic07", 128),
            ("ic08", 256),
            ("ic09", 512),
            ("ic10", 1_024),
        ]
        var chunks = Data()
        for variant in iconVariants {
            let imageData = try renderedPNGData(size: variant.pixels, image: whaleImage)
            chunks.append(Data(variant.type.utf8))
            chunks.append(bigEndianData(UInt32(imageData.count + 8)))
            chunks.append(imageData)
        }
        var iconData = Data("icns".utf8)
        iconData.append(bigEndianData(UInt32(chunks.count + 8)))
        iconData.append(chunks)
        try iconData.write(to: outputURL, options: .atomic)
    } else {
        try renderedPNGData(size: 1_024, image: whaleImage).write(to: outputURL, options: .atomic)
    }
} catch {
    fputs("Unable to write output image: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}

private func renderedPNGData(size: Int, image: NSImage) throws -> Data {
    let imageSize = NSSize(width: size, height: size)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let outerInset = imageSize.width * 0.10
    let tileRect = NSRect(
        x: outerInset,
        y: outerInset,
        width: imageSize.width - outerInset * 2,
        height: imageSize.height - outerInset * 2
    )
    let background = NSBezierPath(
        roundedRect: tileRect,
        xRadius: tileRect.width * 0.18,
        yRadius: tileRect.width * 0.18
    )
    NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
    background.fill()
    let inset = tileRect.width * 0.10
    image.draw(
        in: NSRect(
            x: tileRect.minX + inset,
            y: tileRect.minY + inset,
            width: tileRect.width - inset * 2,
            height: tileRect.height - inset * 2
        ),
        from: NSRect(origin: .zero, size: image.size),
        operation: .sourceOver,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

private func bigEndianData(_ value: UInt32) -> Data {
    var bigEndianValue = value.bigEndian
    return withUnsafeBytes(of: &bigEndianValue) { Data($0) }
}
