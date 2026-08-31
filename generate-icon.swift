#!/usr/bin/env swift
import Cocoa

// Generates TabSwipe.iconset — three white fingers and a swipe bar on a blue
// rounded rect. Geometry is a direct port of the hero icon on czbz.ai/tabswipe,
// so the app and the download page show the same mark.
//
// Every coordinate below is in the SVG's 96x96 space and converted by `pt`.
// SVG's origin is top-left and AppKit's is bottom-left, hence the y flip.

let canvas: CGFloat = 96

func renderIcon(pixels: Int) -> Data? {
    // Draw into an explicitly sized bitmap rather than NSImage.lockFocus():
    // lockFocus() adopts the main display's backing scale, which silently
    // yields 2x-sized PNGs on a Retina Mac and corrupts the iconset.
    guard
        let rep = NSBitmapImageRep(
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
        )
    else { return nil }

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.shouldAntialias = true
    ctx.imageInterpolation = .high

    let u = CGFloat(pixels) / canvas
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: x * u, y: (canvas - y) * u)
    }

    // Background: rect x=6 y=6 w=84 h=84 rx=22, #60a5fa -> #2563eb diagonally.
    let bg = NSBezierPath(
        roundedRect: NSRect(x: 6 * u, y: 6 * u, width: 84 * u, height: 84 * u),
        xRadius: 22 * u,
        yRadius: 22 * u
    )
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.376, green: 0.647, blue: 0.980, alpha: 1),
        ending: NSColor(srgbRed: 0.145, green: 0.388, blue: 0.922, alpha: 1)
    )!
    // -45deg runs top-left to bottom-right, matching the SVG's (6,6)->(90,90).
    gradient.draw(in: bg, angle: -45)

    func stroke(
        from a: NSPoint, to b: NSPoint, width: CGFloat, alpha: CGFloat
    ) {
        let path = NSBezierPath()
        path.move(to: a)
        path.line(to: b)
        path.lineWidth = width * u
        path.lineCapStyle = .round
        NSColor(white: 1, alpha: alpha).setStroke()
        path.stroke()
    }

    // Three fingers, bottoms aligned at y=58, middle one reaching higher.
    stroke(from: pt(34, 40), to: pt(34, 58), width: 4.5, alpha: 0.95)
    stroke(from: pt(48, 34), to: pt(48, 58), width: 4.5, alpha: 0.95)
    stroke(from: pt(62, 40), to: pt(62, 58), width: 4.5, alpha: 0.95)

    // The trackpad the fingers swipe across.
    stroke(from: pt(28, 70), to: pt(68, 70), width: 3.5, alpha: 0.4)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// iconutil only accepts these exact filenames. Several point sizes share a
// pixel size (a 32px render is both 32x32 and 16x16@2x), so map explicitly
// rather than deriving names in a loop.
let outputs: [(pixels: Int, names: [String])] = [
    (16, ["icon_16x16.png"]),
    (32, ["icon_16x16@2x.png", "icon_32x32.png"]),
    (64, ["icon_32x32@2x.png"]),
    (128, ["icon_128x128.png"]),
    (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
    (512, ["icon_256x256@2x.png", "icon_512x512.png"]),
    (1024, ["icon_512x512@2x.png"]),
]

let iconsetPath = "/tmp/TabSwipe.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try! fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

for (pixels, names) in outputs {
    guard let png = renderIcon(pixels: pixels) else {
        FileHandle.standardError.write("Failed to render \(pixels)px\n".data(using: .utf8)!)
        exit(1)
    }
    for name in names {
        try! png.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name)"))
    }
}

print("Generated iconset at \(iconsetPath)")
