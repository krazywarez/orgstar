# Built-in Themes and Alternate App Icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Users pick a built-in light theme and dark theme, and an app icon, in Settings on the Mac and on iOS.

**Architecture:** Palettes are Swift values in `OrgPresentation`: the two Default palettes are today's `ThemeSpec.default` colors, the 14 others are 12 named colors each, mapped onto every slot by one table. Two new `[theme]` settings choose them; `UserConfig.theme` puts them under `theme-file` and `config.toml`'s colors. Icons are drawn by `scripts/make-icon.swift` from a variant table into committed asset catalogs: iOS alternate app icons with dark and tinted appearances, and on the Mac an `actool`-compiled `AppIcon` plus Dock previews set with `NSApp.applicationIconImage`.

**Tech Stack:** Swift 6, SwiftUI, AppKit, UIKit, Swift Testing, `actool`, `xcodebuild`.

**Spec:** `docs/plans/2026-10-14-themes-and-icons-design.md`

## Global constraints

- macOS 26 and iOS 26 only.
- No hand-written Swift file over 1,000 lines (`scripts/check-file-sizes.sh`). `Sources/Orgstar/OrgstarApp.swift` is at 956, so new Mac settings UI goes in new files.
- No SwiftPM resources in `OrgPresentation`: it is linked into app extensions that don't carry resource bundles.
- With `light-theme` and `dark-theme` at their defaults and no other theme settings, every color is what it is today.
- The icon choice is per device, in `UserDefaults` (Mac) or `UIApplication.alternateIconName` (iOS), never in `config.toml`.
- `ios/Orgstar.xcodeproj/project.pbxproj` has uncommitted changes in the working tree that predate this plan. Before Task 8, ask whether to commit or stash them; do not mix them into this branch's commits.
- Commit messages: plain, no trailers.
- Every task ends with `swift build` and `swift test` green, and `scripts/check-file-sizes.sh` passing.

## Decisions

| Question | Decision | Reason |
| --- | --- | --- |
| Palette storage | Swift values in `Sources/OrgPresentation/Palettes.swift` | No resource bundle in extensions; type-checked |
| Ported palettes | 12 named colors through `ThemeSpec.Roles.slots` | A dozen hex values per palette; new slots stay in step |
| Default palettes | `ThemeSpec.default.light` / `.dark` as they are | Zero change to the default look |
| Where the theme ids are read | `UserDefaults` keys `themeLight` / `themeDark`, passed into `UserConfig.theme` like `themeFile` | `UserConfig.apply` has already copied the file into defaults; iOS without a config folder still works |
| Accent fallback | Mac `.controlAccentColor`, iOS `.systemBlue` per appearance | A theme set for one appearance only leaves the other to the system |
| Mac bundle icon | `Assets.car` from `actool`, `CFBundleIconName` | The system's dark and tinted icon styles need a catalog |
| Mac alternate icon | `NSApp.applicationIconImage` from preview PNGs | The only supported way; Dock only, while running |
| Icon PNG check | None | PNG bytes vary with the ImageIO version; the generator is the source |

## Review focus

- A `config.toml` from 0.5.0 with `theme-file` and `[theme.dark]` colors must look the same after upgrading: the layering order is palettes, then `theme-file`, then `config.toml`. Test in Task 4.
- `light-theme = "nord"` (a dark palette in the light key) must report a problem and use Default, not apply Nord to light. Test in Task 4.
- An iOS device with no config folder chosen must still apply a picked theme. Test in Task 4 (`ThemeSpec.base`), used in Task 7.
- Copy to Config Folder must never overwrite an existing `my-theme.toml`. Test in Task 6.
- A Dock icon set at launch must follow a light/dark appearance change while the app runs, and `default` must restore the bundle's icon (`nil`), not a preview PNG. Test in Task 10.

---

### Task 1: Icon pipeline for the default icon (risk check)

Settles both risks in the spec before anything else is drawn: dark and tinted appearances from an `actool`-compiled catalog on macOS 26, and on iOS 26.

**Files:**
- Modify: `scripts/make-icon.swift` (whole file)
- Create: `packaging/AppIcons.xcassets/Contents.json`, `packaging/AppIcons.xcassets/AppIcon.appiconset/*`
- Modify: `ios/Orgstar/Assets.xcassets/AppIcon.appiconset/Contents.json`, add `AppIcon-dark.png`, `AppIcon-tinted.png`
- Modify: `scripts/build-app.sh:60-62`, its Info.plist heredoc (`CFBundleIconFile` → `CFBundleIconName`)

**Interfaces:**
- Produces: `swift scripts/make-icon.swift` with no arguments regenerates every committed icon file. A `Variant` struct and `variants` array that Task 8 extends.

- [ ] **Step 1: Rewrite `make-icon.swift` around a variant table**

```swift
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
```

- [ ] **Step 2: Generate and check the default icon is unchanged**

