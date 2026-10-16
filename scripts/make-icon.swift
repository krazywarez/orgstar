// Draws orgstar's app icons from the variant table below into the committed asset catalogs:
// ios/Orgstar/Assets.xcassets (iOS app icons and their previews), packaging/AppIcons.xcassets
// (the Mac's icon) and packaging/IconPreviews (the Mac's Dock icons).
// Usage: swift scripts/make-icon.swift
import AppKit

struct Variant {
    enum Style { case filled, outline, star }
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
    Variant(id: "unicorn", top: rgb(0x77aa99), bottom: rgb(0x3e7a6a), glyph: rgb(0xffc74d), bars: .white, style: .star),
    Variant(id: "unicorn-night", top: rgb(0x2b2a6b), bottom: rgb(0x14133a), glyph: rgb(0xd8dde6), bars: rgb(0xeae8ff), style: .star),
    Variant(id: "unicorn-pastel", top: rgb(0xffc6dd), bottom: rgb(0xc7b8ff), glyph: rgb(0xffc74d), bars: .white, style: .star),
]

/// `dark`: the icon's background darkened, so each icon keeps its color in the system's Dark
/// icon style and the Mac's dark Dock; `tinted`: a grayscale glyph on black for the system to tint.
enum Look { case light, dark, tinted }

/// The macOS icon grid: an 824-point rounded square in a 1024 canvas; `fullBleed` fills the
/// canvas, as iOS wants.
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
    // The dark look's background: the light one's colors most of the way to black, light
    // ones (Paper, Outline, Pastel) further, so every tile ends up about as dark.
    func shade(_ color: NSColor) -> NSColor {
        guard look == .dark, let c = color.usingColorSpace(.sRGB) else { return color }
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return c.blended(withFraction: luminance > 0.6 ? 0.8 : 0.7, of: .black)!
    }
    switch look {
    case .light where v.id == "rainbow", .dark where v.id == "rainbow":
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let stripes = [0xe40303, 0xff8c00, 0xffed00, 0x008026, 0x004dff, 0x750787].map(rgb)
        let band = square.height / CGFloat(stripes.count)
        for (i, color) in stripes.enumerated() {
            shade(color).setFill()
            NSRect(x: square.minX, y: square.maxY - band * CGFloat(i + 1), width: square.width, height: band).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    case .light, .dark: NSGradient(colors: [shade(v.top), shade(v.bottom)])!.draw(in: shape, angle: -60)
    case .tinted: NSColor.black.setFill(); shape.fill()
    }
    // On a dark background a dark or mid-tone glyph (Paper, Outline) is drawn light.
    func lifted(_ color: NSColor, _ light: CGFloat) -> NSColor {
        guard look == .dark, let c = color.usingColorSpace(.sRGB),
              0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent < 0.5 else { return color }
        return NSColor(white: light, alpha: 1)
    }
    let glyph = look == .tinted ? NSColor(white: 0.95, alpha: 1) : lifted(v.glyph, 0.95)
    let bars = look == .tinted ? NSColor(white: 0.75, alpha: 1) : lifted(v.bars, 0.8)
    switch v.style {
    case .filled: drawOutline(s, glyph: glyph, bars: bars, filled: true)
    case .outline: drawOutline(s, glyph: glyph, bars: bars, filled: false)
    case .star: drawStar(s, glyph: glyph)
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

/// The heading star alone, filling the tile: the glyph's outline, centred and scaled to fit.
func drawStar(_ s: CGFloat, glyph: NSColor) {
    // The font the system draws ✱ in; the system font itself has no such glyph.
    let font = CTFontCreateForString(NSFont.systemFont(ofSize: 100, weight: .heavy) as CTFont, "✱" as CFString, CFRange(location: 0, length: 1))
    var character: UniChar = 0x2731
    var glyphID: CGGlyph = 0
    CTFontGetGlyphsForCharacters(font, &character, &glyphID, 1)
    guard let outline = CTFontCreatePathForGlyph(font, glyphID, nil) else { return }
    let bounds = outline.boundingBoxOfPath
    let scale = 560 * s / max(bounds.width, bounds.height)
    var transform = CGAffineTransform(translationX: 512 * s, y: 512 * s)
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -bounds.midX, y: -bounds.midY)
    guard let placed = outline.copy(using: &transform), let context = NSGraphicsContext.current?.cgContext else { return }
    context.addPath(placed)
    context.setFillColor(glyph.cgColor)
    context.fillPath()
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

    // The iOS picker's preview: the icon in color in both appearances, so each can be told apart.
    let preview = "ios/Orgstar/Assets.xcassets/IconPreview-\(v.id).imageset"
    try? FileManager.default.removeItem(atPath: preview)
    try write(png(draw(v, 256, fullBleed: true)), "\(preview)/light.png")
    try json(["images": [["filename": "light.png", "idiom": "universal"]], "info": info], "\(preview)/Contents.json")

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
