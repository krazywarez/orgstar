import Foundation
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
}