Run: `swift scripts/make-icon.swift && git diff --stat ios/Orgstar/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
Then open the old and new `AppIcon.png` side by side (`git show HEAD:ios/Orgstar/Assets.xcassets/AppIcon.appiconset/AppIcon.png > /tmp/old.png; open /tmp/old.png ios/Orgstar/Assets.xcassets/AppIcon.appiconset/AppIcon.png`).
Expected: they look the same. The bytes may differ.

- [ ] **Step 3: Compile the Mac catalog in `build-app.sh`**

Replace lines 60–62 (`iconset=…` through `rm -rf "$(dirname "$iconset")"`) with:

```sh
# The icon, in the system's default, dark and tinted styles, and the Dock icons Settings offers.
work="$(mktemp -d)"
xcrun actool packaging/AppIcons.xcassets --compile "$app/Contents/Resources" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist "$work/icon.plist" > /dev/null
rm -rf "$work"
mkdir -p "$app/Contents/Resources/IconPreviews"
cp packaging/IconPreviews/*.png "$app/Contents/Resources/IconPreviews/"
```

In the Info.plist heredoc, replace

```
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
```

with

```
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
```

- [ ] **Step 4: Check on macOS 26**

Run: `scripts/build-app.sh && ls .build/*.app/Contents/Resources/Assets.car && open -R .build/*.app`
In System Settings ▸ Appearance ▸ Icon & widget style, switch between Default, Dark and Tinted, and look at the app in Finder and in the Dock after launching it.
Expected: Dark shows the star and bars on the system's dark background; Tinted shows them tinted.
If Dark and Tinted show the same image as Default, delete the `-dark`/`-tinted` entries from the Mac set in `make-icon.swift` (keep only `look == .light` in the Mac loop), regenerate, and record under Decisions: "Mac bundle icon: default variant only; macOS derives dark and tinted."

- [ ] **Step 5: Check on iOS 26**

Build and run the `Orgstar` scheme from `ios/Orgstar.xcodeproj` on a device or the iOS 26 Simulator. On the home screen, long-press ▸ Edit ▸ Customize, and switch between Dark and Tinted.
Expected: the dark and tinted images show. If not, record that in Decisions and stop before Task 8; ask how to proceed.

- [ ] **Step 6: Commit**

```bash
git add scripts/make-icon.swift scripts/build-app.sh packaging/AppIcons.xcassets packaging/IconPreviews ios/Orgstar/Assets.xcassets
git commit -m "Icons from a variant table, with dark and tinted styles; Mac icon from an asset catalog"
```

---

### Task 2: Palettes, the Default palettes and the accent slot

**Files:**
- Create: `Sources/OrgPresentation/Palettes.swift`
- Modify: `Sources/OrgPresentation/ThemeSpec.swift` (`slots`, `systemDefaults`, `typeKeys`)
- Modify: `Sources/Orgstar/ThemeColors.swift` (`systemColor`)
- Test: `Tests/OrgPresentationTests/PaletteTests.swift`

**Interfaces:**
- Produces:
  - `public struct Palette: Sendable, Equatable { public enum Appearance: String, Sendable { case light, dark }; public let id: String; public let name: String; public let appearance: Appearance; public let colors: [String: RGBA] }`
  - `extension ThemeSpec { public static func palettes(_ appearance: Palette.Appearance) -> [Palette]; public static func palette(_ id: String, _ appearance: Palette.Appearance) -> Palette?; public static func defaultPaletteID(_ appearance: Palette.Appearance) -> String }`
  - Theme slot `accent`, in `systemDefaults`.

- [ ] **Step 1: Write the failing tests**

```swift
import OrgPresentation
import Testing

struct PaletteTests {
    @Test func defaultPalettesAreTheDefaultTheme() throws {
        let light = try #require(ThemeSpec.palette("default-light", .light))
        let dark = try #require(ThemeSpec.palette("default-dark", .dark))
        #expect(light.colors == ThemeSpec.default.light && dark.colors == ThemeSpec.default.dark)
        #expect(light.name == "Default" && ThemeSpec.palettes(.light).first == light && ThemeSpec.palettes(.dark).first == dark)
        #expect(ThemeSpec.defaultPaletteID(.light) == "default-light" && ThemeSpec.defaultPaletteID(.dark) == "default-dark")
    }

    @Test func aPaletteIsFoundOnlyInItsAppearance() {
        #expect(ThemeSpec.palette("default-light", .dark) == nil)
        #expect(ThemeSpec.palette("nope", .light) == nil)
    }

    @Test func accentIsASlotTheDefaultLeavesToTheSystem() {
        #expect(ThemeSpec.slots.contains { $0.key == "accent" })
        #expect(ThemeSpec.systemDefaults.contains("accent"))
        #expect(ThemeSpec.default.light["accent"] == nil && ThemeSpec.default.dark["accent"] == nil)
    }

    @Test func everyPaletteHasExactlyTheSlotKeys() {
        let all = Set(ThemeSpec.slots.map(\.key))
        for palette in ThemeSpec.palettes(.light) + ThemeSpec.palettes(.dark) {
            let expected = palette.id.hasPrefix("default-") ? all.subtracting(ThemeSpec.systemDefaults) : all
            #expect(Set(palette.colors.keys) == expected, "\(palette.id): \(expected.symmetricDifference(palette.colors.keys))")
        }
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter PaletteTests`
Expected: compile error, `Palette` not found.

- [ ] **Step 3: Add the slot**

In `ThemeSpec.slots`, after `("selection", "selected text's background"),` add:

```swift
        ("accent", "buttons, toggles and selection in lists; unset: the system's"),
```

In `systemDefaults` add `"accent"`. In `typeKeys` add `"light-theme", "dark-theme"` (Task 4 uses them; adding them now keeps `[theme] light-theme = …` from being read as a color).

In `Sources/Orgstar/ThemeColors.swift` `systemColor`, add a case before `default`:

```swift
        case "accent": .controlAccentColor
```

- [ ] **Step 4: Write `Palettes.swift`**

```swift
/// A built-in theme for one appearance, chosen with `light-theme` or `dark-theme`.
public struct Palette: Sendable, Equatable {
    public enum Appearance: String, Sendable { case light, dark }

    public let id: String
    public let name: String
    public let appearance: Appearance
    public let colors: [String: RGBA]

    public init(id: String, name: String, appearance: Appearance, colors: [String: RGBA]) {
        self.id = id
        self.name = name
        self.appearance = appearance
        self.colors = colors
    }
}

extension ThemeSpec {
    /// The built-in palettes of `appearance`, Default first.
    public static func palettes(_ appearance: Palette.Appearance) -> [Palette] {
        appearance == .light ? lightPalettes : darkPalettes
    }

    public static func palette(_ id: String, _ appearance: Palette.Appearance) -> Palette? {
        palettes(appearance).first { $0.id == id }
    }

    public static func defaultPaletteID(_ appearance: Palette.Appearance) -> String {
        "default-" + appearance.rawValue
    }

    static let lightPalettes: [Palette] = [
        Palette(id: "default-light", name: "Default", appearance: .light, colors: ThemeSpec.default.light),
    ]

    static let darkPalettes: [Palette] = [
        Palette(id: "default-dark", name: "Default", appearance: .dark, colors: ThemeSpec.default.dark),
    ]
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter PaletteTests && swift test`
Expected: PASS. Existing tests that print `default-theme.toml` gain a commented `# accent = "#rrggbb"` line; if a test compares that text exactly, update its expected text to include the line.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrgPresentation Sources/Orgstar/ThemeColors.swift Tests/OrgPresentationTests/PaletteTests.swift
git commit -m "Palettes, with the default theme as Default; accent theme color"
```

---

### Task 3: The ported palettes

**Files:**
- Modify: `Sources/OrgPresentation/Palettes.swift`
- Modify: `THIRD_PARTY.org`
- Test: `Tests/OrgPresentationTests/PaletteTests.swift`

**Interfaces:**
- Consumes: `Palette`, `ThemeSpec.palettes` (Task 2).
- Produces: `public struct ThemeSpec.Roles` with `public func colors(dark: Bool) -> [String: RGBA]`; 14 more palettes with the ids in the spec.

- [ ] **Step 1: Write the failing tests**

Add to `PaletteTests`:

```swift
    @Test func theCatalogIsInOrder() {
        #expect(ThemeSpec.palettes(.light).map(\.id) == ["default-light", "solarized-light", "gruvbox-light", "modus-operandi", "catppuccin-latte", "tomorrow", "paper"])
        #expect(ThemeSpec.palettes(.dark).map(\.id) == ["default-dark", "solarized-dark", "gruvbox-dark", "modus-vivendi", "catppuccin-mocha", "nord", "dracula", "tokyo-night", "doom-one"])
    }

    /// WCAG 2 contrast ratio.
    static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        func luminance(_ c: RGBA) -> Double {
            func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @Test func textReadsOnTheBackground() throws {
        let body = ["foreground", "table"]
        let marks = ["heading-1", "heading-2", "heading-3", "heading-4", "todo", "todo-next", "todo-waiting", "done", "link", "timestamp", "code",
                     "syntax-keyword", "syntax-string", "syntax-function", "syntax-type", "syntax-number", "syntax-property", "syntax-label"]
        for palette in ThemeSpec.palettes(.light) + ThemeSpec.palettes(.dark) {
            let background = try #require(palette.colors["background"])
            for key in body {
                let ratio = Self.contrast(try #require(palette.colors[key]), background)
                #expect(ratio >= 4.5, "\(palette.id) \(key): \(ratio)")
            }
            for key in marks {
                let ratio = Self.contrast(try #require(palette.colors[key]), background)
                #expect(ratio >= 3, "\(palette.id) \(key): \(ratio)")
            }
        }
    }
```

Add `import Foundation` at the top of the file for `pow`.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter PaletteTests`
Expected: `theCatalogIsInOrder` fails. `textReadsOnTheBackground` passes for Default; if it fails for Default, stop and report the key and ratio: the threshold or the default needs a decision.

- [ ] **Step 3: Add `Roles` and the palettes**

Append to `Palettes.swift`:

```swift
extension ThemeSpec {
    /// A palette's named colors, from which every slot is set.
    public struct Roles: Sendable {
        public var bg, alt, fg, dim, red, orange, yellow, green, cyan, blue, purple, accent: String

        /// Slot → role. `selection` and `inline-background` are translucent roles.
        static let slots: [String: KeyPath<Roles, String>] = [
            "background": \.bg, "foreground": \.fg, "cursor": \.accent, "accent": \.accent,
            "heading-1": \.blue, "heading-2": \.purple, "heading-3": \.green, "heading-4": \.orange,
            "heading-5": \.blue, "heading-6": \.purple, "heading-7": \.green, "heading-8": \.orange,
            "todo": \.red, "todo-next": \.blue, "todo-waiting": \.yellow, "done": \.green, "todo-cancelled": \.dim,
            "priority": \.orange, "priority-a": \.red, "priority-b": \.orange, "priority-c": \.dim,
            "tags": \.dim, "link": \.blue, "timestamp": \.purple, "code": \.orange, "verbatim": \.cyan,
            "markup": \.dim, "comment": \.dim, "keyword": \.dim, "metadata": \.dim, "special": \.cyan,
            "block-background": \.alt, "block-delimiter": \.dim, "table": \.fg,
            "line-number": \.dim, "line-number-current": \.fg,
            "syntax-keyword": \.purple, "syntax-string": \.green, "syntax-comment": \.dim, "syntax-function": \.blue,
            "syntax-type": \.yellow, "syntax-number": \.orange, "syntax-property": \.cyan, "syntax-label": \.purple,
            "sidebar-background": \.alt, "sidebar-foreground": \.fg, "sidebar-header": \.dim,
            "modeline-background": \.alt, "modeline-foreground": \.fg, "modeline-highlight": \.accent,
            "state-normal": \.blue, "state-insert": \.green, "state-visual": \.orange,
            "agenda-background": \.bg, "agenda-date": \.fg, "agenda-today": \.accent, "agenda-time": \.dim, "agenda-category": \.dim,
            "agenda-overdue": \.red, "agenda-due-soon": \.orange, "agenda-event": \.purple,
            "habit-clear": \.blue, "habit-ready": \.green, "habit-alert": \.yellow, "habit-overdue": \.red,
        ]

        /// Alphas are whole bytes (`#…33`, `#…59`), so a palette written out as a theme file
        /// reads back equal.
        public func colors(dark: Bool) -> [String: RGBA] {
            var out = Self.slots.compactMapValues { RGBA(hex: self[keyPath: $0]) }
            if var selection = RGBA(hex: accent) {
                selection.alpha = (dark ? 0x59 : 0x33) / 255
                out["selection"] = selection
            }
            if var inline = RGBA(hex: dim) {
                inline.alpha = 0x33 / 255
                out["inline-background"] = inline
            }
            return out
        }
    }

    private static func ported(_ id: String, _ name: String, _ appearance: Palette.Appearance, _ roles: Roles) -> Palette {
        Palette(id: id, name: name, appearance: appearance, colors: roles.colors(dark: appearance == .dark))
    }
}
```

Replace `lightPalettes` and `darkPalettes` with:

```swift
    // Upstream palettes; see THIRD_PARTY.org. Colors darkened from upstream to read at 3:1 on
    // the background: Solarized Light yellow, green and cyan; Catppuccin Latte orange, yellow
    // and green; Tomorrow orange and yellow.
    static let lightPalettes: [Palette] = [
        Palette(id: "default-light", name: "Default", appearance: .light, colors: ThemeSpec.default.light),
        ported("solarized-light", "Solarized Light", .light, Roles(
            bg: "#fdf6e3", alt: "#eee8d5", fg: "#586e75", dim: "#93a1a1", red: "#dc322f", orange: "#cb4b16", yellow: "#a57c00",
            green: "#738a05", cyan: "#258f86", blue: "#268bd2", purple: "#6c71c4", accent: "#268bd2")),
        ported("gruvbox-light", "Gruvbox Light", .light, Roles(
            bg: "#fbf1c7", alt: "#ebdbb2", fg: "#3c3836", dim: "#928374", red: "#9d0006", orange: "#af3a03", yellow: "#b57614",
            green: "#79740e", cyan: "#427b58", blue: "#076678", purple: "#8f3f71", accent: "#076678")),
        ported("modus-operandi", "Modus Operandi", .light, Roles(
            bg: "#ffffff", alt: "#f2f2f2", fg: "#000000", dim: "#595959", red: "#a60000", orange: "#972500", yellow: "#6f5500",
            green: "#006800", cyan: "#005e8b", blue: "#0031a9", purple: "#721045", accent: "#0031a9")),
        ported("catppuccin-latte", "Catppuccin Latte", .light, Roles(
            bg: "#eff1f5", alt: "#e6e9ef", fg: "#4c4f69", dim: "#8c8fa1", red: "#d20f39", orange: "#d0590a", yellow: "#b06f13",
            green: "#388c24", cyan: "#179299", blue: "#1e66f5", purple: "#8839ef", accent: "#8839ef")),
        ported("tomorrow", "Tomorrow", .light, Roles(
            bg: "#ffffff", alt: "#efefef", fg: "#4d4d4c", dim: "#8e908c", red: "#c82829", orange: "#c76b17", yellow: "#a87e00",
            green: "#718c00", cyan: "#3e999f", blue: "#4271ae", purple: "#8959a8", accent: "#4271ae")),
        // orgstar's own: warm paper and ink, for long reading.
        ported("paper", "Paper", .light, Roles(
            bg: "#f8f3e6", alt: "#efe8d6", fg: "#3b3428", dim: "#7d7262", red: "#a8322d", orange: "#a85a1f", yellow: "#8a6d1a",
            green: "#4d6b2f", cyan: "#2f6b6b", blue: "#2f5486", purple: "#6b4a85", accent: "#a85a1f")),
    ]

    static let darkPalettes: [Palette] = [
        Palette(id: "default-dark", name: "Default", appearance: .dark, colors: ThemeSpec.default.dark),
        ported("solarized-dark", "Solarized Dark", .dark, Roles(
            bg: "#002b36", alt: "#073642", fg: "#93a1a1", dim: "#586e75", red: "#dc322f", orange: "#cb4b16", yellow: "#b58900",
            green: "#859900", cyan: "#2aa198", blue: "#268bd2", purple: "#6c71c4", accent: "#268bd2")),
        ported("gruvbox-dark", "Gruvbox Dark", .dark, Roles(
            bg: "#282828", alt: "#3c3836", fg: "#ebdbb2", dim: "#928374", red: "#fb4934", orange: "#fe8019", yellow: "#fabd2f",
            green: "#b8bb26", cyan: "#8ec07c", blue: "#83a598", purple: "#d3869b", accent: "#83a598")),
        ported("modus-vivendi", "Modus Vivendi", .dark, Roles(
            bg: "#000000", alt: "#1e1e1e", fg: "#ffffff", dim: "#989898", red: "#ff5f59", orange: "#fec43f", yellow: "#d0bc00",
            green: "#44bc44", cyan: "#00d3d0", blue: "#2fafff", purple: "#b6a0ff", accent: "#2fafff")),
        ported("catppuccin-mocha", "Catppuccin Mocha", .dark, Roles(
            bg: "#1e1e2e", alt: "#181825", fg: "#cdd6f4", dim: "#7f849c", red: "#f38ba8", orange: "#fab387", yellow: "#f9e2af",
            green: "#a6e3a1", cyan: "#94e2d5", blue: "#89b4fa", purple: "#cba6f7", accent: "#cba6f7")),
        ported("nord", "Nord", .dark, Roles(
            bg: "#2e3440", alt: "#3b4252", fg: "#d8dee9", dim: "#616e88", red: "#bf616a", orange: "#d08770", yellow: "#ebcb8b",
            green: "#a3be8c", cyan: "#8fbcbb", blue: "#88c0d0", purple: "#b48ead", accent: "#88c0d0")),
        ported("dracula", "Dracula", .dark, Roles(
            bg: "#282a36", alt: "#44475a", fg: "#f8f8f2", dim: "#6272a4", red: "#ff5555", orange: "#ffb86c", yellow: "#f1fa8c",
            green: "#50fa7b", cyan: "#8be9fd", blue: "#8be9fd", purple: "#bd93f9", accent: "#bd93f9")),
        ported("tokyo-night", "Tokyo Night", .dark, Roles(
            bg: "#1a1b26", alt: "#16161e", fg: "#c0caf5", dim: "#565f89", red: "#f7768e", orange: "#ff9e64", yellow: "#e0af68",
            green: "#9ece6a", cyan: "#7dcfff", blue: "#7aa2f7", purple: "#bb9af7", accent: "#7aa2f7")),
        ported("doom-one", "doom-one", .dark, Roles(
            bg: "#282c34", alt: "#21242b", fg: "#bbc2cf", dim: "#5b6268", red: "#ff6c6b", orange: "#da8548", yellow: "#ecbe7b",
            green: "#98be65", cyan: "#46d9ff", blue: "#51afef", purple: "#c678dd", accent: "#51afef")),
    ]
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter PaletteTests`
Expected: PASS. If `everyPaletteHasExactlyTheSlotKeys` names a key, add it to `Roles.slots`.

- [ ] **Step 5: Record the sources in `THIRD_PARTY.org`**

Add a heading `* Color themes` listing, one line each, the palette, its upstream URL and license:

```org
* Color themes
The built-in palettes in =Sources/OrgPresentation/Palettes.swift= take their colors from:
- Solarized, https://ethanschoonover.com/solarized/, MIT
- Gruvbox, https://github.com/morhetz/gruvbox, MIT
- Modus themes, https://protesilaos.com/emacs/modus-themes, GPL-3.0-or-later (colors only)
- Catppuccin, https://github.com/catppuccin/catppuccin, MIT
- Tomorrow, https://github.com/chriskempson/tomorrow-theme, MIT
- Nord, https://www.nordtheme.com, MIT
- Dracula, https://draculatheme.com, MIT
- Tokyo Night, https://github.com/folke/tokyonight.nvim, Apache-2.0
- doom-one, https://github.com/doomemacs/themes, MIT
```

Check each license on the upstream page before committing; if any differs, correct the line, and if one is not MIT, Apache or BSD, stop and report it.

- [ ] **Step 6: Commit**

```bash
git add Sources/OrgPresentation/Palettes.swift Tests/OrgPresentationTests/PaletteTests.swift THIRD_PARTY.org
git commit -m "Fourteen built-in palettes, with a contrast test"
```

---

### Task 4: `light-theme` and `dark-theme`

**Files:**
- Modify: `Sources/OrgPresentation/Palettes.swift`
- Modify: `Sources/OrgApp/UserConfig.swift:29-49` (`theme`), the `settings` array after `theme-file`
- Modify: `Sources/OrgApp/ConfigSync.swift` (`readTheme`)
- Modify: `Sources/OrgstarMobile/MobileModel.swift` (`readConfig`)
- Test: `Tests/OrgPresentationTests/PaletteTests.swift`, `Tests/OrgAppTests/UserConfigTests.swift`

**Interfaces:**
- Consumes: `ThemeSpec.palette`, `defaultPaletteID` (Task 2).
- Produces:
  - `extension ThemeSpec { public static func base(light: String?, dark: String?) -> (ThemeSpec, [String]) }`
  - `UserConfig.theme(config:themeFile:lightTheme:darkTheme:in:read:)`, both new parameters `String?`, defaulting to `nil`.
  - Settings with defaults keys `themeLight` and `themeDark`.

- [ ] **Step 1: Write the failing tests**

In `PaletteTests`:

```swift
    @Test func baseTakesEachAppearanceFromItsPalette() throws {
        let (spec, problems) = ThemeSpec.base(light: "paper", dark: "nord")
        #expect(problems.isEmpty)
        #expect(spec.light == ThemeSpec.palette("paper", .light)?.colors && spec.dark == ThemeSpec.palette("nord", .dark)?.colors)
        #expect(ThemeSpec.base(light: nil, dark: nil).0 == ThemeSpec.default)
        #expect(ThemeSpec.base(light: "", dark: "").0 == ThemeSpec.default)
    }

    @Test func aPaletteOfTheOtherAppearanceIsAProblem() {
        let (spec, problems) = ThemeSpec.base(light: "nord", dark: "unknown")
        #expect(spec == ThemeSpec.default)
        #expect(problems == ["config.toml: unknown light-theme nord", "config.toml: unknown dark-theme unknown"])
    }
```

In `UserConfigTests`:

```swift
    @Test func chosenPalettesSitUnderTheThemeFileAndConfig() throws {
        let name = "orgstar-palette-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "[theme.dark]\nlink = \"#000001\"\n".write(to: folder.appendingPathComponent("mine.toml"), atomically: true, encoding: .utf8)
        try "[theme]\nlight-theme = \"paper\"\ndark-theme = \"nord\"\ntheme-file = \"mine.toml\"\n[theme.dark]\ntodo = \"#000002\"\n"
            .write(to: folder.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let sync = ConfigSync(url: folder.appendingPathComponent("config.toml"), defaults: defaults)
        sync.start(watch: false)
        #expect(sync.problems.isEmpty, "\(sync.problems)")
        #expect(defaults.string(forKey: "themeLight") == "paper" && defaults.string(forKey: "themeDark") == "nord")
        let nord = try #require(ThemeSpec.palette("nord", .dark))
        #expect(sync.theme.light["background"] == ThemeSpec.palette("paper", .light)?.colors["background"])
        #expect(sync.theme.dark["background"] == nord.colors["background"])
        #expect(sync.theme.dark["link"]?.hex == "#000001")
        #expect(sync.theme.dark["todo"]?.hex == "#000002")
    }

    @Test func noThemeSettingsGiveTheDefaultTheme() throws {
        let folder = FileManager.default.temporaryDirectory
        let theme = try #require(UserConfig.theme(config: "", themeFile: nil, lightTheme: nil, darkTheme: nil, in: folder))
        #expect(theme.theme == ThemeSpec.default && theme.problems.isEmpty)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter "PaletteTests|UserConfigTests"`
Expected: compile errors for `base` and the new `theme` parameters.

- [ ] **Step 3: Implement `ThemeSpec.base`**

Append to the first `extension ThemeSpec` in `Palettes.swift`:

```swift
    /// The default theme with each appearance's colors from the palette `light-theme` and
    /// `dark-theme` name; Default where one is unset or unknown, with a problem for unknown.
    public static func base(light: String?, dark: String?) -> (ThemeSpec, [String]) {
        var spec = ThemeSpec.default
        var problems: [String] = []
        for (id, appearance) in [(light, Palette.Appearance.light), (dark, .dark)] {
            guard let id, !id.isEmpty, id != defaultPaletteID(appearance) else { continue }
            guard let palette = palette(id, appearance) else {
                problems.append("config.toml: unknown \(appearance.rawValue)-theme \(id)")
                continue
            }
            if appearance == .light { spec.light = palette.colors } else { spec.dark = palette.colors }
        }
        return (spec, problems)
    }
```

- [ ] **Step 4: Use it in `UserConfig.theme`**

Change the signature and body:

```swift
    public static func theme(
        config text: String, themeFile name: String?, lightTheme: String? = nil, darkTheme: String? = nil, in folder: URL,
        read: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
    ) -> (theme: ThemeSpec, problems: [String])? {
        guard let tables = try? TOML.parse(text) else { return nil }
        var (spec, problems) = ThemeSpec.base(light: lightTheme, dark: darkTheme)
        if let name, !name.isEmpty {
            if let themeText = read(folder.appendingPathComponent(name)) {
                do {
                    let (read, more) = ThemeSpec.reading(try TOML.parse(themeText), over: spec, file: name)
                    spec = read
                    problems += more
                } catch {
                    problems.append("\(name): \(error)")
                }
            } else {
                problems.append("config.toml: theme-file \(name) can't be read")
            }
        }
        let (merged, more) = ThemeSpec.reading(tables, over: spec)
        return (merged, problems + more)
    }
```

Update the doc comment above it to: "The theme `config.toml` (`text`) sets: its `[theme]` tables' colors over those of `theme-file` (a path relative to `folder`), over the palettes `light-theme` and `dark-theme` name; with problems in all three. Nil when `text` isn't TOML."

After the `theme-file` entry in `settings`, add:

```swift
        Setting(section: "theme", key: "light-theme", defaultsKey: "themeLight", kind: .string, fallback: .string("default-light"),
                comment: "the built-in theme for the light appearance: default-light, solarized-light, gruvbox-light, modus-operandi, catppuccin-latte, tomorrow or paper", legacy: ""),
        Setting(section: "theme", key: "dark-theme", defaultsKey: "themeDark", kind: .string, fallback: .string("default-dark"),
                comment: "the built-in theme for the dark appearance: default-dark, solarized-dark, gruvbox-dark, modus-vivendi, catppuccin-mocha, nord, dracula, tokyo-night or doom-one", legacy: ""),
```

- [ ] **Step 5: Pass the settings from both callers**

`ConfigSync.readTheme`:

```swift
        guard let text, let read = UserConfig.theme(
            config: text, themeFile: defaults.string(forKey: "themeFile"),
            lightTheme: defaults.string(forKey: "themeLight"), darkTheme: defaults.string(forKey: "themeDark"),
            in: url.deletingLastPathComponent()
        ) else { return }
```

`MobileModel.readConfig`, so a device without a config folder still applies a chosen palette:

```swift
    private static func readConfig(_ folder: URL?) -> ([String], ThemeSpec) {
        let defaults = UserDefaults.standard
        guard let folder else {
            let (base, problems) = ThemeSpec.base(light: defaults.string(forKey: "themeLight"), dark: defaults.string(forKey: "themeDark"))
            return (problems, base)
        }
        guard let text = read(folder.appendingPathComponent("config.toml")) else {
            return (["No config.toml in \(folder.lastPathComponent); the defaults apply."], .default)
        }
        let problems = UserConfig.apply(text, to: defaults)
        guard let theme = UserConfig.theme(
            config: text, themeFile: defaults.string(forKey: "themeFile"),
            lightTheme: defaults.string(forKey: "themeLight"), darkTheme: defaults.string(forKey: "themeDark"), in: folder, read: read
        ) else {
            return (problems, .default)
        }
        return (problems + theme.problems, theme.theme)
    }
```

- [ ] **Step 6: Run the tests**

Run: `swift test && xcodebuild -scheme OrgstarMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/ios build -quiet`
Expected: PASS and the iOS build succeeds. A test that compares the full `config.toml` template text gains the two new lines; update its expected text.

- [ ] **Step 7: Commit**

```bash
git add Sources/OrgPresentation/Palettes.swift Sources/OrgApp Sources/OrgstarMobile/MobileModel.swift Tests
git commit -m "light-theme and dark-theme settings, under theme-file and config.toml colors"
```

---

### Task 5: Accent tint

**Files:**
- Modify: `Sources/Orgstar/OrgstarApp.swift:339,353,361,368` (scene roots)
- Modify: `Sources/OrgstarMobile/MobileTheme.swift` (append extension)
- Modify: `Sources/OrgstarMobile/OrgstarMobileApp.swift` (root `TabView`)

**Interfaces:**
- Consumes: `accent` slot (Task 2); Mac `ThemeSpec.color(_:) -> Color?` in `ThemeColors.swift`.
- Produces: iOS `extension ThemeSpec { var accentColor: Color? }`.

- [ ] **Step 1: Mac**

On each of the four lines `.environment(\.orgTheme, ConfigSync.shared.theme)` at OrgstarApp.swift:339, 353, 361, 368, add on the following line:

```swift
                    .tint(ConfigSync.shared.theme.color("accent"))
```

`color` returns nil when no palette sets `accent`, which leaves the system's tint.

- [ ] **Step 2: iOS**

Append to `MobileTheme.swift`, inside `#if os(iOS)`:

```swift
extension ThemeSpec {
    /// `accent` for `.tint`, the system's blue in an appearance the theme leaves it unset; nil
    /// when neither appearance sets it.
    var accentColor: Color? {
        let (light, dark) = (light["accent"], dark["accent"])
        guard light != nil || dark != nil else { return nil }
        return Color(uiColor: UIColor { traits in
            guard let c = traits.userInterfaceStyle == .dark ? dark : light else { return .systemBlue }
            return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        })
    }
}
```

In `OrgstarMobileApp.swift`, after `.clockAccessory(model.clock, perform: clock)` on the root `TabView`, add:

```swift
        .tint(model.theme.accentColor)
```

- [ ] **Step 3: Check by hand**

Run: `swift build && scripts/build-app.sh`, open the app, set `dark-theme = "dracula"` under `[theme]` in `~/.config/orgstar/config.toml`, switch to dark appearance.
Expected: toggles and the sidebar's selection turn Dracula purple; in light appearance they stay the system accent.

- [ ] **Step 4: Commit**

```bash
git add Sources/Orgstar/OrgstarApp.swift Sources/OrgstarMobile/MobileTheme.swift Sources/OrgstarMobile/OrgstarMobileApp.swift
git commit -m "Theme accent tints controls"
```

---

### Task 6: Mac theme picker and Copy to Config Folder

**Files:**
- Create: `Sources/Orgstar/ThemePickerSection.swift`
- Modify: `Sources/OrgPresentation/Palettes.swift` (`themeFile(light:dark:)`)
- Modify: `Sources/Orgstar/OrgstarApp.swift:776-778` (first section of `appearance`)
- Test: `Tests/OrgPresentationTests/PaletteTests.swift`

**Interfaces:**
- Consumes: `ThemeSpec.palettes`, `palette`, `defaultPaletteID`; settings `themeLight`, `themeDark`, `themeFile`.
- Produces: `extension ThemeSpec { public static func themeFile(light: Palette, dark: Palette) -> String }`; `struct ThemePickerSection: View`.

- [ ] **Step 1: Write the failing test**

```swift
    @Test func aCopiedThemeReadsBackAsThePalettes() throws {
        let light = try #require(ThemeSpec.palette("paper", .light))
        let dark = try #require(ThemeSpec.palette("nord", .dark))
        let text = ThemeSpec.themeFile(light: light, dark: dark)
        #expect(text.hasPrefix("# Paper and Nord, copied from orgstar's built-in themes."))
        let (spec, problems) = ThemeSpec.reading(try TOML.parse(text))
        #expect(problems.isEmpty, "\(problems)")
        #expect(spec.light.filter { light.colors[$0.key] != nil } == light.colors && spec.dark.filter { dark.colors[$0.key] != nil } == dark.colors)
    }
```

Add `import OrgCore` to the test file for `TOML`.

- [ ] **Step 2: Run it to see it fail**

Run: `swift test --filter PaletteTests/aCopiedThemeReadsBackAsThePalettes`
Expected: compile error, `themeFile(light:dark:)` not found.

- [ ] **Step 3: Implement `themeFile`**

Append to `Palettes.swift`:

```swift
extension ThemeSpec {
    /// Two palettes as a theme file, every color written out, in slot order.
    public static func themeFile(light: Palette, dark: Palette) -> String {
        var out = "# \(light.name) and \(dark.name), copied from orgstar's built-in themes. Used with\n"
            + "# theme-file = \"my-theme.toml\" under [theme] in config.toml; colors there apply on top.\n"
        for (table, palette) in [("theme.light", light), ("theme.dark", dark)] {
            out += "\n[\(table)]\n"
            for slot in slots {
                if let color = palette.colors[slot.key] { out += "\(slot.key) = \"\(color.hex)\"\n" }
            }
        }
        return out
    }
}
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter PaletteTests`
Expected: PASS.

- [ ] **Step 5: Write `ThemePickerSection.swift`**

```swift
import AppKit
import OrgApp
import OrgPresentation
import SwiftUI

/// Settings ▸ Appearance ▸ Theme: the built-in palette for each appearance.
struct ThemePickerSection: View {
    @AppStorage("themeLight") private var themeLight = "default-light"
    @AppStorage("themeDark") private var themeDark = "default-dark"
    @AppStorage("themeFile") private var themeFile = ""
    @State private var message: String?

    var body: some View {
        Section {
            picker("Light", .light, $themeLight)
            picker("Dark", .dark, $themeDark)
            LabeledContent("Starting point") {
                Button("Copy to Config Folder") { copy() }
            }
        } header: {
            Text("Theme")
        } footer: {
            Text(message ?? "Colors set in config.toml or in the theme file apply on top of these.")
                .settingsFooter()
        }
    }

    private func picker(_ title: LocalizedStringKey, _ appearance: Palette.Appearance, _ selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ThemeSpec.palettes(appearance), id: \.id) { palette in
                Label { Text(palette.name) } icon: { Image(nsImage: Self.swatch(palette)) }.tag(palette.id)
            }
            if ThemeSpec.palette(selection.wrappedValue, appearance) == nil {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
        }
    }

    /// Background, text, heading, TODO and accent, side by side.
    static func swatch(_ palette: Palette) -> NSImage {
        let keys = ["background", "foreground", "heading-1", "todo", "accent"]
        return NSImage(size: NSSize(width: 40, height: 12), flipped: false) { rect in
            for (i, key) in keys.enumerated() {
                let c = palette.colors[key] ?? palette.colors["cursor"] ?? RGBA(red: 0.5, green: 0.5, blue: 0.5)
                NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1).setFill()
                NSRect(x: CGFloat(i) * 8, y: 0, width: 8, height: rect.height).fill()
            }
            NSColor.separatorColor.setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
    }

    private func copy() {
        let file = UserConfig.directory.appendingPathComponent("my-theme.toml")
        guard !FileManager.default.fileExists(atPath: file.path) else {
            message = String(localized: "my-theme.toml is already in the config folder; it was left as it is.")
            return
        }
        let light = ThemeSpec.palette(themeLight, .light) ?? ThemeSpec.palettes(.light)[0]
        let dark = ThemeSpec.palette(themeDark, .dark) ?? ThemeSpec.palettes(.dark)[0]
        do {
            try ThemeSpec.themeFile(light: light, dark: dark).write(to: file, atomically: true, encoding: .utf8)
            themeFile = "my-theme.toml"
            message = String(localized: "Copied to my-theme.toml, now the theme file.")
        } catch {
            message = error.localizedDescription
        }
    }
}
```

If `settingsFooter()` is `private` in `OrgstarApp.swift`, make it `internal` (drop `private`) so this file can use it.

- [ ] **Step 6: Insert the section**

In `OrgstarApp.swift`, in `private var appearance: some View`, make the first line inside `Form {`:

```swift
            ThemePickerSection()
```

- [ ] **Step 7: Check by hand**

Run: `scripts/check-file-sizes.sh && scripts/build-app.sh`, open Settings ▸ Appearance.
Expected: Light and Dark menus list the palettes with swatches; choosing one recolors the open editor at once and writes `light-theme`/`dark-theme` into `config.toml`; Copy to Config Folder writes `my-theme.toml` once and on the second press shows the "already in the config folder" message without changing the file.

- [ ] **Step 8: Commit**

```bash
git add Sources/Orgstar Sources/OrgPresentation/Palettes.swift Tests/OrgPresentationTests/PaletteTests.swift
git commit -m "Theme pickers in Settings ▸ Appearance; Copy to Config Folder"
```

---

### Task 7: iOS theme picker

**Files:**
- Create: `Sources/OrgstarMobile/ThemePickerScreen.swift`
- Modify: `Sources/OrgstarMobile/SettingsScreen.swift` (new section before `calendarSection`; "In use ▸ Theme")

**Interfaces:**
- Consumes: `ThemeSpec.palettes`, `palette`; `MobileModel.set(_:to:)`, `model.settingsVersion`.
- Produces: `struct ThemePickerScreen: View { init(model: MobileModel, appearance: Palette.Appearance) }`; `ThemePickerScreen.current(_:) -> Palette`.

- [ ] **Step 1: Write `ThemePickerScreen.swift`**

```swift
#if os(iOS)
import OrgCore
import OrgPresentation
import SwiftUI

/// The built-in palettes of one appearance, each as a few lines of Org in its colors.
struct ThemePickerScreen: View {
    let model: MobileModel
    let appearance: Palette.Appearance

    var body: some View {
        let _ = model.settingsVersion
        let current = Self.current(appearance).id
        List(ThemeSpec.palettes(appearance), id: \.id) { palette in
            Button {
                model.set(appearance == .light ? "themeLight" : "themeDark", to: .string(palette.id))
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(palette.name).foregroundStyle(.primary)
                        Self.sample(palette)
                    }
                    Spacer()
                    if palette.id == current { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
        }
        .navigationTitle(appearance == .light ? "Light Theme" : "Dark Theme")
    }

    /// The palette `light-theme` or `dark-theme` names, Default when unknown.
    static func current(_ appearance: Palette.Appearance) -> Palette {
        let id = UserDefaults.standard.string(forKey: appearance == .light ? "themeLight" : "themeDark") ?? ""
        return ThemeSpec.palette(id, appearance) ?? ThemeSpec.palettes(appearance)[0]
    }

    private static func sample(_ palette: Palette) -> some View {
        func color(_ key: String) -> Color {
            guard let c = palette.colors[key] else { return .primary }
            return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
        }
        let font = Font.system(.footnote, design: .monospaced)
        return VStack(alignment: .leading, spacing: 2) {
            (Text("* ").foregroundColor(color("heading-1")) + Text("TODO ").foregroundColor(color("todo")).bold()
                + Text("Plan the trip ").foregroundColor(color("heading-1")).bold() + Text(":travel:").foregroundColor(color("tags")))
            (Text("  SCHEDULED: ").foregroundColor(color("metadata")) + Text("<2026-10-20 Tue>").foregroundColor(color("timestamp")))
            (Text("  Book via ").foregroundColor(color("foreground")) + Text("the site").foregroundColor(color("link")).underline()
                + Text(", ").foregroundColor(color("foreground")) + Text("~code~").foregroundColor(color("code")))
            (Text("** ").foregroundColor(color("heading-2")) + Text("DONE ").foregroundColor(color("done")).bold()
                + Text("Passport").foregroundColor(color("heading-2")).bold())
        }
        .font(font)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color("background"), in: RoundedRectangle(cornerRadius: 8))
    }
}
#endif
```

- [ ] **Step 2: Add the section to `SettingsScreen`**

Before `calendarSection` in `body`:

```swift
            Section("Appearance") {
                let _ = model.settingsVersion
                NavigationLink {
                    ThemePickerScreen(model: model, appearance: .light)
                } label: {
                    LabeledContent("Light Theme", value: ThemePickerScreen.current(.light).name)
                }
                NavigationLink {
                    ThemePickerScreen(model: model, appearance: .dark)
                } label: {
                    LabeledContent("Dark Theme", value: ThemePickerScreen.current(.dark).name)
                }
            }
```

Replace the "In use" Theme row with:

```swift
                LabeledContent("Theme", value: themeInUse)
```

and add to `SettingsScreen`:

```swift
    /// The two palettes' names, and the theme file's when there is one.
    private var themeInUse: String {
        let names = "\(ThemePickerScreen.current(.light).name) / \(ThemePickerScreen.current(.dark).name)"
        guard let file = UserDefaults.standard.string(forKey: "themeFile"), !file.isEmpty else { return names }
        return "\(names), \(file)"
    }
```

- [ ] **Step 3: Build and check**

Run: `xcodebuild -scheme OrgstarMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/ios build -quiet && scripts/build-ios-app.sh && xcrun simctl install booted .build/ios-app/orgstar.app`
Open Settings ▸ Light Theme, pick Paper, go back to an open file.
Expected: the file shows Paper's colors; with a config folder set, its `config.toml` has `light-theme = "paper"`; without one, the choice still applies.

- [ ] **Step 4: Commit**

```bash
git add Sources/OrgstarMobile
git commit -m "Theme pickers in the iOS Settings tab"
```

---

### Task 8: The other twelve icons, as iOS alternates

Before this task: ask about the pre-existing uncommitted change to `project.pbxproj` (Global constraints).

**Files:**
- Modify: `scripts/make-icon.swift` (`variants`, `drawUnicorn`)
- Modify: `ios/Orgstar.xcodeproj/project.pbxproj` (the `Orgstar` app target's Debug and Release build settings, beside `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;` at lines 792 and 816; confirm those two belong to the `Orgstar` target, not the Watch)
- Generated: `ios/Orgstar/Assets.xcassets/AppIcon-*.appiconset`, `IconPreview-*.imageset`, `packaging/IconPreviews/*`

**Interfaces:**
- Consumes: `Variant`, `draw` (Task 1).
- Produces: icon ids `default midnight paper org sunset forest mono rainbow outline terminal unicorn unicorn-night unicorn-pastel`; iOS alternate names `AppIcon-<Id>` with the id in CamelCase (`AppIcon-UnicornNight`).

- [ ] **Step 1: Add the variants**

Append to `variants`:

```swift
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
```

For `rainbow`, the two-color gradient is a placeholder for the stripes; in `draw`, `case .light:`, draw stripes when `v.id == "rainbow"`:

```swift
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
```

Put this case before the plain `case .light:`.

- [ ] **Step 2: Draw the unicorn**

Replace `drawUnicorn` with a head in profile facing left, its horn rising to the upper left, the ✱ at the horn's tip. Coordinates are on the 1024 grid, origin bottom-left:

```swift
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
```

- [ ] **Step 3: Generate and look at every icon**

Run: `swift scripts/make-icon.swift && open packaging/IconPreviews`
Expected: 26 previews. Check each at Finder's largest icon size and at 64 pixels: the star reads in every one; the unicorn reads as a unicorn's head with the star at the horn's tip. Adjust the unicorn's control points in Step 2 until it does, keeping the shape inside the 100–924 square with margin.

- [ ] **Step 4: Make every `AppIcon-*` set an alternate**

In `project.pbxproj`, in the `Orgstar` target's Debug and Release `buildSettings`, add beside `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;`:

```
				ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES;
```

- [ ] **Step 5: Build and check the alternates compile in**

Run: `xcodebuild -project ios/Orgstar.xcodeproj -scheme Orgstar -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/ios-xc build -quiet && /usr/libexec/PlistBuddy -c 'Print :CFBundleIcons~ipad:CFBundleAlternateIcons' .build/ios-xc/Build/Products/Debug-iphonesimulator/Orgstar.app/Info.plist`
Expected: 12 entries, `AppIcon-Midnight` through `AppIcon-UnicornPastel`. If the product's path or name differs, find it with `find .build/ios-xc -name Info.plist -path '*Orgstar.app/*' -maxdepth 6`.

- [ ] **Step 6: Commit**

```bash
git add scripts/make-icon.swift ios/Orgstar/Assets.xcassets packaging/IconPreviews ios/Orgstar.xcodeproj/project.pbxproj
git commit -m "Twelve more app icons, three of them unicorns; iOS alternate icons"
```

Stage only this task's hunks of `project.pbxproj` (`git add -p`) if the earlier uncommitted change is still in the file.

---

### Task 9: iOS icon picker

**Files:**
- Create: `Sources/OrgPresentation/AppIcons.swift`
- Create: `Sources/OrgstarMobile/AppIconScreen.swift`
- Modify: `Sources/OrgstarMobile/SettingsScreen.swift` ("Appearance" section)
- Test: `Tests/OrgPresentationTests/PaletteTests.swift`

**Interfaces:**
- Produces: `public enum AppIcons { public static let ids: [String]; public static func name(_ id: String) -> String; public static func alternateName(_ id: String) -> String?; public static func id(alternateName: String?) -> String }`

- [ ] **Step 1: Write the failing test**

```swift
    @Test func iconIdsMapToAlternateNames() {
        #expect(AppIcons.ids.first == "default" && AppIcons.ids.count == 13)
        #expect(AppIcons.alternateName("default") == nil)
        #expect(AppIcons.alternateName("unicorn-night") == "AppIcon-UnicornNight")
        #expect(AppIcons.id(alternateName: "AppIcon-UnicornNight") == "unicorn-night")
        #expect(AppIcons.id(alternateName: nil) == "default" && AppIcons.id(alternateName: "AppIcon-Gone") == "default")
        #expect(AppIcons.name("unicorn-pastel") == "Unicorn Pastel")
    }
```

- [ ] **Step 2: Run it to see it fail**

Run: `swift test --filter PaletteTests/iconIdsMapToAlternateNames`
Expected: compile error, `AppIcons` not found.

- [ ] **Step 3: Write `AppIcons.swift`**

```swift
/// The app icons `scripts/make-icon.swift` draws, by id, in its order.
public enum AppIcons {
    public static let ids = [
        "default", "midnight", "paper", "org", "sunset", "forest", "mono", "rainbow", "outline", "terminal",
        "unicorn", "unicorn-night", "unicorn-pastel",
    ]

    private static func words(_ id: String) -> [String] { id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() } }

    public static func name(_ id: String) -> String { words(id).joined(separator: " ") }

    /// The iOS alternate icon's name; nil for the primary icon.
    public static func alternateName(_ id: String) -> String? {
        id == "default" ? nil : "AppIcon-" + words(id).joined()
    }

    public static func id(alternateName: String?) -> String {
        ids.first { self.alternateName($0) == alternateName && alternateName != nil } ?? "default"
    }
}
```

- [ ] **Step 4: Run the test**

Run: `swift test --filter PaletteTests`
Expected: PASS.

- [ ] **Step 5: Write `AppIconScreen.swift`**

```swift
#if os(iOS)
import OrgPresentation
import SwiftUI
import UIKit

/// The app icons, as previews; tapping one makes it the home screen's icon.
struct AppIconScreen: View {
    @State private var current = AppIcons.id(alternateName: UIApplication.shared.alternateIconName)
    @State private var failure: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 16)], spacing: 20) {
                ForEach(AppIcons.ids, id: \.self) { id in
                    Button { choose(id) } label: {
                        VStack(spacing: 6) {
                            Image("IconPreview-\(id)")
                                .resizable()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(id == current ? Color.accentColor : .clear, lineWidth: 3).padding(-4))
                            Text(AppIcons.name(id)).font(.caption).foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(id == current ? .isSelected : [])
                }
            }
            .padding()
            if let failure { Text(failure).foregroundStyle(.red).padding(.horizontal) }
        }
        .navigationTitle("App Icon")
    }

    private func choose(_ id: String) {
        guard id != current, UIApplication.shared.supportsAlternateIcons else { return }
        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(AppIcons.alternateName(id))
                current = id
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
#endif
```

`Image("IconPreview-<id>")` reads from the app's asset catalog, which the Xcode project builds; the SwiftPM simulator build (`build-ios-app.sh`) has no catalog, so the previews are blank there. Check this screen through the Xcode project.

- [ ] **Step 6: Add the row**

In `SettingsScreen`'s "Appearance" section, after the Dark Theme link:

```swift
                NavigationLink {
                    AppIconScreen()
                } label: {
                    LabeledContent("App Icon", value: AppIcons.name(AppIcons.id(alternateName: UIApplication.shared.alternateIconName)))
                }
```

- [ ] **Step 7: Check on iOS 26**

Run the `Orgstar` scheme from Xcode on a device or simulator; Settings ▸ App Icon ▸ Unicorn.
Expected: the system alert names the change, the home screen shows the unicorn, and the grid marks Unicorn after reopening the screen. In Customize ▸ Dark and Tinted, the unicorn's dark and tinted versions show.

- [ ] **Step 8: Commit**

```bash
git add Sources/OrgPresentation/AppIcons.swift Sources/OrgstarMobile Tests/OrgPresentationTests/PaletteTests.swift
git commit -m "App icon picker in the iOS Settings tab"
```

---

### Task 10: Mac icon picker and Dock icon

**Files:**
- Create: `Sources/Orgstar/DockIcon.swift`
- Create: `Sources/Orgstar/AppIconSection.swift`
- Modify: `Sources/Orgstar/OrgstarApp.swift` (`AppDelegate.applicationDidFinishLaunching`, `appearance` form)
- Test: `Tests/OrgAppTests/DockIconTests.swift` (only if `DockIcon`'s pure part lives in `OrgApp`; see Step 1)

**Interfaces:**
- Consumes: `AppIcons` (Task 9); `Contents/Resources/IconPreviews/<id>-light.png` / `-dark.png` (Task 1).
- Produces: `@MainActor enum DockIcon { static func previewName(_ id: String, dark: Bool) -> String?; static func apply(); static func start() }`, defaults key `appIcon`.

- [ ] **Step 1: Write the failing test**

`Orgstar` is an executable target that tests can't import, so the choice of file goes in `OrgPresentation` beside `AppIcons`, and is tested there. Add to `AppIcons.swift`:

```swift
extension AppIcons {
    /// The Mac's Dock icon file for `id` in an appearance, in `Contents/Resources/IconPreviews`;
    /// nil for the default, which is the bundle's own icon.
    public static func dockFile(_ id: String, dark: Bool) -> String? {
        guard id != "default", ids.contains(id) else { return nil }
        return "\(id)-\(dark ? "dark" : "light")"
    }
}
```

and first the test in `PaletteTests`:

```swift
    @Test func dockFilesFollowTheAppearance() {
        #expect(AppIcons.dockFile("default", dark: true) == nil)
        #expect(AppIcons.dockFile("gone", dark: false) == nil)
        #expect(AppIcons.dockFile("unicorn", dark: false) == "unicorn-light")
        #expect(AppIcons.dockFile("unicorn", dark: true) == "unicorn-dark")
    }
```

- [ ] **Step 2: Run it to see it fail, then add the extension and see it pass**

Run: `swift test --filter PaletteTests/dockFilesFollowTheAppearance` (fails: no `dockFile`), add the extension, run again.
Expected: PASS.

- [ ] **Step 3: Write `DockIcon.swift`**

```swift
import AppKit
import OrgPresentation

/// The icon chosen in Settings ▸ Appearance, shown in the Dock while orgstar runs, in the
/// variant for the current appearance.
@MainActor
enum DockIcon {
    private static var observation: NSKeyValueObservation?

    static func apply() {
        let id = UserDefaults.standard.string(forKey: "appIcon") ?? "default"
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard let file = AppIcons.dockFile(id, dark: dark),
              let url = Bundle.main.url(forResource: file, withExtension: "png", subdirectory: "IconPreviews") else {
            NSApp.applicationIconImage = nil
            return
        }
        NSApp.applicationIconImage = NSImage(contentsOf: url)
    }

    /// Applies now, and again whenever the appearance changes.
    static func start() {
        apply()
        observation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in apply() }
        }
    }
}
```

- [ ] **Step 4: Start it at launch**

In `AppDelegate.applicationDidFinishLaunching`, add as its first line:

```swift
        DockIcon.start()
```

- [ ] **Step 5: Write `AppIconSection.swift`**

```swift
import AppKit
import OrgPresentation
import SwiftUI

/// Settings ▸ Appearance ▸ App Icon: the icon the Dock shows while orgstar runs.
struct AppIconSection: View {
    @AppStorage("appIcon") private var appIcon = "default"

    var body: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 12) {
                ForEach(AppIcons.ids, id: \.self) { id in
                    Button {
                        appIcon = id
                        DockIcon.apply()
                    } label: {
                        VStack(spacing: 4) {
                            preview(id)
                                .resizable()
                                .frame(width: 56, height: 56)
                                .padding(4)
                                .background(id == appIcon ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            Text(AppIcons.name(id)).font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(id == appIcon ? .isSelected : [])
                }
            }
        } header: {
            Text("App Icon")
        } footer: {
            Text("The icon shows in the Dock while orgstar runs. Finder, and the Dock after orgstar quits, show the default icon.")
                .settingsFooter()
        }
    }

    private func preview(_ id: String) -> Image {
        let url = Bundle.main.url(forResource: "\(id)-light", withExtension: "png", subdirectory: "IconPreviews")
        return url.flatMap { NSImage(contentsOf: $0) }.map { Image(nsImage: $0) } ?? Image(nsImage: NSApp.applicationIconImage)
    }
}
```

- [ ] **Step 6: Insert the section**

In `OrgstarApp.swift`'s `appearance` form, after `ThemePickerSection()`:

```swift
            AppIconSection()
```

The Appearance tab's `.frame(height: 380)` is now too short; change it to `.frame(height: 620)` and check it scrolls rather than clips.

- [ ] **Step 7: Check by hand**

Run: `scripts/check-file-sizes.sh && scripts/build-app.sh`, open the app, Settings ▸ Appearance ▸ App Icon ▸ Unicorn Night.
Expected: the Dock icon changes at once; switching the system appearance swaps the light and dark previews while running; Default restores the bundle's icon (its dark and tinted styles included); after quitting and reopening, the chosen icon comes back once the app has launched.

- [ ] **Step 8: Commit**

```bash
git add Sources/Orgstar Sources/OrgPresentation/AppIcons.swift Tests/OrgPresentationTests/PaletteTests.swift
git commit -m "App icon picker in Settings ▸ Appearance; Dock icon follows the appearance"
```

---

### Task 11: Manual and strings

**Files:**
- Modify: `docs/manual/guide/02-the-editor.org:33,341`
- Modify: `docs/manual/guide/13-configuration.org` (the theme section)
- Modify: `docs/manual/guide/14-ios.org:83,398`
- Modify: `l10n/Localizable.xcstrings`

- [ ] **Step 1: Manual**

`02-the-editor.org:341`, replace the paragraph with:

```org
Settings ▸ Appearance ▸ Theme chooses a built-in theme for the light appearance and one for the dark: Default, Solarized Light, Gruvbox Light, Modus Operandi, Catppuccin Latte, Tomorrow or Paper; and Default, Solarized Dark, Gruvbox Dark, Modus Vivendi, Catppuccin Mocha, Nord, Dracula, Tokyo Night or doom-one. They are =light-theme= and =dark-theme= under =[theme]= in =config.toml=. Colours set in =config.toml=, under =[theme]= for both appearances, =[theme.light]= and =[theme.dark]= for one and =[theme.todo]= for TODO keywords, apply on top, as do those of a theme file named by =theme-file=. Copy to Config Folder writes the two chosen themes, every colour, into =my-theme.toml= and makes it the theme file, to start a theme of your own. Show Default Theme opens =default-theme.toml=, which lists every colour with its default value. Changes apply while orgstar runs. See [[file:13-configuration.org][Configuration]].

Settings ▸ Appearance ▸ App Icon chooses the icon the Dock shows while orgstar runs. Finder, and the Dock once orgstar has quit, show the default icon; it follows the system's icon style (Default, Dark or Tinted).
```

`13-configuration.org`: in the section on themes, add `light-theme`, `dark-theme` and `accent` with the stacking order "the chosen palettes, then the theme file, then =config.toml=". Read the section first and match its table or list form.

`14-ios.org:83`, replace "stacked as on the Mac: the default theme, then the theme file" with "stacked as on the Mac: the themes chosen with =light-theme= and =dark-theme=, then the theme file". After that paragraph add:

```org
Settings ▸ Light Theme and Dark Theme choose the built-in themes, shown as a few lines of Org in each theme's colours; the choice is written to the configuration folder's =config.toml=, so the Mac uses it too. Settings ▸ App Icon chooses the home screen icon from the same thirteen as the Mac; iOS confirms the change. The icon is chosen per device.
```

`14-ios.org:398`: replace "the theme (=Default=, or the theme file's name)" with "the light and dark themes, and the theme file's name when there is one".

- [ ] **Step 2: Strings**

Run: `scripts/sync-strings.sh`
Then add German translations in `l10n/Localizable.xcstrings` for each new key (as commit 880a7cf did for the October 13 strings): Theme → Design, Light → Hell, Dark → Dunkel, Light Theme → Helles Design, Dark Theme → Dunkles Design, App Icon → App-Symbol, Starting point → Ausgangspunkt, Copy to Config Folder → In den Konfigurationsordner kopieren, and the footers and messages in full sentences. Palette and icon names stay untranslated.

- [ ] **Step 3: Check**

Run: `swift test && scripts/check-file-sizes.sh && scripts/build-app.sh`
Open Settings with the system language set to German and check the new rows.
Expected: all green; German labels show.

- [ ] **Step 4: Commit**

```bash
git add docs/manual l10n
git commit -m "Manual and German strings for themes and app icons"
```

---

### Finish

- [ ] Run `swift test`, `scripts/check-file-sizes.sh`, `scripts/build-app.sh` and the iOS Xcode build once more.
- [ ] Push the branch and open the merge request: `git push -u origin themes-and-icons && gitbay mr create --source themes-and-icons --target main --title "Built-in themes and alternate app icons"`.
