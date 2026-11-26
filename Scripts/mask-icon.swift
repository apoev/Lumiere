import AppKit
import CoreGraphics
import Foundation

// macOS app icon is a squircle (superellipse n≈5) that touches the mid-edges
// of the canvas. Legacy .icns is shown as-is, so the mask has to be baked in.
// A plain square icns stays square in the Dock and looks larger than system icons.

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("usage: mask-icon icon.png AppIcon.iconset\n", stderr)
    exit(1)
}

let sourceURL = URL(fileURLWithPath: args[1])
let iconsetURL = URL(fileURLWithPath: args[2])
guard let source = NSImage(contentsOf: sourceURL) else {
    fputs("не открылся \(sourceURL.path)\n", stderr)
    exit(1)
}

let slots: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for (name, pixels) in slots {
    let image = maskedIcon(source, pixels: pixels)
    guard let png = pngData(image) else {
        fputs("не собрался PNG \(name)\n", stderr)
        exit(1)
    }
    try png.write(to: iconsetURL.appendingPathComponent(name))
}

func maskedIcon(_ source: NSImage, pixels: Int) -> NSImage {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return NSImage(size: NSSize(width: size, height: size))
    }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.addPath(squirclePath(size: size))
        ctx.clip()
        source.draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}

/// System icns (Weather and the rest) keep the squircle inside the canvas:
/// about 9% of transparent margin, so the Dock tile matches other apps.
/// Shape is a superellipse n=5, the macOS app-icon mask.
func squirclePath(size: CGFloat) -> CGPath {
    let inset = size * (23.0 / 256.0)
    let inner = size - inset * 2
    let n: CGFloat = 5
    let steps = 128
    let radius = inner / 2
    let path = CGMutablePath()
    for step in 0...steps * 4 {
        let t = (CGFloat(step) / CGFloat(steps * 4)) * 2 * .pi
        let point = superellipse(t, n: n, radius: radius)
        let canvas = CGPoint(x: point.x + size / 2, y: point.y + size / 2)
        if step == 0 {
            path.move(to: canvas)
        } else {
            path.addLine(to: canvas)
        }
    }
    path.closeSubpath()
    return path
}

func superellipse(_ t: CGFloat, n: CGFloat, radius: CGFloat) -> CGPoint {
    let cosine = cos(t)
    let sine = sin(t)
    let exponent = 2 / n
    let x = radius * pow(abs(cosine), exponent) * (cosine < 0 ? -1 : 1)
    let y = radius * pow(abs(sine), exponent) * (sine < 0 ? -1 : 1)
    return CGPoint(x: x, y: y)
}

func pngData(_ image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff)
    else { return nil }
    rep.size = image.size
    return rep.representation(using: .png, properties: [:])
}
