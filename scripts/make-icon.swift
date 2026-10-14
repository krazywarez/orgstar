// Draws orgstar's app icons from the variant table below into the committed asset catalogs:
// ios/Orgstar/Assets.xcassets (iOS app icons and their previews), packaging/AppIcons.xcassets
// (the Mac's icon) and packaging/IconPreviews (the Mac's Dock icons).
// Usage: swift scripts/make-icon.swift
import AppKit

struct Variant {
    enum Style { case filled, outline, unicorn }
    let id: String
    /// The gradient, top-left to bottom-right.
    let top: NSColor, bottom: NSColor
    let glyph: NSColor
    let bars: NSColor
    var style: Style = .filled
}

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let variants: [Variant] = [
    Variant(id: "default", top: NSColor(srgbRed: 0.13, green: 0.20, blue: 0.55, alpha: 1), bottom: NSColor(srgbRed: 0.40, green: 0.22, blue: 0.70, alpha: 1),
            glyph: NSColor(srgbRed: 1, green: 0.78, blue: 0.30, alpha: 1), bars: NSColor(white: 1, alpha: 0.92)),
]

enum Look { case light, dark, tinted }

/// The macOS icon grid: an 824-point rounded square in a 1024 canvas; `fullBleed` fills the
/// canvas, as iOS wants. Dark and tinted leave the background clear (dark) or black (tinted)
/// for the system to fill.
func draw(_ v: Variant, _ size: CGFloat, look: Look = .light, fullBleed: Bool = false) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    if fullBleed {
        let transform = NSAffineTransform()
        transform.scale(by: 1024 / 824)
        transform.translateX(by: -100 * s, yBy: -100 * s)
        transform.concat()
    }
    let square = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = fullBleed ? NSBezierPath(rect: square) : NSBezierPath(roundedRect: square, xRadius: 185 * s, yRadius: 185 * s)
    switch look {
    case .light: NSGradient(colors: [v.top, v.bottom])!.draw(in: shape, angle: -60)
    case .dark: break
    case .tinted: NSColor.black.setFill(); shape.fill()
    }
    let glyph = look == .tinted ? NSColor(white: 0.95, alpha: 1) : v.glyph
    let bars = look == .tinted ? NSColor(white: 0.75, alpha: 1) : v.bars
    switch v.style {
    case .filled: drawOutline(s, glyph: glyph, bars: bars, filled: true)
    case .outline: drawOutline(s, glyph: glyph, bars: bars, filled: false)
    case .unicorn: drawUnicorn(s, glyph: glyph, head: bars)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// The heading star over three outline lines, indented like a heading's children.
func drawOutline(_ s: CGFloat, glyph: NSColor, bars: NSColor, filled: Bool) {
    let star = NSAttributedString(string: "✱", attributes: [
        .font: NSFont.systemFont(ofSize: 330 * s, weight: filled ? .heavy : .light), .foregroundColor: glyph,
    ])
    star.draw(at: NSPoint(x: 190 * s, y: 520 * s))
    for (i, (x, width)) in [(470.0, 330.0), (300.0, 500.0), (380.0, 420.0)].enumerated() {
        let y = (650 - Double(i) * 150) * s
        let line = NSRect(x: x * s, y: y, width: width * s, height: (i == 0 ? 70 : 56) * s)
        let path = NSBezierPath(roundedRect: line, xRadius: 28 * s, yRadius: 28 * s)
        if filled {
            bars.setFill(); path.fill()
        } else {
            bars.setStroke(); path.lineWidth = 10 * s; path.stroke()
        }
    }
}

/// Task 8 draws the unicorn.
func drawUnicorn(_ s: CGFloat, glyph: NSColor, head: NSColor) {
    drawOutline(s, glyph: glyph, bars: head, filled: true)
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

/// Without an alpha channel, as the App Store requires for the light icon.
func opaque(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
    let size = rep.pixelsWide
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: size, height: size))
    return NSBitmapImageRep(cgImage: context.makeImage()!)
}

func write(_ data: Data, _ path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

func json(_ object: Any, _ path: String) throws {
    try write(JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), path)
}

let info = ["author": "xcode", "version": 1] as [String: Any]
let appearances: [(Look, String, [[String: String]])] = [
    (.light, "", []),
    (.dark, "-dark", [["appearance": "luminosity", "value": "dark"]]),
    (.tinted, "-tinted", [["appearance": "luminosity", "value": "tinted"]]),
]

for v in variants {
    // iOS: one set per icon, named AppIcon for the default and AppIcon-<Id> for the others.
    let setName = v.id == "default" ? "AppIcon" : "AppIcon-" + v.id.split(separator: "-").map(\.capitalized).joined()
    let set = "ios/Orgstar/Assets.xcassets/\(setName).appiconset"
    var images: [[String: Any]] = []
    for (look, suffix, appearance) in appearances {
        let rep = draw(v, 1024, look: look, fullBleed: true)
        try write(png(look == .light ? opaque(rep) : rep), "\(set)/AppIcon\(suffix).png")
        var image: [String: Any] = ["filename": "AppIcon\(suffix).png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]
        if !appearance.isEmpty { image["appearances"] = appearance }
        images.append(image)
    }
    try json(["images": images, "info": info], "\(set)/Contents.json")

    // Previews for the iOS picker, light and dark.
    let preview = "ios/Orgstar/Assets.xcassets/IconPreview-\(v.id).imageset"
    try write(png(draw(v, 256, fullBleed: true)), "\(preview)/light.png")
    try write(png(draw(v, 256, look: .dark, fullBleed: true)), "\(preview)/dark.png")
    try json(["images": [
        ["filename": "light.png", "idiom": "universal"],
        ["filename": "dark.png", "idiom": "universal", "appearances": [["appearance": "luminosity", "value": "dark"]]],
    ], "info": info], "\(preview)/Contents.json")

    // The Mac's Dock icons and picker previews.
    try write(png(draw(v, 512)), "packaging/IconPreviews/\(v.id)-light.png")
    try write(png(draw(v, 512, look: .dark)), "packaging/IconPreviews/\(v.id)-dark.png")
}

// The Mac's bundle icon: the default variant at the Mac's sizes, in each appearance.
let mac = "packaging/AppIcons.xcassets/AppIcon.appiconset"
var macImages: [[String: Any]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        for (look, suffix, appearance) in appearances {
            let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "")\(suffix).png"
            try write(png(draw(variants[0], CGFloat(base * scale), look: look)), "\(mac)/\(name)")
            var image: [String: Any] = ["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(base)x\(base)"]
            if !appearance.isEmpty { image["appearances"] = appearance }
            macImages.append(image)
        }
    }
}
try json(["images": macImages, "info": info], "\(mac)/Contents.json")
try json(["info": info], "packaging/AppIcons.xcassets/Contents.json")
