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
    Variant(id: "midnight", top: rgb(0x1a1d24), bottom: rgb(0x0b0c10), glyph: rgb(0xffc74d), bars: NSColor(white: 1, alpha: 0.85)),
    Variant(id: "paper", top: rgb(0xfbf8f1), bottom: rgb(0xece4d2), glyph: rgb(0x3b3428), bars: rgb(0x7d7262)),
    Variant(id: "org", top: rgb(0x77aa99), bottom: rgb(0x3e7a6a), glyph: rgb(0xffc74d), bars: NSColor(white: 1, alpha: 0.92)),
    Variant(id: "sunset", top: rgb(0xff9a3c), bottom: rgb(0xe23e7a), glyph: .white, bars: NSColor(white: 1, alpha: 0.85)),
    Variant(id: "forest", top: rgb(0x2f5d3a), bottom: rgb(0x173322), glyph: rgb(0xf4ecd0), bars: NSColor(white: 1, alpha: 0.8)),
    Variant(id: "mono", top: rgb(0x5a5d63), bottom: rgb(0x2c2e33), glyph: .white, bars: NSColor(white: 1, alpha: 0.8)),
    Variant(id: "rainbow", top: rgb(0xe40303), bottom: rgb(0x732982), glyph: .white, bars: NSColor(white: 1, alpha: 0.9)),
    Variant(id: "outline", top: .white, bottom: rgb(0xf2f2f2), glyph: rgb(0x2f5486), bars: rgb(0x2f5486), style: .outline),
    Variant(id: "terminal", top: rgb(0x0a0f0a), bottom: .black, glyph: rgb(0x39ff6a), bars: rgb(0x2bcc55)),
    Variant(id: "unicorn", top: rgb(0x77aa99), bottom: rgb(0x3e7a6a), glyph: rgb(0xffc74d), bars: .white, style: .unicorn),
    Variant(id: "unicorn-night", top: rgb(0x2b2a6b), bottom: rgb(0x14133a), glyph: rgb(0xd8dde6), bars: rgb(0xeae8ff), style: .unicorn),
    Variant(id: "unicorn-pastel", top: rgb(0xffc6dd), bottom: rgb(0xc7b8ff), glyph: rgb(0xffc74d), bars: .white, style: .unicorn),
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
    case .light where v.id == "rainbow":
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let stripes = [0xe40303, 0xff8c00, 0xffed00, 0x008026, 0x004dff, 0x750787].map(rgb)
        let band = square.height / CGFloat(stripes.count)
        for (i, color) in stripes.enumerated() {
            color.setFill()
            NSRect(x: square.minX, y: square.maxY - band * CGFloat(i + 1), width: square.width, height: band).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
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

/// A unicorn's head in profile, facing left, with a mane; its horn ends in the heading star.
func drawUnicorn(_ s: CGFloat, glyph: NSColor, head: NSColor) {
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }
    let face = NSBezierPath()
    face.move(to: p(640, 200))                                                    // neck, back
    face.curve(to: p(600, 560), controlPoint1: p(700, 330), controlPoint2: p(690, 480))
    face.curve(to: p(470, 640), controlPoint1: p(560, 610), controlPoint2: p(520, 640))  // crown
    face.line(to: p(440, 690))                                                    // ear
    face.line(to: p(410, 620))
    face.curve(to: p(250, 470), controlPoint1: p(340, 590), controlPoint2: p(270, 530))  // brow to nose
    face.curve(to: p(290, 400), controlPoint1: p(235, 430), controlPoint2: p(250, 400))  // muzzle
    face.curve(to: p(430, 430), controlPoint1: p(340, 400), controlPoint2: p(390, 410))  // jaw
    face.curve(to: p(450, 200), controlPoint1: p(470, 360), controlPoint2: p(440, 280))  // throat
    face.close()
    head.setFill()
    face.fill()

    let mane = NSBezierPath()
    mane.move(to: p(600, 560))
    mane.curve(to: p(760, 220), controlPoint1: p(720, 520), controlPoint2: p(800, 360))
    mane.line(to: p(690, 210))
    mane.curve(to: p(600, 520), controlPoint1: p(730, 330), controlPoint2: p(680, 470))
    mane.close()
    glyph.withAlphaComponent(0.85).setFill()
    mane.fill()

    let horn = NSBezierPath()
    horn.move(to: p(440, 640))
    horn.line(to: p(300, 790))
    horn.line(to: p(475, 660))
    horn.close()
    head.blended(withFraction: 0.25, of: glyph)?.setFill()
    horn.fill()

    let eye = NSBezierPath(ovalIn: NSRect(x: 360 * s, y: 520 * s, width: 28 * s, height: 28 * s))
    NSColor(white: 0.15, alpha: 1).setFill()
    eye.fill()

    let star = NSAttributedString(string: "✱", attributes: [.font: NSFont.systemFont(ofSize: 190 * s, weight: .heavy), .foregroundColor: glyph])
    star.draw(at: p(205, 700))
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

// The Mac's bundle icon: the default variant at the Mac's sizes. actool drops dark and
// tinted renditions from a macOS app icon set, so macOS derives those styles itself.
let mac = "packaging/AppIcons.xcassets/AppIcon.appiconset"
try? FileManager.default.removeItem(atPath: mac)
var macImages: [[String: Any]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try write(png(draw(variants[0], CGFloat(base * scale))), "\(mac)/\(name)")
        macImages.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(base)x\(base)"])
    }
}
try json(["images": macImages, "info": info], "\(mac)/Contents.json")
try json(["info": info], "packaging/AppIcons.xcassets/Contents.json")
