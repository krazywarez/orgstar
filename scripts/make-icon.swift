// Draws Orgstar's app icon and writes an iconset: an outline's heading star over three
// indented lines, on a deep blue-to-violet square. Usage: swift scripts/make-icon.swift <dir.iconset>
import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // The macOS icon grid: an 824-point rounded square in a 1024 canvas.
    let square = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: square, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(srgbRed: 0.13, green: 0.20, blue: 0.55, alpha: 1), NSColor(srgbRed: 0.40, green: 0.22, blue: 0.70, alpha: 1)])!
        .draw(in: shape, angle: -60)
    // The heading star.
    let star = NSAttributedString(string: "✱", attributes: [
        .font: NSFont.systemFont(ofSize: 330 * s, weight: .heavy), .foregroundColor: NSColor(srgbRed: 1, green: 0.78, blue: 0.30, alpha: 1),
    ])
    star.draw(at: NSPoint(x: 190 * s, y: 520 * s))
    // Three outline lines, indented like a heading's children.
    NSColor(white: 1, alpha: 0.92).setFill()
    for (i, (x, width)) in [(470.0, 330.0), (300.0, 500.0), (380.0, 420.0)].enumerated() {
        let y = (650 - Double(i) * 150) * s
        let line = i == 0 ? NSRect(x: x * s, y: y, width: width * s, height: 70 * s) : NSRect(x: x * s, y: y, width: width * s, height: 56 * s)
        NSBezierPath(roundedRect: line, xRadius: 28 * s, yRadius: 28 * s).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = draw(CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try data.write(to: folder.appendingPathComponent(name))
    }
}
