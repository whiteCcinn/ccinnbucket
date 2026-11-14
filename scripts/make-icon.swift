// Renders the CcinnBucket app icon (all macOS iconset sizes) with AppKit.
// Usage: swift scripts/make-icon.swift <output.iconset> [preview.png]
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset> [preview.png]\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// Bucket rim (ring) and three stacked "object" bands, matching `BucketGlyph` in the app.
func bucketPath(in rect: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    path.windingRule = .evenOdd
    let w = rect.width, h = rect.height, x = rect.minX
    // AppKit's origin is bottom-left: convert "top" fractions with y(t) = maxY - t * h.
    func y(_ t: CGFloat) -> CGFloat { rect.maxY - t * h }
    let rim = NSRect(x: x + w * 0.04, y: y(0.30), width: w * 0.92, height: h * 0.22)
    path.appendOval(in: rim)
    path.appendOval(in: rim.insetBy(dx: w * 0.07, dy: h * 0.035))
    let bands: [(CGFloat, CGFloat, CGFloat)] = [(0.30, 0.50, 0.10), (0.53, 0.72, 0.15), (0.75, 0.94, 0.20)]
    for (top, bottom, inset) in bands {
        let topInset = inset - 0.02
        let band = NSBezierPath()
        band.move(to: NSPoint(x: x + w * topInset, y: y(top)))
        band.line(to: NSPoint(x: x + w * (1 - topInset), y: y(top)))
        band.line(to: NSPoint(x: x + w * (1 - inset - 0.02), y: y(bottom)))
        band.curve(to: NSPoint(x: x + w * (inset + 0.02), y: y(bottom)),
                   controlPoint1: NSPoint(x: x + w * 0.66, y: y(bottom + 0.035)),
                   controlPoint2: NSPoint(x: x + w * 0.34, y: y(bottom + 0.035)))
        band.close()
        path.append(band)
    }
    return path
}

func renderIcon(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let scale = CGFloat(pixels) / 1024
    let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let radius = 186 * scale
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // Drop shadow under the squircle.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(srgbRed: 0.02, green: 0.25, blue: 0.48, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // "Lagoon sky" gradient.
    NSGradient(colors: [
        NSColor(srgbRed: 0.22, green: 0.74, blue: 0.97, alpha: 1),
        NSColor(srgbRed: 0.01, green: 0.52, blue: 0.78, alpha: 1),
        NSColor(srgbRed: 0.04, green: 0.22, blue: 0.45, alpha: 1),
    ], atLocations: [0, 0.55, 1], colorSpace: .sRGB)?.draw(in: shape, angle: -55)

    // Soft top highlight and subtle "data ripples".
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])?
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    for ring in 0..<3 {
        let inset = CGFloat(ring) * 90 * scale
        let ringRect = NSRect(x: body.midX - 140 * scale - (420 * scale - inset), y: body.midY - 220 * scale - (420 * scale - inset),
                              width: 2 * (420 * scale - inset), height: 2 * (420 * scale - inset))
        let path = NSBezierPath(ovalIn: ringRect)
        path.lineWidth = 10 * scale
        NSColor.white.withAlphaComponent(0.06).setStroke()
        path.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Bucket glyph.
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    glyphShadow.shadowBlurRadius = 18 * scale
    glyphShadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
    NSGraphicsContext.saveGraphicsState()
    glyphShadow.set()
    NSColor.white.withAlphaComponent(0.96).setFill()
    let glyphSize = 470 * scale
    bucketPath(in: NSRect(x: body.midX - glyphSize / 2, y: body.midY - glyphSize / 2 - 18 * scale, width: glyphSize, height: glyphSize)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in sizes {
    guard let data = renderIcon(pixels: pixels) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(name))
}
if arguments.count >= 3, let preview = renderIcon(pixels: 512) {
    try preview.write(to: URL(fileURLWithPath: arguments[2]))
}
print("wrote \(sizes.count) images to \(outputDirectory.path)")
