#!/usr/bin/env swift
import Cocoa

// Generate TabSwipe app icon: 3 white fingers on a blue rounded-rect background

func renderIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    // Background: rounded rect with gradient
    let bgRect = NSRect(x: 0, y: 0, width: s, height: s)
    let cornerRadius = s * 0.22
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Blue gradient background
    let gradient = NSGradient(
        starting: NSColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0),
        ending: NSColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1.0)
    )!
    gradient.draw(in: bgPath, angle: -90)

    // Draw 3 white fingers
    NSColor.white.setFill()

    let fingerWidth = s * 0.13
    let fingerRadius = fingerWidth / 2
    let gap = s * 0.06
    let totalWidth = 3 * fingerWidth + 2 * gap
    let startX = (s - totalWidth) / 2
    let heights: [CGFloat] = [s * 0.38, s * 0.48, s * 0.38]
    let centerY = s * 0.5

    for i in 0..<3 {
        let x = startX + CGFloat(i) * (fingerWidth + gap)
        let h = heights[i]
        let y = centerY - h / 2
        let fingerRect = NSRect(x: x, y: y, width: fingerWidth, height: h)
        let path = NSBezierPath(roundedRect: fingerRect, xRadius: fingerRadius, yRadius: fingerRadius)
        path.fill()
    }

    image.unlockFocus()
    return image
}

// Required sizes for .iconset
let sizes = [16, 32, 64, 128, 256, 512, 1024]

let iconsetPath = "/tmp/TabSwipe.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try! fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

for size in sizes {
    let image = renderIcon(size: size)

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { continue }

    // Standard resolution
    if size <= 512 {
        let filename = "icon_\(size)x\(size).png"
        try! png.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(filename)"))
    }

    // @2x resolution (half the point size)
    let halfSize = size / 2
    if halfSize >= 16 && halfSize <= 512 {
        let filename = "icon_\(halfSize)x\(halfSize)@2x.png"
        try! png.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(filename)"))
    }
}

print("Generated iconset at \(iconsetPath)")
